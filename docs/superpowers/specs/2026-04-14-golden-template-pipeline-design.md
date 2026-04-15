# Golden Template Pipeline: VMware to ROKS via MTV

## Overview

This document describes the end-to-end workflow for importing VMware VM templates into ROKS on VPC (OCP 4.20+) as golden images using the Migration Toolkit for Virtualization (MTV), and promoting them into reusable, cloneable templates with InstanceType and Preference CRDs.

**Audience**: Platform engineers implementing golden image import and lifecycle on ROKS VPC.

**Assumptions**:
- MTV operator is deployed and the VMware provider is configured
- vSphere with vCenter is the source environment
- ROKS VPC cluster running OCP 4.20+
- OCP Virtualization operator installed

**Document structure**: Shared pipeline through MTV import, then explicit Linux and Windows tracks for post-import template promotion. Storage considerations (ODF vs IBM Cloud File) handled as a cross-cutting reference section.

---

## Manifest Files

All YAML examples in this document are available as standalone, apply-ready files:

| Section | Manifest | Description |
|---|---|---|
| Prerequisites | [`manifests/namespace.yaml`](../../../manifests/namespace.yaml) | `vm-golden-images` namespace |
| Prerequisites | [`manifests/resource-quota.yaml`](../../../manifests/resource-quota.yaml) | Storage quota |
| Landing Zone | [`manifests/rbac/clone-source-clusterrole.yaml`](../../../manifests/rbac/clone-source-clusterrole.yaml) | CDI cross-namespace clone ClusterRole |
| Landing Zone | [`manifests/rbac/clone-source-rolebinding.yaml`](../../../manifests/rbac/clone-source-rolebinding.yaml) | Example consumer RoleBinding |
| MTV Import | [`manifests/mtv/migration-example.yaml`](../../../manifests/mtv/migration-example.yaml) | Example Migration CR |
| Storage | [`manifests/storage/clone-test-dv.yaml`](../../../manifests/storage/clone-test-dv.yaml) | Clone test DataVolume |
| Linux Track | [`manifests/linux/instancetype.yaml`](../../../manifests/linux/instancetype.yaml) | `linux-medium` InstanceType |
| Linux Track | [`manifests/linux/preference.yaml`](../../../manifests/linux/preference.yaml) | `rhel9-golden` Preference |
| Linux Track | [`manifests/linux/consumer-vm.yaml`](../../../manifests/linux/consumer-vm.yaml) | Full consumer VM example |
| Windows Track | [`manifests/windows/instancetype.yaml`](../../../manifests/windows/instancetype.yaml) | `windows-medium` InstanceType |
| Windows Track | [`manifests/windows/preference.yaml`](../../../manifests/windows/preference.yaml) | `win2022-golden` Preference |
| Windows Track | [`manifests/windows/sysprep-configmap.yaml`](../../../manifests/windows/sysprep-configmap.yaml) | Sysprep ConfigMap with `unattend.xml` |
| Windows Track | [`manifests/windows/virtio-win-cdrom-patch.yaml`](../../../manifests/windows/virtio-win-cdrom-patch.yaml) | VirtIO driver remediation patch |
| Windows Track | [`manifests/windows/consumer-vm.yaml`](../../../manifests/windows/consumer-vm.yaml) | Full consumer VM example |
| Lifecycle | [`manifests/lifecycle/cleanup-cronjob.yaml`](../../../manifests/lifecycle/cleanup-cronjob.yaml) | Deprecated image cleanup CronJob |

**Architecture diagram:** [`diagrams/golden-template-pipeline.drawio`](../../../diagrams/golden-template-pipeline.drawio)

---

## Image Strategy: Choosing Your Approach

Before following the detailed procedures in this document, decide which image strategy fits your migration. There are three paths, and they are not mutually exclusive.

### Path 1: Migrate and Convert Existing VMs (MTV)

Take existing VMware VMs and convert them via MTV. This is the primary workflow documented in this runbook.

**Two migration modes:**

- **Cold migration** — VM powered off, VMDK transferred via VDDK, converted by `virtv2v` (VMDK to raw). Use for golden templates and workloads where downtime is acceptable.
- **Warm migration** — VM stays running, Changed Block Tracking (CBC/CBT) syncs delta changes, then a short cutover window for final sync. Use for production workloads where downtime must be minimised.

**Pros:**
- Preserves existing OS configuration, applications, and data
- Fastest path to the same workload running on OCP Virtualization
- No need to re-apply application configuration

**Cons:**
- Inherits all VMware cruft — VMware Tools remnants, old drivers, potentially outdated OS configurations
- VirtIO driver injection can fail on edge cases, especially older Windows Server versions
- You are migrating technical debt, not just workloads

**Best for:** Workloads that cannot be rebuilt — legacy applications, stateful services with complex configuration, vendor appliances.

### Path 2: Build New Golden Images Natively

Skip VMware entirely. Build images directly for OCP Virtualization from scratch.

**Options:**

