# Tutorial: GitOps-Managed Golden Images on ROKS with ArgoCD

## Overview

This tutorial walks a platform engineer through setting up a GitOps-managed golden image lifecycle on a ROKS VPC cluster. You will install OpenShift GitOps, connect it to a git repository, and sync a namespace and RBAC configuration that will serve as the foundation for golden image management.

**Audience**: Platform engineers managing OCP Virtualization golden images via GitOps.

**Estimated time**: 60-90 minutes.

**What you'll build**:
- OpenShift GitOps operator managing a `vm-golden-images` namespace
- A git repository containing golden image definitions structured with Kustomize
- A Fedora 41 cloud image as the first golden image, synced via ArgoCD
- A consumer VM in a separate namespace, cloned from the golden image with cloud-init
- A v2 image rotation with v1 retirement — all driven by git commits

**Prerequisites** (must be in place before starting):
- ROKS VPC cluster running OCP 4.20+
- OCP Virtualization operator installed
- ODF installed (`ocs-storagecluster-ceph-rbd-virtualization` StorageClass available)
- `oc` and `virtctl` CLIs authenticated to the cluster
- A git repository you control (GitHub, GitLab, or Bitbucket) — the tutorial scaffolds the content
- `kustomize` CLI installed (or use `oc apply -k` which bundles it)

---

## Phase 1: Foundation

Install OpenShift GitOps and connect it to your git repository. Sync the base namespace and RBAC.

### 1.1 Install OpenShift GitOps Operator

Install via the Subscription CR. Save the following to `subscription.yaml` and apply it:

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

```bash
oc apply -f subscription.yaml
```

The operator installs and bootstraps an ArgoCD instance in the `openshift-gitops` namespace. Wait 2-3 minutes, then verify:

```bash
# Expect: openshift-gitops-operator.v<version>   Succeeded
oc get csv -n openshift-operators | grep gitops

# Expect: ArgoCD component pods in Running state
oc get pods -n openshift-gitops

# Get the ArgoCD UI URL
oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}'
```

Open the ArgoCD URL in a browser to confirm the UI is accessible. You can log in with your OpenShift credentials via the SSO button.

### 1.2 Scaffold the Git Repo

Create the following directory structure in your git repository:

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
    kustomization.yaml
  kustomization.yaml
```

Create each file with the content below.

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

**`golden-images/base/namespace.yaml`**:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: vm-golden-images
  labels:
    purpose: golden-images
```

**`golden-images/base/rbac/clone-source-clusterrole.yaml`**:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: golden-image-clone-source
rules:
  - apiGroups: ["cdi.kubevirt.io"]
    resources: ["datavolumes/source"]
    verbs: ["create"]
```

**`golden-images/base/rbac/clone-source-rolebinding.yaml`**:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: allow-clone-from-golden-images
  namespace: vm-golden-images
subjects:
  - kind: ServiceAccount
    name: default
    namespace: tutorial-consumer
roleRef:
  kind: ClusterRole
  name: golden-image-clone-source
  apiGroup: rbac.authorization.k8s.io
```

This RoleBinding grants the `tutorial-consumer` namespace permission to clone PVCs from `vm-golden-images`. The `tutorial-consumer` namespace is created in Phase 3.

**`golden-images/base/resource-quota.yaml`**:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: golden-image-storage
  namespace: vm-golden-images
spec:
  hard:
    requests.storage: 500Gi
```

**`golden-images/images/kustomization.yaml`** (empty for now — images are added in Phase 2):

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
```

Initialise the repository and push:

```bash
git init
git add .
git commit -m "feat: scaffold golden-images GitOps repo — base infrastructure"
git remote add origin https://github.com/<your-org>/golden-images.git
git push -u origin main
```

### 1.3 Create the ArgoCD Application

Save the following to `application.yaml`, replacing `REPLACE_WITH_YOUR_ORG` with your actual GitHub organisation or username:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: golden-images
  namespace: openshift-gitops
