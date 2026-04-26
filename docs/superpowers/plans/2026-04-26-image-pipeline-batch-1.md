# Image Pipeline Expansion — Batch 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the shared Tekton scaffolding + 4 pilot golden-image pipelines (RHEL 9 vanilla/hardened, Win Server 2025 UEFI vanilla/hardened) and prove the templating pattern with a scratch-branch RHEL 8 reuse test, satisfying §6 of the PRD.

**Architecture:** Reusable Tekton `Task`s in `manifests/pipelines/shared-tasks/` and `manifests/pipelines/boot-trigger-tasks/`, plus per-variant Kustomize overlays in `manifests/<class>/<variant>/` that compose those Tasks into thin Pipelines. Build namespaces (`linux-image-build`, `windows-image-build`) reuse the existing pattern; output catalogue is `openshift-virtualization-os-images`.

**Tech Stack:** OpenShift Pipelines (Tekton v1), OpenShift Virtualization (KubeVirt + CDI), Kustomize, kickstart (Anaconda) + OpenSCAP `scap-security-guide` for Linux, Autounattend.xml + Microsoft Security Compliance Toolkit for Windows.

**Cluster:** `nrt-prod-cluster1`. Source `.env` before any `oc`/`kubectl` work (per project CLAUDE.md).

**Plan scope:** Batch 1 only. Batches 2–5 (the remaining 26 pipelines) get their own plans.

---

## Prerequisites — resolve before starting

These open decisions from PRD §6.3 must be locked before code starts. Capture answers in a comment on the implementation tracking issue (or inline at the top of this plan as it executes).

- **D1 — Hardened baseline:** CIS L1 (recommended) or DISA STIG? *This plan assumes CIS L1.*
- **D2 — Audit retention:** 30-day in-cluster ConfigMap (recommended) or push to long-term storage? *This plan assumes 30-day in-cluster.*
- **D3 — SLES inclusion:** not relevant to Batch 1; defer to Batch 3.
- **D4 — Build namespace strategy:** single `image-build` or per-class? *This plan assumes per-class (`linux-image-build`, `windows-image-build`), mirroring today's split.*
- **D5 — `Task` vs `ClusterTask`:** *This plan uses namespaced `Task` per build namespace, referenced from per-variant Pipelines in the same namespace. ClusterTask deliberately avoided.*
- **D6 — Microsoft SCT mirror:** Phase 5 begins with a spike (Task 5.1) that must produce a go/no-go answer before any hardened-Windows code. If "no-go" (SCT URLs are unstable), we mirror SCT to internal storage as a one-off exception to vendor-direct sourcing.
- **D7 — Installer-VM spec location:** *This plan inlines the installer-VM `taskSpec` in each variant's `pipeline.yaml`*, per the spec's recommendation in §3.5.

If any decision changes from the assumed default, revise affected tasks before executing.

---

## File structure

```
manifests/
├── pipelines/                              # NEW
│   ├── kustomization.yaml                  # NEW — aggregates all sub-kustomizations below
│   ├── build-namespaces/                   # NEW
│   │   ├── kustomization.yaml
│   │   ├── linux-image-build.yaml          # Namespace + SA + ClusterRole + ClusterRoleBinding
│   │   └── windows-image-build.yaml        # ditto
│   ├── shared-tasks/                       # NEW — applied per build namespace
│   │   ├── kustomization.yaml
│   │   ├── upload-source-artefact.yaml
│   │   ├── create-blank-root-disk.yaml
│   │   ├── wait-for-vm-shutdown.yaml
│   │   ├── clone-to-catalog.yaml
│   │   └── cleanup-build-namespace.yaml
│   └── boot-trigger-tasks/                 # NEW
│       ├── kustomization.yaml
│       ├── trigger-cd-boot-uefi.yaml
│       ├── trigger-cd-boot-bios.yaml
│       └── trigger-cd-boot-linux.yaml
├── linux/
│   ├── rhel-9/                             # NEW
│   │   ├── kustomization.yaml
│   │   ├── pipeline.yaml
│   │   ├── pipelinerun.yaml
│   │   ├── pipeline-rbac.yaml
│   │   ├── kickstart-configmap.yaml
│   │   └── README.md
│   └── rhel-9-hardened/                    # NEW
│       └── (same shape, hardened kickstart)
└── windows/
    ├── server-2025-uefi/                   # NEW
    │   ├── kustomization.yaml
    │   ├── pipeline.yaml
    │   ├── pipelinerun.yaml
    │   ├── pipeline-rbac.yaml
    │   ├── autounattend-configmap.yaml
    │   └── README.md
    ├── server-2025-uefi-hardened/          # NEW
    │   └── (same shape, hardened Autounattend with SCT)
    ├── pipeline-bios/                      # UNTOUCHED in Batch 1
    └── pipeline-uefi/                      # UNTOUCHED in Batch 1
```

**Existing files left untouched in Batch 1:** `manifests/windows/pipeline-bios/*`, `manifests/windows/pipeline-uefi/*`, `manifests/linux/{consumer-vm,instancetype,preference}.yaml`, `manifests/lifecycle/*`, `manifests/storage/*`, `manifests/rbac/*`, `manifests/mtv/*`, `manifests/namespace.yaml`, `manifests/resource-quota.yaml`. The existing Win 2022 UEFI pipeline is the *reference implementation* for the new pattern but is not refactored until Batch 4.

---

## Phase 1 — Shared scaffolding

Phase goal: the cluster ends up with two build namespaces, each containing the 5 shared Tasks + 3 boot-trigger Tasks. After this phase, the next phase can reference `taskRef: { name: upload-source-artefact }` etc. without further setup.

### Task 1.1: Create `linux-image-build` namespace + RBAC

**Files:**
- Create: `manifests/pipelines/build-namespaces/linux-image-build.yaml`
- Create: `manifests/pipelines/build-namespaces/kustomization.yaml`

The RBAC follows the existing `manifests/windows/pipeline-uefi/pipeline-rbac.yaml` pattern: a single ClusterRole granting permissions across kubevirt, cdi, pods, pods/exec, and pvcs, plus a per-namespace SA + ClusterRoleBinding.

- [ ] **Step 1: Define state check**

```bash
oc get ns linux-image-build -o jsonpath='{.metadata.name}' 2>/dev/null
```
Expected before apply: empty (namespace does not exist).

- [ ] **Step 2: Confirm state check fails**

Run the command from Step 1. Confirm output is empty.

- [ ] **Step 3: Create `linux-image-build.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: linux-image-build
  labels:
    purpose: image-build
    image-class: linux
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: linux-image-pipeline
  namespace: linux-image-build
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: linux-image-pipeline
rules:
  - apiGroups: ["kubevirt.io"]
    resources: ["virtualmachines", "virtualmachineinstances"]
    verbs: ["get", "list", "watch", "create", "delete", "update", "patch"]
  - apiGroups: ["cdi.kubevirt.io"]
    resources: ["datavolumes", "datasources"]
    verbs: ["get", "list", "watch", "create", "delete", "update", "patch"]
  - apiGroups: ["cdi.kubevirt.io"]
    resources: ["datavolumes/source"]
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list", "watch", "create", "delete"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: linux-image-pipeline
subjects:
  - kind: ServiceAccount
    name: linux-image-pipeline
    namespace: linux-image-build
roleRef:
  kind: ClusterRole
  name: linux-image-pipeline
  apiGroup: rbac.authorization.k8s.io
```

- [ ] **Step 4: Create `kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - linux-image-build.yaml
```

- [ ] **Step 5: Apply**

```bash
source .env
oc apply -k manifests/pipelines/build-namespaces/
```

- [ ] **Step 6: Verify state check passes**

```bash
oc get ns linux-image-build -o jsonpath='{.metadata.name}'
```
Expected: `linux-image-build`

```bash
oc get sa linux-image-pipeline -n linux-image-build -o jsonpath='{.metadata.name}'
```
Expected: `linux-image-pipeline`

- [ ] **Step 7: Commit**

```bash
git add manifests/pipelines/build-namespaces/linux-image-build.yaml \
        manifests/pipelines/build-namespaces/kustomization.yaml
git commit -m "Add linux-image-build namespace and pipeline RBAC"
```

---

### Task 1.2: Add `windows-image-build` namespace + RBAC

**Files:**
- Create: `manifests/pipelines/build-namespaces/windows-image-build.yaml`
- Modify: `manifests/pipelines/build-namespaces/kustomization.yaml`

The existing `windows-image-build` namespace was created imperatively in earlier work; this task brings it under git control alongside Linux. If the namespace already exists with the existing `windows-image-pipeline` SA, the apply is idempotent and only adds the missing parts.

- [ ] **Step 1: Inspect existing namespace state**

```bash
oc get ns windows-image-build -o jsonpath='{.metadata.name}'
oc get sa windows-image-pipeline -n windows-image-build -o jsonpath='{.metadata.name}'
oc get clusterrole windows-image-pipeline -o jsonpath='{.metadata.name}'
```
If all three exist, Step 4 will reconcile (apply is idempotent). If anything is missing, Step 4 creates it.

- [ ] **Step 2: Create `windows-image-build.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: windows-image-build
  labels:
    purpose: image-build
    image-class: windows
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: windows-image-pipeline
  namespace: windows-image-build
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: windows-image-pipeline
rules:
  - apiGroups: ["kubevirt.io"]
    resources: ["virtualmachines", "virtualmachineinstances"]
    verbs: ["get", "list", "watch", "create", "delete", "update", "patch"]
  - apiGroups: ["cdi.kubevirt.io"]
    resources: ["datavolumes", "datasources"]
    verbs: ["get", "list", "watch", "create", "delete", "update", "patch"]
  - apiGroups: ["cdi.kubevirt.io"]
    resources: ["datavolumes/source"]
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list", "watch", "create", "delete"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: windows-image-pipeline
subjects:
  - kind: ServiceAccount
    name: windows-image-pipeline
    namespace: windows-image-build
roleRef:
  kind: ClusterRole
  name: windows-image-pipeline
  apiGroup: rbac.authorization.k8s.io
```

- [ ] **Step 3: Update `kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - linux-image-build.yaml
  - windows-image-build.yaml
```

- [ ] **Step 4: Apply**

```bash
source .env
oc apply -k manifests/pipelines/build-namespaces/
```

- [ ] **Step 5: Verify**

```bash
oc get ns windows-image-build linux-image-build \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
```
Expected (order may vary):
```
linux-image-build
windows-image-build
```

- [ ] **Step 6: Commit**

```bash
git add manifests/pipelines/build-namespaces/windows-image-build.yaml \
        manifests/pipelines/build-namespaces/kustomization.yaml
git commit -m "Bring windows-image-build namespace under git control"
```

---

### Task 1.3: Shared `Task` — `upload-source-artefact`

Replaces the duplicated "upload Windows ISO" / "upload virtio ISO" / hypothetical "upload RHEL ISO" steps from `manifests/windows/pipeline-uefi/pipeline.yaml:29-130`. Idempotent: if the target DataVolume already exists and is `Ready`, the Task short-circuits.

**Files:**
- Create: `manifests/pipelines/shared-tasks/upload-source-artefact.yaml`
- Create: `manifests/pipelines/shared-tasks/kustomization.yaml`

- [ ] **Step 1: Define state check**

```bash
oc get task upload-source-artefact -n linux-image-build -o jsonpath='{.metadata.name}' 2>/dev/null
```
Expected before apply: empty.

- [ ] **Step 2: Confirm state check fails**

Run the command. Confirm empty output.

- [ ] **Step 3: Create the Task manifest**

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: upload-source-artefact
spec:
  description: |
    Idempotently create a DataVolume from an HTTP URL.
    If the named DataVolume already exists and is Ready, exit 0.
  params:
    - name: dvName
      description: Target DataVolume name
      type: string
    - name: namespace
      description: Namespace for the DataVolume
      type: string
    - name: url
      description: HTTP URL of the source artefact (ISO or qcow2)
      type: string
    - name: storageClass
      description: StorageClass for the DataVolume PVC
      type: string
    - name: storageSize
      description: Storage request (e.g. 7Gi)
      type: string
    - name: accessMode
      description: ReadWriteOnce or ReadWriteMany
      type: string
      default: ReadWriteMany
  steps:
    - name: create-dv
      image: image-registry.openshift-image-registry.svc:5000/openshift/cli:latest
      script: |
        #!/bin/bash
        set -euo pipefail
        if oc wait datavolume/$(params.dvName) \
          -n $(params.namespace) \
          --for=condition=Ready \
          --timeout=5s 2>/dev/null; then
          echo "DataVolume $(params.dvName) already exists and is Ready -- skipping download"
          exit 0
        fi
        echo "Creating DataVolume $(params.dvName)..."
        cat <<DVEOF | oc apply -f -
        apiVersion: cdi.kubevirt.io/v1beta1
        kind: DataVolume
        metadata:
          name: $(params.dvName)
          namespace: $(params.namespace)
        spec:
          source:
            http:
              url: "$(params.url)"
          storage:
            storageClassName: $(params.storageClass)
            accessModes:
              - $(params.accessMode)
            resources:
              requests:
                storage: $(params.storageSize)
        DVEOF
        echo "Waiting for DataVolume $(params.dvName) to complete..."
        oc wait datavolume/$(params.dvName) \
          -n $(params.namespace) \
          --for=condition=Ready \
          --timeout=60m
        echo "DataVolume $(params.dvName) ready"
```

- [ ] **Step 4: Create `kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: linux-image-build
resources:
  - upload-source-artefact.yaml
```

The kustomization initially targets `linux-image-build`; later tasks add an overlay that retargets the same set into `windows-image-build`. Per D5 (namespaced Tasks), the same Task definitions are applied into each build namespace.

- [ ] **Step 5: Apply to Linux namespace**

```bash
source .env
oc apply -k manifests/pipelines/shared-tasks/
```

- [ ] **Step 6: Verify state check passes**

```bash
oc get task upload-source-artefact -n linux-image-build -o jsonpath='{.metadata.name}'
```
Expected: `upload-source-artefact`

- [ ] **Step 7: Commit**

```bash
git add manifests/pipelines/shared-tasks/upload-source-artefact.yaml \
        manifests/pipelines/shared-tasks/kustomization.yaml
git commit -m "Add shared Task: upload-source-artefact"
```

---

### Task 1.4: Shared `Task` — `create-blank-root-disk`

Replaces the per-pipeline blank-disk creation in `manifests/windows/pipeline-uefi/pipeline.yaml:132-173`.

**Files:**
- Create: `manifests/pipelines/shared-tasks/create-blank-root-disk.yaml`
- Modify: `manifests/pipelines/shared-tasks/kustomization.yaml`

- [ ] **Step 1: Define state check**

```bash
oc get task create-blank-root-disk -n linux-image-build -o jsonpath='{.metadata.name}' 2>/dev/null
```
Expected before apply: empty.

- [ ] **Step 2: Create the Task manifest**

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: create-blank-root-disk
spec:
  description: Create a blank DataVolume to be the installer VM's root disk.
  params:
    - name: dvName
      type: string
    - name: namespace
      type: string
    - name: storageClass
      type: string
    - name: rootDiskSize
      type: string
    - name: accessMode
      type: string
      default: ReadWriteMany
  steps:
    - name: create-dv
      image: image-registry.openshift-image-registry.svc:5000/openshift/cli:latest
      script: |
        #!/bin/bash
        set -euo pipefail
        cat <<DVEOF | oc apply -f -
        apiVersion: cdi.kubevirt.io/v1beta1
        kind: DataVolume
        metadata:
          name: $(params.dvName)
          namespace: $(params.namespace)
        spec:
          source:
            blank: {}
          storage:
            storageClassName: $(params.storageClass)
            accessModes:
              - $(params.accessMode)
            resources:
              requests:
                storage: $(params.rootDiskSize)
        DVEOF
        echo "Waiting for blank DataVolume $(params.dvName)..."
        oc wait datavolume/$(params.dvName) \
          -n $(params.namespace) \
          --for=condition=Ready \
          --timeout=30m
        echo "Blank DataVolume $(params.dvName) ready"
```

- [ ] **Step 3: Append to kustomization**

Edit `manifests/pipelines/shared-tasks/kustomization.yaml` so `resources:` becomes:

```yaml
resources:
  - upload-source-artefact.yaml
  - create-blank-root-disk.yaml
```

- [ ] **Step 4: Apply**

```bash
oc apply -k manifests/pipelines/shared-tasks/
```

- [ ] **Step 5: Verify**

```bash
oc get task create-blank-root-disk -n linux-image-build -o jsonpath='{.metadata.name}'
```
Expected: `create-blank-root-disk`

- [ ] **Step 6: Commit**

```bash
git add manifests/pipelines/shared-tasks/create-blank-root-disk.yaml \
        manifests/pipelines/shared-tasks/kustomization.yaml
git commit -m "Add shared Task: create-blank-root-disk"
```

---

### Task 1.5: Shared `Task` — `wait-for-vm-shutdown`

Replaces `manifests/windows/pipeline-uefi/pipeline.yaml:327-364`.