- **`virtctl image-upload`** — Upload a qcow2 or raw image directly into a PVC. Red Hat, Ubuntu, and most distributions publish KVM-ready cloud images with VirtIO drivers and cloud-init pre-installed.
- **CDI HTTP source** — Create a DataVolume with `source: http` pointing to a cloud image URL. CDI downloads and provisions the PVC automatically. This is the most GitOps-friendly approach:
  ```yaml
  apiVersion: cdi.kubevirt.io/v1beta1
  kind: DataVolume
  metadata:
    name: rhel9-cloud-20260415
    namespace: vm-golden-images
  spec:
    source:
      http:
        url: "https://download.example.com/rhel-9.4-x86_64-kvm.qcow2"
    storage:
      storageClassName: ocs-storagecluster-ceph-rbd
      resources:
        requests:
          storage: 20Gi
  ```
- **Tekton pipeline-built images** — Boot from an ISO inside a VM, install the OS, sysprep/seal, capture the root disk as a golden PVC. This is the approach used in the Windows image build pipeline (`windows-image-pipeline.md`). More work up front but produces a clean, purpose-built image with no VMware baggage.
- **Packer with QEMU builder** — Build locally or in CI, output a qcow2, upload via `virtctl image-upload` or CDI HTTP source.

**Pros:**
- Clean images with no VMware artifacts
- VirtIO native from the start — no driver injection risk
- Reproducible via pipeline or GitOps
- Lower long-term maintenance burden

**Cons:**
- More upfront effort to build and validate
- Existing application configuration must be re-applied (Ansible, cloud-init, scripts)

**Best for:** Greenfield workloads, standardised fleet images, anything where rebuilding clean is cheaper than migrating and fixing.

### Path 3: Hybrid — Migrate Then Replace

Migrate existing VMs via MTV to get workloads running quickly, then incrementally replace them with pipeline-built golden images over time.

**Pattern:**

1. **MTV cold-migrate** existing VMware templates — workloads are running on OCP Virtualization with the same configuration, same warts
2. **In parallel**, build clean golden images via Tekton pipeline (Linux cloud images with cloud-init, Windows ISO pipeline with sysprep)
3. As each clean golden image is validated, **redeploy workloads** from the new image, migrating application configuration via Ansible, cloud-init, or sysprep
4. **Retire the migrated VMs** once the clean replacements are validated

**Pros:**
- Unblocks migration immediately — operations team is not waiting for golden images to be built
- Provides a clean target state to converge toward
- Reduces risk — migrated VMs are the fallback if clean images have issues

**Cons:**
- Two image lineages running temporarily
- Requires discipline to actually retire the migrated VMs
- More operational overhead during the transition period

**Best for:** Most real-world migrations where you need to move fast but also want a clean long-term state.

### Decision Framework

| Factor | Migrate (MTV) | Build New | Hybrid |
|---|---|---|---|
| Time to first VM running | Hours | Days to weeks | Hours (migrated), weeks (clean) |
| Image cleanliness | Inherited from VMware | Clean, native KVM | Converges to clean |
| VirtIO driver risk | Injection can fail | Native, no risk | Both during transition |
| Application config effort | Zero (carried over) | Must re-apply | Phased re-application |
| Long-term maintenance | Higher (legacy cruft) | Lower | Lower (once converged) |
| Best for | Lift-and-shift, legacy | Greenfield, fleet | Most real migrations |

### Recommendation

For environments with an existing VMware estate, the **hybrid approach** is typically the right choice. It provides immediate migration capability (Sections 1-9 of this document) while allowing a parallel track to build clean native images. The golden template pipeline documented below handles the MTV migration path. The Tekton pipeline (`windows-image-pipeline.md`) handles the native build path for Windows. For Linux, CDI HTTP source with published cloud images is the simplest native path.

---

## 1. Prerequisites & Environment

Confirm the following before starting:

### Cluster

- ROKS VPC cluster running OCP 4.20+
- OCP Virtualization operator installed and healthy
- Worker nodes sized to accommodate golden image storage (each golden image = 1 PVC per disk at full provisioned size)

### Storage Classes

| Storage Class | Provider | Access Mode | Use Case |
|---|---|---|---|
| `ocs-storagecluster-ceph-rbd` | ODF (Ceph RBD) | RWO | Golden image PVCs, VM boot disks |
| `ocs-storagecluster-cephfs` | ODF (CephFS) | RWX | Not recommended for VM boot disks |
| `ibmc-file-gold` / `ibmc-file-gold-gid` | IBM Cloud File | RWX | Secondary data volumes, fallback golden images |