spec:
  project: default
  source:
    repoURL: https://github.com/REPLACE_WITH_YOUR_ORG/golden-images.git
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

If your repository is private, add the credentials to ArgoCD before applying: in the ArgoCD UI go to **Settings > Repositories** and add your repo URL with a personal access token. Alternatively use the ArgoCD CLI: `argocd repo add https://github.com/<your-org>/golden-images.git --username <user> --password <token>`.

Apply the Application CR:

```bash
oc apply -f application.yaml
```

ArgoCD detects the Application and begins the first sync immediately.

### 1.4 Verify Sync

Wait 30-60 seconds for the initial sync to complete, then verify each resource:

```bash
# Expect: STATUS=Synced, HEALTH=Healthy
oc get application golden-images -n openshift-gitops

# Expect: namespace present with purpose=golden-images label
oc get ns vm-golden-images --show-labels

# Expect: ClusterRole present
oc get clusterrole golden-image-clone-source

# Expect: RoleBinding present in vm-golden-images
oc get rolebinding allow-clone-from-golden-images -n vm-golden-images

# Expect: ResourceQuota present limiting storage to 500Gi
oc get resourcequota golden-image-storage -n vm-golden-images
```

### Checkpoint

At this point you should have: `oc get ns vm-golden-images` returns the namespace with a `purpose=golden-images` label, and the ArgoCD Application shows Synced/Healthy. The namespace, ClusterRole, RoleBinding, and ResourceQuota all exist on the cluster, managed by ArgoCD from git. Any manual change to these resources will be automatically reverted by ArgoCD's self-heal policy — the git repository is now the single source of truth for this namespace.

---

## Phase 2: First Golden Image

Add a Fedora 41 cloud image as the first golden image. CDI will download the qcow2 directly from the Fedora project servers, convert it to raw format, and write it to a PVC in the `vm-golden-images` namespace. ArgoCD manages the DataVolume, InstanceType, and Preference as a single Kustomize component.

### 2.1 Create the Image Directory

Add the `images/fedora41/` directory with four files:

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
    fedora41/
      datavolume.yaml
      instancetype.yaml
      preference.yaml
      kustomization.yaml
    kustomization.yaml
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
    storageClassName: ocs-storagecluster-ceph-rbd-virtualization
    resources:
      requests:
        storage: 10Gi
```

When ArgoCD syncs this resource, CDI takes over: it schedules an import pod that downloads the qcow2 from the Fedora CDN (~500 MB), converts it to raw block format, and writes the result to a 10 Gi PVC named `fedora41-base-v1`. The DataVolume CR tracks import progress through a series of phases: `ImportScheduled` → `ImportInProgress` → `Succeeded`. The PVC is not usable until the phase reaches `Succeeded`.

The `image-status: current` label is how consumer workloads (and Phase 4 automation) identify which version of a golden image is active.

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

`VirtualMachineInstancetype` defines a named resource profile (2 vCPU, 4 Gi RAM) that VMs reference by name. Keeping it in `vm-golden-images` alongside the image means the profile and the image are versioned together in git.

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

`VirtualMachinePreference` captures Fedora-specific hardware defaults: EFI firmware, virtio bus for disk and network, q35 machine type, and multi-queue networking. Any VM that references `fedora41-golden` inherits these settings without having to specify them individually. Secure Boot is disabled here because the Fedora Cloud image does not ship a signed shim by default.

### 2.5 Kustomization Files

**`golden-images/images/fedora41/kustomization.yaml`**:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - datavolume.yaml
  - instancetype.yaml
  - preference.yaml
```

Update **`golden-images/images/kustomization.yaml`** to include the `fedora41` directory:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - fedora41
```

### 2.6 Commit, Push, and Verify

Stage and push the new files:

```bash
git add golden-images/images/
git commit -m "feat: add Fedora 41 golden image — v1 via CDI HTTP import"
git push origin main
```

ArgoCD detects the push within seconds (default poll interval is 3 minutes; use a webhook for immediate detection). Watch the sync and import progress:

```bash
# Expect: STATUS=Synced, HEALTH=Healthy (after ArgoCD picks up the commit)
oc get application golden-images -n openshift-gitops

