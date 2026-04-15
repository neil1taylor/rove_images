# GitOps Golden Images Tutorial Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a hands-on tutorial document with supporting git repo scaffold files that walks a platform engineer through GitOps-managed golden image lifecycle on ROKS with ArgoCD.

**Architecture:** The spec (`docs/superpowers/specs/2026-04-15-gitops-golden-images-tutorial-design.md`) defines four phases. This plan produces: (1) a scaffold of the golden-images git repo structure the reader will create, (2) the tutorial markdown with all commands and YAML inline, (3) YAML validation. The scaffold files serve as a reference — the tutorial text tells the reader to create them, and the scaffold files in this repo are the answer key.

**Tech Stack:** Kubernetes/OCP YAML, Kustomize, ArgoCD CRs, Markdown

---

## File Structure

```
tutorial/
  golden-images/                          # scaffold of the git repo the reader creates
    base/
      namespace.yaml
      rbac/
        clone-source-clusterrole.yaml
        clone-source-rolebinding.yaml
      resource-quota.yaml
      kustomization.yaml
    images/
      fedora41/
        datavolume.yaml                   # v1 golden image (CDI HTTP source)
        datavolume-v1.yaml                # v1 retained during v2 transition (deprecated label)
        instancetype.yaml
        preference.yaml
        kustomization.yaml                # final state (v2 only, after v1 retirement)
        kustomization-with-v1.yaml        # intermediate state (both v1 and v2)
      kustomization.yaml
    kustomization.yaml
  argocd/
    subscription.yaml                     # OpenShift GitOps operator
    application.yaml                      # ArgoCD Application for golden-images
  consumer/
    vm.yaml                               # consumer VM with cloud-init
    validation-vm.yaml                    # temporary validation VM
docs/
  tutorials/
    gitops-golden-images.md               # the tutorial document
```

Each file in `tutorial/` is a standalone reference file. The tutorial document in `docs/tutorials/` is the primary deliverable — it contains all YAML inline so the reader doesn't need to clone this repo.

---

### Task 1: ArgoCD and Base Infrastructure Scaffold

**Files:**
- Create: `tutorial/argocd/subscription.yaml`
- Create: `tutorial/argocd/application.yaml`
- Create: `tutorial/golden-images/base/namespace.yaml`
- Create: `tutorial/golden-images/base/rbac/clone-source-clusterrole.yaml`
- Create: `tutorial/golden-images/base/rbac/clone-source-rolebinding.yaml`
- Create: `tutorial/golden-images/base/resource-quota.yaml`
- Create: `tutorial/golden-images/base/kustomization.yaml`
- Create: `tutorial/golden-images/kustomization.yaml`
- Create: `tutorial/golden-images/images/kustomization.yaml`

- [ ] **Step 1: Create OpenShift GitOps Subscription**

```yaml
# tutorial/argocd/subscription.yaml
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

- [ ] **Step 2: Create ArgoCD Application**

```yaml
# tutorial/argocd/application.yaml
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

- [ ] **Step 3: Create namespace manifest**

```yaml
# tutorial/golden-images/base/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: vm-golden-images
  labels:
    purpose: golden-images
```

- [ ] **Step 4: Create ClusterRole**

```yaml
# tutorial/golden-images/base/rbac/clone-source-clusterrole.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: golden-image-clone-source
rules:
  - apiGroups: ["cdi.kubevirt.io"]
    resources: ["datavolumes/source"]
    verbs: ["create"]
```

- [ ] **Step 5: Create RoleBinding**

```yaml
# tutorial/golden-images/base/rbac/clone-source-rolebinding.yaml
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

- [ ] **Step 6: Create ResourceQuota**

```yaml
# tutorial/golden-images/base/resource-quota.yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: golden-image-storage
  namespace: vm-golden-images
spec:
  hard:
    requests.storage: 500Gi
```

- [ ] **Step 7: Create base kustomization**

```yaml
# tutorial/golden-images/base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - rbac/clone-source-clusterrole.yaml
  - rbac/clone-source-rolebinding.yaml
  - resource-quota.yaml
```

- [ ] **Step 8: Create top-level kustomization**

```yaml
# tutorial/golden-images/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - base
  - images
