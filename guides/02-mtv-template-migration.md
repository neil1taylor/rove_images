# Migrating VMware Templates with MTV (Migration Toolkit for Virtualization)

## Why Migrate Templates?

You have a library of golden images in vCenter — patched, hardened, approved. Rebuilding them from scratch in OpenShift Virtualization is wasted effort. The **Migration Toolkit for Virtualization (MTV)** can import those existing VMware templates directly, converting them into OpenShift-Virt boot sources ready for cloning.

---

## What Is MTV?

MTV is a Red Hat operator that migrates VMs from VMware (and other platforms) into OpenShift Virtualization. It handles:

- Disk conversion (VMDK → raw/qcow2 on a PVC)
- Network mapping (vSphere port groups → OpenShift networks)
- Storage mapping (datastores → StorageClasses)
- Guest conversion (drivers, bootloader adjustments)

Under the hood, MTV uses **virt-v2v** for the actual disk conversion and guest OS adaptation — the same tool that has handled V2V migrations in the Linux ecosystem for years.

---

## Prerequisites

| Requirement | Detail |
|---|---|
| **MTV Operator** | Installed from OperatorHub (`mtv-operator`) |
| **vCenter credentials** | Service account with read access to the templates and their datastores |
| **Network connectivity** | OpenShift nodes must reach the vCenter API and ESXi hosts (port 443, NBD/VDDK ports) |
| **VDDK image** | VMware Virtual Disk Development Kit, packaged as a container image and referenced in MTV config — significantly speeds up disk transfer |
| **Target StorageClass** | A CSI-backed StorageClass in OpenShift that supports `ReadWriteMany` or `ReadWriteOnce` depending on your live-migration requirements |

---

## Step-by-Step: Import a VMware Template

### 1. Create a Provider

Define the source vCenter environment. MTV connects to the vCenter API to discover VMs, templates, networks, and datastores.

```yaml
apiVersion: forklift.konveyor.io/v1beta1
kind: Provider
metadata:
  name: vcenter-prod
  namespace: openshift-mtv
spec:
  type: vsphere
  url: "https://vcenter.example.com/sdk"
  secret:
    name: vcenter-prod-creds
    namespace: openshift-mtv
---
apiVersion: v1
kind: Secret
metadata:
  name: vcenter-prod-creds
  namespace: openshift-mtv
type: Opaque
stringData:
  user: "svc-mtv@vsphere.local"
  password: "changeme"
  thumbprint: "AB:CD:12:34:..."
```

Once created, MTV inventories the vCenter — you'll see templates appear alongside VMs in the MTV console.

### 2. Create Network and Storage Mappings

Map vSphere constructs to OpenShift equivalents. These mappings are reusable across multiple migrations.

**Network Mapping**

```yaml
apiVersion: forklift.konveyor.io/v1beta1
kind: NetworkMap
metadata:
  name: vmware-to-ocp
  namespace: openshift-mtv
spec:
  provider:
    source:
      name: vcenter-prod
      namespace: openshift-mtv
    destination:
      name: host
      namespace: openshift-mtv
  map:
    - source:
        id: dvportgroup-123   # vSphere network ID
      destination:
        type: pod              # or 'multus' for secondary networks
```

**Storage Mapping**

```yaml
apiVersion: forklift.konveyor.io/v1beta1
kind: StorageMap
metadata:
  name: vmware-to-ocp
  namespace: openshift-mtv
spec:
  provider:
    source:
      name: vcenter-prod
      namespace: openshift-mtv
    destination:
      name: host
      namespace: openshift-mtv
  map:
    - source:
        id: datastore-456     # vSphere datastore ID
      destination:
        storageClass: ocs-storagecluster-ceph-rbd
```

### 3. Create a Migration Plan

A `Plan` defines what to migrate and how. For templates, the workflow is the same as for VMs — MTV treats templates as source objects.

```yaml
apiVersion: forklift.konveyor.io/v1beta1
kind: Plan
metadata:
  name: import-golden-images
  namespace: openshift-mtv
spec:
  provider:
    source:
      name: vcenter-prod
      namespace: openshift-mtv
    destination:
      name: host
      namespace: openshift-mtv
  map:
    network:
      name: vmware-to-ocp
      namespace: openshift-mtv
    storage:
      name: vmware-to-ocp
      namespace: openshift-mtv
  targetNamespace: golden-images
  vms:
    - id: vm-1001            # vCenter MoRef ID of the template
      name: rhel9-golden
    - id: vm-1002
      name: win2022-golden
```

> **Tip:** Find the MoRef IDs in the MTV inventory (console or API), or via `govc` / PowerCLI against vCenter.

### 4. Execute the Migration

```yaml
apiVersion: forklift.konveyor.io/v1beta1
kind: Migration
metadata:
  name: import-golden-images-run1
  namespace: openshift-mtv
spec:
  plan:
    name: import-golden-images
    namespace: openshift-mtv
```

Or simply click **Start** on the plan in the OpenShift console under **Virtualization → Migrations**.

MTV will:

1. Snapshot the template disks in vCenter (non-destructive — source templates are untouched)
2. Stream disk data via VDDK to the OpenShift cluster
3. Run **virt-v2v** to convert the guest (install VirtIO drivers, adjust bootloader, remove VMware Tools)
4. Create a `VirtualMachine` object with attached PVCs in the target namespace

### 5. Monitor Progress

```bash
# CLI
oc get migrations -n openshift-mtv
oc get plans -n openshift-mtv -o yaml

# Per-VM status
oc get vmimports -n golden-images
```

The OpenShift console also provides a step-by-step progress view per VM under the migration plan.

---

## Post-Migration: Turn Migrated VMs into Reusable Boot Sources