# Watch CDI import progress — phases: ImportScheduled → ImportInProgress → Succeeded
# Import takes 1-3 minutes depending on network throughput to the Fedora CDN
oc get dv -n vm-golden-images -w

# After the DataVolume reaches Succeeded, confirm the PVC is Bound
oc get pvc -n vm-golden-images
```

The PVC output should show `fedora41-base-v1` with status `Bound` and capacity `10Gi`.

### Checkpoint

```bash
oc get dv fedora41-base-v1 -n vm-golden-images -o jsonpath='{.status.phase}'
```

Expected output: `Succeeded`

The golden image is on-cluster, managed by ArgoCD, and ready to be cloned. The DataVolume PVC (`fedora41-base-v1`) contains a raw Fedora 41 cloud disk. The `image-status: current` label marks it as the active version. Phase 3 will create a consumer VM in a separate namespace that clones from this PVC using cloud-init for first-boot configuration.

---

## Phase 3: Template Promotion & Consumer VM

The golden image is on-cluster. Before any workload clones from it, validate that it actually boots on KVM. Then create the consumer namespace, deploy a VM that clones the PVC, and verify it has a unique identity.

### 3.1 Validate the Golden Image

Create a temporary validation VM that boots directly from the golden PVC — no clone, no cloud-init. This is purely a smoke test to confirm the image is bootable before consumer workloads depend on it.

```yaml
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
```

Save this as `validation-vm.yaml` and apply it:

```bash
oc apply -f validation-vm.yaml
```

Wait for the VMI to reach `Running`:

```bash
oc get vmi -n vm-golden-images -w
```

Once running, open a serial console:

```bash
virtctl console fedora41-validation -n vm-golden-images
```

Inside the VM, verify the core properties of a healthy Fedora cloud image:

```bash
# Confirm virtio drivers are loaded — should list VirtIO devices
lspci | grep -i virtio

# Confirm cloud-init ran to completion
cloud-init status

# Inspect the machine-id — it will be non-empty (cloud image ships pre-sealed)
cat /etc/machine-id
```

Exit the console with `Ctrl+]`.

**Why no re-seal step?** Fedora cloud images are distributed in a pre-sealed state: cloud-init is enabled, SSH keys are generated fresh at each boot, and the machine-id is unique per boot cycle. This is a direct benefit of the "build new natively" path (CDI HTTP import of an upstream cloud image) over the MTV migration path, where you would need to manually seal a migrated VM before templating it. Nothing extra is required here — the image is ready.

Clean up the validation VM:

```bash
virtctl stop fedora41-validation -n vm-golden-images
oc delete vm fedora41-validation -n vm-golden-images
```

### 3.2 Set Up the Consumer Namespace

Create the consumer namespace:

```bash
oc create ns tutorial-consumer
```

The RoleBinding that grants `tutorial-consumer` permission to clone PVCs from `vm-golden-images` was already committed to git and synced by ArgoCD in Phase 1. The subject namespace in that RoleBinding is `tutorial-consumer`, so no further RBAC work is needed now that the namespace exists.

Verify the binding is in place:

```bash
oc get rolebinding allow-clone-from-golden-images -n vm-golden-images -o yaml | grep tutorial-consumer
```

Expected output: a line confirming `namespace: tutorial-consumer` under the subjects block.

### 3.3 Deploy the Consumer VM

Consumer VMs are workload-side resources — they are not managed by ArgoCD. Apply the following directly:

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
          storageClassName: ocs-storagecluster-ceph-rbd-virtualization
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
                - ssh-rsa AAAAB3_REPLACE_WITH_YOUR_KEY user@workstation
              runcmd:
                - echo "Golden image clone successful" > /var/log/clone-status.txt
```

Key points about this manifest:

