# export-to-cos — golden image → IBM Cloud Object Storage

Generic, image-agnostic pipeline that takes any DataVolume in the
`openshift-virtualization-os-images` catalog and publishes it to IBM
Cloud Object Storage as a compressed `qcow2`.

The same approach can be run as a one-shot procedure (no Tekton) for
ad-hoc validation — see [One-shot procedure](#one-shot-procedure) below.

## How it works

1. **clone-for-export** — clone the source PVC into the `image-export`
   namespace, **matching the source's volumeMode** (Block on the
   default `ocs-storagecluster-ceph-rbd-virtualization` storage class).
   CDI's populator-based clone path requires source/destination to
   share volume mode; cross-mode clones leave the destination PVC
   `Pending` with `IncompatibleVolumeModes`.
2. **convert-and-upload** — a Kubernetes Job runs:
   - init container (default: `alpine:3.19`) — installs `qemu-img` via
     apk if missing, then
     `qemu-img convert -f raw -O qcow2 -c /dev/source-disk /work/out.qcow2`.
     The clone PVC is mounted as a block device via `volumeDevices`,
     so qemu-img reads `/dev/source-disk` directly.
   - main container (`amazon/aws-cli`) →
     `aws --endpoint-url $COS_ENDPOINT s3 cp /work/out.qcow2 s3://$bucket/$key`
3. **cleanup-export** (in `finally`) — delete the clone DataVolume
   regardless of pipeline outcome.

The export Job retains for 1 hour (`ttlSecondsAfterFinished`) so logs
remain available after the pipeline ends.

