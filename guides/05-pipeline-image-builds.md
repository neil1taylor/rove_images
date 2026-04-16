# Automated Golden Image Pipelines with OpenShift Pipelines (Tekton)

## Why Pipelines?

In VMware, golden image updates are a manual process — someone logs in, patches the template VM, re-seals it, and converts it back to a template. It works, but it depends on a person remembering to do it on schedule, and there's no audit trail beyond "someone updated the template last Tuesday."

**OpenShift Pipelines (Tekton)** automates the entire lifecycle: build the image, test it, publish it, and update the cluster's boot sources — triggered by a schedule, a git push, or a webhook. The golden image becomes a CI/CD artefact with the same rigour as your application containers.

---

## Architecture

```
Trigger (cron / git push / manual)
    │
    ▼
Tekton Pipeline
    │
    ├── Task: Build image (Packer, virt-customize, or CDI import)
    ├── Task: Test image (boot a VM, run validation, tear down)
    ├── Task: Publish image (push to registry, tag)
    └── Task: Update DataSource (point cluster boot sources at new image)
    │
    ▼
DataSource updated ──→ New VMs clone the latest golden image
```

### Prerequisites

| Requirement | Detail |
|---|---|
| **OpenShift Pipelines Operator** | Installed from OperatorHub (based on Tekton) |
| **Tekton CLI (`tkn`)** | Optional but useful for debugging |
| **Container registry** | Internal registry or external (Quay, Harbor, etc.) with push credentials |
| **ServiceAccount** | With permissions to create VMs, PVCs, and DataSources in the target namespace |
| **PipelineRun storage** | A PVC or VolumeClaimTemplate for workspace data shared between tasks |

---

## Pipeline Overview

The pipeline below implements the full lifecycle for an Ubuntu golden image. The same pattern applies to Windows — the build and test tasks change, but the pipeline structure stays the same.

### Pipeline Definition

```yaml
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: golden-image-ubuntu
  namespace: golden-images
spec:
  params:
    - name: image-name
      type: string
      default: "ubuntu-2404-golden"
    - name: source-image-url
      type: string
      default: "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
    - name: registry-url
      type: string
      default: "registry.example.com/golden/ubuntu-2404"
    - name: disk-size
      type: string
      default: "30Gi"
  workspaces:
    - name: shared-data
    - name: registry-credentials
  tasks:
    - name: build-image
      taskRef:
        name: build-golden-image
      params:
        - name: image-name
          value: $(params.image-name)
        - name: source-image-url
          value: $(params.source-image-url)
        - name: disk-size
          value: $(params.disk-size)
      workspaces:
        - name: output
          workspace: shared-data

    - name: test-image
      taskRef:
        name: test-golden-image
      params:
        - name: image-name
          value: $(params.image-name)
      workspaces:
        - name: data
          workspace: shared-data
      runAfter:
        - build-image

    - name: publish-image
      taskRef:
        name: publish-golden-image
      params:
        - name: image-name
          value: $(params.image-name)
        - name: registry-url
          value: $(params.registry-url)
      workspaces:
        - name: data
          workspace: shared-data
        - name: registry-credentials
          workspace: registry-credentials
      runAfter:
        - test-image

    - name: update-datasource
      taskRef:
        name: update-datasource
      params:
        - name: image-name
          value: $(params.image-name)
        - name: registry-url
          value: $(params.registry-url)
        - name: disk-size
          value: $(params.disk-size)
      runAfter:
        - publish-image
```

---

## Task Definitions

### Task 1: Build the Golden Image

This task uses `virt-customize` to layer customisations on top of a vendor cloud image. For Packer-based builds, replace this task with one that invokes `packer build` (see [Packer guide](04-packer-image-builds.md)).

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: build-golden-image
  namespace: golden-images