- **instancetype and preference** reference `fedora-small` and `fedora41-golden` by name. Both CRDs live in `vm-golden-images` — cross-namespace references to instancetype and preference are supported by KubeVirt.
- **dataVolumeTemplates** instructs CDI to clone `fedora41-base-v1` from `vm-golden-images` into a new PVC named `tutorial-vm-rootdisk` in `tutorial-consumer`. The cross-namespace clone is permitted by the RoleBinding set up in Phase 1.
- **cloudInitNoCloud** sets the hostname to `tutorial-vm` and injects an SSH public key at first boot. Replace `AAAAB3_REPLACE_WITH_YOUR_KEY` with your actual SSH public key before applying. The `runcmd` writes a sentinel file that confirms the clone and cloud-init run both succeeded.

On ODF with the Ceph RBD storage class, the CDI clone is a copy-on-write operation at the Ceph layer. It completes almost instantly regardless of image size — only divergent blocks are materialised over time as the VM writes data.

Save the manifest as `tutorial-vm.yaml`, replacing the placeholder SSH key, then apply:

```bash
oc apply -f tutorial-vm.yaml
```

### 3.4 Verify the Consumer VM

Wait for the VM to reach `Running`:

```bash
oc get vm tutorial-vm -n tutorial-consumer
```

Once running, check the reported IP address:

```bash
oc get vmi tutorial-vm -n tutorial-consumer -o jsonpath='{.status.interfaces}' | jq .
```

SSH into the VM using `virtctl`:

```bash
virtctl ssh fedora@tutorial-vm -n tutorial-consumer
```

Inside the VM, verify its identity and the clone outcome:

```bash
# Should return: tutorial-vm
hostname

# Should return a unique machine-id generated by cloud-init at first boot
cat /etc/machine-id

# Should return: Golden image clone successful
cat /var/log/clone-status.txt
```

Exit the SSH session.

### Checkpoint

The consumer VM is running in `tutorial-consumer`, cloned from the `fedora41-base-v1` golden image in `vm-golden-images`. Cloud-init has assigned it a unique hostname and machine-id, confirming it is an independent instance. The cross-namespace clone permission is managed entirely via git — the RoleBinding in ArgoCD will revert any manual change. The golden image PVC in `vm-golden-images` is unmodified and remains available for further clones.

---

## Phase 4: Version Rotation

Publish a v2 golden image, migrate the consumer VM to it, and retire v1 — all through git commits. No kubectl edits to the DataVolumes directly; ArgoCD is the change agent throughout.

### 4.1 Publish v2

The rotation starts with two git file operations: preserve v1 under a new filename with a status label change, then update the primary `datavolume.yaml` to describe v2.

**Step 1 — Preserve v1.** Copy `golden-images/images/fedora41/datavolume.yaml` to `golden-images/images/fedora41/datavolume-v1.yaml` and change the `image-status` label from `current` to `previous`:

**`golden-images/images/fedora41/datavolume-v1.yaml`**:

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: fedora41-base-v1
  namespace: vm-golden-images
  labels:
    os-family: linux
    image-status: previous
  annotations:
    golden-image/os-version: "Fedora 41"
    golden-image/source: "CDI HTTP import"
    golden-image/sealed-by: "cloud-init"
spec:
  source:
    http:
      url: "https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2"
  storage:
    storageClassName: ocs-storagecluster-ceph-rbd-virtualization
    resources:
      requests:
        storage: 10Gi
```

**Step 2 — Describe v2.** Update `golden-images/images/fedora41/datavolume.yaml` — change the `name` from `fedora41-base-v1` to `fedora41-base-v2`, keeping `image-status: current`:

**`golden-images/images/fedora41/datavolume.yaml`**:

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: fedora41-base-v2
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
    storageClassName: ocs-storagecluster-ceph-rbd-virtualization
    resources:
      requests:
        storage: 10Gi
```

**Step 3 — Register both files in Kustomize.** Update `golden-images/images/fedora41/kustomization.yaml` to include both DataVolume files:

