# Tutorial: GitOps-Managed Golden Images on ROKS with ArgoCD

## Overview

A hands-on tutorial that walks a platform engineer through setting up a GitOps-managed golden image lifecycle on a single ROKS VPC cluster, from OpenShift GitOps operator install through to image version rotation and retirement.

**Audience**: Platform engineers who want to manage OCP Virtualization golden images via GitOps.

**Format**: Single document, four phases with verification checkpoints after each. The reader can stop after any phase and have something working.

**Estimated time**: 60-90 minutes.

**What you'll build**:
- OpenShift GitOps operator managing a `vm-golden-images` namespace
- A git repo containing golden image definitions (DataVolume, InstanceType, Preference) structured with Kustomize
- A Fedora 41 cloud image as the first golden image, synced via ArgoCD
- A consumer VM in a separate namespace, cloned from the golden image with cloud-init
- A v2 image rotation with consumer VM migration and v1 retirement — all driven by git commits

**Prerequisites** (must be in place before starting):
- ROKS VPC cluster running OCP 4.20+
- OCP Virtualization operator installed
- ODF installed (`ocs-storagecluster-ceph-rbd` StorageClass available)
- `oc` and `virtctl` CLIs authenticated to the cluster
- A git repository the reader controls (GitHub, GitLab, or Bitbucket) — the tutorial scaffolds the content
- `kustomize` CLI installed (or use `oc apply -k` which bundles it)

**Relationship to other docs**: This tutorial implements the GitOps lifecycle option (Option A) described in the [Golden Template Pipeline spec](2026-04-14-golden-template-pipeline-design.md), Section 8. The spec describes the pattern conceptually; this tutorial makes it concrete.

---

## Phase 1: Foundation

Install OpenShift GitOps and connect it to the reader's git repo. Sync the base namespace and RBAC.

### 1.1 Install OpenShift GitOps Operator

Install via the Subscription CR (OperatorHub). The tutorial provides the exact YAML:

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-operators
spec:
  channel: latest
  installPlanApproval: Automatic
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
```

Verify:
- `oc get csv -n openshift-operators | grep gitops` — shows Succeeded
- `oc get pods -n openshift-gitops` — ArgoCD pods running
- Access the ArgoCD UI via the route: `oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}'`

### 1.2 Scaffold the Git Repo

Create the following structure and push to the remote:

```
golden-images/
  base/
    namespace.yaml
    rbac/
      clone-source-clusterrole.yaml
      clone-source-rolebinding.yaml
    resource-quota.yaml
    kustomization.yaml
  images/
    kustomization.yaml          # empty resources list initially
  kustomization.yaml            # top-level, references base/ and images/
```

**`golden-images/kustomization.yaml`** (top-level):
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - base
  - images
```

**`golden-images/base/kustomization.yaml`**:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - rbac/clone-source-clusterrole.yaml
  - rbac/clone-source-rolebinding.yaml
  - resource-quota.yaml
```

**`golden-images/images/kustomization.yaml`** (empty for now):
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
```

The base manifests (`namespace.yaml`, `clone-source-clusterrole.yaml`, `clone-source-rolebinding.yaml`, `resource-quota.yaml`) use the exact content from the golden template pipeline manifests. The tutorial provides the full YAML for each file.

The initial RoleBinding grants clone access to a `tutorial-consumer` namespace (created in Phase 3).

### 1.3 Create the ArgoCD Application

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: golden-images
  namespace: openshift-gitops
spec:
  project: default
  source:
    repoURL: https://github.com/<your-org>/golden-images.git  # reader substitutes their repo
    targetRevision: main
    path: golden-images
  destination:
    server: https://kubernetes.default.svc
    namespace: vm-golden-images
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Apply via `oc apply -f`. ArgoCD needs access to the git repo — if private, the tutorial walks through adding a repo credential in ArgoCD (Settings > Repositories).

### 1.4 Verify Sync

```bash
oc get application golden-images -n openshift-gitops
# Status: Synced, Health: Healthy

oc get ns vm-golden-images --show-labels
# purpose=golden-images label present

oc get clusterrole golden-image-clone-source
oc get rolebinding allow-clone-from-golden-images -n vm-golden-images
oc get resourcequota golden-image-storage -n vm-golden-images
```

### Checkpoint

`oc get ns vm-golden-images` returns the namespace with `purpose: golden-images` label. ArgoCD Application shows Synced/Healthy. The namespace, ClusterRole, RoleBinding, and ResourceQuota all exist on the cluster, managed by ArgoCD from git.

---

## Phase 2: First Golden Image

Add a Fedora 41 cloud image as the first golden image. ArgoCD syncs it to the cluster.

### 2.1 Create the Image Directory

Add to the git repo:

```
golden-images/
  images/
    fedora41/
      datavolume.yaml
      instancetype.yaml
      preference.yaml
      kustomization.yaml