```

- [ ] **Step 9: Create empty images kustomization**

```yaml
# tutorial/golden-images/images/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
```

- [ ] **Step 10: Validate all YAML**

Run: `for f in $(find tutorial/argocd tutorial/golden-images/base tutorial/golden-images/kustomization.yaml tutorial/golden-images/images/kustomization.yaml -name '*.yaml'); do echo "--- $f ---"; python3.11 -c "import yaml, sys; yaml.safe_load(open('$f')); print('OK')"; done`

Expected: All files print `OK`.

- [ ] **Step 11: Validate Kustomize builds**

Run: `kustomize build tutorial/golden-images/`

Expected: Outputs combined YAML for namespace, ClusterRole, RoleBinding, ResourceQuota.

- [ ] **Step 12: Commit**

```bash
git add tutorial/argocd/ tutorial/golden-images/
git commit -m "feat: add ArgoCD and base infrastructure scaffold for GitOps tutorial"
```

---

### Task 2: Golden Image and Consumer VM Scaffold

**Files:**
- Create: `tutorial/golden-images/images/fedora41/datavolume.yaml`
- Create: `tutorial/golden-images/images/fedora41/datavolume-v1.yaml`
- Create: `tutorial/golden-images/images/fedora41/instancetype.yaml`
- Create: `tutorial/golden-images/images/fedora41/preference.yaml`
- Create: `tutorial/golden-images/images/fedora41/kustomization.yaml`
- Create: `tutorial/golden-images/images/fedora41/kustomization-with-v1.yaml`
- Modify: `tutorial/golden-images/images/kustomization.yaml`
- Create: `tutorial/consumer/vm.yaml`
- Create: `tutorial/consumer/validation-vm.yaml`

- [ ] **Step 1: Create v1 DataVolume (current — becomes v2 after rotation)**

```yaml
# tutorial/golden-images/images/fedora41/datavolume.yaml
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
    storageClassName: ocs-storagecluster-ceph-rbd
    resources:
      requests:
        storage: 10Gi
```

Note: This file represents the **final state** of the repo after Phase 4 (v2 is current). The tutorial walks the reader through creating it first as v1, then modifying it to v2.

- [ ] **Step 2: Create v1 DataVolume (retained during transition, deprecated)**

```yaml
# tutorial/golden-images/images/fedora41/datavolume-v1.yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: fedora41-base-v1
  namespace: vm-golden-images
  labels:
    os-family: linux
    image-status: deprecated
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

This file exists during the v1→v2 transition. It is removed from the repo when v1 is retired.

- [ ] **Step 3: Create InstanceType**

```yaml
# tutorial/golden-images/images/fedora41/instancetype.yaml
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

- [ ] **Step 4: Create Preference**

```yaml
# tutorial/golden-images/images/fedora41/preference.yaml
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

- [ ] **Step 5: Create final kustomization (v2 only — after v1 retirement)**

```yaml
# tutorial/golden-images/images/fedora41/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - datavolume.yaml
  - instancetype.yaml
  - preference.yaml
```

- [ ] **Step 6: Create intermediate kustomization (v1 + v2 — during transition)**

```yaml
# tutorial/golden-images/images/fedora41/kustomization-with-v1.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - datavolume.yaml
  - datavolume-v1.yaml
  - instancetype.yaml
  - preference.yaml
```

- [ ] **Step 7: Update images kustomization to include fedora41**

```yaml
# tutorial/golden-images/images/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - fedora41
```

- [ ] **Step 8: Create consumer VM**

```yaml
# tutorial/consumer/vm.yaml
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
                - ssh-rsa AAAAB3_REPLACE_WITH_YOUR_KEY user@workstation
              runcmd:
                - echo "Golden image clone successful" > /var/log/clone-status.txt
```

- [ ] **Step 9: Create validation VM**