**`golden-images/images/fedora41/kustomization.yaml`** (intermediate state):

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - datavolume.yaml
  - datavolume-v1.yaml
  - instancetype.yaml
  - preference.yaml
```

**Step 4 — Commit and push:**

```bash
git add golden-images/images/fedora41/
git commit -m "feat: publish Fedora 41 golden image v2 — retain v1 as previous"
git push origin main
```

### 4.2 Verify ArgoCD Syncs v2

ArgoCD detects the push and syncs the updated Kustomize output. CDI begins importing v2 while v1 continues to exist on-cluster.

```bash
# Expect: two DataVolumes — fedora41-base-v1 Succeeded, fedora41-base-v2 ImportInProgress → Succeeded
oc get dv -n vm-golden-images
```

Watch until v2 reaches `Succeeded` (1–3 minutes). Then confirm the labels are applied correctly:

```bash
# Expect: fedora41-base-v2 PVC with image-status=current
oc get pvc -n vm-golden-images -l image-status=current

# Expect: fedora41-base-v1 PVC with image-status=previous
oc get pvc -n vm-golden-images -l image-status=previous
```

Wait for v2 import to fully complete before proceeding to validation:

```bash
oc get dv fedora41-base-v2 -n vm-golden-images -o jsonpath='{.status.phase}'
# Expected output: Succeeded
```

### 4.3 Validate v2

Before migrating any consumer VM to v2, confirm it boots. The pattern is identical to 3.1 — a temporary VM that reads directly from the PVC with no cloud-init.

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: fedora41-v2-validation
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
            claimName: fedora41-base-v2
```

Save as `validation-vm-v2.yaml` and apply:

```bash
oc apply -f validation-vm-v2.yaml
```

Wait for the VMI to reach `Running`:

```bash
oc get vmi -n vm-golden-images -w
```

Open a serial console and verify the image is healthy:

```bash
virtctl console fedora41-v2-validation -n vm-golden-images
```

Inside the VM:

```bash
lspci | grep -i virtio
cloud-init status
cat /etc/machine-id
```

Exit with `Ctrl+]`. Then stop and delete the validation VM:

```bash
virtctl stop fedora41-v2-validation -n vm-golden-images
oc delete vm fedora41-v2-validation -n vm-golden-images
```

### 4.4 Migrate Consumer VM to v2

Migration requires three steps: stop the VM, delete its root disk PVC (which contains the v1 clone), and patch the VM definition to source from v2. The VM then re-clones on next start.

**Stop the VM:**

```bash
virtctl stop tutorial-vm -n tutorial-consumer
```

**Delete the existing root disk PVC** — this forces a fresh clone from the new source on restart:

```bash
oc delete pvc tutorial-vm-rootdisk -n tutorial-consumer
```

**Patch the VM to reference v2.** The patch updates `dataVolumeTemplates` to clone from `fedora41-base-v2`:

```bash
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
          storageClassName: ocs-storagecluster-ceph-rbd-virtualization
          resources:
            requests:
              storage: 10Gi
'
```

**Start the VM:**

```bash
virtctl start tutorial-vm -n tutorial-consumer
```

CDI clones `fedora41-base-v2` into a new `tutorial-vm-rootdisk` PVC in `tutorial-consumer`. Wait for the VM to reach `Running`, then verify the migrated VM has a fresh identity:

```bash
virtctl ssh fedora@tutorial-vm -n tutorial-consumer
```

Inside the VM:

```bash
# Should return: tutorial-vm
hostname

# Should return a new machine-id — different from the one observed in Phase 3
cat /etc/machine-id

# Should return: Golden image clone successful
cat /var/log/clone-status.txt
```

Exit the SSH session.

### 4.5 Retire v1

Retirement is a two-commit sequence: first label v1 as deprecated, verify no active consumers remain, then remove it from git and let ArgoCD prune the on-cluster resources.