```

### 2.2 DataVolume — CDI HTTP Source

**`golden-images/images/fedora41/datavolume.yaml`**:

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: fedora41-base-v1
  namespace: vm-golden-images
  labels:
    os-family: linux
    image-status: current
  annotations:
    golden-image/os-version: "Fedora 41"
    golden-image/source: "CDI HTTP import"
    golden-image/sealed-by: "cloud-init"
spec:
  source:
    http:
      url: "https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2"
  storage:
    storageClassName: ocs-storagecluster-ceph-rbd
    resources:
      requests:
        storage: 10Gi
```

The Fedora cloud image is ~500MB. CDI downloads and converts it to raw format in the PVC. 10Gi is generous for the tutorial — the actual image is much smaller but the PVC needs space for runtime writes during validation.

### 2.3 InstanceType

**`golden-images/images/fedora41/instancetype.yaml`**:

```yaml
apiVersion: instancetype.kubevirt.io/v1beta1
kind: VirtualMachineInstancetype
metadata:
  name: fedora-small
  namespace: vm-golden-images
spec:
  cpu:
    guest: 2
  memory:
    guest: 4Gi
```

### 2.4 Preference

**`golden-images/images/fedora41/preference.yaml`**:

```yaml
apiVersion: instancetype.kubevirt.io/v1beta1
kind: VirtualMachinePreference
metadata:
  name: fedora41-golden
  namespace: vm-golden-images
spec:
  cpu:
    preferredCPUTopology: preferSockets
  devices:
    preferredDiskBus: virtio
    preferredInterfaceModel: virtio
    preferredNetworkInterfaceMultiQueue: true
  firmware:
    preferredUseEfi: true
    preferredUseSecureBoot: false
  machine:
    preferredMachineType: q35
```

### 2.5 Kustomization

**`golden-images/images/fedora41/kustomization.yaml`**:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - datavolume.yaml
  - instancetype.yaml
  - preference.yaml
```

Update **`golden-images/images/kustomization.yaml`** to include the new directory:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - fedora41
```

### 2.6 Commit, Push, Verify

```bash
git add . && git commit -m "feat: add Fedora 41 golden image (v1)" && git push
```

ArgoCD detects the change and syncs. Monitor:

```bash
# ArgoCD sync status
oc get application golden-images -n openshift-gitops

# DataVolume progress
oc get dv -n vm-golden-images -w
# Phases: ImportScheduled → ImportInProgress → Succeeded

# PVC
oc get pvc -n vm-golden-images
```

Wait for the DataVolume import to complete (1-3 minutes depending on network speed).

### Checkpoint

`oc get dv fedora41-base-v1 -n vm-golden-images -o jsonpath='{.status.phase}'` returns `Succeeded`. The golden image PVC exists, is Bound, and is ready for cloning. ArgoCD Application shows Synced/Healthy with the new resources.

---

## Phase 3: Template Promotion & Consumer VM

Validate the golden image boots, then deploy a consumer VM that clones from it.

### 3.1 Validate the Golden Image

Start a temporary VM to verify the image boots on KVM:

```bash
# Create a temporary test VM
cat <<'EOF' | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: fedora41-validation
  namespace: vm-golden-images
spec:
  runStrategy: Always
  instancetype:
    kind: VirtualMachineInstancetype
    name: fedora-small
    inferFromVolume: false
  preference:
    kind: VirtualMachinePreference
    name: fedora41-golden
    inferFromVolume: false
  template:
    spec:
      domain:
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
          interfaces:
            - name: default
              masquerade: {}
        resources: {}
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          persistentVolumeClaim:
            claimName: fedora41-base-v1
EOF
```

Note: this boots directly from the golden PVC (not a clone) — for validation only.

```bash
# Wait for the VM to start
oc get vmi -n vm-golden-images -w

# Console access
virtctl console fedora41-validation -n vm-golden-images

# Inside the VM:
lspci | grep -i virtio          # VirtIO devices present
cloud-init status               # cloud-init is active
cat /etc/machine-id             # unique machine-id generated at boot
```

Fedora cloud images ship pre-sealed: cloud-init enabled, SSH host keys generated at boot, unique machine-id per boot. No re-seal step is needed — a benefit of the "build new natively" path.

Clean up the validation VM:

```bash
virtctl stop fedora41-validation -n vm-golden-images
oc delete vm fedora41-validation -n vm-golden-images
```

### 3.2 Set Up the Consumer Namespace

Create a `tutorial-consumer` namespace and grant it clone access via git.

In the git repo, update **`golden-images/base/rbac/clone-source-rolebinding.yaml`** to include the `tutorial-consumer` namespace as a subject (or add a second RoleBinding file). The tutorial provides the exact YAML.

```bash
git add . && git commit -m "feat: grant tutorial-consumer namespace clone access" && git push
```

ArgoCD syncs the RBAC change. Verify:

```bash
oc get rolebinding -n vm-golden-images
```

Create the consumer namespace:

```bash
oc create ns tutorial-consumer
```

### 3.3 Deploy the Consumer VM

Apply the consumer VM directly via `oc apply -f` (consumer VMs are workload-side, not managed by the golden-images ArgoCD Application):

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: tutorial-vm
  namespace: tutorial-consumer
spec:
  instancetype:
    kind: VirtualMachineInstancetype
    name: fedora-small
    inferFromVolume: false
  preference:
    kind: VirtualMachinePreference
    name: fedora41-golden
    inferFromVolume: false
  runStrategy: Always
  dataVolumeTemplates:
    - metadata:
        name: tutorial-vm-rootdisk
      spec:
        source:
          pvc:
            namespace: vm-golden-images
            name: fedora41-base-v1
        storage:
          storageClassName: ocs-storagecluster-ceph-rbd
          resources:
            requests:
              storage: 10Gi
  template:
    spec:
      domain:
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
          interfaces:
            - name: default
              masquerade: {}
        resources: {}
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          dataVolume:
            name: tutorial-vm-rootdisk
        - name: cloudinitdisk
          cloudInitNoCloud:
            userData: |
              #cloud-config
              hostname: tutorial-vm
              ssh_authorized_keys:
                - ssh-rsa AAAAB3... your-key-here
              runcmd:
                - echo "Golden image clone successful" > /var/log/clone-status.txt
```

CDI clones the golden PVC (instant on ODF Ceph RBD — copy-on-write).

### 3.4 Verify the Consumer VM

```bash
# VM is running
oc get vm tutorial-vm -n tutorial-consumer

# Guest agent reporting IP
oc get vmi tutorial-vm -n tutorial-consumer -o jsonpath='{.status.interfaces}' | jq .

# SSH access
virtctl ssh fedora@tutorial-vm -n tutorial-consumer

# Inside the VM:
hostname                        # tutorial-vm (from cloud-init)
cat /etc/machine-id             # unique, different from validation boot
cat /var/log/clone-status.txt   # "Golden image clone successful"
```

### Checkpoint

A consumer VM is running in `tutorial-consumer`, cloned from the golden image in `vm-golden-images`, with a unique identity via cloud-init. Cross-namespace RBAC was managed via git commit and ArgoCD sync.

---

## Phase 4: Version Rotation

Publish a v2 golden image via git commit, migrate the consumer VM, and retire v1.

### 4.1 Publish v2

In the git repo:

1. Copy `images/fedora41/datavolume.yaml` to `images/fedora41/datavolume-v1.yaml` (preserves v1 on the cluster during transition).

2. Update `images/fedora41/datavolume-v1.yaml`:
   - Change the label `image-status: current` to `image-status: previous`

3. Update `images/fedora41/datavolume.yaml`:
   - Change the PVC name from `fedora41-base-v1` to `fedora41-base-v2`
   - Label remains `image-status: current`
   - Source URL remains the same (in production this would be a new image URL; for the tutorial the mechanics are the point)

4. Update `images/fedora41/kustomization.yaml` to include both DataVolume files:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - datavolume.yaml
  - datavolume-v1.yaml
  - instancetype.yaml
  - preference.yaml
```

5. Commit and push:

```bash
git add . && git commit -m "feat: publish Fedora 41 golden image v2, demote v1" && git push
```

### 4.2 Verify ArgoCD Syncs v2

```bash
# Two DataVolumes now
oc get dv -n vm-golden-images
# fedora41-base-v1   Succeeded
# fedora41-base-v2   ImportInProgress → Succeeded

# Label check
oc get pvc -n vm-golden-images -l image-status=current
# fedora41-base-v2

oc get pvc -n vm-golden-images -l image-status=previous
# fedora41-base-v1
```

Wait for v2 import to complete.

### 4.3 Validate v2

Quick boot test — same pattern as Phase 3.1. Start a temporary VM from v2 PVC, verify it boots, stop and delete.

### 4.4 Migrate the Consumer VM to v2