spec:
  params:
    - name: image-name
    - name: source-image-url
    - name: disk-size
  workspaces:
    - name: output
  steps:
    - name: download-base
      image: registry.redhat.io/ubi9/ubi-minimal:latest
      script: |
        #!/bin/bash
        set -euo pipefail
        curl -L -o $(workspaces.output.path)/base.qcow2 \
          "$(params.source-image-url)"
        echo "Downloaded base image"

    - name: customise
      image: registry.redhat.io/rhel9/guest-tools:latest
      securityContext:
        privileged: true
      script: |
        #!/bin/bash
        set -euo pipefail

        virt-customize -a $(workspaces.output.path)/base.qcow2 \
          --install qemu-guest-agent,openssh-server,curl,vim \
          --run-command 'systemctl enable qemu-guest-agent' \
          --run-command 'systemctl enable ssh' \
          --run-command 'sed -i "s/^#*PermitRootLogin.*/PermitRootLogin no/" /etc/ssh/sshd_config' \
          --truncate /etc/machine-id \
          --run-command 'cloud-init clean --logs'

        # Sparsify to reduce image size
        virt-sparsify --in-place $(workspaces.output.path)/base.qcow2

        mv $(workspaces.output.path)/base.qcow2 \
           $(workspaces.output.path)/$(params.image-name).qcow2

        echo "Customisation complete"
```

> **Note:** The `guest-tools` image provides `virt-customize` and `virt-sparsify`. The `privileged` security context is required for libguestfs to launch its appliance. In production, use a dedicated build namespace with appropriate SCCs.

### Task 2: Test the Golden Image

Boot a VM from the newly built image, run validation checks, and tear it down. This is the automated equivalent of "start the template VM and make sure it works."

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: test-golden-image
  namespace: golden-images
spec:
  params:
    - name: image-name
  workspaces:
    - name: data
  steps:
    - name: upload-test-image
      image: registry.redhat.io/container-native-virtualization/virtctl-rhel9:latest
      script: |
        #!/bin/bash
        set -euo pipefail

        IMAGE_PATH="$(workspaces.data.path)/$(params.image-name).qcow2"
        DV_NAME="$(params.image-name)-test"

        # Upload the image as a DataVolume
        virtctl image-upload dv "$DV_NAME" \
          --size=30Gi \
          --image-path="$IMAGE_PATH" \
          --namespace=golden-images \
          --insecure

        echo "Test image uploaded as DV: $DV_NAME"

    - name: boot-and-validate
      image: bitnami/kubectl:latest
      script: |
        #!/bin/bash
        set -euo pipefail

        VM_NAME="$(params.image-name)-test-vm"
        NAMESPACE="golden-images"

        # Create a test VM
        cat <<EOF | kubectl apply -f -
        apiVersion: kubevirt.io/v1
        kind: VirtualMachine
        metadata:
          name: $VM_NAME
          namespace: $NAMESPACE
        spec:
          running: true
          template:
            spec:
              domain:
                cpu:
                  cores: 2
                memory:
                  guest: 2Gi
                devices:
                  disks:
                    - name: rootdisk
                      disk:
                        bus: virtio
              volumes:
                - name: rootdisk
                  dataVolume:
                    name: $(params.image-name)-test
        EOF

        # Wait for the VM to be ready
        echo "Waiting for VM to start..."
        kubectl wait --for=condition=Ready vmi/$VM_NAME \
          -n $NAMESPACE --timeout=300s

        # Wait for guest agent to report in
        echo "Waiting for guest agent..."
        for i in $(seq 1 30); do
          GA_STATUS=$(kubectl get vmi $VM_NAME -n $NAMESPACE \
            -o jsonpath='{.status.conditions[?(@.type=="AgentConnected")].status}' 2>/dev/null)
          if [ "$GA_STATUS" = "True" ]; then
            echo "Guest agent connected"
            break
          fi
          if [ "$i" -eq 30 ]; then
            echo "ERROR: Guest agent did not connect within timeout"
            exit 1
          fi
          sleep 10
        done

        # Verify guest OS info is reported
        OS_INFO=$(kubectl get vmi $VM_NAME -n $NAMESPACE \
          -o jsonpath='{.status.guestOSInfo.id}')
        echo "Guest OS: $OS_INFO"

        if [ -z "$OS_INFO" ]; then
          echo "WARNING: Guest OS info not reported"
        fi

        echo "Validation passed"

    - name: cleanup-test
      image: bitnami/kubectl:latest
      script: |
        #!/bin/bash
        set -euo pipefail

        VM_NAME="$(params.image-name)-test-vm"
        NAMESPACE="golden-images"

        # Delete the test VM and its DV
        kubectl delete vm $VM_NAME -n $NAMESPACE --wait=true
        kubectl delete dv $(params.image-name)-test -n $NAMESPACE --wait=true

        echo "Test resources cleaned up"
```