**Commit 1 — Mark v1 deprecated.** Update `golden-images/images/fedora41/datavolume-v1.yaml`, changing `image-status: previous` to `image-status: deprecated`:

```bash
# Edit datavolume-v1.yaml — change image-status label value from previous to deprecated
git add golden-images/images/fedora41/datavolume-v1.yaml
git commit -m "chore: mark fedora41-base-v1 as deprecated"
git push origin main
```

**Verify no VMs reference v1.** Before deleting, confirm no running VM is still sourcing from v1:

```bash
# Should return no output — confirms no VM references fedora41-base-v1
oc get vm -A -o yaml | grep fedora41-base-v1
```

If this returns any output, do not proceed — identify the VM and migrate it to v2 first.

**Commit 2 — Remove v1 from git.** Delete `datavolume-v1.yaml` from the repository and restore `kustomization.yaml` to the v2-only state:

**`golden-images/images/fedora41/kustomization.yaml`** (final state):

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - datavolume.yaml
  - instancetype.yaml
  - preference.yaml
```

```bash
git rm golden-images/images/fedora41/datavolume-v1.yaml
git add golden-images/images/fedora41/kustomization.yaml
git commit -m "chore: retire fedora41-base-v1 — remove from GitOps management"
git push origin main
```

ArgoCD syncs the updated Kustomize output. Because the Application was created with `prune: true`, ArgoCD deletes the `fedora41-base-v1` DataVolume from the cluster. CDI deletes the DataVolume CR; the backing PVC is garbage-collected shortly after.

Confirm only v2 remains:

```bash
# Expect: only fedora41-base-v2 listed
oc get pvc -n vm-golden-images
```

### Checkpoint

v2 is the sole golden image in `vm-golden-images`. The consumer VM `tutorial-vm` in `tutorial-consumer` is running from a v2 clone with a fresh identity. v1 has been retired through a sequence of git commits — label change, consumer verification, git removal — with ArgoCD performing the on-cluster pruning. The full golden image lifecycle (publish, validate, migrate consumers, retire) has been exercised entirely through git operations.

---

## Cleanup

Tear down all tutorial resources:

```bash
# Delete the consumer VM and namespace
oc delete vm tutorial-vm -n tutorial-consumer
oc delete ns tutorial-consumer

# Delete the ArgoCD Application — this removes all synced resources
# (namespace, PVCs, RBAC, quota) because prune is enabled
oc delete application golden-images -n openshift-gitops

# Verify golden images namespace is removed
oc get ns vm-golden-images
# Expected: NotFound

# Optionally uninstall OpenShift GitOps operator
oc delete subscription openshift-gitops-operator -n openshift-operators
oc delete csv -n openshift-operators -l operators.coreos.com/openshift-gitops-operator.openshift-operators=
```

The git repo can be kept as a starting point for production use.

---

## Summary

What you learned:

1. How to install and configure OpenShift GitOps to manage golden VM images
2. How to structure a git repo with Kustomize for golden image definitions
3. How to import a cloud image via CDI HTTP source, managed by ArgoCD
4. How to set up cross-namespace RBAC for clone access, managed via git
5. How to deploy a consumer VM that clones from a GitOps-managed golden image
6. How to rotate image versions through git commits with ArgoCD handling sync and pruning
7. How the full image lifecycle (create, deploy, version, migrate, retire) maps to git operations

**Key takeaway:** Every cluster-side change in this tutorial (except the consumer VM itself) was driven by a git commit. The git repo is the single source of truth for golden image state.

---

## Next Steps

- Add Windows golden images using the sysprep ConfigMap pattern from the golden template pipeline spec, Section 7
- Add MTV-imported images by replacing `source: http` with `source: pvc` after an MTV cold migration lands a PVC
- Scale to multi-cluster using an ArgoCD ApplicationSet with cluster generators and per-cluster Kustomize overlays (described in the golden template pipeline spec, Section 8)
- Add alerting on failed DataVolume imports — an OCP PrometheusRule watching for DataVolumes stuck in ImportInProgress is the simplest approach