MTV produces a `VirtualMachine` with attached PVCs. To use these as golden images for cloning, a few extra steps:

### Option A: Create a DataSource pointing to the migrated PVC

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataSource
metadata:
  name: rhel9-golden
  namespace: golden-images
spec:
  source:
    pvc:
      name: rhel9-golden-root     # PVC created by MTV
      namespace: golden-images
```

New VMs can now reference this DataSource via `sourceRef` in their `dataVolumeTemplates` — exactly as described in the golden images guide.

### Option B: Stop and seal the migrated VM

If the migrated VM booted with residual VMware identity (hostname, SSH keys, etc.):

1. Start the VM, verify it boots cleanly
2. Install the **QEMU Guest Agent** (see *Installing the QEMU Guest Agent* above) — this replaces VMware Tools, which virt-v2v removed
3. Run your standard sealing process (`virt-sysprep`, `cloud-init clean`, `sysprep.exe`)
4. Stop the VM
5. Use the root PVC as your golden image DataSource

### Option C: Push the disk to a registry

Export the PVC as a container image for use with `DataImportCron` and registry-based distribution:

```bash
virtctl image-upload dv rhel9-golden-registry \
  --size=30Gi \
  --storage-class=ocs-storagecluster-ceph-rbd \
  --uploadproxy-url=https://cdi-uploadproxy-openshift-cnv.apps.cluster.example.com \
  --image-path=/exported/rhel9-golden.qcow2
```

Or use a CI pipeline to wrap the qcow2 in a container image and push to your registry, enabling the `DataImportCron` auto-update pattern.

---

## Practical Considerations

### What virt-v2v Does During Conversion

- **Installs VirtIO drivers** — replaces VMware PVSCSI/VMXNET3 with VirtIO block/net drivers. For Windows, MTV injects the Red Hat VirtIO driver ISO.
- **Removes VMware Tools** — uninstalls guest agents that serve no purpose in KubeVirt. **Note:** virt-v2v does *not* install the QEMU Guest Agent as a replacement — see below.
- **Adjusts bootloader** — ensures the guest can boot from a VirtIO disk (updates GRUB/BCD as needed).
- **Fixes device references** — updates `/etc/fstab`, network config files, etc. to reflect new device names.

### Installing the QEMU Guest Agent

virt-v2v removes VMware Tools during conversion but does **not** install its KubeVirt equivalent — the **QEMU Guest Agent (qemu-ga)**. This is a gap you need to close before sealing the image.

**Why it matters:** Without qemu-ga, OpenShift Virtualization loses visibility into the guest:

- **Graceful shutdown** falls back to ACPI power-off — the guest gets no chance to flush buffers or stop services cleanly.
- **Snapshots** are crash-consistent only — no filesystem freeze/thaw, so database or application-level consistency is not guaranteed.
- **Guest info** is unavailable — `virtctl guestosinfo` returns nothing, and the console won't show the guest IP address or OS details.

**Linux (RHEL/CentOS/Fedora):**

```bash
dnf install -y qemu-guest-agent
systemctl enable --now qemu-guest-agent
```

**Linux (Debian/Ubuntu):**

```bash
apt-get install -y qemu-guest-agent
systemctl enable --now qemu-guest-agent
```

**Windows:**

Install the [Red Hat VirtIO guest tools MSI](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/), which bundles the QEMU GA service (`QEMU Guest Agent` Windows service) alongside the VirtIO drivers.

**Recommended approach:** Install qemu-ga during the post-migration seal step (Option B). Boot the migrated VM, install the agent, verify it's running, then seal and stop. This way every VM cloned from the golden image inherits a working guest agent from day one.

Alternatively, inject it via **cloud-init** on first boot if you prefer not to bake it into the image:

```yaml
cloudInitNoCloud:
  userData: |
    #cloud-config
    packages:
      - qemu-guest-agent
    runcmd:
      - systemctl enable --now qemu-guest-agent
```

### Templates with Multiple Disks

MTV migrates all disks attached to the template. Each disk becomes a separate PVC. Your resulting `VirtualMachine` will reference all of them — no manual reassembly needed.

### Windows Templates

- Ensure the VDDK image is configured — Windows disk conversion without VDDK is significantly slower.
- MTV handles VirtIO driver injection for supported Windows versions (Server 2016+, Windows 10+).
- After migration, you may want to re-run `sysprep` before using the image as a golden image to clear any SID/activation state carried over from vCenter.

### Batch Imports

MTV supports migrating multiple templates in a single plan. For large template libraries, consider:

- Grouping by OS family (all RHEL, all Windows) for consistent post-migration handling
- Running plans sequentially if storage bandwidth is limited
- Using `cutover` scheduling for large disk transfers during off-peak hours

### What MTV Does NOT Do

- **Does not migrate vCenter template metadata** (notes, custom attributes, tags). Capture these separately if needed.
- **Does not migrate snapshots** — only the current state of the template disk is imported.
- **Does not create OpenShift VM templates automatically** — you get a `VirtualMachine` and PVCs; wiring these into reusable templates/DataSources is a manual (or automated) post-step as shown above.

---

## Summary Workflow

```
vCenter Template
       │
       ▼
   MTV Plan  ──→  Provider + Mappings (network, storage)
       │
       ▼
  Migration  ──→  Disk transfer (VDDK) + virt-v2v conversion
       │
       ▼
  VirtualMachine + PVCs  (in target namespace)
       │
       ▼
  Post-migration:
    ├── Verify boot
    ├── Seal guest (if needed)
    └── Create DataSource  ──→  Ready for cloning
```

Your VMware golden images are now OpenShift-Virt boot sources — same images, new platform, no rebuild required.