```bash
# Stop the consumer VM
virtctl stop tutorial-vm -n tutorial-consumer

# Delete the old clone PVC
oc delete pvc tutorial-vm-rootdisk -n tutorial-consumer

# Update the consumer VM to reference v2
oc patch vm tutorial-vm -n tutorial-consumer --type merge --patch '
spec:
  dataVolumeTemplates:
    - metadata:
        name: tutorial-vm-rootdisk
      spec:
        source:
          pvc:
            namespace: vm-golden-images
            name: fedora41-base-v2
        storage:
          storageClassName: ocs-storagecluster-ceph-rbd
          resources:
            requests:
              storage: 10Gi'

# Start the VM — CDI clones from v2
virtctl start tutorial-vm -n tutorial-consumer
```

Verify:

```bash
virtctl ssh fedora@tutorial-vm -n tutorial-consumer
hostname                        # tutorial-vm (cloud-init re-applied)
cat /etc/machine-id             # new unique ID (fresh clone)
cat /var/log/clone-status.txt   # "Golden image clone successful"
```

### 4.5 Retire v1

In the git repo:

1. Update `images/fedora41/datavolume-v1.yaml` — change label to `image-status: deprecated`.

2. Commit and push:
   ```bash
   git add . && git commit -m "chore: mark Fedora 41 v1 as deprecated" && git push
   ```

3. Verify no VMs still reference v1:
   ```bash
   oc get vm -A -o yaml | grep fedora41-base-v1
   # Should return nothing
   ```

4. Remove `datavolume-v1.yaml` from the repo and from `kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - datavolume.yaml
  - instancetype.yaml
  - preference.yaml
```

5. Commit and push:
   ```bash
   git add . && git commit -m "chore: retire Fedora 41 v1 golden image" && git push
   ```

6. ArgoCD prunes the v1 PVC (automated prune is enabled):
   ```bash
   oc get pvc -n vm-golden-images
   # Only fedora41-base-v2 remains
   ```

### Checkpoint

v2 is the sole golden image. The consumer VM is running from v2. v1 has been retired via git commit, with ArgoCD handling the pruning. The full lifecycle — create, deploy, version, migrate, retire — has been exercised through git commits only.

---

## Cleanup

To remove all tutorial resources:

```bash
# Delete the consumer VM and namespace
oc delete vm tutorial-vm -n tutorial-consumer
oc delete ns tutorial-consumer

# Delete the ArgoCD Application (prunes all synced resources)
oc delete application golden-images -n openshift-gitops

# Verify golden images namespace is removed
oc get ns vm-golden-images
# NotFound

# Optionally uninstall OpenShift GitOps operator (if installed solely for this tutorial)
oc delete subscription openshift-gitops-operator -n openshift-operators
oc delete csv -n openshift-operators -l operators.coreos.com/openshift-gitops-operator.openshift-operators=
```

The git repo can be kept as a starting point for production use.

---

## Summary

What you learned:

1. **OpenShift GitOps setup** — Installing the operator and creating an ArgoCD Application targeting a golden images namespace
2. **Git repo structure** — Kustomize-based layout separating base infrastructure (namespace, RBAC, quotas) from image definitions
3. **CDI HTTP import via GitOps** — DataVolume with `source: http` synced by ArgoCD, downloading a cloud image into a PVC
4. **Cross-namespace RBAC via git** — Managing clone permissions through git commits and ArgoCD sync
5. **Consumer VM cloning** — Deploying a VM that clones from a GitOps-managed golden image with cloud-init identity injection
6. **Version rotation via git** — Publishing v2, migrating consumers, and retiring v1 entirely through git operations with ArgoCD handling cluster-side sync and pruning

Every cluster-side change in this tutorial (except the consumer VM itself) was driven by a git commit. The git repo is the single source of truth for golden image state.

---

## Next Steps

- **Add Windows golden images**: Use the sysprep ConfigMap pattern from the [golden template pipeline spec](2026-04-14-golden-template-pipeline-design.md), Section 7
- **Add MTV-imported images**: Replace `source: http` with `source: pvc` after an MTV cold migration lands a PVC in `vm-golden-images`
- **Scale to multi-cluster**: Use an ArgoCD ApplicationSet with cluster generators and per-cluster Kustomize overlays (repo structure shown in the [golden template pipeline spec](2026-04-14-golden-template-pipeline-design.md), Section 8)
- **Add alerting**: Monitor for failed DataVolume imports so ArgoCD sync failures are caught. An OCP PrometheusRule watching for DataVolumes stuck in ImportInProgress is the simplest approach.