### Task 3: Publish to Registry

Package the qcow2 as a container image and push to the registry.

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: publish-golden-image
  namespace: golden-images
spec:
  params:
    - name: image-name
    - name: registry-url
  workspaces:
    - name: data
    - name: registry-credentials
  steps:
    - name: build-and-push
      image: quay.io/buildah/stable:latest
      securityContext:
        privileged: true
      script: |
        #!/bin/bash
        set -euo pipefail

        WORK="$(workspaces.data.path)"
        REGISTRY="$(params.registry-url)"
        DATE_TAG=$(date +%Y.%m.%d)
        SHORT_SHA=$(head -c 8 /proc/sys/kernel/random/uuid | tr -d '-')

        # Create a minimal Containerfile
        cat > "$WORK/Containerfile" <<EOF
        FROM scratch
        ADD --chown=107:107 $(params.image-name).qcow2 /disk/
        EOF

        # Build
        buildah bud -t "$REGISTRY:$DATE_TAG" \
          -t "$REGISTRY:latest" \
          -t "$REGISTRY:$SHORT_SHA" \
          -f "$WORK/Containerfile" "$WORK"

        # Push all tags
        AUTHFILE="$(workspaces.registry-credentials.path)/.dockerconfigjson"

        buildah push --authfile "$AUTHFILE" "$REGISTRY:$DATE_TAG"
        buildah push --authfile "$AUTHFILE" "$REGISTRY:latest"
        buildah push --authfile "$AUTHFILE" "$REGISTRY:$SHORT_SHA"

        echo "Published: $REGISTRY:$DATE_TAG, :latest, :$SHORT_SHA"
```

### Task 4: Update the Cluster DataSource

Point the cluster's boot source at the new image so new VMs automatically use it.

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: update-datasource
  namespace: golden-images
spec:
  params:
    - name: image-name
    - name: registry-url
    - name: disk-size
  steps:
    - name: update
      image: bitnami/kubectl:latest
      script: |
        #!/bin/bash
        set -euo pipefail

        NAMESPACE="golden-images"
        DV_NAME="$(params.image-name)"
        REGISTRY="$(params.registry-url)"

        # Import the latest image from registry into a new DataVolume
        cat <<EOF | kubectl apply -f -
        apiVersion: cdi.kubevirt.io/v1beta1
        kind: DataVolume
        metadata:
          name: $DV_NAME
          namespace: $NAMESPACE
        spec:
          source:
            registry:
              url: "docker://$REGISTRY:latest"
          storage:
            resources:
              requests:
                storage: $(params.disk-size)
        EOF

        # Wait for import to complete
        echo "Waiting for DataVolume import..."
        kubectl wait --for=jsonpath='{.status.phase}'=Succeeded \
          dv/$DV_NAME -n $NAMESPACE --timeout=600s

        # Create or update the DataSource
        cat <<EOF | kubectl apply -f -
        apiVersion: cdi.kubevirt.io/v1beta1
        kind: DataSource
        metadata:
          name: $DV_NAME
          namespace: $NAMESPACE
        spec:
          source:
            pvc:
              name: $DV_NAME
              namespace: $NAMESPACE
        EOF

        echo "DataSource $DV_NAME updated — new VMs will use the latest image"
```