```yaml
# tutorial/consumer/validation-vm.yaml
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

- [ ] **Step 10: Validate all YAML**

Run: `for f in $(find tutorial/golden-images/images tutorial/consumer -name '*.yaml'); do echo "--- $f ---"; python3.11 -c "import yaml, sys; yaml.safe_load(open('$f')); print('OK')"; done`

Expected: All files print `OK`.

- [ ] **Step 11: Validate Kustomize builds with full image set**

Run: `kustomize build tutorial/golden-images/`

Expected: Outputs combined YAML including namespace, RBAC, quota, DataVolume (v2), InstanceType, Preference.

- [ ] **Step 12: Commit**

```bash
git add tutorial/golden-images/images/ tutorial/consumer/
git commit -m "feat: add Fedora golden image, consumer VM, and validation VM scaffold"
```

---

### Task 3: Tutorial Document — Phase 1 (Foundation)

**Files:**
- Create: `docs/tutorials/gitops-golden-images.md`

- [ ] **Step 1: Write the tutorial document through Phase 1**

Create `docs/tutorials/gitops-golden-images.md` containing:

1. **Title and overview** — title, audience, estimated time, what you'll build, prerequisites (exact content from the spec overview section)

2. **Phase 1: Foundation** — all of the following with inline YAML and CLI commands:
   - Step 1.1: Install OpenShift GitOps operator — Subscription CR YAML (from `tutorial/argocd/subscription.yaml`), verification commands (`oc get csv`, `oc get pods -n openshift-gitops`, route to ArgoCD UI)
   - Step 1.2: Scaffold the git repo — directory tree diagram, each file's content inline (from `tutorial/golden-images/base/` and top-level kustomization files), `git init && git add . && git commit && git remote add && git push` commands
   - Step 1.3: Create ArgoCD Application — Application CR YAML (from `tutorial/argocd/application.yaml`), note about private repo credentials, `oc apply -f` command
   - Step 1.4: Verify sync — `oc get application`, `oc get ns`, `oc get clusterrole`, `oc get rolebinding`, `oc get resourcequota` commands with expected output
   - Phase 1 checkpoint paragraph

All YAML blocks must match the scaffold files exactly. All commands must include expected output descriptions.

- [ ] **Step 2: Commit**

```bash
git add docs/tutorials/gitops-golden-images.md
git commit -m "feat: add GitOps golden images tutorial — Phase 1 (Foundation)"
```

---

### Task 4: Tutorial Document — Phase 2 (First Golden Image)

**Files:**
- Modify: `docs/tutorials/gitops-golden-images.md`

- [ ] **Step 1: Append Phase 2 to the tutorial**

Add Phase 2 content covering:

- Step 2.1: Create the `images/fedora41/` directory in the git repo — directory tree showing the new files
- Step 2.2: DataVolume with CDI HTTP source — full YAML inline (v1 version: name `fedora41-base-v1`, label `image-status: current`). Explain what CDI does: downloads the qcow2, converts to raw, writes to PVC. Note the Fedora cloud image URL and size.
- Step 2.3: InstanceType — full YAML inline (`fedora-small`, 2 vCPU, 4Gi)
- Step 2.4: Preference — full YAML inline (`fedora41-golden`, EFI, virtio, q35)
- Step 2.5: Kustomization files — `images/fedora41/kustomization.yaml` and updated `images/kustomization.yaml`, both inline
- Step 2.6: Commit, push, verify — git commands, ArgoCD sync check, `oc get dv -w` to watch import progress, `oc get pvc` to confirm Bound
- Phase 2 checkpoint paragraph

Important: In Phase 2, the DataVolume name is `fedora41-base-v1` with `image-status: current`. This differs from the scaffold file `datavolume.yaml` which shows the final v2 state. The tutorial walks the reader through creating v1 first, then modifying to v2 in Phase 4.

- [ ] **Step 2: Commit**

```bash
git add docs/tutorials/gitops-golden-images.md
git commit -m "feat: add GitOps golden images tutorial — Phase 2 (First Golden Image)"
```

---

### Task 5: Tutorial Document — Phase 3 (Template Promotion & Consumer VM)

**Files:**
- Modify: `docs/tutorials/gitops-golden-images.md`

- [ ] **Step 1: Append Phase 3 to the tutorial**

Add Phase 3 content covering:

- Step 3.1: Validate the golden image — create a temporary validation VM (`oc apply -f` with inline YAML matching `tutorial/consumer/validation-vm.yaml` but with `claimName: fedora41-base-v1`), `virtctl console` commands, what to check inside the VM (`lspci | grep -i virtio`, `cloud-init status`, `cat /etc/machine-id`), explain why no re-seal is needed (Fedora cloud images are pre-sealed), cleanup commands (`virtctl stop`, `oc delete vm`)
- Step 3.2: Set up consumer namespace — `oc create ns tutorial-consumer`, explain that the RoleBinding already grants access (created in Phase 1 with `tutorial-consumer` as subject), verify with `oc get rolebinding -n vm-golden-images`
- Step 3.3: Deploy consumer VM — full YAML inline (matching `tutorial/consumer/vm.yaml`), explain each section (instancetype/preference references, dataVolumeTemplates with cross-namespace source, cloudInitNoCloud), note about CDI clone being instant on ODF
- Step 3.4: Verify the consumer VM — `oc get vm`, `oc get vmi -o jsonpath` for IP, `virtctl ssh` command, what to check inside (`hostname`, `cat /etc/machine-id`, `cat /var/log/clone-status.txt`)
- Phase 3 checkpoint paragraph

- [ ] **Step 2: Commit**

```bash
git add docs/tutorials/gitops-golden-images.md
git commit -m "feat: add GitOps golden images tutorial — Phase 3 (Consumer VM)"
```

---

### Task 6: Tutorial Document — Phase 4 (Version Rotation)

**Files:**
- Modify: `docs/tutorials/gitops-golden-images.md`

- [ ] **Step 1: Append Phase 4 to the tutorial**

Add Phase 4 content covering:

- Step 4.1: Publish v2 — explain the git operations: (a) copy `datavolume.yaml` to `datavolume-v1.yaml` and change its label to `image-status: previous`, (b) update `datavolume.yaml` to name `fedora41-base-v2` with label `image-status: current`, (c) update kustomization to include both files. Show the exact file diffs or full file content for each change. Show the updated kustomization (matching `tutorial/golden-images/images/fedora41/kustomization-with-v1.yaml`). Git commit and push commands.
- Step 4.2: Verify ArgoCD syncs v2 — `oc get dv` showing both v1 and v2, `oc get pvc -l image-status=current`, wait for v2 import
- Step 4.3: Validate v2 — quick boot test (same pattern as 3.1 but referencing v2 PVC)
- Step 4.4: Migrate consumer VM — `virtctl stop`, `oc delete pvc tutorial-vm-rootdisk -n tutorial-consumer`, `oc patch vm` command (full patch YAML inline updating source PVC name to `fedora41-base-v2`), `virtctl start`, verification via SSH
- Step 4.5: Retire v1 — (a) update v1 label to `deprecated`, commit and push, (b) verify no VMs reference v1 (`oc get vm -A -o yaml | grep fedora41-base-v1`), (c) remove `datavolume-v1.yaml` from repo and kustomization, commit and push, (d) verify ArgoCD prunes v1 PVC (`oc get pvc -n vm-golden-images` shows only v2)
- Phase 4 checkpoint paragraph

- [ ] **Step 2: Commit**

```bash
git add docs/tutorials/gitops-golden-images.md
git commit -m "feat: add GitOps golden images tutorial — Phase 4 (Version Rotation)"
```

---

### Task 7: Tutorial Document — Cleanup and Summary

**Files:**
- Modify: `docs/tutorials/gitops-golden-images.md`

- [ ] **Step 1: Append Cleanup and Summary sections**

Add:

- **Cleanup** — `oc delete vm tutorial-vm -n tutorial-consumer`, `oc delete ns tutorial-consumer`, `oc delete application golden-images -n openshift-gitops` (explain that prune deletes all synced resources), optional operator uninstall commands, note that git repo can be kept for production use
- **Summary** — numbered list of what was learned (7 items from the spec: GitOps setup, repo structure, CDI import, RBAC via git, consumer cloning, version rotation, full lifecycle mapping to git operations)
- **Next Steps** — bullet list: add Windows golden images (link to main spec Section 7), add MTV-imported images, scale to multi-cluster with ApplicationSet (link to main spec Section 8), add alerting on failed DataVolume imports

- [ ] **Step 2: Commit**

```bash
git add docs/tutorials/gitops-golden-images.md
git commit -m "feat: complete GitOps golden images tutorial — Cleanup and Summary"
```

---

### Task 8: Final Validation

- [ ] **Step 1: Validate all YAML in tutorial/ directory**

Run: `for f in $(find tutorial -name '*.yaml'); do echo "--- $f ---"; python3.11 -c "import yaml, sys; yaml.safe_load(open('$f')); print('OK')"; done`

Expected: All files print `OK`.

- [ ] **Step 2: Validate Kustomize builds**

Run: `kustomize build tutorial/golden-images/`

Expected: Valid combined YAML output with no errors.

- [ ] **Step 3: Verify tutorial document exists and has all phases**

Run: `grep -c '## Phase' docs/tutorials/gitops-golden-images.md`

Expected: `4` (Phase 1 through Phase 4).

Run: `grep -c '### Checkpoint' docs/tutorials/gitops-golden-images.md`

Expected: `4` (one checkpoint per phase).

- [ ] **Step 4: Verify all YAML in the tutorial document matches scaffold files**

Spot-check: the DataVolume URL, InstanceType spec, Preference spec, consumer VM spec in the tutorial text should match the scaffold files in `tutorial/`. The tutorial contains inline YAML that must be consistent with the reference files.

- [ ] **Step 5: Commit if any fixes needed**

```bash
git status  # should be clean if all passed
```