**Files:**
- Create: `manifests/pipelines/shared-tasks/wait-for-vm-shutdown.yaml`
- Modify: `manifests/pipelines/shared-tasks/kustomization.yaml`

- [ ] **Step 1: Define state check**

```bash
oc get task wait-for-vm-shutdown -n linux-image-build -o jsonpath='{.metadata.name}' 2>/dev/null
```
Expected: empty.

- [ ] **Step 2: Create the Task manifest**

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: wait-for-vm-shutdown
spec:
  description: |
    Wait for a VirtualMachineInstance to reach phase Succeeded
    (i.e. guest cleanly shut down). Default timeout 4h covers
    Windows install + Sysprep cycle.
  params:
    - name: vmName
      type: string
    - name: namespace
      type: string
  steps:
    - name: wait
      image: image-registry.openshift-image-registry.svc:5000/openshift/cli:latest
      timeout: "4h"
      script: |
        #!/bin/bash
        set -euo pipefail
        echo "Waiting for VMI $(params.vmName) to shut down..."
        echo "(45-90 min for unattended Windows install + Sysprep; ~20-40 min for typical Linux kickstart.)"
        while true; do
          PHASE=$(oc get vmi $(params.vmName) -n $(params.namespace) \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
          echo "$(date): VMI phase = $PHASE"
          if [ "$PHASE" = "Succeeded" ]; then
            echo "VMI shut down successfully (install/Sysprep complete)"
            exit 0
          fi
          if [ "$PHASE" = "Failed" ]; then
            echo "ERROR: VMI failed"
            exit 1
          fi
          if [ "$PHASE" = "NotFound" ]; then
            VM_STATUS=$(oc get vm $(params.vmName) -n $(params.namespace) \
              -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "Unknown")
            if [ "$VM_STATUS" = "Stopped" ]; then
              echo "VMI gone and VM is Stopped -- shutdown complete"
              exit 0
            fi
            echo "VMI not found, VM status = $VM_STATUS (may be starting up)"
          fi
          sleep 15
        done
```

- [ ] **Step 3: Append to kustomization**

Edit `kustomization.yaml` so `resources:` includes `- wait-for-vm-shutdown.yaml`.

- [ ] **Step 4: Apply**

```bash
oc apply -k manifests/pipelines/shared-tasks/
```

- [ ] **Step 5: Verify**

```bash
oc get task wait-for-vm-shutdown -n linux-image-build -o jsonpath='{.metadata.name}'
```
Expected: `wait-for-vm-shutdown`

- [ ] **Step 6: Commit**

```bash
git add manifests/pipelines/shared-tasks/wait-for-vm-shutdown.yaml \
        manifests/pipelines/shared-tasks/kustomization.yaml
git commit -m "Add shared Task: wait-for-vm-shutdown"
```

---

### Task 1.6: Shared `Task` — `clone-to-catalog`

Replaces `manifests/windows/pipeline-uefi/pipeline.yaml:366-435`. Clones the build root-disk PVC into `openshift-virtualization-os-images` and creates/updates a `DataSource` with instancetype + preference labels (and an optional compliance label for hardened variants).

**Files:**
- Create: `manifests/pipelines/shared-tasks/clone-to-catalog.yaml`
- Modify: `manifests/pipelines/shared-tasks/kustomization.yaml`

- [ ] **Step 1: Define state check**

```bash
oc get task clone-to-catalog -n linux-image-build -o jsonpath='{.metadata.name}' 2>/dev/null
```
Expected: empty.

- [ ] **Step 2: Create the Task manifest**

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: clone-to-catalog
spec:
  description: |
    Clone the build root-disk PVC into openshift-virtualization-os-images
    and create/update a DataSource with the appropriate labels.
  params:
    - name: sourcePvcName
      type: string
    - name: sourceNamespace
      type: string
    - name: goldenImageName
      type: string
    - name: storageClass
      type: string
    - name: rootDiskSize
      type: string
    - name: defaultInstancetype
      type: string
    - name: defaultPreference
      type: string
    - name: complianceBaseline
      description: |
        Optional compliance baseline label (e.g. "cis-l1") for hardened
        variants. Empty string means no label is added.
      type: string
      default: ""
    - name: accessMode
      type: string
      default: ReadWriteMany
  steps:
    - name: clone
      image: image-registry.openshift-image-registry.svc:5000/openshift/cli:latest
      script: |
        #!/bin/bash
        set -euo pipefail
        TARGET_NS="openshift-virtualization-os-images"

        # Build label block for DV + DS
        LABEL_BLOCK="
                  instancetype.kubevirt.io/default-instancetype: $(params.defaultInstancetype)
                  instancetype.kubevirt.io/default-preference: $(params.defaultPreference)"
        if [ -n "$(params.complianceBaseline)" ]; then
          LABEL_BLOCK="${LABEL_BLOCK}
                  compliance.kubevirt.io/baseline: $(params.complianceBaseline)"
        fi

        cat <<DVEOF | oc apply -f -
        apiVersion: cdi.kubevirt.io/v1beta1
        kind: DataVolume
        metadata:
          name: $(params.goldenImageName)
          namespace: ${TARGET_NS}
          labels:${LABEL_BLOCK}
        spec:
          source:
            pvc:
              name: $(params.sourcePvcName)
              namespace: $(params.sourceNamespace)
          storage:
            storageClassName: $(params.storageClass)
            accessModes:
              - $(params.accessMode)
            resources:
              requests:
                storage: $(params.rootDiskSize)
        DVEOF

        echo "Waiting for clone to complete..."
        oc wait datavolume/$(params.goldenImageName) \
          -n ${TARGET_NS} \
          --for=condition=Ready \
          --timeout=60m

        cat <<DSEOF | oc apply -f -
        apiVersion: cdi.kubevirt.io/v1beta1
        kind: DataSource
        metadata:
          name: $(params.goldenImageName)
          namespace: ${TARGET_NS}
          labels:${LABEL_BLOCK}
        spec:
          source:
            pvc:
              name: $(params.goldenImageName)
              namespace: ${TARGET_NS}
        DSEOF
        echo "DataSource $(params.goldenImageName) created/updated in ${TARGET_NS}"
```

- [ ] **Step 3: Append to kustomization**

Add `- clone-to-catalog.yaml` to `resources:`.

- [ ] **Step 4: Apply**

```bash
oc apply -k manifests/pipelines/shared-tasks/
```

- [ ] **Step 5: Verify**

```bash
oc get task clone-to-catalog -n linux-image-build -o jsonpath='{.metadata.name}'
```
Expected: `clone-to-catalog`

- [ ] **Step 6: Commit**

```bash
git add manifests/pipelines/shared-tasks/clone-to-catalog.yaml \
        manifests/pipelines/shared-tasks/kustomization.yaml
git commit -m "Add shared Task: clone-to-catalog"
```

---

### Task 1.7: Shared `Task` — `cleanup-build-namespace`

Replaces `manifests/windows/pipeline-uefi/pipeline.yaml:438-451`. Deletes the installer VM and its blank root-disk DV, leaving the source-artefact DataVolumes intact (they're cached for future runs).

**Files:**
- Create: `manifests/pipelines/shared-tasks/cleanup-build-namespace.yaml`
- Modify: `manifests/pipelines/shared-tasks/kustomization.yaml`

- [ ] **Step 1: Define state check**

```bash
oc get task cleanup-build-namespace -n linux-image-build -o jsonpath='{.metadata.name}' 2>/dev/null
```
Expected: empty.

- [ ] **Step 2: Create the Task manifest**

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: cleanup-build-namespace
spec:
  description: |
    Delete the installer VM and the blank root-disk DataVolume.
    Source-artefact DataVolumes (ISOs, cloud images) are retained
    for cache-hits on future runs.
  params:
    - name: vmName
      type: string
    - name: rootDiskDvName
      type: string
    - name: namespace
      type: string
  steps:
    - name: cleanup
      image: image-registry.openshift-image-registry.svc:5000/openshift/cli:latest
      script: |
        #!/bin/bash
        set -euo pipefail
        echo "Cleaning up build resources..."
        oc delete vm $(params.vmName) -n $(params.namespace) --ignore-not-found
        oc delete dv $(params.rootDiskDvName) -n $(params.namespace) --ignore-not-found
        echo "Cleanup complete (source ISOs retained)"
```

- [ ] **Step 3: Append to kustomization**

Add `- cleanup-build-namespace.yaml` to `resources:`.

- [ ] **Step 4: Apply**

```bash
oc apply -k manifests/pipelines/shared-tasks/
```

- [ ] **Step 5: Verify**

```bash
oc get task cleanup-build-namespace -n linux-image-build -o jsonpath='{.metadata.name}'
```
Expected: `cleanup-build-namespace`

- [ ] **Step 6: Commit**

```bash
git add manifests/pipelines/shared-tasks/cleanup-build-namespace.yaml \
        manifests/pipelines/shared-tasks/kustomization.yaml
git commit -m "Add shared Task: cleanup-build-namespace"
```

---

### Task 1.8: Apply shared Tasks to `windows-image-build` namespace

Per D5, Tasks are namespaced. The kustomization currently targets `linux-image-build`. We add a per-namespace overlay so the same five Tasks land in `windows-image-build` too.

**Files:**
- Modify: `manifests/pipelines/shared-tasks/kustomization.yaml` (rename to base + add overlay layout)
- Create: `manifests/pipelines/shared-tasks/overlays/linux/kustomization.yaml`
- Create: `manifests/pipelines/shared-tasks/overlays/windows/kustomization.yaml`

- [ ] **Step 1: Refactor base kustomization**

Edit `manifests/pipelines/shared-tasks/kustomization.yaml` to remove the `namespace:` line — it becomes a pure base.

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - upload-source-artefact.yaml
  - create-blank-root-disk.yaml
  - wait-for-vm-shutdown.yaml
  - clone-to-catalog.yaml
  - cleanup-build-namespace.yaml
```

- [ ] **Step 2: Create `overlays/linux/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: linux-image-build
resources:
  - ../..
```

- [ ] **Step 3: Create `overlays/windows/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: windows-image-build
resources:
  - ../..
```

- [ ] **Step 4: Apply both overlays**

```bash
oc apply -k manifests/pipelines/shared-tasks/overlays/linux/
oc apply -k manifests/pipelines/shared-tasks/overlays/windows/
```

- [ ] **Step 5: Verify in both namespaces**

```bash
for NS in linux-image-build windows-image-build; do
  echo "=== $NS ==="
  oc get tasks -n $NS -o name
done
```
Expected (each namespace):
```
task.tekton.dev/upload-source-artefact
task.tekton.dev/create-blank-root-disk
task.tekton.dev/wait-for-vm-shutdown
task.tekton.dev/clone-to-catalog
task.tekton.dev/cleanup-build-namespace
```

- [ ] **Step 6: Commit**

```bash
git add manifests/pipelines/shared-tasks/
git commit -m "Apply shared Tasks to both linux and windows build namespaces"
```

---

### Task 1.9: Boot-trigger Task — `trigger-cd-boot-uefi`

Lift-and-shift the existing OVMF boot-manager dance from `manifests/windows/pipeline-uefi/pipeline.yaml:275-324` into a reusable Task.

**Files:**
- Create: `manifests/pipelines/boot-trigger-tasks/trigger-cd-boot-uefi.yaml`
- Create: `manifests/pipelines/boot-trigger-tasks/kustomization.yaml`
- Create: `manifests/pipelines/boot-trigger-tasks/overlays/linux/kustomization.yaml`
- Create: `manifests/pipelines/boot-trigger-tasks/overlays/windows/kustomization.yaml`

- [ ] **Step 1: Define state check**

```bash
oc get task trigger-cd-boot-uefi -n windows-image-build -o jsonpath='{.metadata.name}' 2>/dev/null
```
Expected: empty.

- [ ] **Step 2: Create the Task manifest**

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: trigger-cd-boot-uefi
spec:
  description: |
    For UEFI installer VMs: wait for the CD boot prompt to time out,
    navigate the OVMF Boot Manager, and select the CDROM device.
    The OVMF Boot Manager waits indefinitely for input, so there's
    no timing race. Originally extracted from the Win 2022 UEFI pipeline.
  params:
    - name: vmName
      type: string
    - name: namespace
      type: string
  steps:
    - name: send-keypress
      image: image-registry.openshift-image-registry.svc:5000/openshift/cli:latest
      script: |
        #!/bin/bash
        set -euo pipefail
        echo "Waiting for VMI $(params.vmName) to be Running..."
        oc wait vmi/$(params.vmName) -n $(params.namespace) \
          --for=jsonpath='{.status.phase}'=Running \
          --timeout=10m
        POD=$(oc get pods -n $(params.namespace) \
          -l kubevirt.io/vm=$(params.vmName) \
          -o jsonpath='{.items[0].metadata.name}')
        VIRSH="oc exec -n $(params.namespace) $POD -- virsh -c qemu:///session"

        echo "Waiting 15s for UEFI CD boot prompt to time out..."
        sleep 15

        echo "Entering OVMF firmware setup..."
        $VIRSH send-key 1 KEY_ENTER
        sleep 2

        echo "Navigating to Boot Manager..."
        $VIRSH send-key 1 KEY_DOWN
        sleep 1
        $VIRSH send-key 1 KEY_DOWN
        sleep 1
        $VIRSH send-key 1 KEY_ENTER
        sleep 2

        echo "Selecting CDROM device..."
        $VIRSH send-key 1 KEY_ENTER
        sleep 1

        echo "Sending keypresses for CD boot prompt..."
        for i in $(seq 1 10); do
          $VIRSH send-key 1 KEY_SPACE 2>/dev/null || true
          sleep 1
        done
        echo "Boot sequence complete -- installer should be loading"
```

- [ ] **Step 3: Create base kustomization**

`manifests/pipelines/boot-trigger-tasks/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - trigger-cd-boot-uefi.yaml
```

- [ ] **Step 4: Create per-namespace overlays**

`overlays/linux/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: linux-image-build
resources:
  - ../..
```

`overlays/windows/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: windows-image-build
resources:
  - ../..
```

- [ ] **Step 5: Apply**

```bash
oc apply -k manifests/pipelines/boot-trigger-tasks/overlays/linux/
oc apply -k manifests/pipelines/boot-trigger-tasks/overlays/windows/
```

- [ ] **Step 6: Verify**

```bash
oc get task trigger-cd-boot-uefi -n windows-image-build -o jsonpath='{.metadata.name}'
oc get task trigger-cd-boot-uefi -n linux-image-build -o jsonpath='{.metadata.name}'
```
Both expected: `trigger-cd-boot-uefi`

- [ ] **Step 7: Commit**

```bash
git add manifests/pipelines/boot-trigger-tasks/
git commit -m "Add boot-trigger Task: trigger-cd-boot-uefi"
```

---

### Task 1.10: Boot-trigger Task — `trigger-cd-boot-bios`

Lift the BIOS-equivalent from the existing `manifests/windows/pipeline-bios/pipeline.yaml`. The legacy-BIOS prompt uses a brief keypress race rather than the OVMF dance.

**Files:**
- Create: `manifests/pipelines/boot-trigger-tasks/trigger-cd-boot-bios.yaml`
- Modify: `manifests/pipelines/boot-trigger-tasks/kustomization.yaml`

- [ ] **Step 1: Read the existing BIOS boot-trigger script**

```bash
grep -A 40 "trigger-cd-boot\|send-keypress\|send-key" \
  manifests/windows/pipeline-bios/pipeline.yaml | head -80
```
This locates the script block to lift. Note the timing values used.

- [ ] **Step 2: Create the Task manifest**

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: trigger-cd-boot-bios
spec:
  description: |
    For BIOS installer VMs: send rapid spacebar keypresses to catch
    the "Press any key to boot from CD or DVD" prompt, which only
    waits ~5 seconds before falling through to disk boot.
    Lifted from the Win 2022 BIOS pipeline.
  params:
    - name: vmName
      type: string
    - name: namespace
      type: string
  steps:
    - name: send-keypress
      image: image-registry.openshift-image-registry.svc:5000/openshift/cli:latest
      script: |
        #!/bin/bash
        set -euo pipefail
        echo "Waiting for VMI $(params.vmName) to be Running..."
        oc wait vmi/$(params.vmName) -n $(params.namespace) \
          --for=jsonpath='{.status.phase}'=Running \
          --timeout=10m
        POD=$(oc get pods -n $(params.namespace) \
          -l kubevirt.io/vm=$(params.vmName) \
          -o jsonpath='{.items[0].metadata.name}')
        VIRSH="oc exec -n $(params.namespace) $POD -- virsh -c qemu:///session"

        # Hammer spacebar through the boot prompt window
        echo "Sending 30 spacebar presses to catch BIOS CD-boot prompt..."
        for i in $(seq 1 30); do
          $VIRSH send-key 1 KEY_SPACE 2>/dev/null || true
          sleep 1
        done
        echo "Boot sequence complete -- installer should be loading"
```

> **Note on lifting from the existing BIOS pipeline:** if the existing script differs (different sleep counts, different key codes), use the existing values verbatim — this Task is meant to reproduce known-working behaviour, not change it.

- [ ] **Step 3: Append to base kustomization**

Edit `manifests/pipelines/boot-trigger-tasks/kustomization.yaml` so `resources:` includes `- trigger-cd-boot-bios.yaml`.

- [ ] **Step 4: Apply**

```bash
oc apply -k manifests/pipelines/boot-trigger-tasks/overlays/linux/
oc apply -k manifests/pipelines/boot-trigger-tasks/overlays/windows/
```

- [ ] **Step 5: Verify**

```bash
oc get task trigger-cd-boot-bios -n windows-image-build -o jsonpath='{.metadata.name}'
```
Expected: `trigger-cd-boot-bios`

- [ ] **Step 6: Commit**

```bash
git add manifests/pipelines/boot-trigger-tasks/trigger-cd-boot-bios.yaml \
        manifests/pipelines/boot-trigger-tasks/kustomization.yaml
git commit -m "Add boot-trigger Task: trigger-cd-boot-bios"
```

---

### Task 1.11: Boot-trigger Task — `trigger-cd-boot-linux`

Most Linux installer ISOs (RHEL, Rocky, Alma, Ubuntu, SLES) boot directly from the CD without a "press any key" prompt — the firmware boot order picks the CDROM first and Anaconda/Subiquity/AutoYaST loads automatically. This Task is therefore a no-op except for the "wait until VM is Running" handoff that the pipeline shape expects, so other downstream Tasks have a defined precondition.

**Files:**
- Create: `manifests/pipelines/boot-trigger-tasks/trigger-cd-boot-linux.yaml`
- Modify: `manifests/pipelines/boot-trigger-tasks/kustomization.yaml`

- [ ] **Step 1: Define state check**

```bash
oc get task trigger-cd-boot-linux -n linux-image-build -o jsonpath='{.metadata.name}' 2>/dev/null
```
Expected: empty.

- [ ] **Step 2: Create the Task manifest**

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: trigger-cd-boot-linux
spec:
  description: |
    Linux installer ISOs (Anaconda/Subiquity/AutoYaST) boot directly
    from the CDROM with no "press any key" prompt. This Task only
    waits until the VMI is Running so downstream tasks have a
    defined precondition.
  params:
    - name: vmName
      type: string
    - name: namespace
      type: string
  steps:
    - name: wait-running
      image: image-registry.openshift-image-registry.svc:5000/openshift/cli:latest
      script: |
        #!/bin/bash
        set -euo pipefail
        echo "Waiting for VMI $(params.vmName) to be Running..."
        oc wait vmi/$(params.vmName) -n $(params.namespace) \
          --for=jsonpath='{.status.phase}'=Running \
          --timeout=10m
        echo "Linux installer is booting from CDROM (no keypress required)"
```

- [ ] **Step 3: Append to base kustomization**

Edit `manifests/pipelines/boot-trigger-tasks/kustomization.yaml` so `resources:` includes `- trigger-cd-boot-linux.yaml`.

- [ ] **Step 4: Apply**

```bash
oc apply -k manifests/pipelines/boot-trigger-tasks/overlays/linux/
oc apply -k manifests/pipelines/boot-trigger-tasks/overlays/windows/
```

- [ ] **Step 5: Verify**

```bash
oc get task trigger-cd-boot-linux -n linux-image-build -o jsonpath='{.metadata.name}'
```
Expected: `trigger-cd-boot-linux`

- [ ] **Step 6: Commit**

```bash
git add manifests/pipelines/boot-trigger-tasks/trigger-cd-boot-linux.yaml \
        manifests/pipelines/boot-trigger-tasks/kustomization.yaml
git commit -m "Add boot-trigger Task: trigger-cd-boot-linux"
```

---

### Task 1.12: Aggregate kustomization for the whole `pipelines/` tree

So Phase-1 scaffolding can be applied with a single `oc apply -k manifests/pipelines/`.

**Files:**
- Create: `manifests/pipelines/kustomization.yaml`

- [ ] **Step 1: Create the aggregator**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - build-namespaces
  - shared-tasks/overlays/linux
  - shared-tasks/overlays/windows
  - boot-trigger-tasks/overlays/linux
  - boot-trigger-tasks/overlays/windows
```

- [ ] **Step 2: Apply (idempotent — everything is already applied)**

```bash
oc apply -k manifests/pipelines/
```

- [ ] **Step 3: Verify aggregator-level apply succeeded**

```bash
for NS in linux-image-build windows-image-build; do
  echo "=== $NS ==="
  oc get tasks -n $NS -o name | sort
done
```
Expected (each namespace, sorted):
```
task.tekton.dev/cleanup-build-namespace
task.tekton.dev/clone-to-catalog
task.tekton.dev/create-blank-root-disk
task.tekton.dev/trigger-cd-boot-bios
task.tekton.dev/trigger-cd-boot-linux
task.tekton.dev/trigger-cd-boot-uefi
task.tekton.dev/upload-source-artefact
task.tekton.dev/wait-for-vm-shutdown
```

- [ ] **Step 4: Commit**

```bash
git add manifests/pipelines/kustomization.yaml
git commit -m "Add aggregator kustomization for pipelines/ scaffolding"
```

---

## Phase 2 — RHEL 9 vanilla pipeline

Phase goal: a working `oc apply -k manifests/linux/rhel-9/` deploys a Tekton Pipeline that, when triggered, builds a RHEL 9 golden image and produces a `DataSource` named `rhel-9` in `openshift-virtualization-os-images`.

**Pipeline shape** (each task uses the shared Tasks from Phase 1):

1. `upload-source-artefact` — RHEL 9 boot ISO from Red Hat customer portal entitled URL
2. `create-blank-root-disk` — `rhel-9-root-disk`, 30Gi
3. `create-installer-vm` (inline `taskSpec`, see Task 2.5) — VM with ISO CDROM, blank disk, kickstart-via-OEMDRV ConfigMap
4. `trigger-cd-boot-linux` — no keypress
5. `wait-for-vm-shutdown` — Anaconda installs, runs `%post`, VM shuts down
6. `clone-to-catalog` — clone to `openshift-virtualization-os-images/rhel-9`
7. `cleanup-build-namespace` — delete VM + blank disk

### Task 2.1: Variant directory skeleton

**Files:**
- Create: `manifests/linux/rhel-9/kustomization.yaml`
- Create: `manifests/linux/rhel-9/README.md` (initial placeholder; expanded in Task 2.7)

- [ ] **Step 1: Create kustomization stub**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: linux-image-build
resources:
  - kickstart-configmap.yaml
  - pipeline-rbac.yaml
  - pipeline.yaml
  - pipelinerun.yaml
```

- [ ] **Step 2: Create initial README**

```markdown
# RHEL 9 — vanilla golden image pipeline

Builds a RHEL 9 golden image from the vendor ISO and publishes it as
DataSource `rhel-9` in `openshift-virtualization-os-images`.

**Status:** under construction (Batch 1 pilot).

See `docs/superpowers/specs/2026-04-26-image-pipeline-expansion-design.md`
for the design context.
```

- [ ] **Step 3: Commit**

```bash
git add manifests/linux/rhel-9/kustomization.yaml \
        manifests/linux/rhel-9/README.md
git commit -m "Add RHEL 9 variant directory skeleton"
```

---

### Task 2.2: Vanilla kickstart ConfigMap

The ConfigMap is mounted into the installer VM as a virtio-fs / OEMDRV-labelled device that Anaconda picks up automatically (`inst.ks=hd:LABEL=OEMDRV:/ks.cfg`). For pilot simplicity, we mount it as a `configMap` volume and use the `kubevirt.io/sysprep` mechanism (which works for kickstart-as-data on KubeVirt — confirm during execution). If sysprep volume doesn't accept arbitrary kickstarts, fall back to building a small ISO with the kickstart in `%post` of the installer VM definition (see installer-VM Task 2.5 for that fallback).

**Files:**
- Create: `manifests/linux/rhel-9/kickstart-configmap.yaml`

- [ ] **Step 1: Define state check**

```bash
oc get configmap rhel-9-kickstart -n linux-image-build -o jsonpath='{.metadata.name}' 2>/dev/null
```
Expected: empty.

- [ ] **Step 2: Create the ConfigMap**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: rhel-9-kickstart
  namespace: linux-image-build
data:
  ks.cfg: |
    #version=RHEL9
    text
    eula --agreed
    keyboard --vckeymap=us --xlayouts='us'
    lang en_US.UTF-8
    timezone Etc/UTC --utc
    network --bootproto=dhcp --device=link --activate --onboot=on
    rootpw --lock
    user --name=cloud-user --groups=wheel --plaintext --password=changeme123!
    selinux --enforcing
    firewall --enabled --service=ssh
    services --enabled=sshd,qemu-guest-agent,chronyd
    bootloader --append="rhgb quiet" --location=mbr
    zerombr
    clearpart --all --initlabel
    autopart --type=lvm
    reboot --eject

    %packages
    @^minimal-environment
    @core
    chrony
    cloud-init
    qemu-guest-agent
    -plymouth
    %end

    %post --erroronfail
    # Allow cloud-user passwordless sudo (locked down on first boot in real estates)
    echo 'cloud-user ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/90-cloud-init-users
    chmod 0440 /etc/sudoers.d/90-cloud-init-users

    # Reset machine-id so cloned VMs get fresh IDs
    truncate -s 0 /etc/machine-id

    # Clean cloud-init so first boot triggers init
    cloud-init clean --logs --machine-id || true

    # Trim history & logs
    rm -f /root/.bash_history /home/cloud-user/.bash_history
    journalctl --rotate || true
    journalctl --vacuum-time=1s || true
    %end
```

> **Note:** The locked root + plaintext `cloud-user` password is for pilot only. Hardened variant (Phase 3) replaces this with SSH-key-only access and removes the cloud-user password entirely.

- [ ] **Step 3: Apply (via the variant kustomization, which already lists this file)**

```bash
oc apply -k manifests/linux/rhel-9/
```
This will fail until the rest of Task 2.x is done because the kustomization references files we haven't created yet. To verify *just* this ConfigMap, apply it standalone first:

```bash
oc apply -f manifests/linux/rhel-9/kickstart-configmap.yaml
```

- [ ] **Step 4: Verify**

```bash
oc get configmap rhel-9-kickstart -n linux-image-build -o jsonpath='{.data.ks\.cfg}' | head -5
```
Expected: first lines of the kickstart (`#version=RHEL9`, `text`, ...).

- [ ] **Step 5: Commit**

```bash
git add manifests/linux/rhel-9/kickstart-configmap.yaml
git commit -m "Add vanilla RHEL 9 kickstart ConfigMap"
```

---

### Task 2.3: Pipeline RBAC for the variant

Reuses the namespace-level `linux-image-pipeline` SA (created in Task 1.1). This file is empty for vanilla variants — kept as a placeholder so the per-variant directory layout is uniform (hardened variants may need extra perms; see Phase 3).

**Files:**
- Create: `manifests/linux/rhel-9/pipeline-rbac.yaml`

- [ ] **Step 1: Create the placeholder file**

```yaml
# RHEL 9 vanilla — no per-variant RBAC needed.
# The pipeline runs under the shared `linux-image-pipeline` ServiceAccount
# created in manifests/pipelines/build-namespaces/linux-image-build.yaml.
#
# Hardened variants may add a Role/RoleBinding here if the SCAP scan
# step needs additional permissions (e.g. to write a compliance-report
# ConfigMap).
---
# Empty resource block — Kustomize tolerates empty docs in resources.
```

- [ ] **Step 2: Commit**

```bash
git add manifests/linux/rhel-9/pipeline-rbac.yaml
git commit -m "Add RHEL 9 pipeline-rbac placeholder"
```

---

### Task 2.4: Pipeline manifest

The thin Pipeline composing the shared Tasks. Roughly 100 lines including the inline installer-VM `taskSpec` (per D7).

**Files:**
- Create: `manifests/linux/rhel-9/pipeline.yaml`

- [ ] **Step 1: Define state check**

```bash
oc get pipeline rhel-9-image-builder -n linux-image-build -o jsonpath='{.metadata.name}' 2>/dev/null
```
Expected: empty.

- [ ] **Step 2: Create the Pipeline manifest**

```yaml
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: rhel-9-image-builder
spec:
  params:
    - name: rhelIsoUrl
      description: HTTP URL of the RHEL 9 boot ISO
      type: string
    - name: storageClass
      type: string
      default: ocs-storagecluster-ceph-rbd-virtualization
    - name: goldenImageName
      type: string
      default: rhel-9
    - name: rootDiskSize
      type: string
      default: "30Gi"
    - name: defaultInstancetype
      type: string
      default: u1.medium
    - name: defaultPreference
      type: string
      default: rhel.9

  tasks:
    - name: upload-rhel-iso
      taskRef: { name: upload-source-artefact }
      params:
        - { name: dvName,        value: rhel-9-iso }
        - { name: namespace,     value: linux-image-build }
        - { name: url,           value: $(params.rhelIsoUrl) }
        - { name: storageClass,  value: $(params.storageClass) }
        - { name: storageSize,   value: 12Gi }

    - name: create-root-disk
      taskRef: { name: create-blank-root-disk }
      params:
        - { name: dvName,        value: rhel-9-root-disk }
        - { name: namespace,     value: linux-image-build }
        - { name: storageClass,  value: $(params.storageClass) }
        - { name: rootDiskSize,  value: $(params.rootDiskSize) }

    - name: create-installer-vm
      runAfter:
        - upload-rhel-iso
        - create-root-disk
      taskSpec:
        steps:
          - name: create-vm
            image: image-registry.openshift-image-registry.svc:5000/openshift/cli:latest
            script: |
              #!/bin/bash
              set -euo pipefail
              cat <<'VMEOF' | oc apply -f -
              apiVersion: kubevirt.io/v1
              kind: VirtualMachine
              metadata:
                name: rhel-9-installer
                namespace: linux-image-build
              spec:
                runStrategy: RerunOnFailure
                template:
                  metadata:
                    labels:
                      kubevirt.io/vm: rhel-9-installer
                  spec:
                    domain:
                      firmware:
                        bootloader:
                          efi:
                            secureBoot: false
                      cpu:
                        cores: 2
                      resources:
                        requests:
                          memory: 4Gi
                      devices:
                        disks:
                          - name: rootdisk
                            disk: { bus: virtio }
                            bootOrder: 2
                          - name: installer-iso
                            cdrom: { bus: sata }
                            bootOrder: 1
                          - name: kickstart
                            disk: { bus: virtio }
                        interfaces:
                          - name: default
                            masquerade: {}
                    networks:
                      - name: default
                        pod: {}
                    volumes:
                      - name: rootdisk
                        persistentVolumeClaim:
                          claimName: rhel-9-root-disk
                      - name: installer-iso
                        persistentVolumeClaim:
                          claimName: rhel-9-iso
                      - name: kickstart
                        configMap:
                          name: rhel-9-kickstart
                          # Anaconda picks up ks.cfg via inst.ks= kernel arg
                          # which we add via the boot menu / GRUB; for pilot
                          # we rely on Anaconda's auto-detection of OEMDRV.
                          # If auto-detection fails, switch to a kernel-arg
                          # injection on the installer ISO PVC (see README).
              VMEOF
              echo "Installer VM created"

    - name: trigger-boot
      runAfter: [create-installer-vm]
      taskRef: { name: trigger-cd-boot-linux }
      params:
        - { name: vmName,    value: rhel-9-installer }
        - { name: namespace, value: linux-image-build }

    - name: wait-shutdown
      runAfter: [trigger-boot]
      timeout: "2h"
      taskRef: { name: wait-for-vm-shutdown }
      params:
        - { name: vmName,    value: rhel-9-installer }
        - { name: namespace, value: linux-image-build }

    - name: clone
      runAfter: [wait-shutdown]
      taskRef: { name: clone-to-catalog }
      params:
        - { name: sourcePvcName,         value: rhel-9-root-disk }
        - { name: sourceNamespace,       value: linux-image-build }
        - { name: goldenImageName,       value: $(params.goldenImageName) }
        - { name: storageClass,          value: $(params.storageClass) }
        - { name: rootDiskSize,          value: $(params.rootDiskSize) }
        - { name: defaultInstancetype,   value: $(params.defaultInstancetype) }
        - { name: defaultPreference,     value: $(params.defaultPreference) }
        - { name: complianceBaseline,    value: "" }

    - name: cleanup
      runAfter: [clone]
      taskRef: { name: cleanup-build-namespace }
      params:
        - { name: vmName,         value: rhel-9-installer }
        - { name: rootDiskDvName, value: rhel-9-root-disk }
        - { name: namespace,      value: linux-image-build }
```

> **Open implementation question raised by this Task:** the kickstart auto-detection via configMap volume *may* not work — Anaconda usually expects the kickstart on a partition labelled OEMDRV or fetched via `inst.ks=`. If the pilot run fails because Anaconda doesn't find the kickstart, the resolution is to either (a) build a small ISO containing `ks.cfg` and attach as a second CDROM, or (b) inject `inst.ks=` via cloud-init userdata on the installer VM. The variant README will document whichever fallback is applied. Don't block on this until Task 2.6 actually fails.

- [ ] **Step 3: Apply standalone**

The variant kustomization references `pipelinerun.yaml`, which is not yet created (Task 2.5 creates it). Apply this Pipeline manifest standalone for now; Task 2.5 then applies the full kustomization.

```bash
oc apply -f manifests/linux/rhel-9/pipeline.yaml
```

- [ ] **Step 4: Verify**

```bash
oc get pipeline rhel-9-image-builder -n linux-image-build -o jsonpath='{.metadata.name}'
```
Expected: `rhel-9-image-builder`

- [ ] **Step 5: Commit**

```bash
git add manifests/linux/rhel-9/pipeline.yaml
git commit -m "Add RHEL 9 vanilla Pipeline manifest"
```

---

### Task 2.5: PipelineRun manifest

**Files:**
- Create: `manifests/linux/rhel-9/pipelinerun.yaml`

- [ ] **Step 1: Create the PipelineRun template**

```yaml
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: rhel-9-image-build-
  namespace: linux-image-build
spec:
  pipelineRef:
    name: rhel-9-image-builder
  taskRunTemplate:
    serviceAccountName: linux-image-pipeline
  timeouts:
    pipeline: "3h"
    tasks: "2h30m"
  params:
    - name: rhelIsoUrl
      # Replace with the actual URL from the Red Hat customer portal
      # (entitled download). For the pilot, this URL is set per-run by
      # the operator; the value below is a placeholder example.
      value: "https://access.redhat.com/downloads/content/479/REPLACE-ME-rhel-9-x86_64-boot.iso"
    - name: storageClass
      value: "ocs-storagecluster-ceph-rbd-virtualization"
    - name: goldenImageName
      value: "rhel-9"
    - name: rootDiskSize
      value: "30Gi"
    - name: defaultInstancetype
      value: "u1.medium"
    - name: defaultPreference
      value: "rhel.9"
```

The placeholder URL is intentional — the operator must paste an entitled URL at run time. The variant README (Task 2.7) explains how to obtain one.

- [ ] **Step 2: Apply (creates the *template*; not yet a PipelineRun)**

```bash
oc apply -k manifests/linux/rhel-9/
```
This creates the PipelineRun resource. Because it uses `generateName`, applying it creates a new run each time — for the template-as-template pattern, the operator will use `oc create -f manifests/linux/rhel-9/pipelinerun.yaml` to spawn runs (see Task 2.6).

- [ ] **Step 3: Verify all variant resources exist**

```bash
oc get pipeline,configmap,pipelinerun -n linux-image-build \
  -l 'kustomize.toolkit.fluxcd.io/name!=' 2>/dev/null
oc get pipeline rhel-9-image-builder -n linux-image-build -o name
oc get configmap rhel-9-kickstart -n linux-image-build -o name
```
Expected: pipeline + configmap exist.

- [ ] **Step 4: Commit**

```bash
git add manifests/linux/rhel-9/pipelinerun.yaml
git commit -m "Add RHEL 9 vanilla PipelineRun template"
```

---

### Task 2.6: End-to-end pipeline run + verification

**Files:** none modified — this is a runtime test.

- [ ] **Step 1: Obtain a RHEL 9 boot ISO URL**

From the Red Hat customer portal: https://access.redhat.com/downloads/content/479/ — generate an entitled download URL for the latest RHEL 9 boot ISO (≈1 GB). Save the URL.

- [ ] **Step 2: Trigger the run**

```bash
source .env
oc create -f manifests/linux/rhel-9/pipelinerun.yaml \
  --dry-run=client -o yaml \
  | sed 's|REPLACE-ME-rhel-9-x86_64-boot.iso|<your-url-here>|' \
  | oc create -f -
```
Or simpler — edit `manifests/linux/rhel-9/pipelinerun.yaml` to paste the URL, then:

```bash
oc create -f manifests/linux/rhel-9/pipelinerun.yaml
```
**Do not commit the edited URL** if it's a personal entitled URL. Reset before commit.

- [ ] **Step 3: Watch the run**

```bash
RUN=$(oc get pipelinerun -n linux-image-build \
  -o jsonpath='{.items[-1].metadata.name}')
echo "Run: $RUN"
oc get pipelinerun $RUN -n linux-image-build -w
```
Expected progression: `Started` → each task `Succeeded` in turn → final state `Succeeded`. Total runtime: ~30–60 min.

- [ ] **Step 4: Investigate any failure (if needed)**

If a task fails:
```bash
tkn pipelinerun logs $RUN -n linux-image-build -f
```
Most likely failure mode is Anaconda not finding the kickstart. If so, follow the fallback documented in Task 2.4's open-question note: rebuild the installer-VM Task to inject `inst.ks=` via boot args, or build a kickstart ISO. Document the resolution in the variant README.

- [ ] **Step 5: Verify the catalogue DataSource**

```bash
oc get datasource rhel-9 -n openshift-virtualization-os-images \
  -o jsonpath='{.metadata.labels}{"\n"}'
```
Expected output contains:
```
"instancetype.kubevirt.io/default-instancetype":"u1.medium"
"instancetype.kubevirt.io/default-preference":"rhel.9"
```
And no `compliance.kubevirt.io/baseline` label (vanilla).

```bash
oc get datasource rhel-9 -n openshift-virtualization-os-images \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
```
Expected: `True`

- [ ] **Step 6: Boot a consumer VM from the DataSource**

```bash
cat <<EOF | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: rhel-9-consumer-test
  namespace: linux-image-build
spec:
  runStrategy: RerunOnFailure
  dataVolumeTemplates:
    - metadata:
        name: rhel-9-consumer-test-disk
      spec:
        sourceRef:
          kind: DataSource
          name: rhel-9
          namespace: openshift-virtualization-os-images
        storage:
          resources:
            requests:
              storage: 30Gi
  template:
    spec:
      domain:
        cpu: { cores: 2 }
        resources:
          requests:
            memory: 4Gi
        devices:
          disks:
            - name: rootdisk
              disk: { bus: virtio }
          interfaces:
            - name: default
              masquerade: {}
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          dataVolume:
            name: rhel-9-consumer-test-disk
EOF

oc wait vmi/rhel-9-consumer-test -n linux-image-build \
  --for=condition=Ready --timeout=10m

# Check guest agent
oc get vmi rhel-9-consumer-test -n linux-image-build \
  -o jsonpath='{.status.conditions[?(@.type=="AgentConnected")].status}'
```
Expected: `True`.

- [ ] **Step 7: Tear down the consumer test VM**

```bash
oc delete vm rhel-9-consumer-test -n linux-image-build
oc delete dv rhel-9-consumer-test-disk -n linux-image-build --ignore-not-found
```

- [ ] **Step 8: Commit (if pipeline.yaml was modified during failure-resolution)**

```bash
# If pipeline.yaml or kickstart-configmap.yaml was modified, commit
# the resolution. If not, skip this step.
git status
git diff manifests/linux/rhel-9/
git add manifests/linux/rhel-9/
git commit -m "Resolve <issue> in RHEL 9 vanilla pipeline"
```

---

### Task 2.7: Variant README

**Files:**
- Modify: `manifests/linux/rhel-9/README.md` (replace placeholder from 2.1)

- [ ] **Step 1: Replace README content**

```markdown
# RHEL 9 — vanilla golden image pipeline

Builds a RHEL 9 golden image from the vendor boot ISO and publishes it
as DataSource `rhel-9` in `openshift-virtualization-os-images`.

## ISO source

Red Hat customer portal — https://access.redhat.com/downloads/content/479/ —
"Boot ISO" variant for x86_64. Requires an entitled subscription.

The PipelineRun template at `pipelinerun.yaml` has a placeholder URL.
Edit it to paste the entitled URL before running, **but do not commit
the edited URL** (it's tied to your customer account).

## Deploy

```bash
source .env
oc apply -k manifests/linux/rhel-9/
```

This creates the Pipeline, kickstart ConfigMap, and PipelineRun
template in the `linux-image-build` namespace.

## Run

```bash
# Edit pipelinerun.yaml to paste the entitled ISO URL, then:
oc create -f manifests/linux/rhel-9/pipelinerun.yaml
RUN=$(oc get pipelinerun -n linux-image-build \
  -o jsonpath='{.items[-1].metadata.name}')
tkn pipelinerun logs $RUN -n linux-image-build -f
```

## Expected runtime

30–60 minutes end-to-end.

## Catalogue output

- `DataVolume` `rhel-9` in `openshift-virtualization-os-images`
- `DataSource` `rhel-9` in `openshift-virtualization-os-images` with
  `default-instancetype: u1.medium`, `default-preference: rhel.9`,
  no compliance baseline label.

## Known gotchas

- **Kickstart auto-detection:** Anaconda finds `ks.cfg` from a configMap
  volume only if the disk has the OEMDRV label. If the pipeline run
  hangs at the Anaconda welcome screen, fall back to injecting
  `inst.ks=` via the installer ISO boot args. (See pipeline.yaml's
  `create-installer-vm` task for the fallback shape.)
- **Cloud-user password:** the vanilla kickstart uses
  `cloud-user / changeme123!`. Real estates should rotate this via
  cloud-init at consumer-VM deployment time.
```

- [ ] **Step 2: Commit**

```bash
git add manifests/linux/rhel-9/README.md
git commit -m "Document RHEL 9 vanilla variant"
```

---

## Phase 3 — RHEL 9 hardened pipeline

Phase goal: a `rhel-9-hardened` sibling variant that produces a CIS L1-hardened DataSource. The Pipeline, RBAC, and PipelineRun are nearly identical to vanilla; the kickstart ConfigMap differs (it adds an `oscap` `%post`).

### Task 3.1: Variant directory + skeleton (clone of RHEL 9)

**Files:**
- Create: `manifests/linux/rhel-9-hardened/kustomization.yaml`
- Create: `manifests/linux/rhel-9-hardened/pipeline-rbac.yaml`
- Create: `manifests/linux/rhel-9-hardened/README.md`

- [ ] **Step 1: Create kustomization**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: linux-image-build
resources:
  - kickstart-configmap.yaml
  - pipeline-rbac.yaml
  - pipeline.yaml
  - pipelinerun.yaml
```

- [ ] **Step 2: Create pipeline-rbac placeholder**

```yaml
# RHEL 9 hardened — no per-variant RBAC needed beyond the shared
# linux-image-pipeline ServiceAccount.
---
```

- [ ] **Step 3: Create README skeleton**

```markdown
# RHEL 9 hardened — CIS L1 golden image pipeline

Builds a CIS Benchmark Level 1 (Server) hardened RHEL 9 image and
publishes it as DataSource `rhel-9-hardened` in
`openshift-virtualization-os-images`.

**Status:** under construction (Batch 1 pilot).

Hardening is applied via OpenSCAP `oscap xccdf eval --remediate` in
the kickstart `%post`, using profile `xccdf_org.ssgproject.content_profile_cis`
from `scap-security-guide` (RHEL 9 build).

See the design doc at
`docs/superpowers/specs/2026-04-26-image-pipeline-expansion-design.md`
§5 for hardening policy context.
```

- [ ] **Step 4: Commit**

```bash
git add manifests/linux/rhel-9-hardened/
git commit -m "Add RHEL 9 hardened variant directory skeleton"
```

---

### Task 3.2: Hardened kickstart ConfigMap

The hardened kickstart adds CIS L1 partitioning (separate `/var`, `/var/log`, `/var/log/audit`, `/home`, `/tmp`, `/var/tmp`), removes the cloud-user plaintext password (SSH-key only), and runs `oscap` remediation in `%post`.

**Files:**
- Create: `manifests/linux/rhel-9-hardened/kickstart-configmap.yaml`

- [ ] **Step 1: Define state check**

```bash
oc get configmap rhel-9-hardened-kickstart -n linux-image-build -o jsonpath='{.metadata.name}' 2>/dev/null
```
Expected: empty.

- [ ] **Step 2: Create the ConfigMap**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: rhel-9-hardened-kickstart
  namespace: linux-image-build
data:
  ks.cfg: |
    #version=RHEL9
    text
    eula --agreed
    keyboard --vckeymap=us --xlayouts='us'
    lang en_US.UTF-8
    timezone Etc/UTC --utc
    network --bootproto=dhcp --device=link --activate --onboot=on
    rootpw --lock
    user --name=cloud-user --groups=wheel --lock
    selinux --enforcing
    firewall --enabled --service=ssh
    services --enabled=sshd,qemu-guest-agent,chronyd,auditd
    bootloader --append="audit=1 audit_backlog_limit=8192" --location=mbr
    zerombr
    clearpart --all --initlabel

    # CIS L1 partitioning
    part /boot      --fstype=xfs --size=1024 --asprimary
    part pv.01      --grow --size=1
    volgroup vg00 pv.01
    logvol /        --vgname=vg00 --size=8192 --name=root  --fstype=xfs
    logvol /home    --vgname=vg00 --size=2048 --name=home  --fstype=xfs --fsoptions="defaults,nodev,nosuid"
    logvol /var     --vgname=vg00 --size=4096 --name=var   --fstype=xfs --fsoptions="defaults,nosuid"
    logvol /var/log --vgname=vg00 --size=2048 --name=varlog --fstype=xfs --fsoptions="defaults,nodev,nosuid,noexec"
    logvol /var/log/audit --vgname=vg00 --size=1024 --name=varlogaudit --fstype=xfs --fsoptions="defaults,nodev,nosuid,noexec"
    logvol /tmp     --vgname=vg00 --size=2048 --name=tmp   --fstype=xfs --fsoptions="defaults,nodev,nosuid,noexec"
    logvol /var/tmp --vgname=vg00 --size=1024 --name=vartmp --fstype=xfs --fsoptions="defaults,nodev,nosuid,noexec"
    logvol swap     --vgname=vg00 --size=2048 --name=swap

    reboot --eject

    %packages
    @^minimal-environment
    @core
    chrony
    cloud-init
    qemu-guest-agent
    openscap-scanner
    scap-security-guide
    aide
    -plymouth
    %end

    %post --erroronfail
    set -euo pipefail

    # ── CIS L1 remediation via oscap ────────────────────────────
    SSG_PROFILE="xccdf_org.ssgproject.content_profile_cis"
    SSG_DS="/usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml"
    REPORT_DIR=/var/log/openscap-build
    mkdir -p "$REPORT_DIR"
    oscap xccdf eval \
      --profile "$SSG_PROFILE" \
      --remediate \
      --results "$REPORT_DIR/results.xml" \
      --report  "$REPORT_DIR/report.html" \
      "$SSG_DS" || true
    # `oscap --remediate` exits non-zero when any rule remains failing;
    # we accept that and rely on the post-build CIS L1 scan in Task 3.3
    # for pass/fail evaluation.

    # Capture the ssg version used (for R2 mitigation)
    rpm -q scap-security-guide > "$REPORT_DIR/ssg-version.txt"

    # ── First-boot reset ────────────────────────────────────────
    truncate -s 0 /etc/machine-id
    cloud-init clean --logs --machine-id || true

    rm -f /root/.bash_history /home/cloud-user/.bash_history
    journalctl --rotate || true
    journalctl --vacuum-time=1s || true

    # ── Compliance report extraction ─────────────────────────────
    # The pipeline's clone-to-catalog Task picks up reports from the
    # build-namespace ConfigMap. Stage them here so a later Task can
    # exfiltrate.
    cp "$REPORT_DIR/results.xml" /root/oscap-results.xml || true
    cp "$REPORT_DIR/ssg-version.txt" /root/ssg-version.txt || true
    %end
```

> **Note on ssg version drift (R2):** `scap-security-guide` is pulled from the RHEL repos at install time, so the version isn't pinned. The kickstart records the version into `/root/ssg-version.txt` so it's visible inside the cloned image. A future enhancement (out of Batch 1 scope) could push this version into a per-run ConfigMap for the audit retention path (D2).

- [ ] **Step 3: Apply standalone**

```bash
oc apply -f manifests/linux/rhel-9-hardened/kickstart-configmap.yaml
```

- [ ] **Step 4: Verify**

```bash
oc get configmap rhel-9-hardened-kickstart -n linux-image-build \
  -o jsonpath='{.data.ks\.cfg}' | head -5
```
Expected: first lines of the hardened kickstart.

- [ ] **Step 5: Commit**

```bash
git add manifests/linux/rhel-9-hardened/kickstart-configmap.yaml
git commit -m "Add RHEL 9 CIS L1 hardened kickstart ConfigMap"
```

---

### Task 3.3: Hardened Pipeline manifest

The Pipeline reuses every shared Task. Only the configMap reference, the goldenImageName, and the `complianceBaseline` param differ from vanilla.

**Files:**
- Create: `manifests/linux/rhel-9-hardened/pipeline.yaml`

- [ ] **Step 1: Define state check**

```bash
oc get pipeline rhel-9-hardened-image-builder -n linux-image-build -o jsonpath='{.metadata.name}' 2>/dev/null
```
Expected: empty.

- [ ] **Step 2: Create the Pipeline manifest**

```yaml
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: rhel-9-hardened-image-builder
spec:
  params:
    - name: rhelIsoUrl
      type: string
    - name: storageClass
      type: string
      default: ocs-storagecluster-ceph-rbd-virtualization
    - name: goldenImageName
      type: string
      default: rhel-9-hardened
    - name: rootDiskSize
      type: string
      default: "30Gi"
    - name: defaultInstancetype
      type: string
      default: u1.medium
    - name: defaultPreference
      type: string
      default: rhel.9
    - name: complianceBaseline
      type: string
      default: cis-l1

  tasks:
    - name: upload-rhel-iso
      taskRef: { name: upload-source-artefact }
      params:
        - { name: dvName,        value: rhel-9-iso }
        - { name: namespace,     value: linux-image-build }
        - { name: url,           value: $(params.rhelIsoUrl) }
        - { name: storageClass,  value: $(params.storageClass) }
        - { name: storageSize,   value: 12Gi }
      # Note: shares the rhel-9-iso DV with the vanilla pipeline.
      # If both pipelines run concurrently and the DV doesn't exist,
      # only the first triggers the download; the second hits the
      # idempotent short-circuit in upload-source-artefact.

    - name: create-root-disk
      taskRef: { name: create-blank-root-disk }
      params:
        - { name: dvName,        value: rhel-9-hardened-root-disk }
        - { name: namespace,     value: linux-image-build }
        - { name: storageClass,  value: $(params.storageClass) }
        - { name: rootDiskSize,  value: $(params.rootDiskSize) }

    - name: create-installer-vm
      runAfter: [upload-rhel-iso, create-root-disk]
      taskSpec:
        steps:
          - name: create-vm
            image: image-registry.openshift-image-registry.svc:5000/openshift/cli:latest
            script: |
              #!/bin/bash
              set -euo pipefail
              cat <<'VMEOF' | oc apply -f -
              apiVersion: kubevirt.io/v1
              kind: VirtualMachine
              metadata:
                name: rhel-9-hardened-installer
                namespace: linux-image-build
              spec:
                runStrategy: RerunOnFailure
                template:
                  metadata:
                    labels:
                      kubevirt.io/vm: rhel-9-hardened-installer
                  spec:
                    domain:
                      firmware:
                        bootloader:
                          efi:
                            secureBoot: false
                      cpu:
                        cores: 2
                      resources:
                        requests:
                          memory: 4Gi
                      devices:
                        disks:
                          - name: rootdisk
                            disk: { bus: virtio }
                            bootOrder: 2
                          - name: installer-iso
                            cdrom: { bus: sata }
                            bootOrder: 1
                          - name: kickstart
                            disk: { bus: virtio }
                        interfaces:
                          - name: default
                            masquerade: {}
                    networks:
                      - name: default
                        pod: {}
                    volumes:
                      - name: rootdisk
                        persistentVolumeClaim:
                          claimName: rhel-9-hardened-root-disk
                      - name: installer-iso
                        persistentVolumeClaim:
                          claimName: rhel-9-iso
                      - name: kickstart
                        configMap:
                          name: rhel-9-hardened-kickstart
              VMEOF
              echo "Hardened installer VM created"

    - name: trigger-boot
      runAfter: [create-installer-vm]
      taskRef: { name: trigger-cd-boot-linux }
      params:
        - { name: vmName,    value: rhel-9-hardened-installer }
        - { name: namespace, value: linux-image-build }

    - name: wait-shutdown
      runAfter: [trigger-boot]
      timeout: "2h"
      taskRef: { name: wait-for-vm-shutdown }
      params:
        - { name: vmName,    value: rhel-9-hardened-installer }
        - { name: namespace, value: linux-image-build }

    - name: clone
      runAfter: [wait-shutdown]
      taskRef: { name: clone-to-catalog }
      params:
        - { name: sourcePvcName,         value: rhel-9-hardened-root-disk }
        - { name: sourceNamespace,       value: linux-image-build }
        - { name: goldenImageName,       value: $(params.goldenImageName) }
        - { name: storageClass,          value: $(params.storageClass) }
        - { name: rootDiskSize,          value: $(params.rootDiskSize) }
        - { name: defaultInstancetype,   value: $(params.defaultInstancetype) }
        - { name: defaultPreference,     value: $(params.defaultPreference) }
        - { name: complianceBaseline,    value: $(params.complianceBaseline) }

    - name: cleanup
      runAfter: [clone]
      taskRef: { name: cleanup-build-namespace }
      params:
        - { name: vmName,         value: rhel-9-hardened-installer }
        - { name: rootDiskDvName, value: rhel-9-hardened-root-disk }
        - { name: namespace,      value: linux-image-build }
```

- [ ] **Step 3: Apply standalone**

The kustomization references `pipelinerun.yaml`, which Task 3.4 creates. Apply this manifest standalone for now.

```bash
oc apply -f manifests/linux/rhel-9-hardened/pipeline.yaml
```

- [ ] **Step 4: Verify**

```bash
oc get pipeline rhel-9-hardened-image-builder -n linux-image-build -o jsonpath='{.metadata.name}'
```
Expected: `rhel-9-hardened-image-builder`

- [ ] **Step 5: Commit**

```bash
git add manifests/linux/rhel-9-hardened/pipeline.yaml
git commit -m "Add RHEL 9 hardened Pipeline manifest"
```

---

### Task 3.4: PipelineRun + end-to-end run + CIS L1 scan

**Files:**
- Create: `manifests/linux/rhel-9-hardened/pipelinerun.yaml`

- [ ] **Step 1: Create the PipelineRun template**

```yaml
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: rhel-9-hardened-image-build-
  namespace: linux-image-build
spec:
  pipelineRef:
    name: rhel-9-hardened-image-builder
  taskRunTemplate:
    serviceAccountName: linux-image-pipeline
  timeouts:
    pipeline: "3h"
    tasks: "2h30m"
  params:
    - name: rhelIsoUrl
      value: "https://access.redhat.com/downloads/content/479/REPLACE-ME-rhel-9-x86_64-boot.iso"
    - name: storageClass
      value: "ocs-storagecluster-ceph-rbd-virtualization"
    - name: goldenImageName
      value: "rhel-9-hardened"
    - name: rootDiskSize
      value: "30Gi"
    - name: defaultInstancetype
      value: "u1.medium"
    - name: defaultPreference
      value: "rhel.9"
    - name: complianceBaseline
      value: "cis-l1"
```

- [ ] **Step 2: Apply**

```bash
oc apply -k manifests/linux/rhel-9-hardened/
```

- [ ] **Step 3: Trigger a run (after pasting URL — do not commit pasted URL)**

```bash
oc create -f manifests/linux/rhel-9-hardened/pipelinerun.yaml
RUN=$(oc get pipelinerun -n linux-image-build \
  -o jsonpath='{.items[-1].metadata.name}')
tkn pipelinerun logs $RUN -n linux-image-build -f
```
Expected runtime: 45–75 min (slightly longer than vanilla due to oscap remediation).

- [ ] **Step 4: Verify the catalogue DataSource has the compliance label**

```bash
oc get datasource rhel-9-hardened -n openshift-virtualization-os-images \
  -o jsonpath='{.metadata.labels.compliance\.kubevirt\.io/baseline}'
```
Expected: `cis-l1`

- [ ] **Step 5: Boot a consumer VM and run the post-build CIS L1 scan**

```bash
cat <<EOF | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: rhel-9-hardened-consumer-test
  namespace: linux-image-build
spec:
  runStrategy: RerunOnFailure
  dataVolumeTemplates:
    - metadata:
        name: rhel-9-hardened-consumer-test-disk
      spec:
        sourceRef:
          kind: DataSource
          name: rhel-9-hardened
          namespace: openshift-virtualization-os-images
        storage:
          resources:
            requests:
              storage: 30Gi
  template:
    spec:
      domain:
        cpu: { cores: 2 }
        resources:
          requests:
            memory: 4Gi
        devices:
          disks:
            - name: rootdisk
              disk: { bus: virtio }
          interfaces:
            - name: default
              masquerade: {}
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          dataVolume:
            name: rhel-9-hardened-consumer-test-disk
EOF

oc wait vmi/rhel-9-hardened-consumer-test -n linux-image-build \
  --for=condition=Ready --timeout=10m
```

The hardened image's `cloud-user` is locked. To run the scan, use `virtctl console` (requires SSH key injection via cloud-init userdata, which the pilot kickstart doesn't yet wire up) **or** mount the disk read-only on a separate maintenance VM and run `oscap` against the offline filesystem.

For pilot acceptance, the simplest path is: **re-run the on-image scan results that were captured during build** — `/root/oscap-results.xml` was written in the kickstart `%post`. Mount the consumer-test VM's disk and read the file:

```bash
# Get the consumer VM's pod and exec virsh console (or use serial console
# logs if root login isn't available). Easiest: extract from the
# DataVolume PVC by mounting on a maintenance pod.

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: rhel-9-hardened-scan-extract
  namespace: linux-image-build
spec:
  containers:
    - name: extract
      image: registry.redhat.io/rhel9/guest-tools:latest
      command: ["sleep", "3600"]
      securityContext:
        privileged: true
      volumeMounts:
        - name: target
          mountPath: /image
  volumes:
    - name: target
      persistentVolumeClaim:
        claimName: rhel-9-hardened-consumer-test-disk
  restartPolicy: Never
EOF
oc wait pod/rhel-9-hardened-scan-extract -n linux-image-build \
  --for=condition=Ready --timeout=2m

oc exec -n linux-image-build rhel-9-hardened-scan-extract -- \
  bash -c 'guestmount -a /image/disk.img -i --ro /mnt && cat /mnt/root/oscap-results.xml' \
  > /tmp/rhel-9-hardened-results.xml
```

- [ ] **Step 6: Compute pass rate and verify ≥ 90%**

```bash
oc exec -n linux-image-build rhel-9-hardened-scan-extract -- \
  bash -c 'guestmount -a /image/disk.img -i --ro /mnt && \
    oscap xccdf eval --profile xccdf_org.ssgproject.content_profile_cis \
      --results /tmp/results.xml \
      /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml; cat /tmp/results.xml' \
  > /tmp/rhel-9-hardened-rescan.xml || true

# Count pass/fail/notapplicable
PASS=$(grep -c '<result>pass</result>'           /tmp/rhel-9-hardened-results.xml || echo 0)
FAIL=$(grep -c '<result>fail</result>'           /tmp/rhel-9-hardened-results.xml || echo 0)
NA=$(grep -c   '<result>notapplicable</result>'  /tmp/rhel-9-hardened-results.xml || echo 0)
APPLICABLE=$((PASS + FAIL))
echo "Pass: $PASS / Fail: $FAIL / N/A: $NA"
echo "Applicable rules: $APPLICABLE"
echo "Pass rate: $(awk -v p=$PASS -v a=$APPLICABLE 'BEGIN{printf "%.1f%%", (p/a)*100}')"
```
Expected: pass rate ≥ 90% of applicable rules.

If under 90%: list the failing rules, evaluate each in the README as either (a) a real gap to fix in the kickstart, (b) a known acceptable exception (e.g. requirements that don't apply to a single-tenant golden image like password-aging policies). Update the variant README with documented exceptions.

- [ ] **Step 7: Tear down test resources**

```bash
oc delete pod rhel-9-hardened-scan-extract -n linux-image-build
oc delete vm rhel-9-hardened-consumer-test -n linux-image-build
oc delete dv rhel-9-hardened-consumer-test-disk -n linux-image-build --ignore-not-found
```

- [ ] **Step 8: Commit (PipelineRun template + any kickstart adjustments)**

```bash
git add manifests/linux/rhel-9-hardened/pipelinerun.yaml
# Reset any pasted entitled URL
git checkout manifests/linux/rhel-9-hardened/pipelinerun.yaml \
  || true   # only reset if you pasted a URL; otherwise skip
# If kickstart was adjusted to fix CIS gaps:
git add manifests/linux/rhel-9-hardened/kickstart-configmap.yaml
git commit -m "Add RHEL 9 hardened PipelineRun template + CIS L1 verification"
```

---

### Task 3.5: Document the hardened variant + exceptions

**Files:**
- Modify: `manifests/linux/rhel-9-hardened/README.md`

- [ ] **Step 1: Replace README content**

```markdown
# RHEL 9 hardened — CIS L1 golden image pipeline

Builds a CIS Benchmark Level 1 (Server) hardened RHEL 9 image and
publishes it as DataSource `rhel-9-hardened` in
`openshift-virtualization-os-images`, labelled with
`compliance.kubevirt.io/baseline: cis-l1`.

## Hardening mechanism

OpenSCAP (`oscap xccdf eval --remediate`) is invoked in the kickstart
`%post` using the SCAP datastream from `scap-security-guide` for RHEL 9
(`/usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml`), profile
`xccdf_org.ssgproject.content_profile_cis`.

The `scap-security-guide` package is installed from the vendor repos at
build time, so its version is *not pinned* across runs (see PRD risk R2).
The kickstart writes the installed version to `/root/ssg-version.txt` so
the resulting image carries a record of which baseline it was built
against.

## ISO source

Same as vanilla — see `../rhel-9/README.md`.

## Deploy + run

```bash
source .env
oc apply -k manifests/linux/rhel-9-hardened/
# Edit pipelinerun.yaml to paste the entitled ISO URL (do not commit)
oc create -f manifests/linux/rhel-9-hardened/pipelinerun.yaml
```

Expected runtime: 45–75 min.

## Catalogue output

- `DataSource` `rhel-9-hardened` in `openshift-virtualization-os-images`
- Labels: `default-instancetype: u1.medium`,
  `default-preference: rhel.9`,
  `compliance.kubevirt.io/baseline: cis-l1`.

## CIS L1 scan results

Last verified pass rate: <fill in after Task 3.4>.

### Documented exceptions

<List rules that fail the scan but are accepted as exceptions, with
reasons. Update this list whenever the kickstart or ssg version
changes.>

| Rule ID | Reason for exception |
|---|---|
| (e.g.) xccdf_org.ssgproject.content_rule_accounts_passwords_pam_faillock_deny | Single-tenant golden image; account-lockout policies applied at deploy time via cloud-init |
```

- [ ] **Step 2: Commit**

```bash
git add manifests/linux/rhel-9-hardened/README.md
git commit -m "Document RHEL 9 hardened variant"
```

---

## Phase 4 — Win Server 2025 vanilla pipeline

Phase goal: a working `oc apply -k manifests/windows/server-2025-uefi/` deploys a Pipeline that builds a Win Server 2025 golden image and publishes `win2k25-uefi` to the catalogue. Pipeline shape mirrors the existing Win 2022 UEFI pipeline (`manifests/windows/pipeline-uefi/`) but composed from the new shared Tasks.

### Task 4.1: Variant directory skeleton

**Files:**
- Create: `manifests/windows/server-2025-uefi/kustomization.yaml`
- Create: `manifests/windows/server-2025-uefi/pipeline-rbac.yaml`
- Create: `manifests/windows/server-2025-uefi/README.md`

- [ ] **Step 1: Create kustomization**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: windows-image-build
resources:
  - autounattend-configmap.yaml
  - pipeline-rbac.yaml
  - pipeline.yaml
  - pipelinerun.yaml
```

- [ ] **Step 2: Create pipeline-rbac placeholder**

```yaml
# Win Server 2025 vanilla — no per-variant RBAC needed.
# The pipeline runs under the shared `windows-image-pipeline`
# ServiceAccount in manifests/pipelines/build-namespaces/windows-image-build.yaml.
---
```

- [ ] **Step 3: Create README skeleton**

```markdown
# Win Server 2025 UEFI — vanilla golden image pipeline

Builds a Win Server 2025 golden image from the vendor evaluation ISO
and publishes it as DataSource `win2k25-uefi` in
`openshift-virtualization-os-images`.

**Status:** under construction (Batch 1 pilot).
```

- [ ] **Step 4: Commit**

```bash
git add manifests/windows/server-2025-uefi/
git commit -m "Add Win Server 2025 UEFI variant directory skeleton"
```

---

### Task 4.2: Vanilla Autounattend ConfigMap

The Autounattend.xml is structurally identical to the existing 2022 UEFI variant (`manifests/windows/pipeline-uefi/Autounattend.xml`) with the WIM image name updated to `Windows Server 2025 SERVERSTANDARD`.

**Files:**
- Create: `manifests/windows/server-2025-uefi/autounattend-configmap.yaml`

- [ ] **Step 1: Read existing 2022 Autounattend as the starting reference**

```bash
cat manifests/windows/pipeline-uefi/Autounattend.xml | head -100
```
Note the structure: WindowsPE → specialize → oobeSystem passes; the WIM image name field; the FirstLogonCommands at the end that drive Sysprep.

- [ ] **Step 2: Compare against 2022 sysprep ConfigMap**

```bash
cat manifests/windows/sysprep-configmap.yaml | head -50
```
Confirm how the existing pipeline injects the Autounattend (sysprep volume → ConfigMap with key `Autounattend.xml` + key `Unattend.xml`).

- [ ] **Step 3: Create the 2025 ConfigMap**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: win2k25-autounattend
  namespace: windows-image-build
data:
  Autounattend.xml: |
    <?xml version="1.0" encoding="utf-8"?>
    <unattend xmlns="urn:schemas-microsoft-com:unattend">
      <settings pass="windowsPE">
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35" language="neutral"
                   versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
                   xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <DiskConfiguration>
            <Disk wcm:action="add">
              <CreatePartitions>
                <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>300</Size></CreatePartition>
                <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>128</Size></CreatePartition>
                <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
              </CreatePartitions>
              <ModifyPartitions>
                <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
                <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>
                <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label></ModifyPartition>
              </ModifyPartitions>
              <DiskID>0</DiskID>
              <WillWipeDisk>true</WillWipeDisk>
            </Disk>
          </DiskConfiguration>
          <ImageInstall>
            <OSImage>
              <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
              <InstallFrom>
                <MetaData wcm:action="add">
                  <Key>/IMAGE/NAME</Key>
                  <Value>Windows Server 2025 SERVERSTANDARD</Value>
                </MetaData>
              </InstallFrom>
            </OSImage>
          </ImageInstall>
          <UserData>
            <AcceptEula>true</AcceptEula>
            <FullName>Administrator</FullName>
            <Organization>OpenShift Virt</Organization>
          </UserData>
          <DriverPaths>
            <PathAndCredentials wcm:action="add" wcm:keyValue="1">
              <Path>D:\amd64\2k25</Path>
            </PathAndCredentials>
            <PathAndCredentials wcm:action="add" wcm:keyValue="2">
              <Path>D:\NetKVM\2k25\amd64</Path>
            </PathAndCredentials>
          </DriverPaths>
        </component>
      </settings>
      <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35" language="neutral"
                   versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <ComputerName>WIN-GOLDEN</ComputerName>
          <TimeZone>UTC</TimeZone>
        </component>
      </settings>
      <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35" language="neutral"
                   versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <UserAccounts>
            <AdministratorPassword>
              <Value>changeme123!</Value>
              <PlainText>true</PlainText>
            </AdministratorPassword>
          </UserAccounts>
          <OOBE>
            <HideEULAPage>true</HideEULAPage>
            <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
            <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
            <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
            <NetworkLocation>Work</NetworkLocation>
            <ProtectYourPC>3</ProtectYourPC>
            <SkipMachineOOBE>true</SkipMachineOOBE>
            <SkipUserOOBE>true</SkipUserOOBE>
          </OOBE>
          <FirstLogonCommands>
            <SynchronousCommand wcm:action="add">
              <Order>1</Order>
              <CommandLine>cmd /c "pnputil /add-driver D:\amd64\2k25\*.inf /subdirs /install"</CommandLine>
              <Description>Install virtio drivers</Description>
            </SynchronousCommand>
            <SynchronousCommand wcm:action="add">
              <Order>2</Order>
              <CommandLine>cmd /c "msiexec /i D:\virtio-win-guest-tools.msi /qn /norestart"</CommandLine>
              <Description>Install QEMU guest agent + tools</Description>
            </SynchronousCommand>
            <SynchronousCommand wcm:action="add">
              <Order>3</Order>
              <CommandLine>cmd /c "C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /quiet"</CommandLine>
              <Description>Sysprep generalize and shutdown</Description>
            </SynchronousCommand>
          </FirstLogonCommands>
        </component>
      </settings>
    </unattend>
```

> **Note:** the virtio-win path `D:\amd64\2k25` and `D:\NetKVM\2k25\amd64` follows the virtio-win ISO layout. If 2025 isn't yet in the latest virtio-win ISO at run time, fall back to the `2k22` paths — Win Server 2025 accepts 2022 drivers in most cases. Document any fallback in the variant README.

- [ ] **Step 4: Apply standalone**

```bash
oc apply -f manifests/windows/server-2025-uefi/autounattend-configmap.yaml
```

- [ ] **Step 5: Verify**

```bash
oc get configmap win2k25-autounattend -n windows-image-build \
  -o jsonpath='{.data.Autounattend\.xml}' | head -10
```
Expected: first 10 lines of the XML.

- [ ] **Step 6: Commit**

```bash
git add manifests/windows/server-2025-uefi/autounattend-configmap.yaml
git commit -m "Add Win Server 2025 vanilla Autounattend ConfigMap"
```

---

### Task 4.3: Win Server 2025 vanilla Pipeline manifest

**Files:**
- Create: `manifests/windows/server-2025-uefi/pipeline.yaml`

- [ ] **Step 1: Define state check**

```bash
oc get pipeline win2k25-uefi-image-builder -n windows-image-build -o jsonpath='{.metadata.name}' 2>/dev/null
```
Expected: empty.

- [ ] **Step 2: Create the Pipeline manifest**

```yaml
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: win2k25-uefi-image-builder
spec:
  params:
    - name: windowsIsoUrl
      type: string
    - name: virtioIsoUrl
      type: string
    - name: storageClass
      type: string
      default: ocs-storagecluster-ceph-rbd-virtualization
    - name: goldenImageName
      type: string
      default: win2k25-uefi
    - name: rootDiskSize
      type: string
      default: "60Gi"
    - name: defaultInstancetype
      type: string
      default: u1.2xlarge
    - name: defaultPreference
      type: string
      default: windows.2k25

  tasks:
    - name: upload-windows-iso
      taskRef: { name: upload-source-artefact }
      params:
        - { name: dvName,        value: win2k25-iso }
        - { name: namespace,     value: windows-image-build }
        - { name: url,           value: $(params.windowsIsoUrl) }
        - { name: storageClass,  value: $(params.storageClass) }
        - { name: storageSize,   value: 8Gi }

    - name: upload-virtio-iso
      taskRef: { name: upload-source-artefact }
      params:
        - { name: dvName,        value: virtio-win-iso }
        - { name: namespace,     value: windows-image-build }
        - { name: url,           value: $(params.virtioIsoUrl) }
        - { name: storageClass,  value: $(params.storageClass) }
        - { name: storageSize,   value: 2Gi }

    - name: create-root-disk
      taskRef: { name: create-blank-root-disk }
      params:
        - { name: dvName,        value: win2k25-root-disk }
        - { name: namespace,     value: windows-image-build }
        - { name: storageClass,  value: $(params.storageClass) }
        - { name: rootDiskSize,  value: $(params.rootDiskSize) }

    - name: create-installer-vm
      runAfter: [upload-windows-iso, upload-virtio-iso, create-root-disk]
      taskSpec:
        steps:
          - name: create-vm
            image: image-registry.openshift-image-registry.svc:5000/openshift/cli:latest
            script: |
              #!/bin/bash
              set -euo pipefail
              cat <<'VMEOF' | oc apply -f -
              apiVersion: kubevirt.io/v1
              kind: VirtualMachine
              metadata:
                name: win2k25-installer
                namespace: windows-image-build
              spec:
                runStrategy: RerunOnFailure
                template:
                  metadata:
                    labels:
                      kubevirt.io/vm: win2k25-installer
                  spec:
                    domain:
                      firmware:
                        bootloader:
                          efi:
                            secureBoot: false
                      cpu:
                        cores: 4
                      resources:
                        requests:
                          memory: 8Gi
                      clock:
                        utc: {}
                        timer:
                          hpet: { present: false }
                          hyperv: {}
                          pit: { tickPolicy: delay }
                          rtc: { tickPolicy: catchup }
                      features:
                        acpi: {}
                        apic: {}
                        hyperv:
                          spinlocks: { spinlocks: 8191 }
                          vapic: {}
                          relaxed: {}
                      devices:
                        disks:
                          - name: rootdisk
                            disk: { bus: virtio }
                            bootOrder: 2
                          - name: windows-iso
                            cdrom: { bus: sata }
                            bootOrder: 1
                          - name: virtio-drivers
                            cdrom: { bus: sata }
                          - name: sysprep
                            cdrom: { bus: sata }
                        interfaces:
                          - name: default
                            masquerade: {}
                    networks:
                      - name: default
                        pod: {}
                    volumes:
                      - name: rootdisk
                        persistentVolumeClaim:
                          claimName: win2k25-root-disk
                      - name: windows-iso
                        persistentVolumeClaim:
                          claimName: win2k25-iso
                      - name: virtio-drivers
                        persistentVolumeClaim:
                          claimName: virtio-win-iso
                      - name: sysprep
                        sysprep:
                          configMap:
                            name: win2k25-autounattend
              VMEOF
              echo "Win Server 2025 installer VM created"

    - name: trigger-boot
      runAfter: [create-installer-vm]
      taskRef: { name: trigger-cd-boot-uefi }
      params:
        - { name: vmName,    value: win2k25-installer }
        - { name: namespace, value: windows-image-build }

    - name: wait-shutdown
      runAfter: [trigger-boot]
      timeout: "4h"
      taskRef: { name: wait-for-vm-shutdown }
      params:
        - { name: vmName,    value: win2k25-installer }
        - { name: namespace, value: windows-image-build }

    - name: clone
      runAfter: [wait-shutdown]
      taskRef: { name: clone-to-catalog }
      params:
        - { name: sourcePvcName,         value: win2k25-root-disk }
        - { name: sourceNamespace,       value: windows-image-build }
        - { name: goldenImageName,       value: $(params.goldenImageName) }
        - { name: storageClass,          value: $(params.storageClass) }
        - { name: rootDiskSize,          value: $(params.rootDiskSize) }
        - { name: defaultInstancetype,   value: $(params.defaultInstancetype) }
        - { name: defaultPreference,     value: $(params.defaultPreference) }
        - { name: complianceBaseline,    value: "" }

    - name: cleanup
      runAfter: [clone]
      taskRef: { name: cleanup-build-namespace }
      params:
        - { name: vmName,         value: win2k25-installer }
        - { name: rootDiskDvName, value: win2k25-root-disk }
        - { name: namespace,      value: windows-image-build }
```

- [ ] **Step 3: Apply standalone**

The kustomization references `pipelinerun.yaml`, which Task 4.4 creates. Apply this manifest standalone for now.

```bash
oc apply -f manifests/windows/server-2025-uefi/pipeline.yaml
```

- [ ] **Step 4: Verify**

```bash
oc get pipeline win2k25-uefi-image-builder -n windows-image-build -o jsonpath='{.metadata.name}'
```
Expected: `win2k25-uefi-image-builder`

- [ ] **Step 5: Commit**

```bash
git add manifests/windows/server-2025-uefi/pipeline.yaml
git commit -m "Add Win Server 2025 UEFI vanilla Pipeline manifest"
```

---

### Task 4.4: Win Server 2025 PipelineRun + end-to-end run

**Files:**
- Create: `manifests/windows/server-2025-uefi/pipelinerun.yaml`

- [ ] **Step 1: Create the PipelineRun template**

```yaml
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: win2k25-uefi-image-build-
  namespace: windows-image-build
spec:
  pipelineRef:
    name: win2k25-uefi-image-builder
  taskRunTemplate:
    serviceAccountName: windows-image-pipeline
  timeouts:
    pipeline: "5h"
    tasks: "4h30m"
  params:
    - name: windowsIsoUrl
      # Win Server 2025 evaluation ISO from Microsoft Evaluation Center
      # https://www.microsoft.com/en-us/evalcenter/download-windows-server-2025
      # Replace below with the latest direct-download URL.
      value: "https://go.microsoft.com/fwlink/?linkid=REPLACE-ME-2025"
    - name: virtioIsoUrl
      value: "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
    - name: storageClass
      value: "ocs-storagecluster-ceph-rbd-virtualization"
    - name: goldenImageName
      value: "win2k25-uefi"
    - name: rootDiskSize
      value: "60Gi"
    - name: defaultInstancetype
      value: "u1.2xlarge"
    - name: defaultPreference
      value: "windows.2k25"
```

- [ ] **Step 2: Apply**

```bash
oc apply -k manifests/windows/server-2025-uefi/
```

- [ ] **Step 3: Trigger a run**

Edit `pipelinerun.yaml` to paste the latest Microsoft evaluation URL (do not commit), then:

```bash
oc create -f manifests/windows/server-2025-uefi/pipelinerun.yaml
RUN=$(oc get pipelinerun -n windows-image-build \
  -o jsonpath='{.items[-1].metadata.name}')
tkn pipelinerun logs $RUN -n windows-image-build -f
```
Expected runtime: 60–90 min.

- [ ] **Step 4: Verify the catalogue DataSource**

```bash
oc get datasource win2k25-uefi -n openshift-virtualization-os-images \
  -o jsonpath='{.metadata.labels}{"\n"}'
```
Expected output contains:
```
"instancetype.kubevirt.io/default-instancetype":"u1.2xlarge"
"instancetype.kubevirt.io/default-preference":"windows.2k25"
```

- [ ] **Step 5: Boot a consumer VM**

```bash
cat <<EOF | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: win2k25-consumer-test
  namespace: windows-image-build
spec:
  runStrategy: RerunOnFailure
  dataVolumeTemplates:
    - metadata:
        name: win2k25-consumer-test-disk
      spec:
        sourceRef:
          kind: DataSource
          name: win2k25-uefi
          namespace: openshift-virtualization-os-images
        storage:
          resources:
            requests:
              storage: 60Gi
  template:
    spec:
      domain:
        firmware:
          bootloader:
            efi:
              secureBoot: false
        cpu: { cores: 4 }
        resources:
          requests:
            memory: 8Gi
        clock:
          utc: {}
          timer:
            hpet: { present: false }
            hyperv: {}
            pit: { tickPolicy: delay }
            rtc: { tickPolicy: catchup }
        features:
          acpi: {}
          apic: {}
          hyperv:
            spinlocks: { spinlocks: 8191 }
            vapic: {}
            relaxed: {}
        devices:
          disks:
            - name: rootdisk
              disk: { bus: virtio }
          interfaces:
            - name: default
              masquerade: {}
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          dataVolume:
            name: win2k25-consumer-test-disk
EOF

oc wait vmi/win2k25-consumer-test -n windows-image-build \
  --for=condition=Ready --timeout=15m

oc get vmi win2k25-consumer-test -n windows-image-build \
  -o jsonpath='{.status.conditions[?(@.type=="AgentConnected")].status}'
```
Expected: `True`. Allow up to 10 min for first boot + guest-agent registration on Windows.

- [ ] **Step 6: Tear down test resources**

```bash
oc delete vm win2k25-consumer-test -n windows-image-build
oc delete dv win2k25-consumer-test-disk -n windows-image-build --ignore-not-found
```

- [ ] **Step 7: Reset any pasted URL and commit**

```bash
git checkout manifests/windows/server-2025-uefi/pipelinerun.yaml
git add manifests/windows/server-2025-uefi/pipelinerun.yaml
git commit -m "Add Win Server 2025 UEFI PipelineRun template"
```

---

### Task 4.5: Win Server 2025 README

**Files:**
- Modify: `manifests/windows/server-2025-uefi/README.md`

- [ ] **Step 1: Replace README content**

```markdown
# Win Server 2025 UEFI — vanilla golden image pipeline

Builds a Win Server 2025 golden image via Sysprep and publishes it as
DataSource `win2k25-uefi` in `openshift-virtualization-os-images`.

## ISO sources

- **Win Server 2025 evaluation ISO** — Microsoft Evaluation Center:
  https://www.microsoft.com/en-us/evalcenter/download-windows-server-2025
  Microsoft direct-download URLs are not stable; obtain a fresh URL
  before each run by clicking through the Eval Center.
- **virtio-win drivers** — Fedora People stable build:
  https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso

## Deploy + run

```bash
source .env
oc apply -k manifests/windows/server-2025-uefi/
# Edit pipelinerun.yaml to paste the Eval Center URL (do not commit)
oc create -f manifests/windows/server-2025-uefi/pipelinerun.yaml
RUN=$(oc get pipelinerun -n windows-image-build \
  -o jsonpath='{.items[-1].metadata.name}')
tkn pipelinerun logs $RUN -n windows-image-build -f
```

Expected runtime: 60–90 min.

## Catalogue output

- `DataSource` `win2k25-uefi` in `openshift-virtualization-os-images`
  with `default-instancetype: u1.2xlarge`, `default-preference: windows.2k25`.
- No `compliance.kubevirt.io/baseline` label (vanilla).

## Known gotchas

- **virtio-win driver paths**: the Autounattend hard-codes
  `D:\amd64\2k25` and `D:\NetKVM\2k25\amd64`. If those paths don't
  exist in the virtio-win ISO at run time, the install will succeed
  with built-in drivers but virtio NIC may not initialise. Fallback:
  use `2k22` paths in Autounattend.
- **OVMF boot-key dance**: the `trigger-cd-boot-uefi` Task is timing-
  sensitive. If the install hangs at the OVMF "No bootable option"
  screen, see PRD risk R6 — fixes propagate via the shared boot-trigger
  Task.
- **Microsoft Eval Center URLs are not stable**: they expire / change
  without notice. Don't bake URLs into git.
```

- [ ] **Step 2: Commit**

```bash
git add manifests/windows/server-2025-uefi/README.md
git commit -m "Document Win Server 2025 UEFI vanilla variant"
```

---

## Phase 5 — Win Server 2025 hardened pipeline

Phase goal: a `win2k25-uefi-hardened` sibling that applies CIS L1 (Server) GPO via Microsoft Security Compliance Toolkit during `FirstLogonCommands`, before Sysprep generalize. Begins with a spike to validate SCT availability (R3 mitigation).

### Task 5.1: SCT availability spike (R3)

**Files:** none committed unless the spike needs to mirror SCT internally.

- [ ] **Step 1: Identify the latest SCT download**

Microsoft publishes SCT at https://www.microsoft.com/en-us/download/details.aspx?id=55319. The download is a self-extracting `.cab`. The Windows Server 2025 Security Baseline is a separate download at https://www.microsoft.com/en-us/download/details.aspx?id=...

Manually walk through Microsoft's Download Center and capture:
- The current direct-download URL for the SCT installer.
- The current direct-download URL for the Win Server 2025 Security Baseline `.zip`.

- [ ] **Step 2: Test stability**

`curl -I` each URL. Note any redirects. Re-test 24 hours later. Record:
- Did the URL still resolve?
- Was the artefact bit-identical (`sha256sum`)?
- Did Microsoft introduce a CAPTCHA or login wall?

- [ ] **Step 3: Decide go/no-go**

- **Go:** URLs stable for 24 hours, no auth wall. Hardcode them in the Autounattend (Task 5.3).
- **No-go:** URLs expire, change content, or require interactive download. Mirror SCT + the 2025 baseline ZIP to an internal HTTP source (e.g. an `nginx` Pod backed by a PVC in `windows-image-build`, or COS bucket). The hardened Autounattend's `FirstLogonCommands` then `curl`s from the mirror.

- [ ] **Step 4: Document the outcome**

In the variant README (Task 5.5), capture the decision and the URLs (or mirror endpoint) used.

- [ ] **Step 5: If mirroring is required, commit the mirror manifest**

If the spike outcome is "no-go", create `manifests/windows/server-2025-uefi-hardened/sct-mirror.yaml` (a small `nginx` Deployment + Service + PVC seeded with SCT). Otherwise skip.

```bash
# Only if no-go:
git add manifests/windows/server-2025-uefi-hardened/sct-mirror.yaml
git commit -m "Mirror Microsoft SCT for Win 2025 hardened pipeline"
```

---

### Task 5.2: Hardened variant directory skeleton

**Files:**
- Create: `manifests/windows/server-2025-uefi-hardened/kustomization.yaml`
- Create: `manifests/windows/server-2025-uefi-hardened/pipeline-rbac.yaml`
- Create: `manifests/windows/server-2025-uefi-hardened/README.md`

- [ ] **Step 1: Create kustomization**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: windows-image-build
resources:
  - autounattend-configmap.yaml
  - pipeline-rbac.yaml
  - pipeline.yaml
  - pipelinerun.yaml
```

- [ ] **Step 2: Create pipeline-rbac placeholder**

```yaml
# Win Server 2025 hardened — no per-variant RBAC needed beyond the
# shared windows-image-pipeline ServiceAccount.
---
```

- [ ] **Step 3: Create README skeleton**

```markdown
# Win Server 2025 UEFI hardened — CIS L1 golden image pipeline

Builds a CIS L1-hardened Win Server 2025 image and publishes it as
DataSource `win2k25-uefi-hardened` in
`openshift-virtualization-os-images`.

**Status:** under construction (Batch 1 pilot).

Hardening is applied via Microsoft Security Compliance Toolkit
(LGPO.exe + GPO backups) during `FirstLogonCommands`, *before* Sysprep
generalize, so the policy is baked into the cloned image.
```

- [ ] **Step 4: Commit**

```bash
git add manifests/windows/server-2025-uefi-hardened/
git commit -m "Add Win Server 2025 UEFI hardened variant directory skeleton"
```

---

### Task 5.3: Hardened Autounattend ConfigMap with SCT

**Files:**
- Create: `manifests/windows/server-2025-uefi-hardened/autounattend-configmap.yaml`

- [ ] **Step 1: Define state check**

```bash
oc get configmap win2k25-hardened-autounattend -n windows-image-build -o jsonpath='{.metadata.name}' 2>/dev/null
```
Expected: empty.

- [ ] **Step 2: Create the hardened ConfigMap**

The Autounattend is identical to vanilla until `FirstLogonCommands`. The hardened version inserts SCT download + LGPO apply between the virtio install and Sysprep.

> **URL placeholders below:** replace `SCT_URL` and `BASELINE_URL` with the values from Task 5.1's spike before applying. If the spike concluded "no-go", point to the internal mirror endpoint instead.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: win2k25-hardened-autounattend
  namespace: windows-image-build
data:
  Autounattend.xml: |
    <?xml version="1.0" encoding="utf-8"?>
    <unattend xmlns="urn:schemas-microsoft-com:unattend">
      <settings pass="windowsPE">
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35" language="neutral"
                   versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
                   xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <DiskConfiguration>
            <Disk wcm:action="add">
              <CreatePartitions>
                <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>300</Size></CreatePartition>
                <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>128</Size></CreatePartition>
                <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
              </CreatePartitions>
              <ModifyPartitions>
                <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
                <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>
                <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label></ModifyPartition>
              </ModifyPartitions>
              <DiskID>0</DiskID>
              <WillWipeDisk>true</WillWipeDisk>
            </Disk>
          </DiskConfiguration>
          <ImageInstall>
            <OSImage>
              <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
              <InstallFrom>
                <MetaData wcm:action="add">
                  <Key>/IMAGE/NAME</Key>
                  <Value>Windows Server 2025 SERVERSTANDARD</Value>
                </MetaData>
              </InstallFrom>
            </OSImage>
          </ImageInstall>
          <UserData>
            <AcceptEula>true</AcceptEula>
            <FullName>Administrator</FullName>
            <Organization>OpenShift Virt</Organization>
          </UserData>
          <DriverPaths>
            <PathAndCredentials wcm:action="add" wcm:keyValue="1">
              <Path>D:\amd64\2k25</Path>
            </PathAndCredentials>
            <PathAndCredentials wcm:action="add" wcm:keyValue="2">
              <Path>D:\NetKVM\2k25\amd64</Path>
            </PathAndCredentials>
          </DriverPaths>
        </component>
      </settings>
      <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35" language="neutral"
                   versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <ComputerName>WIN-GOLDEN</ComputerName>
          <TimeZone>UTC</TimeZone>
        </component>
      </settings>
      <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35" language="neutral"
                   versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <UserAccounts>
            <AdministratorPassword>
              <Value>changeme123!</Value>
              <PlainText>true</PlainText>
            </AdministratorPassword>
          </UserAccounts>
          <OOBE>
            <HideEULAPage>true</HideEULAPage>
            <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
            <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
            <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
            <NetworkLocation>Work</NetworkLocation>
            <ProtectYourPC>3</ProtectYourPC>
            <SkipMachineOOBE>true</SkipMachineOOBE>
            <SkipUserOOBE>true</SkipUserOOBE>
          </OOBE>
          <FirstLogonCommands>
            <SynchronousCommand wcm:action="add">
              <Order>1</Order>
              <CommandLine>cmd /c "pnputil /add-driver D:\amd64\2k25\*.inf /subdirs /install"</CommandLine>
              <Description>Install virtio drivers</Description>
            </SynchronousCommand>
            <SynchronousCommand wcm:action="add">
              <Order>2</Order>
              <CommandLine>cmd /c "msiexec /i D:\virtio-win-guest-tools.msi /qn /norestart"</CommandLine>
              <Description>Install QEMU guest tools</Description>
            </SynchronousCommand>
            <SynchronousCommand wcm:action="add">
              <Order>3</Order>
              <CommandLine>powershell -ExecutionPolicy Bypass -Command "New-Item -ItemType Directory -Path C:\harden -Force | Out-Null; Invoke-WebRequest -Uri 'SCT_URL' -OutFile C:\harden\sct.zip; Expand-Archive C:\harden\sct.zip -DestinationPath C:\harden\sct -Force; Invoke-WebRequest -Uri 'BASELINE_URL' -OutFile C:\harden\baseline.zip; Expand-Archive C:\harden\baseline.zip -DestinationPath C:\harden\baseline -Force"</CommandLine>
              <Description>Download SCT + Server 2025 CIS L1 baseline</Description>
            </SynchronousCommand>
            <SynchronousCommand wcm:action="add">
              <Order>4</Order>
              <CommandLine>powershell -ExecutionPolicy Bypass -Command "Get-ChildItem -Path C:\harden\baseline -Recurse -Filter 'GptTmpl.inf' | ForEach-Object { &amp; C:\harden\sct\LGPO.exe /s $_.FullName }; Get-ChildItem -Path C:\harden\baseline -Recurse -Directory -Filter 'DomainSysvol' | ForEach-Object { &amp; C:\harden\sct\LGPO.exe /g $_.FullName }"</CommandLine>
              <Description>Apply CIS L1 GPO via LGPO.exe</Description>
            </SynchronousCommand>
            <SynchronousCommand wcm:action="add">
              <Order>5</Order>
              <CommandLine>powershell -ExecutionPolicy Bypass -Command "&amp; C:\harden\sct\PolicyAnalyzer.exe /CompareToTemplate C:\harden\baseline /Output C:\Windows\Temp\policy-analyzer-results.xml" </CommandLine>
              <Description>Snapshot Policy Analyzer comparison for audit</Description>
            </SynchronousCommand>
            <SynchronousCommand wcm:action="add">
              <Order>6</Order>
              <CommandLine>cmd /c "C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /quiet"</CommandLine>
              <Description>Sysprep generalize and shutdown</Description>
            </SynchronousCommand>
          </FirstLogonCommands>
        </component>
      </settings>
    </unattend>
```

> **Note on the LGPO commands**: PolicyAnalyzer's CLI syntax may differ
> from above; the actual flags are documented in the SCT package. The
> command shown is a reasonable starting point; expect to adjust based
> on the SCT version downloaded in the spike. If PolicyAnalyzer's CLI
> is unavailable, the audit step (Order 5) can be dropped and replaced
> by an offline scan of the cloned image (similar to the RHEL approach
> in Task 3.4).

- [ ] **Step 3: Replace placeholders with spike-resolved URLs**

```bash
# Replace SCT_URL and BASELINE_URL placeholders before apply
sed -i.bak "s|SCT_URL|<spike-url-1>|; s|BASELINE_URL|<spike-url-2>|" \
  manifests/windows/server-2025-uefi-hardened/autounattend-configmap.yaml
rm manifests/windows/server-2025-uefi-hardened/autounattend-configmap.yaml.bak
```
**Decision:** if the spike outcome is "go" with stable URLs, commit the URLs. If "no-go", commit the mirror endpoint URL instead. Either way, update the README to record the choice.

- [ ] **Step 4: Apply standalone**

```bash
oc apply -f manifests/windows/server-2025-uefi-hardened/autounattend-configmap.yaml
```

- [ ] **Step 5: Verify**

```bash
oc get configmap win2k25-hardened-autounattend -n windows-image-build \
  -o jsonpath='{.data.Autounattend\.xml}' | grep -A 2 LGPO | head
```
Expected: lines containing the LGPO.exe invocations.

- [ ] **Step 6: Commit**

```bash
git add manifests/windows/server-2025-uefi-hardened/autounattend-configmap.yaml
git commit -m "Add Win Server 2025 hardened Autounattend with SCT/LGPO"
```

---

### Task 5.4: Hardened Pipeline manifest + PipelineRun + run

**Files:**
- Create: `manifests/windows/server-2025-uefi-hardened/pipeline.yaml`
- Create: `manifests/windows/server-2025-uefi-hardened/pipelinerun.yaml`

The Pipeline is identical to Task 4.3 except for: name (`win2k25-uefi-hardened-image-builder`), VM name (`win2k25-hardened-installer`), DV names (`win2k25-hardened-root-disk`), `goldenImageName` default (`win2k25-uefi-hardened`), Autounattend ConfigMap reference (`win2k25-hardened-autounattend`), and `complianceBaseline` param (`cis-l1`).

- [ ] **Step 1: Create the Pipeline**

```yaml
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: win2k25-uefi-hardened-image-builder
spec:
  params:
    - name: windowsIsoUrl
      type: string
    - name: virtioIsoUrl
      type: string
    - name: storageClass
      type: string
      default: ocs-storagecluster-ceph-rbd-virtualization
    - name: goldenImageName
      type: string
      default: win2k25-uefi-hardened
    - name: rootDiskSize
      type: string
      default: "60Gi"
    - name: defaultInstancetype
      type: string
      default: u1.2xlarge
    - name: defaultPreference
      type: string
      default: windows.2k25
    - name: complianceBaseline
      type: string
      default: cis-l1

  tasks:
    - name: upload-windows-iso
      taskRef: { name: upload-source-artefact }
      params:
        - { name: dvName,        value: win2k25-iso }
        - { name: namespace,     value: windows-image-build }
        - { name: url,           value: $(params.windowsIsoUrl) }
        - { name: storageClass,  value: $(params.storageClass) }
        - { name: storageSize,   value: 8Gi }

    - name: upload-virtio-iso
      taskRef: { name: upload-source-artefact }
      params:
        - { name: dvName,        value: virtio-win-iso }
        - { name: namespace,     value: windows-image-build }
        - { name: url,           value: $(params.virtioIsoUrl) }
        - { name: storageClass,  value: $(params.storageClass) }
        - { name: storageSize,   value: 2Gi }

    - name: create-root-disk
      taskRef: { name: create-blank-root-disk }
      params:
        - { name: dvName,        value: win2k25-hardened-root-disk }
        - { name: namespace,     value: windows-image-build }
        - { name: storageClass,  value: $(params.storageClass) }
        - { name: rootDiskSize,  value: $(params.rootDiskSize) }

    - name: create-installer-vm
      runAfter: [upload-windows-iso, upload-virtio-iso, create-root-disk]
      taskSpec:
        steps:
          - name: create-vm
            image: image-registry.openshift-image-registry.svc:5000/openshift/cli:latest
            script: |
              #!/bin/bash
              set -euo pipefail
              cat <<'VMEOF' | oc apply -f -
              apiVersion: kubevirt.io/v1
              kind: VirtualMachine
              metadata:
                name: win2k25-hardened-installer
                namespace: windows-image-build
              spec:
                runStrategy: RerunOnFailure
                template:
                  metadata:
                    labels:
                      kubevirt.io/vm: win2k25-hardened-installer
                  spec:
                    domain:
                      firmware:
                        bootloader:
                          efi:
                            secureBoot: false
                      cpu:
                        cores: 4
                      resources:
                        requests:
                          memory: 8Gi
                      clock:
                        utc: {}
                        timer:
                          hpet: { present: false }
                          hyperv: {}
                          pit: { tickPolicy: delay }
                          rtc: { tickPolicy: catchup }
                      features:
                        acpi: {}
                        apic: {}
                        hyperv:
                          spinlocks: { spinlocks: 8191 }
                          vapic: {}
                          relaxed: {}
                      devices:
                        disks:
                          - name: rootdisk
                            disk: { bus: virtio }
                            bootOrder: 2
                          - name: windows-iso
                            cdrom: { bus: sata }
                            bootOrder: 1
                          - name: virtio-drivers
                            cdrom: { bus: sata }
                          - name: sysprep
                            cdrom: { bus: sata }
                        interfaces:
                          - name: default
                            masquerade: {}
                    networks:
                      - name: default
                        pod: {}
                    volumes:
                      - name: rootdisk
                        persistentVolumeClaim:
                          claimName: win2k25-hardened-root-disk
                      - name: windows-iso
                        persistentVolumeClaim:
                          claimName: win2k25-iso
                      - name: virtio-drivers
                        persistentVolumeClaim:
                          claimName: virtio-win-iso
                      - name: sysprep
                        sysprep:
                          configMap:
                            name: win2k25-hardened-autounattend
              VMEOF
              echo "Win Server 2025 hardened installer VM created"

    - name: trigger-boot
      runAfter: [create-installer-vm]
      taskRef: { name: trigger-cd-boot-uefi }
      params:
        - { name: vmName,    value: win2k25-hardened-installer }
        - { name: namespace, value: windows-image-build }

    - name: wait-shutdown
      runAfter: [trigger-boot]
      timeout: "5h"
      taskRef: { name: wait-for-vm-shutdown }
      params:
        - { name: vmName,    value: win2k25-hardened-installer }
        - { name: namespace, value: windows-image-build }

    - name: clone
      runAfter: [wait-shutdown]
      taskRef: { name: clone-to-catalog }
      params:
        - { name: sourcePvcName,         value: win2k25-hardened-root-disk }
        - { name: sourceNamespace,       value: windows-image-build }
        - { name: goldenImageName,       value: $(params.goldenImageName) }
        - { name: storageClass,          value: $(params.storageClass) }
        - { name: rootDiskSize,          value: $(params.rootDiskSize) }
        - { name: defaultInstancetype,   value: $(params.defaultInstancetype) }
        - { name: defaultPreference,     value: $(params.defaultPreference) }
        - { name: complianceBaseline,    value: $(params.complianceBaseline) }

    - name: cleanup
      runAfter: [clone]
      taskRef: { name: cleanup-build-namespace }
      params:
        - { name: vmName,         value: win2k25-hardened-installer }
        - { name: rootDiskDvName, value: win2k25-hardened-root-disk }
        - { name: namespace,      value: windows-image-build }
```

- [ ] **Step 2: Create the PipelineRun**

```yaml
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: win2k25-uefi-hardened-image-build-
  namespace: windows-image-build
spec:
  pipelineRef:
    name: win2k25-uefi-hardened-image-builder
  taskRunTemplate:
    serviceAccountName: windows-image-pipeline
  timeouts:
    pipeline: "6h"
    tasks: "5h30m"
  params:
    - name: windowsIsoUrl
      value: "https://go.microsoft.com/fwlink/?linkid=REPLACE-ME-2025"
    - name: virtioIsoUrl
      value: "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
    - name: storageClass
      value: "ocs-storagecluster-ceph-rbd-virtualization"
    - name: goldenImageName
      value: "win2k25-uefi-hardened"
    - name: rootDiskSize
      value: "60Gi"
    - name: defaultInstancetype
      value: "u1.2xlarge"
    - name: defaultPreference
      value: "windows.2k25"
    - name: complianceBaseline
      value: "cis-l1"
```

- [ ] **Step 3: Apply**

```bash
oc apply -k manifests/windows/server-2025-uefi-hardened/
```

- [ ] **Step 4: Run end-to-end**

Edit `pipelinerun.yaml` to paste Eval Center URL (do not commit), then:

```bash
oc create -f manifests/windows/server-2025-uefi-hardened/pipelinerun.yaml
RUN=$(oc get pipelinerun -n windows-image-build \
  -o jsonpath='{.items[-1].metadata.name}')
tkn pipelinerun logs $RUN -n windows-image-build -f
```
Expected runtime: 90–120 min (vanilla 2025 + extra time for SCT download + LGPO apply + PolicyAnalyzer scan).

- [ ] **Step 5: Verify the catalogue DataSource has the compliance label**

```bash
oc get datasource win2k25-uefi-hardened -n openshift-virtualization-os-images \
  -o jsonpath='{.metadata.labels.compliance\.kubevirt\.io/baseline}'
```
Expected: `cis-l1`

- [ ] **Step 6: Verify CIS L1 pass rate via Policy Analyzer comparison**

The Autounattend's Order 5 wrote `C:\Windows\Temp\policy-analyzer-results.xml` inside the image. Extract using the same pattern as Task 3.4 Step 5–6 (mount the cloned PVC on a maintenance pod, but for Windows the PVC is NTFS — use a Linux pod with `ntfs-3g` to mount).

```bash
cat <<EOF | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: win2k25-hardened-consumer-test
  namespace: windows-image-build
spec:
  runStrategy: RerunOnFailure
  dataVolumeTemplates:
    - metadata:
        name: win2k25-hardened-consumer-test-disk
      spec:
        sourceRef:
          kind: DataSource
          name: win2k25-uefi-hardened
          namespace: openshift-virtualization-os-images
        storage:
          resources:
            requests:
              storage: 60Gi
  template:
    spec:
      domain:
        firmware:
          bootloader:
            efi:
              secureBoot: false
        cpu: { cores: 4 }
        resources:
          requests:
            memory: 8Gi
        clock:
          utc: {}
          timer:
            hpet: { present: false }
            hyperv: {}
            pit: { tickPolicy: delay }
            rtc: { tickPolicy: catchup }
        features:
          acpi: {}
          apic: {}
          hyperv:
            spinlocks: { spinlocks: 8191 }
            vapic: {}
            relaxed: {}
        devices:
          disks:
            - name: rootdisk
              disk: { bus: virtio }
          interfaces:
            - name: default
              masquerade: {}
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          dataVolume:
            name: win2k25-hardened-consumer-test-disk
EOF

oc wait vmi/win2k25-hardened-consumer-test -n windows-image-build \
  --for=condition=Ready --timeout=15m
```

Once the VM is Ready, log in via `virtctl console` (Administrator / changeme123!) and inspect `C:\Windows\Temp\policy-analyzer-results.xml`. Count `<Pass>` vs `<Fail>` elements. Compute pass rate over applicable rules (PolicyAnalyzer's output format gives Configured/NotConfigured/Mismatch — pass = Configured, applicable = Configured + Mismatch).

Expected: pass rate ≥ 90%.

If under 90%: review failing rules, document acceptable exceptions in the variant README (Task 5.5), or update the Autounattend's CIS GPO source if a misapply is identified.

- [ ] **Step 7: Tear down test resources**

```bash
oc delete vm win2k25-hardened-consumer-test -n windows-image-build
oc delete dv win2k25-hardened-consumer-test-disk -n windows-image-build --ignore-not-found
```

- [ ] **Step 8: Commit**

```bash
git checkout manifests/windows/server-2025-uefi-hardened/pipelinerun.yaml
git add manifests/windows/server-2025-uefi-hardened/pipeline.yaml \
        manifests/windows/server-2025-uefi-hardened/pipelinerun.yaml
git commit -m "Add Win Server 2025 hardened Pipeline + PipelineRun"
```

---

### Task 5.5: Hardened README + documented exceptions

**Files:**
- Modify: `manifests/windows/server-2025-uefi-hardened/README.md`

- [ ] **Step 1: Replace README content**

```markdown
# Win Server 2025 UEFI hardened — CIS L1 golden image pipeline

Builds a CIS Benchmark Level 1 (Server) hardened Win Server 2025 image
and publishes it as DataSource `win2k25-uefi-hardened` in
`openshift-virtualization-os-images`, labelled with
`compliance.kubevirt.io/baseline: cis-l1`.

## Hardening mechanism

Microsoft Security Compliance Toolkit (LGPO.exe) applies the
Win Server 2025 CIS L1 GPO during Autounattend `FirstLogonCommands`,
*before* Sysprep generalize. The applied policy is therefore baked
into the cloned golden image, not deferred to first-boot.

## SCT and baseline source

Outcome of the SCT availability spike (R3 in PRD §6):

- **Decision:** <go / no-go — fill in after Task 5.1>
- **SCT URL or mirror endpoint:** <URL>
- **Win 2025 CIS baseline URL or mirror endpoint:** <URL>

## ISO sources

Same as vanilla — see `../server-2025-uefi/README.md`.

## Deploy + run

```bash
source .env
oc apply -k manifests/windows/server-2025-uefi-hardened/
oc create -f manifests/windows/server-2025-uefi-hardened/pipelinerun.yaml
```

Expected runtime: 90–120 min.

## Catalogue output

- `DataSource` `win2k25-uefi-hardened` in
  `openshift-virtualization-os-images`
- Labels: `default-instancetype: u1.2xlarge`,
  `default-preference: windows.2k25`,
  `compliance.kubevirt.io/baseline: cis-l1`.

## Policy Analyzer pass rate

Last verified pass rate: <fill in after Task 5.4>.

### Documented exceptions

| GPO Setting | Reason for exception |
|---|---|
| (e.g.) Account lockout duration | Single-tenant golden image; lockout policies set per-tenant by joining domain at deploy time |

## Known gotchas

- **PolicyAnalyzer CLI flags drift with SCT versions** — if Order 5
  in the Autounattend fails silently, run PolicyAnalyzer interactively
  inside the VM to confirm the correct flags for the SCT version.
- **LGPO requires admin context** — `FirstLogonCommands` runs as the
  Administrator account by default; if a future change moves these
  commands elsewhere, ensure they retain admin rights.
- **Sysprep ordering** — LGPO must run *before* sysprep generalize.
  The Autounattend's Order numbers preserve this; do not reorder.
```

- [ ] **Step 2: Commit**

```bash
git add manifests/windows/server-2025-uefi-hardened/README.md
git commit -m "Document Win Server 2025 hardened variant"
```

---

## Phase 6 — Pattern-reuse acceptance test

Phase goal: prove pilot acceptance criterion §6.2.7 — that adding a 5th variant requires zero edits to `shared-tasks/`, `boot-trigger-tasks/`, or any other variant. RHEL 8 is the candidate because it's a near-clone of RHEL 9 with only minor differences (kernel version, package set, SCAP datastream filename).

This is a *proof*, not a ship — work happens on a scratch branch and is left as a documented PR or spike artefact, not merged into main as a Batch 1 deliverable. Batch 2 picks up RHEL 8 properly.

### Task 6.1: Scaffold RHEL 8 variant on scratch branch

**Files:** all created on a scratch branch named `spike/rhel-8-pattern-reuse`. Nothing merges to `main` from this phase.

- [ ] **Step 1: Create scratch branch**

```bash
git checkout -b spike/rhel-8-pattern-reuse
```

- [ ] **Step 2: Copy RHEL 9 vanilla as starting point**

```bash
cp -r manifests/linux/rhel-9 manifests/linux/rhel-8
```

- [ ] **Step 3: Edit only RHEL 8-specific values**

Modify `manifests/linux/rhel-8/`:
- `kickstart-configmap.yaml`: change `name:` to `rhel-8-kickstart`; change `#version=RHEL9` to `#version=RHEL8`; remove `cloud-init` from `%packages` if not desired (or keep — RHEL 8 has it too); confirm package list works on RHEL 8.
- `pipeline.yaml`: change Pipeline `name:` to `rhel-8-image-builder`, `goldenImageName` default to `rhel-8`, `defaultPreference` to `rhel.8`. Change DV names: `rhel-8-iso`, `rhel-8-root-disk`, VM name `rhel-8-installer`. Reference `rhel-8-kickstart` ConfigMap.
- `pipelinerun.yaml`: same name updates; URL placeholder for RHEL 8 boot ISO.
- `kustomization.yaml`: unchanged (still references the same filenames).
- `README.md`: replace "RHEL 9" with "RHEL 8" throughout.

- [ ] **Step 4: Verify the templating-reuse property**

The crux of this phase: confirm that adding RHEL 8 required no edits outside `manifests/linux/rhel-8/`.

```bash
git status
git diff --name-only
```
Expected output: every file is under `manifests/linux/rhel-8/`. **Zero edits** to `manifests/pipelines/shared-tasks/`, `manifests/pipelines/boot-trigger-tasks/`, `manifests/pipelines/build-namespaces/`, or `manifests/linux/rhel-9/` etc.

If any files outside `rhel-8/` were modified, the templating pattern has leaked — investigate why and fix the leak before treating this as passing.

- [ ] **Step 5: Optional: dry-run apply**

```bash
oc apply -k manifests/linux/rhel-8/ --dry-run=client
```
Expected: all four resources (ConfigMap, Pipeline, PipelineRun, RBAC placeholder) are validated without errors. **Do not run the pipeline** — this is a templating proof, not a real RHEL 8 build.

- [ ] **Step 6: Commit on scratch branch**

```bash
git add manifests/linux/rhel-8/
git commit -m "spike: RHEL 8 scaffolded from RHEL 9 — zero shared-task edits"
```

- [ ] **Step 7: Document the outcome**

Switch back to main and record the result in the variant README registry (or as a note in the design spec):

```bash
git checkout main
```

Then add a note to `docs/superpowers/specs/2026-04-26-image-pipeline-expansion-design.md` under §6.2 acceptance criterion 7 confirming the reuse property held. (Or, if templating leaked, document the leak and the fix needed.)

```bash
# Edit the spec to add a "Pilot acceptance results" subsection
# referencing the scratch branch.
git add docs/superpowers/specs/2026-04-26-image-pipeline-expansion-design.md
git commit -m "Record pilot acceptance results: pattern-reuse property verified"
```

The scratch branch can be left dangling, deleted, or kept as a starting point for Batch 2's RHEL 8 work.

---

## Phase 7 — Pilot retrospective + handoff

### Task 7.1: Verify all PRD §6.2 pilot acceptance criteria

**Files:** none modified — checklist verification.

- [ ] **Step 1: Walk the criteria checklist**

Open `docs/superpowers/specs/2026-04-26-image-pipeline-expansion-design.md` §6.2 and confirm each:

1. ☐ All 4 PipelineRuns completed successfully on `nrt-prod-cluster1`.
2. ☐ All 4 produced `DataSource`s with correct labels.
3. ☐ Test consumer VMs booted; `AgentConnected=True` for each.
4. ☐ Hardened variants ≥ 90% CIS L1 pass rate.
5. ☐ Existing Win Server 2022 BIOS/UEFI pipelines still functional (run a smoke test if needed):
   ```bash
   oc get pipeline -n windows-image-build
   # confirm windows-image-builder-uefi and any pre-existing BIOS pipelines are still listed
   ```
6. ☐ `oc apply -k manifests/<class>/<variant>/` deploys end-to-end.
7. ☐ Pattern-reuse test (Phase 6) passed.
8. ☐ READMEs in each pilot variant cover ISO source, baseline, runtime, gotchas.

- [ ] **Step 2: Note any failed criteria**

If any criterion failed, document the failure and remediation in the spec's pilot-results section. Do not declare Batch 1 done with unmet criteria.

- [ ] **Step 3: Commit retrospective notes**

```bash
git add docs/superpowers/specs/2026-04-26-image-pipeline-expansion-design.md
git commit -m "Record pilot retrospective: $(date +%Y-%m-%d)"
```

---

### Task 7.2: Handoff signal

**Files:** none.

- [ ] **Step 1: Create a Batch 2 placeholder**

Surface to the user that Batch 1 is complete and Batch 2 is the next implementation plan. Either via a tracking issue (`gh issue create`), a TO-DOs entry, or by drafting `docs/superpowers/plans/<future-date>-image-pipeline-batch-2.md` with a stub.

- [ ] **Step 2: Final commit**

```bash
git log --oneline -20
```
Confirm the Batch 1 commits form a coherent sequence and the spec's pilot results are recorded.

---

## Self-review

The plan was reviewed against the spec. Coverage of PRD requirements:

- §1.1 problem / §1.2 goals: addressed by the 4 pilot pipelines + templating proof.
- §1.3 non-goals: no registry, no scheduler, no triggers, no retrofit of existing pipelines — preserved throughout.
- §1.4 success criteria #3 (pattern reuse): tested in Phase 6.
- §1.4 success criteria #5 (CIS L1 thresholds): tested in Tasks 3.4 and 5.4.
- §2 architecture: Phase 1 builds the layout shown in §2.1.
- §3 OS matrix: only the pilot subset (rows 3 + 15) covered; remainder deferred to later batches.
- §4 per-variant componentry: each pilot variant has all four swappable pieces in place.
- §5 hardened-variant policy: SCAP for Linux (Task 3.2), SCT for Windows (Task 5.3); CIS L1 baseline; in-ConfigMap hardening; compliance label and audit ConfigMap.
- §6 pilot scope: matches Phases 2–6 exactly.
- §7 risks: R1 (vendor URL drift) accepted via README guidance; R2 (ssg drift) captured via on-image version recording (Task 3.2); R3 (SCT mirror) covered by Task 5.1 spike; R4 (existing-pipeline regression) covered by Task 7.1 step 1 §6.2.5; R6 (boot-trigger flakiness) reused without fix; R7 (SLES) deferred to Batch 3; R8 (privileged pods) inherited from existing.
- §7.2 open decisions: D1, D2, D4, D5, D7 assumed at top of plan; D3 deferred (not in Batch 1); D6 resolved by Task 5.1 spike.

Type-consistency check: shared Task names (`upload-source-artefact`, `create-blank-root-disk`, `wait-for-vm-shutdown`, `clone-to-catalog`, `cleanup-build-namespace`, `trigger-cd-boot-{uefi,bios,linux}`) are used consistently in Phases 1–5. Param names (`dvName`, `namespace`, `goldenImageName`, `defaultInstancetype`, `defaultPreference`, `complianceBaseline`, `accessMode`) consistent across all callers.

Placeholder scan: explicit URL placeholders (`REPLACE-ME-rhel-9-x86_64-boot.iso`, `REPLACE-ME-2025`, `SCT_URL`, `BASELINE_URL`) are intentional — they require operator input at run time and are flagged for non-commit. README "fill in after Task X" placeholders are intentional retrospective fields. No "TBD/TODO" left in pipeline-shape code.

---

## Execution handoff

Plan complete and committed. Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, with review between tasks and fast iteration. Best for a 30-task plan with cluster-side waits.
2. **Inline Execution** — execute tasks in this session via `executing-plans`, with batch checkpoints for review.

Operator action before either: resolve the assumed defaults in the **Prerequisites** block at the top of this plan if any of D1, D2, D4, D5, or D7 should differ. D6 is resolved by Task 5.1's spike during execution.