---

## Triggering the Pipeline

### Manual Run

```bash
tkn pipeline start golden-image-ubuntu \
  -n golden-images \
  -p image-name=ubuntu-2404-golden \
  -p source-image-url="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img" \
  -p registry-url="registry.example.com/golden/ubuntu-2404" \
  -w name=shared-data,claimName=pipeline-workspace \
  -w name=registry-credentials,secret=registry-push-creds
```

### Scheduled (CronJob Trigger)

Use a Tekton `TriggerTemplate` + `CronJob` to run the pipeline on a schedule — the CI equivalent of "patch the golden image every Monday."

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: golden-image-ubuntu-weekly
  namespace: golden-images
spec:
  schedule: "0 4 * * 1"    # Monday 04:00 UTC
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: pipeline-sa
          containers:
            - name: trigger
              image: registry.redhat.io/openshift-pipelines/pipelines-cli-tkn-rhel8:latest
              command:
                - tkn
              args:
                - pipeline
                - start
                - golden-image-ubuntu
                - -n
                - golden-images
                - -p
                - image-name=ubuntu-2404-golden
                - -p
                - source-image-url=https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
                - -p
                - registry-url=registry.example.com/golden/ubuntu-2404
                - -w
                - name=shared-data,claimName=pipeline-workspace
                - -w
                - name=registry-credentials,secret=registry-push-creds
          restartPolicy: OnFailure
```

### Git-Triggered

If your Packer templates or provisioner scripts live in a Git repo, use Tekton Triggers to kick off a build on push:

```yaml
apiVersion: triggers.tekton.dev/v1beta1
kind: EventListener
metadata:
  name: golden-image-listener
  namespace: golden-images
spec:
  serviceAccountName: pipeline-sa
  triggers:
    - name: on-push
      interceptors:
        - ref:
            name: github
          params:
            - name: eventTypes
              value: ["push"]
        - ref:
            name: cel
          params:
            - name: filter
              value: "body.ref == 'refs/heads/main'"
      bindings:
        - ref: golden-image-binding
      template:
        ref: golden-image-trigger-template
---
apiVersion: triggers.tekton.dev/v1beta1
kind: TriggerBinding
metadata:
  name: golden-image-binding
  namespace: golden-images
spec:
  params:
    - name: git-revision
      value: $(body.after)
---
apiVersion: triggers.tekton.dev/v1beta1
kind: TriggerTemplate
metadata:
  name: golden-image-trigger-template
  namespace: golden-images
spec:
  params:
    - name: git-revision
  resourcetemplates:
    - apiVersion: tekton.dev/v1
      kind: PipelineRun
      metadata:
        generateName: golden-image-ubuntu-
      spec:
        pipelineRef:
          name: golden-image-ubuntu
        params:
          - name: image-name
            value: ubuntu-2404-golden
          - name: registry-url
            value: registry.example.com/golden/ubuntu-2404
        workspaces:
          - name: shared-data
            volumeClaimTemplate:
              spec:
                accessModes: ["ReadWriteOnce"]
                resources:
                  requests:
                    storage: 50Gi
          - name: registry-credentials
            secret:
              secretName: registry-push-creds
```

---

## Windows Pipeline Considerations

The pipeline structure is identical for Windows, but the build task differs:

### Build Task for Windows (Packer-based)

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: build-golden-image-windows
  namespace: golden-images
spec:
  params:
    - name: image-name
    - name: packer-repo
      default: "https://git.example.com/infra/golden-images.git"
    - name: packer-dir
      default: "windows-2022"
  workspaces:
    - name: output
  steps:
    - name: clone-packer-source
      image: alpine/git:latest
      script: |
        #!/bin/sh
        git clone $(params.packer-repo) /workspace/source

    - name: packer-build
      image: hashicorp/packer:latest
      workingDir: /workspace/source/$(params.packer-dir)
      securityContext:
        privileged: true    # Required for KVM access
      script: |
        #!/bin/sh
        set -euo pipefail
        packer init .
        packer build -var "vm_name=$(params.image-name).qcow2" .
        cp output-*/$(params.image-name).qcow2 $(workspaces.output.path)/
        echo "Packer build complete"
      resources:
        requests:
          memory: 10Gi      # Windows builds need more memory
          cpu: 4
```