The convert init container runs as `runAsUser: 0` — needed to read the
mounted block device and to install `qemu-img` at runtime if the chosen
image doesn't ship it. The privileged SCC required for that is granted
**only** to a dedicated SA `image-export-job` (used solely as the
Job pod's `serviceAccountName`). The pipeline SA `image-export-pipeline`
that runs the Tekton TaskRuns themselves stays on restricted SCC. The
upload container runs unprivileged.

## Prerequisites

### One-time cluster setup

```bash
source .env
ibmcloud oc cluster config --cluster nrt-prod-cluster1 --admin
oc config current-context  # MUST be the production context

oc apply -f manifests/export-to-cos/pipeline/pipeline-rbac.yaml
oc apply -f manifests/export-to-cos/pipeline/pipeline.yaml
oc apply -f manifests/export-to-cos/pipeline/pipeline-register-vpc-image.yaml
```

This creates:
- `image-export` namespace
- `image-export-pipeline` SA — runs the Tekton TaskRuns; restricted SCC
- `image-export-job` SA — used **only** by the export Job pod;
  has the `privileged` SCC
- Cluster-scoped permissions to drive CDI clones and manage the export Job
- Tekton `Pipeline export-image-to-cos` — image → COS
- Tekton `Pipeline register-vpc-custom-image` — COS → VPC custom image

### COS HMAC credentials Secret

The pipeline reads HMAC credentials from a Secret in `image-export`.
Create it once per environment (it is **not** committed to git):

```bash
oc create secret generic cos-hmac \
  -n image-export \
  --from-literal=access_key_id=<HMAC access key> \
  --from-literal=secret_access_key=<HMAC secret>
```

If you use a Secret with a different name, set `cosSecretName` on the
PipelineRun.

### CDI cross-namespace clone permission

The clone task creates a CDI DataVolume in `image-export` with
`source.pvc` referencing `openshift-virtualization-os-images`. The
`cdi-cloner` cluster-scoped permission set installed by OpenShift
Virtualization usually allows this by default. If the clone fails with
a permissions error, grant explicitly:

```bash
oc create rolebinding image-export-cdi-cloner \
  -n openshift-virtualization-os-images \
  --clusterrole=cdi-cloner \
  --serviceaccount=image-export:image-export-pipeline
```

## Run the pipeline

```bash
# Edit pipelinerun.yaml first -- bucket name, endpoint, region, key.
oc create -f manifests/export-to-cos/pipeline/pipelinerun.yaml

RUN=$(oc get pipelinerun -n image-export \
  --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1].metadata.name}')

tkn pipelinerun logs $RUN -n image-export -f
```

Verify the upload:

```bash
aws --endpoint-url https://s3.eu-de.cloud-object-storage.appdomain.cloud \
  --region eu-de \
  s3api head-object \
  --bucket "$BUCKET" \
  --key vyos-rolling.qcow2
```

## Expected runtime

For a 4 Gi VyOS golden image: ~3-5 minutes. Dominated by the CDI clone
(~1-2 min on Ceph RBD) and the qcow2 conversion (~30 s). Upload is
small because qcow2 is sparse + zlib-compressed.

For larger images (Windows, ~30+ Gi virtual disk): expect 15-30 minutes
total, with conversion and multipart upload taking the bulk of the time.
Bump `cloneSize` and `scratchSize` accordingly on the PipelineRun.

## Parameters

| Param | Default | Notes |
|---|---|---|
| `sourceDataVolume` | — | DV name in catalog, e.g. `vyos-rolling` |
| `sourceNamespace` | `openshift-virtualization-os-images` | |
| `cosSecretName` | `cos-hmac` | Must contain `access_key_id` + `secret_access_key` |
| `cosEndpoint` | — | e.g. `https://s3.eu-de.cloud-object-storage.appdomain.cloud` |
| `cosRegion` | — | e.g. `eu-de` |
| `cosBucket` | — | Target bucket |
| `cosObjectKey` | `<sourceDataVolume>.qcow2` | Object key |
| `cloneStorageClass` | `ocs-storagecluster-ceph-rbd-virtualization` | |
| `cloneSize` | `40Gi` | Storage request for clone PVC |
| `scratchSize` | `40Gi` | sizeLimit for emptyDir holding qcow2 |
| `imageQemuTools` | `quay.io/containerdisks/qemu-tools:latest` | |
| `imageAwsCli` | `docker.io/amazon/aws-cli:latest` | |

## One-shot procedure

Equivalent steps without Tekton — useful for validating the approach
before wiring up the pipeline, or for one-off exports.

```bash
source .env
ibmcloud oc cluster config --cluster nrt-prod-cluster1 --admin
oc config current-context  # MUST be the production context

# 0. namespace + secret (skip if already done)
oc new-project image-export
oc create secret generic cos-hmac \
  -n image-export \
  --from-literal=access_key_id=<HMAC access key> \
  --from-literal=secret_access_key=<HMAC secret>

# 1. clone the catalog DV into image-export (block mode -- same as source)
SRC=vyos-rolling
CLONE=${SRC}-export
cat <<EOF | oc apply -f -
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ${CLONE}
  namespace: image-export
spec:
  source:
    pvc:
      name: ${SRC}
      namespace: openshift-virtualization-os-images
  storage:
    storageClassName: ocs-storagecluster-ceph-rbd-virtualization
    volumeMode: Block
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 8Gi
EOF
oc wait datavolume/${CLONE} -n image-export --for=condition=Ready --timeout=30m

# 2. run the export Job (same Job spec as the pipeline produces)
BUCKET=<bucket>
ENDPOINT=https://s3.eu-de.cloud-object-storage.appdomain.cloud
REGION=eu-de
KEY=${SRC}.qcow2

cat <<EOF | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${CLONE}-export
  namespace: image-export
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      serviceAccountName: image-export-pipeline
      initContainers:
        - name: convert
          image: docker.io/library/alpine:3.19
          securityContext: { runAsUser: 0, runAsNonRoot: false }
          command: ["sh", "-c"]
          args:
            - |
              set -eu
              command -v qemu-img >/dev/null 2>&1 || apk add --no-cache qemu-img
              qemu-img info /dev/source-disk
              qemu-img convert -p -f raw -O qcow2 -c /dev/source-disk /work/out.qcow2
              qemu-img info /work/out.qcow2
          volumeDevices:
            - { name: clone, devicePath: /dev/source-disk }
          volumeMounts:
            - { name: work,  mountPath: /work }
      containers:
        - name: upload
          image: docker.io/amazon/aws-cli:latest
          env:
            - name: AWS_ACCESS_KEY_ID
              valueFrom: { secretKeyRef: { name: cos-hmac, key: access_key_id } }
            - name: AWS_SECRET_ACCESS_KEY
              valueFrom: { secretKeyRef: { name: cos-hmac, key: secret_access_key } }
          command: ["sh", "-c"]
          args:
            - |
              set -eu
              aws --endpoint-url ${ENDPOINT} --region ${REGION} \
                s3 cp /work/out.qcow2 s3://${BUCKET}/${KEY}
              aws --endpoint-url ${ENDPOINT} --region ${REGION} \
                s3api head-object --bucket ${BUCKET} --key ${KEY}
          volumeMounts:
            - { name: work, mountPath: /work }
      volumes:
        - name: clone
          persistentVolumeClaim: { claimName: ${CLONE} }
        - name: work
          emptyDir: { sizeLimit: 8Gi }
EOF

# 3. watch logs
POD=$(oc get pod -n image-export -l job-name=${CLONE}-export \
  -o jsonpath='{.items[0].metadata.name}')
oc logs -n image-export ${POD} -c convert -f
oc logs -n image-export ${POD} -c upload  -f

# 4. verify on COS side
aws --endpoint-url ${ENDPOINT} --region ${REGION} \
  s3api head-object --bucket ${BUCKET} --key ${KEY}

# 5. cleanup
oc delete datavolume ${CLONE} -n image-export
oc delete job ${CLONE}-export -n image-export
```

## Follow-up: register as a VPC custom image

A separate `register-vpc-custom-image` Tekton Pipeline takes a qcow2
already in COS and registers it as a VPC custom image via the VPC
Infrastructure REST API. Decoupled from the export pipeline so
registration can be retried independently.

### Prerequisites

- Service-to-service IAM authorization between IBM Cloud VPC
  Infrastructure Services (source) and Cloud Object Storage (target).
  Without this VPC can't read from the bucket. Create with:
  `ibmcloud iam authorization-policy-create is cloud-object-storage Reader`
- IBM Cloud platform API key in a Secret in `image-export`:
  ```bash
  oc create secret generic ibmcloud-apikey \
    -n image-export \
    --from-literal=api_key=<api key>
  ```
- VPC region must equal the COS bucket region (VPC reads the object
  server-side).

### Run

```bash
RG_ID=$(ibmcloud resource group nrt-prod-resource-group --output json | jq -r .[0].id)

cat <<EOF | oc create -f -
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: register-vyos-rolling-
  namespace: image-export
spec:
  pipelineRef:
    name: register-vpc-custom-image
  taskRunTemplate:
    serviceAccountName: image-export-pipeline
  timeouts:
    pipeline: "30m"
  params:
    - { name: cosBucket,          value: "nrt-prod-golden-images" }
    - { name: cosRegion,          value: "jp-tok" }
    - { name: cosObjectKey,       value: "vyos-rolling.qcow2" }
    - { name: vpcImageName,       value: "vyos-rolling" }
    - { name: vpcOsName,          value: "debian-12-amd64" }
    - { name: vpcRegion,          value: "jp-tok" }
    - { name: vpcResourceGroupId, value: "${RG_ID}" }
EOF
```

### Picking the OS slug

`ibmcloud is operating-systems --output json | jq '.[].name'` lists
valid VPC OS names. Useful pairings:

- VyOS rolling (Debian 12 derived) → `debian-12-amd64`
- Rocky 9 / RHEL-compatible 9 → `red-9-amd64`
- Windows Server 2022 → `windows-2022-amd64`

### One-shot equivalent (no Tekton)

```bash
ibmcloud is image-create vyos-rolling \
  --file cos://jp-tok/nrt-prod-golden-images/vyos-rolling.qcow2 \
  --os-name debian-12-amd64 \
  --resource-group-id "$RG_ID"
```

The pipeline calls the underlying VPC REST API directly (via
`curl` + `jq`), avoiding a CLI install at runtime — but the
one-shot CLI form above is equivalent.

## Troubleshooting

- **Clone PVC stuck `Pending` with `IncompatibleVolumeModes`** — the
  clone DV's volumeMode doesn't match the source. The pipeline asks
  for Block to match the catalog's RBD storage; if you change
  `cloneStorageClass` make sure the destination supports the source's
  volume mode.
- **Clone PVC stuck `Pending` with no events** — `cdi-cloner`
  ClusterRoleBinding may not cover the source namespace. See the
  rolebinding command under [Prerequisites](#prerequisites).
- **Pod stuck `PodInitializing` with `ErrImagePull`** — the chosen
  `imageQemuTools` requires registry auth this cluster doesn't have.
  Default `alpine:3.19` is publicly pullable; if you override, use
  another public image or seed the namespace with a pull secret.
- **Pod fails with `Permission denied` on apk/microdnf or `/dev/source-disk`** —
  the convert container needs root. Confirm `serviceAccountName:
  image-export-pipeline` is set on the Job pod (it is by default) and
  the SA has the `privileged` SCC binding from `pipeline-rbac.yaml`.
- **`aws s3 cp` fails with 403 / SignatureDoesNotMatch** — HMAC keys
  are wrong, or the endpoint/region don't match the bucket's region.
- **Job pod evicted** — the emptyDir may have exceeded `scratchSize`
  or the node ran out of ephemeral storage. Bump `scratchSize` on the
  PipelineRun.