See [Section 4: Storage Considerations](#4-storage-considerations-cross-cutting-reference) for detailed guidance.

### VMware Source Access

- vCenter credentials configured in the MTV VMware provider
- Network connectivity from ROKS workers to vCenter and ESXi datastore network (VDDK-based transfers)

### Tooling

- `oc` CLI authenticated to the ROKS cluster
- `virtctl` CLI installed (from the OCP Virtualization operator or downloaded separately)
- MTV console access or CLI
- Optional: `guestfish` / `virt-customize` for offline image manipulation

### Namespace Convention

A dedicated namespace for golden images, separate from workload VMs:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: vm-golden-images
  labels:
    purpose: golden-images
```

RBAC:
- Platform engineers: full access to `vm-golden-images`
- Consumer namespaces: `datavolumes/source` permission for cross-namespace cloning (see [Section 5: Landing Zone](#5-landing-zone-configuration))

---

## 2. Source Preparation (VMware Side)

### Common Steps

1. Identify the source VM in vCenter. Confirm it is powered off or will be powered off for cold migration.
2. Remove VMware-specific agents that will not function on KVM — Aria agents, vROps agents, custom monitoring agents. VMware Tools can remain; MTV handles removal/replacement.
3. Document the VM hardware profile:
   - vCPU count and topology
   - Memory (MB)
   - Disk count, size (provisioned and used), and controller type
   - NIC count and port group assignments

This maps directly to InstanceType selection later.

### Linux Preparation

1. Remove hardcoded MAC addresses and interface names:
   - RHEL/CentOS: check `/etc/sysconfig/network-scripts/ifcfg-*` for `HWADDR` and `DEVICE` lines
   - Ubuntu/netplan: check `/etc/netplan/*.yaml` for `macaddress` entries

2. Ensure `cloud-init` is installed and enabled:
   ```bash
   systemctl enable cloud-init cloud-init-local cloud-config cloud-final
   ```

3. Clear machine identity:
   ```bash
   truncate -s 0 /etc/machine-id
   rm -f /var/lib/dbus/machine-id
   ```

4. Remove SSH host keys (will regenerate per clone):
   ```bash
   rm -f /etc/ssh/ssh_host_*
   ```

5. Optional — install `qemu-guest-agent`:
   ```bash
   # RHEL/CentOS
   dnf install -y qemu-guest-agent
   systemctl enable qemu-guest-agent

   # Ubuntu
   apt-get install -y qemu-guest-agent
   systemctl enable qemu-guest-agent
   ```
   Can also be injected post-import via `virt-customize` if preferred.

6. Power off the VM.

### Windows Preparation

1. **Install VirtIO drivers** (recommended — pre-migration):
   - Download the `virtio-win` ISO from Red Hat
   - Mount the ISO in the VM
   - Install via silent MSI:
     ```cmd
     D:\virtio-win-gt-x64.msi /quiet /norestart
     ```
   - Verify in Device Manager: VirtIO SCSI controller, VirtIO network adapter, VirtIO balloon, VirtIO serial should all appear as recognized devices.

   If not pre-installed, MTV's `virtv2v` will attempt driver injection at import time. This is less reliable for newer Windows Server versions and not recommended as the primary approach.

2. **Install `qemu-guest-agent`** from the same ISO:
   ```cmd
   D:\guest-agent\qemu-ga-x86_64.msi /quiet
   ```
   Confirm the `QEMU Guest Agent` service is running in Windows Services.

3. **Run sysprep** as the final step:
   ```cmd
   C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown
   ```
   This strips SIDs, machine-specific state, and prepares for OOBE on first boot. The `unattend.xml` that pairs with this image is defined in the [Windows Track (Section 7)](#7-windows-track--template-promotion).

4. **Do not snapshot after sysprep** in vSphere. The sealed state is fragile. Migrate immediately or leave the VM powered off.

---

## 3. MTV Migration Plan for Golden Templates

### Migration Type

**Cold migration only.** Golden templates are sealed/stopped VMs. There is no need for warm migration, cutover windows, or CDC/snapshot overhead. Cold migration is simpler and more reliable.

### Migration Plan Configuration

| Setting | Value |
|---|---|
| Source provider | Existing vCenter provider |
| Target provider | Host cluster (ROKS) |
| Target namespace | `vm-golden-images` |
| Migration type | Cold |

**Network mapping**: Map vSphere port groups to the appropriate `NetworkAttachmentDefinition` (NAD), or use the pod network if the golden image does not need L2 connectivity at import time. The image only needs to boot for validation, not serve production traffic.

**Storage mapping**: Map VMware datastores to the target StorageClass:
- **ODF `ocs-storagecluster-ceph-rbd`** (recommended): Ceph RBD clone is a fast metadata operation (copy-on-write). Supports CSI snapshots.
- **IBM Cloud File `ibmc-file-gold`**: Full data copy on clone. Use when ODF is unavailable or clone frequency is low.

See [Section 4: Storage Considerations](#4-storage-considerations-cross-cutting-reference) for detailed comparison.

**Disk sizing**: MTV converts VMDK to raw format at import time. PVC sizing should account for the full provisioned disk size, not just the thin-provisioned used space from VMware.

### Example Migration CR

```yaml
apiVersion: forklift.konveyor.io/v1beta1
kind: Migration
metadata:
  name: golden-rhel9-import
  namespace: openshift-mtv
spec:
  plan:
    name: golden-rhel9-plan
    namespace: openshift-mtv
```

The `Plan` CR (referenced above) defines the VM selection, network mapping, and storage mapping. Create via the MTV console or YAML.

### Monitoring

```bash
# Watch migration progress
oc get migrations -n openshift-mtv -w

# Check DataVolume status (created per disk)
oc get dv -n vm-golden-images

# Check conversion pod logs if troubleshooting
oc logs -n vm-golden-images -l app=containerized-data-importer
```

### Post-Import State

On completion:
- A `VirtualMachine` CR exists in `vm-golden-images` with imported disks attached as PVCs
- The VM is **not yet a template** — it is a regular `VirtualMachine` object
- Do not start it yet

### Post-Import Cleanup

```bash
# Verify DataVolumes completed
oc get dv -n vm-golden-images
# All should show Phase: Succeeded

# Verify PVC sizes match expectations
oc get pvc -n vm-golden-images

# Optional: remove MTV migration plan artifacts
oc delete migration golden-rhel9-import -n openshift-mtv
```

---

## 4. Storage Considerations (Cross-Cutting Reference)

Both OS tracks reference this section for storage class selection and its impact on clone performance, snapshot capability, and access patterns.

### ODF — Ceph RBD (`ocs-storagecluster-ceph-rbd`)

- **Access mode**: RWO (ReadWriteOnce) — one VM per PVC
- **Clone mechanism**: CSI clone via Ceph RBD copy-on-write. Near-instant regardless of disk size. This is the primary reason ODF is recommended for golden images.
- **Snapshots**: `VirtualMachineSnapshot` delegates to Ceph RBD snapshot. Fast, space-efficient (COW). Requires a `VolumeSnapshotClass` for `openshift-storage.rbd.csi.ceph.com`.
- **Resize**: Online expansion supported.
- **Best for**: Golden image source PVCs where many clones are expected. VMs that need pre-change snapshots.

### ODF — CephFS (`ocs-storagecluster-cephfs`)

- **Access mode**: RWX (ReadWriteMany)
- **Not recommended for VM boot disks.** Block device performance on CephFS is poor. Listed for completeness only — do not use for golden images.

### IBM Cloud File Storage (`ibmc-file-gold`, `ibmc-file-gold-gid`)

- **Access mode**: RWX (ReadWriteMany)
- **Clone mechanism**: No CSI clone. Cloning a golden image triggers a full PVC-to-PVC data copy via CDI. For a 100GB disk, expect minutes, not seconds.
- **Snapshots**: Limited. Depends on the IBM Cloud File CSI driver version. Do not rely on `VirtualMachineSnapshot` with this backend for anything beyond testing.
- **Resize**: Supported.
- **Best for**: Shared data volumes, ancillary storage. Functional as a golden image source if ODF is unavailable, but with slower clone performance.

### Recommendation Matrix

| Concern | ODF Ceph RBD | IBM Cloud File |
|---|---|---|
| Clone speed | Instant (COW) | Minutes (full copy) |
| Snapshot support | Full | Limited |
| Access mode | RWO | RWX |
| Golden image source | Recommended | Functional, slower |
| VM boot disk | Yes | Yes (lower IOPS) |

### Practical Guidance

- If your cluster has ODF, use Ceph RBD for all golden image PVCs and VM boot disks.
- Use IBM Cloud File for secondary data volumes where RWX is needed (shared config, log aggregation).
- If ODF is not available, IBM Cloud File works but engineers should expect longer provisioning times when cloning.
- Clone performance difference example with a DataVolume using `source: pvc`:

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: rhel9-clone-test
  namespace: test-vms
spec:
  source:
    pvc:
      namespace: vm-golden-images
      name: rhel9-base-20260414
  storage:
    storageClassName: ocs-storagecluster-ceph-rbd  # or ibmc-file-gold
    resources:
      requests:
        storage: 100Gi
```

On ODF Ceph RBD, this completes in seconds. On IBM Cloud File, expect ~5-10 minutes for 100Gi.

---

## 5. Landing Zone Configuration

### Namespace Setup

The `vm-golden-images` namespace (created in prerequisites) is the landing zone for all golden image PVCs.

### PVC Naming Convention

Format: `<os>-<version>-<purpose>-<date>`

Examples:
- `rhel9-base-20260414`
- `ubuntu2404-base-20260414`
- `win2022-std-sysprep-20260414`
- `win2022-dc-sysprep-20260414`

The date suffix enables versioning. New golden image versions get new PVCs. Old PVCs are retained or pruned per lifecycle policy.

### PVC Annotations

Annotate golden image PVCs with source metadata for operational traceability:

```yaml
metadata:
  annotations:
    golden-image/source-vm: "vcenter.example.com/vm/rhel9-template"
    golden-image/migration-date: "2026-04-14"
    golden-image/os-version: "RHEL 9.4"
    golden-image/virtio-driver-version: ""  # Windows only
    golden-image/sealed-by: "cloud-init"    # or "sysprep"
  labels:
    image-status: current  # current | previous | deprecated
    os-family: linux        # linux | windows
```

### Cross-Namespace Cloning RBAC

CDI requires explicit permission for cross-namespace cloning. Without this, VMs in consumer namespaces cannot clone from golden image PVCs.

**ClusterRole** — grants DataVolume source access:

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

**RoleBinding** — applied in the `vm-golden-images` namespace, granting a consumer namespace's default ServiceAccount (or a dedicated SA) the ability to clone:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: allow-clone-from-golden-images
  namespace: vm-golden-images
subjects:
  - kind: ServiceAccount
    name: default
    namespace: team-a-vms  # consumer namespace
roleRef:
  kind: ClusterRole
  name: golden-image-clone-source
  apiGroup: rbac.authorization.k8s.io
```

Repeat the RoleBinding for each consumer namespace, or use a Group subject for broader access.

### Resource Quotas

Set PVC storage quotas on `vm-golden-images` appropriate to the number of golden images maintained:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: golden-image-storage
  namespace: vm-golden-images
spec:
  hard:
    requests.storage: 2Ti  # adjust based on expected image count and sizes
```

---

## 6. Linux Track — Template Promotion

### Validation Boot

Start the imported VM to verify it boots on KVM:

```bash
virtctl start <vm-name> -n vm-golden-images
```

Verify:

```bash
# Console access
virtctl console <vm-name> -n vm-golden-images

# Or VNC
virtctl vnc <vm-name> -n vm-golden-images
```

Confirm:
- OS boots successfully
- VirtIO devices are recognized: `lspci | grep -i virtio`
- Network is up
- `qemu-guest-agent` is running and reporting IP:
  ```bash
  oc get vmi <vm-name> -n vm-golden-images -o jsonpath='{.status.interfaces}' | jq .
  ```

If `qemu-guest-agent` was not pre-installed, install it now via console:

```bash
# RHEL/CentOS
dnf install -y qemu-guest-agent && systemctl enable --now qemu-guest-agent

# Ubuntu
apt-get install -y qemu-guest-agent && systemctl enable --now qemu-guest-agent
```

### Re-Seal After Validation

The validation boot generated new machine-id, SSH host keys, and cloud-init state. Clear them before the image becomes a clone source:

```bash
# SSH into the VM or use virtctl console
virtctl ssh <user>@<vm-name> -n vm-golden-images

# Inside the VM:
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
rm -f /etc/ssh/ssh_host_*
cloud-init clean --logs
```

Stop the VM:

```bash
virtctl stop <vm-name> -n vm-golden-images
```

### InstanceType and Preference CRDs

**InstanceType** — defines compute sizing. Use a cluster-provided type or create a custom one:

```bash
# List available cluster instance types
oc get virtualmachineclusterinstancetype
```

Custom InstanceType example:

```yaml
apiVersion: instancetype.kubevirt.io/v1beta1
kind: VirtualMachineInstancetype
metadata:
  name: linux-medium
  namespace: vm-golden-images
spec:
  cpu:
    guest: 4
  memory:
    guest: 8Gi
```

**Preference** — sets OS-specific defaults (machine type, firmware, CPU topology). Red Hat ships preferences for common OSes:

```bash
# Inspect a shipped preference
oc get virtualmachineclusterpreference rhel.9 -o yaml
```

Custom Preference example:

```yaml
apiVersion: instancetype.kubevirt.io/v1beta1
kind: VirtualMachinePreference
metadata:
  name: rhel9-golden
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

### Cloud-Init Integration

The golden image has `cloud-init` installed and enabled from source preparation. Consumers provide identity and configuration at clone time via a `cloudInitNoCloud` volume.

Example consumer cloud-init:

```yaml
volumes:
  - name: cloudinitdisk
    cloudInitNoCloud:
      userData: |
        #cloud-config
        hostname: web-server-01
        ssh_authorized_keys:
          - ssh-rsa AAAAB3... user@workstation
        runcmd:
          - [systemctl, enable, --now, httpd]
```

### Clone Workflow — Full Consumer VM Example

This is the complete YAML a consumer uses to provision a VM from the Linux golden image:

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: web-server-01
  namespace: team-a-vms
spec:
  instancetype:
    kind: VirtualMachineInstancetype
    name: linux-medium
    inferFromVolume: false
  preference:
    kind: VirtualMachinePreference
    name: rhel9-golden
    inferFromVolume: false
  runStrategy: Always
  dataVolumeTemplates:
    - metadata:
        name: web-server-01-rootdisk
      spec:
        source:
          pvc:
            namespace: vm-golden-images
            name: rhel9-base-20260414
        storage:
          storageClassName: ocs-storagecluster-ceph-rbd
          resources:
            requests:
              storage: 100Gi
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
            name: web-server-01-rootdisk
        - name: cloudinitdisk
          cloudInitNoCloud:
            userData: |
              #cloud-config
              hostname: web-server-01
              ssh_authorized_keys:
                - ssh-rsa AAAAB3... user@workstation
```

CDI clones the golden PVC (instant on ODF Ceph RBD, full copy on IBM Cloud File). The VM boots with cloud-init, receives a unique identity, and is ready.

---

## 7. Windows Track — Template Promotion

### Validation Boot

Start the imported VM:

```bash
virtctl start <vm-name> -n vm-golden-images
```

Use VNC for graphical console (Windows VMs typically require this for OOBE/sysprep validation):

```bash
virtctl vnc <vm-name> -n vm-golden-images
```

Verify:
- Windows boots (may enter OOBE if sysprep was run before migration)
- **Device Manager**: confirm VirtIO SCSI controller, VirtIO network adapter, VirtIO balloon, VirtIO serial are all recognized with no unknown devices
- **Services**: confirm `QEMU Guest Agent` service (`qemu-ga`) is running
- **IP reporting**: `oc get vmi <vm-name> -n vm-golden-images -o jsonpath='{.status.interfaces}' | jq .`

### VirtIO Driver Remediation

If drivers were not pre-installed or `virtv2v` injection failed (unknown devices in Device Manager):

1. Patch the VM spec to attach the `virtio-win` ISO as a CD-ROM:

```yaml
spec:
  template:
    spec:
      volumes:
        - name: virtio-win
          containerDisk:
            image: registry.redhat.io/container-native-virtualization/virtio-win
      domain:
        devices:
          disks:
            - name: virtio-win
              cdrom:
                bus: sata
```

2. Boot the VM and install from the mounted ISO:

```cmd
:: Install VirtIO drivers
D:\virtio-win-gt-x64.msi /quiet /norestart

:: Install QEMU Guest Agent
D:\guest-agent\qemu-ga-x86_64.msi /quiet
```

3. Restart the VM, verify all devices are recognized in Device Manager.

4. Remove the `virtio-win` volume from the VM spec.

### Sysprep and unattend.xml

**If sysprep was run before migration** (recommended): Windows will boot into OOBE. Complete OOBE manually for validation purposes, then re-sysprep before sealing:

```cmd
C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown
```

**If sysprep was not run before migration**: Run sysprep now from within the running VM using the same command.

**Reference unattend.xml**:

The `unattend.xml` is delivered to clone VMs via a `sysprep` volume (ConfigMap). This is the Windows equivalent of cloud-init.

```xml
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">

  <settings pass="specialize">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <ComputerName>*</ComputerName>
    </component>
    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Path>powershell.exe -ExecutionPolicy Bypass -File C:\Scripts\post-clone-setup.ps1</Path>
          <Description>Post-clone configuration</Description>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>

  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value><!-- Set via sealed secret or runtime injection --></Value>
          <PlainText>false</PlainText>
        </AdministratorPassword>
      </UserAccounts>
    </component>
  </settings>

</unattend>
```

**ConfigMap for the unattend.xml**:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: win2022-sysprep
  namespace: team-a-vms
data:
  unattend.xml: |
    <?xml version="1.0" encoding="utf-8"?>
    <unattend xmlns="urn:schemas-microsoft-com:unattend">
      <settings pass="specialize">
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
                   xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <InputLocale>en-US</InputLocale>
          <SystemLocale>en-US</SystemLocale>
          <UILanguage>en-US</UILanguage>
          <UserLocale>en-US</UserLocale>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
                   xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <ComputerName>*</ComputerName>
        </component>
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
                   xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <RunSynchronous>
            <RunSynchronousCommand wcm:action="add">
              <Order>1</Order>
              <Path>powershell.exe -ExecutionPolicy Bypass -File C:\Scripts\post-clone-setup.ps1</Path>
              <Description>Post-clone configuration</Description>
            </RunSynchronousCommand>
          </RunSynchronous>
        </component>
      </settings>
      <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
                   xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <OOBE>
            <HideEULAPage>true</HideEULAPage>
            <HideLocalAccountScreen>true</HideLocalAccountScreen>
            <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
            <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
            <ProtectYourPC>3</ProtectYourPC>
          </OOBE>
          <UserAccounts>
            <AdministratorPassword>
              <Value><!-- Set via sealed secret or runtime injection --></Value>
              <PlainText>false</PlainText>
            </AdministratorPassword>
          </UserAccounts>
        </component>
      </settings>
    </unattend>
```

### Licensing Considerations

**KMS (Volume Licensing)**:
- The golden image should point to the organization's KMS server
- Each clone activates independently against KMS
- Verify after cloning:
  ```cmd
  slmgr /skms kms.example.com
  slmgr /ato
  slmgr /dli
  ```

**AVMA (Automatic Virtual Machine Activation)**:
- Requires a qualifying Hyper-V host OS. **Not supported on ROKS/KVM.** Do not use AVMA keys in golden images destined for OCP Virtualization.

**Per-VM Licensing (SPLA)**:
- Each clone requires its own license. This is an organizational/procurement concern, not a technical one, but engineers should be aware that cloning golden images creates licensing obligations.

### Windows Preference CRDs

Red Hat ships Windows-specific preferences. Inspect them:

```bash
oc get virtualmachineclusterpreference | grep windows
oc get virtualmachineclusterpreference windows.2k22.virtio -o yaml
```

Key settings these preferences control:
- **UEFI with SecureBoot**
- **Hyper-V enlightenments**: vapic, spinlocks, relaxed, vpindex, runtime, synic, stimer, frequencies, reset, tlbflush, ipi, reenlightenment — these significantly improve Windows performance on KVM
- **TPM** (if required by policy or Windows 11)
- **Input devices**: tablet device for absolute pointer in VNC (prevents mouse offset issues)

Custom Windows Preference example:

```yaml
apiVersion: instancetype.kubevirt.io/v1beta1
kind: VirtualMachinePreference
metadata:
  name: win2022-golden
  namespace: vm-golden-images
spec:
  cpu:
    preferredCPUTopology: preferSockets
  devices:
    preferredDiskBus: virtio
    preferredInterfaceModel: virtio
    preferredInputBus: usb
    preferredInputType: tablet
    preferredTPM: {}
  features:
    preferredHyperv:
      vapic: {}
      spinlocks:
        spinlocks: 8191
      relaxed: {}
      vpindex: {}
      runtime: {}
      synic: {}
      stimer:
        direct: {}
      frequencies: {}
      reset: {}
      tlbflush: {}
      ipi: {}
      reenlightenment: {}
  firmware:
    preferredUseEfi: true
    preferredUseSecureBoot: true
  machine:
    preferredMachineType: q35
```

### Clone Workflow — Full Consumer VM Example

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: app-server-01
  namespace: team-a-vms
spec:
  instancetype:
    kind: VirtualMachineInstancetype
    name: windows-medium
    inferFromVolume: false
  preference:
    kind: VirtualMachinePreference
    name: win2022-golden
    inferFromVolume: false
  runStrategy: Always
  dataVolumeTemplates:
    - metadata:
        name: app-server-01-rootdisk
      spec:
        source:
          pvc:
            namespace: vm-golden-images
            name: win2022-std-sysprep-20260414
        storage:
          storageClassName: ocs-storagecluster-ceph-rbd
          resources:
            requests:
              storage: 100Gi
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
            name: app-server-01-rootdisk
        - name: sysprep
          sysprep:
            configMap:
              name: win2022-sysprep
```

First boot sequence: Windows detects sysprep state, runs the specialize pass with `unattend.xml`, completes OOBE (hidden), executes `RunSynchronous` commands, and boots to the login screen with a unique SID and hostname.

---

## 8. Golden Image Versioning & Lifecycle

Golden images are not static. OS patches, driver updates, security hardening, and application pre-installs require versioning, rotation, and retirement. There is no native "content library" equivalent on OCP Virtualization.

Two approaches are presented. Choose based on operational maturity and tooling.

### Option A: GitOps-Driven Lifecycle

Golden image definitions are stored in a git repository. ArgoCD or Flux watches the repo and syncs resources to the `vm-golden-images` namespace. This is the closest equivalent to VMware's Content Library — version-controlled, auditable, and multi-cluster capable.

**Example repository structure:**

```
golden-images/
  base/
    namespace.yaml                  # vm-golden-images namespace
    rbac/
      clone-source-clusterrole.yaml
      clone-source-rolebinding.yaml # one per consumer namespace
    resource-quota.yaml
  images/
    linux/
      rhel9/
        datavolume.yaml             # source: http or source: pvc (MTV-imported)
        instancetype.yaml
        preference.yaml
        kustomization.yaml
      ubuntu2404/
        datavolume.yaml
        instancetype.yaml
        preference.yaml
        kustomization.yaml
    windows/
      win2022-std/
        datavolume.yaml
        instancetype.yaml
        preference.yaml
        sysprep-configmap.yaml      # unattend.xml
        kustomization.yaml
  overlays/
    cluster-us-east/                # per-cluster overrides (storage class, replicas)
      kustomization.yaml
    cluster-eu-west/
      kustomization.yaml
  argocd/
    applicationset.yaml             # generates one ArgoCD Application per cluster
```

**Workflow:**

- **New version** = new commit: update the DataVolume source (HTTP URL to a new qcow2, or re-trigger MTV import), bump the PVC name date suffix (e.g., `rhel9-base-20260501`). The commit triggers ArgoCD sync.
- **Retirement**: remove the image directory from the repo. ArgoCD prunes the PVC (if prune is enabled) or engineers delete manually after confirming no VMs reference it.
- **Rollback**: revert the git commit to restore the previous image version. ArgoCD re-syncs the old DataVolume definition.
- **Multi-cluster**: use an ArgoCD `ApplicationSet` with cluster generators to sync the same golden images to multiple ROKS clusters. Per-cluster overlays handle storage class or sizing differences.
- **PR-based review**: image updates go through a pull request. Reviewers can see exactly what changed (new image URL, PVC name bump, preference tweak) before it reaches any cluster.

**ArgoCD ApplicationSet example:**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: golden-images
  namespace: openshift-gitops
spec:
  generators:
    - clusters:
        selector:
          matchLabels:
            golden-images: "true"
  template:
    metadata:
      name: "golden-images-{{name}}"
    spec:
      project: default
      source:
        repoURL: https://github.com/your-org/golden-images.git
        targetRevision: main
        path: "overlays/{{metadata.labels.cluster-overlay}}"
      destination:
        server: "{{server}}"
        namespace: vm-golden-images
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

**Advantages**:
- Audit trail via git history — every image change is a commit with author, timestamp, and review
- PR-based review for image changes — no unreviewed changes reach clusters
- Multi-cluster consistency by syncing the same repo to multiple ROKS clusters
- Rollback by reverting a commit
- Kustomize overlays handle per-cluster differences (storage class, sizing) without duplicating definitions

**Tradeoffs**:
- Requires ArgoCD/Flux infrastructure
- Team needs GitOps and Kustomize familiarity
- CDI import/clone triggered by sync needs monitoring — failed DataVolume imports need alerting
- Initial repo setup and ApplicationSet configuration has a learning curve

### Option B: Manual/CLI-Driven Lifecycle

- Platform engineers manage golden images directly via `oc` and `virtctl`
- **New version**: run a new MTV cold migration or `virtctl image-upload` for a locally-built qcow2. Land as a new PVC with updated date suffix.
- **Version tracking** via PVC labels:
  ```bash
  # Promote new image to current
  oc label pvc rhel9-base-20260501 -n vm-golden-images image-status=current --overwrite

  # Demote old image
  oc label pvc rhel9-base-20260414 -n vm-golden-images image-status=previous --overwrite

  # Mark for retirement
  oc label pvc rhel9-base-20260301 -n vm-golden-images image-status=deprecated --overwrite
  ```
- **Retirement**: label deprecated, wait for consumers to migrate, delete PVC

**Advantages**:
- No additional tooling required
- Lower barrier to entry
- Works well for small-scale environments

**Tradeoffs**:
- No audit trail beyond `oc` command history
- Multi-cluster consistency requires repeating steps per cluster
- Human error risk on labelling and cleanup

### Common to Both Approaches

- PVC naming convention with date suffix is the versioning mechanism
- Consumer VMs should reference golden images by **explicit PVC name**, not "latest". There is no mutable tag concept. This is deliberate — clone reproducibility requires knowing exactly which image version was used.
- Optional cleanup automation — a CronJob that checks for deprecated PVCs with no referencing VMs:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: golden-image-cleanup-check
  namespace: vm-golden-images
spec:
  schedule: "0 6 * * 1"  # Weekly Monday 6am
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: golden-image-manager
          containers:
            - name: cleanup-check
              image: bitnami/kubectl:latest
              command:
                - /bin/bash
                - -c
                - |
                  echo "=== Deprecated golden images ==="
                  oc get pvc -n vm-golden-images -l image-status=deprecated -o name
                  echo ""
                  echo "=== Check for referencing VMs before deleting ==="
                  # Engineers review output and delete manually
          restartPolicy: OnFailure
```

---

## 9. Validation & Smoke Testing

### Per-Image Validation

Run each time a new golden image version is created:

```bash
# DataVolume status — must be Succeeded
oc get dv -n vm-golden-images

# PVC bound and correctly sized
oc get pvc -n vm-golden-images

# Labels and annotations set
oc get pvc <pvc-name> -n vm-golden-images -o yaml | grep -A 20 "annotations\|labels"
```

### Clone Test

Create a test VM in a separate namespace that clones from the golden image.

**Linux**:
```bash
# After test VM boots:
# Confirm unique machine-id
cat /etc/machine-id

# Confirm SSH host keys regenerated
ls -la /etc/ssh/ssh_host_*

# Confirm cloud-init ran
cloud-init status

# Confirm hostname from cloud-init
hostname
```

**Windows**:
```cmd
:: Confirm unique SID
whoami /user

:: Confirm hostname from unattend.xml
hostname

:: Confirm RunSynchronous commands executed
:: (check for expected output of post-clone-setup.ps1)
```

**Both**:
```bash
# Confirm guest agent reporting IP
oc get vmi <test-vm> -n <test-ns> -o jsonpath='{.status.interfaces}' | jq .

# Confirm VirtIO devices
# Linux: lspci | grep -i virtio
# Windows: check Device Manager via VNC
```

**Cleanup**:
```bash
# Delete test VM — confirm clone PVC is garbage collected via ownerReference
oc delete vm <test-vm> -n <test-ns>
oc get pvc -n <test-ns>  # clone PVC should be gone
```

### Storage-Specific Validation

**ODF Ceph RBD**:
- Check DataVolume creation-to-completion time. Should be seconds, not minutes.
- If it took minutes, CDI fell back to host-assisted copy — CSI clone is not working correctly. Investigate the CSI driver and `VolumeSnapshotClass` configuration.

```bash
# Check DV timestamps
oc get dv <dv-name> -n <ns> -o jsonpath='{.status.conditions}' | jq .
```

**IBM Cloud File**:
- Full copy is expected. Confirm completion and verify PVC is usable.
- Note expected duration for the disk size (approximately 5-10 minutes per 100Gi).

### Cross-Namespace RBAC Validation

```bash
# From an authorized consumer namespace — should succeed
oc create -f test-clone-dv.yaml -n team-a-vms

# From an unauthorized namespace — should be denied
oc create -f test-clone-dv.yaml -n unauthorized-ns
```

### Ongoing Validation Checklist

Use this as a run sheet when rotating golden images:

| Check | Command / Method | Expected |
|---|---|---|
| DV status | `oc get dv -n vm-golden-images` | Succeeded |
| PVC bound | `oc get pvc -n vm-golden-images` | Bound, correct size |
| Clone test (Linux) | Deploy test VM, check cloud-init | Unique machine-id, hostname, SSH keys |
| Clone test (Windows) | Deploy test VM, check sysprep | Unique SID, correct hostname |
| Guest agent | `oc get vmi -o jsonpath='{.status.interfaces}'` | IP reported |
| Cross-NS clone (authorized) | DataVolume from consumer NS | Succeeds |
| Cross-NS clone (unauthorized) | DataVolume from wrong NS | Denied |
| Clone performance (ODF) | DV creation-to-completion time | Seconds |
| Clone performance (File) | DV creation-to-completion time | Minutes (expected) |