> **Important:** Packer with KVM requires a privileged pod and a node with `/dev/kvm` available. Either run on bare-metal worker nodes or use nodes with nested virtualisation enabled.

### Windows Test Task Adjustments

- Increase the VMI ready timeout to 600s (Windows boots slower)
- Check for the `QEMU-GA` service via guest agent commands rather than SSH
- Verify the guest reports as `windows` in `guestOSInfo`

---

## Monitoring and Notifications

### Pipeline Runs

```bash
# List recent runs
tkn pipelinerun list -n golden-images

# Watch a running pipeline
tkn pipelinerun logs golden-image-ubuntu-run-xyz -f -n golden-images

# Check task status
tkn taskrun list -n golden-images
```

### Adding Slack/Email Notifications

Add a `finally` task to the pipeline for notifications on success or failure:

```yaml
  finally:
    - name: notify
      taskRef:
        name: send-notification
      params:
        - name: message
          value: "Golden image pipeline $(context.pipelineRun.name): $(tasks.status)"
        - name: channel
          value: "#infra-alerts"
```

---

## RBAC and Security

### ServiceAccount Permissions

The pipeline ServiceAccount needs:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: golden-image-pipeline
  namespace: golden-images
rules:
  # Create and manage DataVolumes
  - apiGroups: ["cdi.kubevirt.io"]
    resources: ["datavolumes", "datasources"]
    verbs: ["get", "list", "create", "update", "patch", "delete"]
  # Create and manage test VMs
  - apiGroups: ["kubevirt.io"]
    resources: ["virtualmachines", "virtualmachineinstances"]
    verbs: ["get", "list", "create", "update", "delete", "watch"]
  # Manage PVCs for workspace and images
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list", "create", "delete"]
  # Read secrets for registry auth
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: golden-image-pipeline
  namespace: golden-images
subjects:
  - kind: ServiceAccount
    name: pipeline-sa
    namespace: golden-images
roleRef:
  kind: Role
  name: golden-image-pipeline
  apiGroup: rbac.authorization.k8s.io
```

### Registry Credentials

```bash
oc create secret docker-registry registry-push-creds \
  --docker-server=registry.example.com \
  --docker-username=golden-image-pusher \
  --docker-password=changeme \
  -n golden-images
```

---

## Comparison: VMware vs Pipeline-Driven Image Lifecycle

| Aspect | VMware (Manual) | Tekton Pipeline |
|---|---|---|
| **Build trigger** | Admin remembers / calendar reminder | Cron schedule, git push, or webhook |
| **Build process** | Interactive — login, patch, seal, convert | Automated — no human in the loop |
| **Testing** | "Boot it and see if it works" | Automated validation with pass/fail gates |
| **Publishing** | Convert VM to template in vCenter | Push to registry, update DataSource |
| **Audit trail** | vCenter events (limited) | PipelineRun logs, git history, registry tags |
| **Rollback** | Restore from backup or previous template | Re-tag a previous registry image |
| **Time to update** | 30–60 min of admin time | 0 min of admin time (fully automated) |

### What the Pipeline Replaces

The pipeline replaces the **manual patch-and-seal cycle**. It does not replace:

- **Packer / virt-customize** — these are the build tools *inside* the pipeline
- **cloud-init / sysprep** — per-VM customisation still happens at deploy time
- **DataImportCron** — can be used alongside or instead of the pipeline's update-datasource task
- **Instancetypes / Preferences / Templates** — still define how VMs are deployed from the golden image
