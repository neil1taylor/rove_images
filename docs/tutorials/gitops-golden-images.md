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
- ODF installed (`ocs-storagecluster-ceph-rbd` StorageClass available)
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
    storageClassName: ocs-storagecluster-ceph-rbd
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
