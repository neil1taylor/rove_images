# Golden Images: VMware Templates to OpenShift Virtualization

## The VMware Way

In VMware, a **golden image** is a fully configured VM that serves as the baseline for deploying new instances. The typical workflow:

1. **Build a VM** — install the OS, apply patches, harden, install agents (monitoring, backup, etc.), and configure to organisational standards.
2. **Convert to Template** — mark the VM as a template in vCenter. This makes it read-only and prevents accidental modification.
3. **Deploy from Template** — use *Clone to Virtual Machine* or *Deploy from Template* to stamp out new VMs. Each clone gets a full copy (or linked clone) of the template's disks.
4. **Customise at deploy time** — apply a *Customization Specification* (sysprep for Windows, cloud-init or scripted for Linux) to set hostname, network config, domain join, etc.

**Content Libraries** extend this model across vCenters — publish a template once, subscribe from other sites, and keep images in sync.

Key characteristics of the VMware model:

- Templates are **mutable infrastructure** — you periodically update the golden image by converting it back to a VM, patching, and re-sealing.
- Lifecycle is **UI/API-driven** — vCenter is the control plane for template management.
- Storage is tightly coupled — templates live on datastores alongside the VMs they produce.

---

## The OpenShift Virtualization Way

OpenShift Virtualization (KubeVirt) achieves the same goal — repeatable, standardised VM provisioning — but the primitives and workflow are different.

### Core Concepts

| VMware Concept | OpenShift-Virt Equivalent | Description |
|---|---|---|
| VM Template | **VirtualMachine manifest + boot source** | A YAML definition of the VM spec, paired with a golden disk image |
| Template disk (VMDK) | **PVC / DataVolume** | The disk image, stored as a PersistentVolumeClaim managed by CDI |
| Content Library | **DataSource / DataImportCron** | Centralised, auto-updating references to boot images |
| Customization Spec | **cloud-init / sysprep (via CloudInitNoCloud or Sysprep volume)** | Guest customisation embedded in the VM manifest |
| Linked Clone | **DataVolume cloning / smart clone** | CSI-level clone of a source PVC — fast, storage-efficient |
| VM Hardware version | **VirtualMachineInstancetype + VirtualMachinePreference** | Reusable definitions for compute resources and guest OS defaults |
| VMware Tools | **QEMU Guest Agent (qemu-ga)** | In-guest agent for graceful shutdown, filesystem freeze, and guest info reporting |

### How It Works

**1. Import or build a boot source**

Golden disk images are imported into the cluster as PVCs using the **Containerized Data Importer (CDI)**. Sources can be:

- A registry image (`containerDisk` or CDI registry import)
- An HTTP/S3 endpoint hosting a qcow2 or raw image
- An existing PVC to clone

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: rhel9-golden
spec:
  source:
    http:
      url: "https://image-repo.example.com/rhel9-base.qcow2"
  storage:
    resources:
      requests:
        storage: 30Gi
```

**2. Create a DataSource for automatic updates**

A `DataImportCron` periodically pulls the latest image and updates a `DataSource`, so new VMs always get the most current golden image — similar to a subscribed Content Library.

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataImportCron
metadata:
  name: rhel9-updates
spec:
  schedule: "0 4 * * 1"          # weekly Monday 04:00
  managedDataSource: rhel9-golden
  template:
    spec:
      source:
        registry:
          url: "docker://registry.example.com/golden/rhel9:latest"
      storage:
        resources:
          requests:
            storage: 30Gi
```

**3. Define instancetypes and preferences**

Rather than baking CPU/memory into every template, OpenShift-Virt separates concerns:

- **VirtualMachineInstancetype** — defines compute (vCPUs, memory, IO threads). Think *VM sizing policy*.
- **VirtualMachinePreference** — defines guest-OS defaults (disk bus, NIC model, EFI/BIOS). Think *hardware compatibility profile*.

These are cluster-scoped and reusable across all VM definitions.

**4. Deploy a VM from the golden image**

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: webserver-01
spec:
  instancetype:
    name: u1.medium
  preference:
    name: rhel.9
  dataVolumeTemplates:
    - metadata:
        name: webserver-01-root
      spec:
        sourceRef:
          kind: DataSource
          name: rhel9-golden
        storage:
          resources:
            requests:
              storage: 30Gi
  template:
    spec:
      volumes:
        - dataVolume:
            name: webserver-01-root
          name: rootdisk
        - cloudInitNoCloud:
            userData: |
              #cloud-config
              hostname: webserver-01
              ssh_authorized_keys:
                - ssh-rsa AAAA...
          name: cloudinit
```

Each new VM gets a **clone** of the golden PVC. If the storage class supports smart/CSI cloning, this is near-instant.

---

## Key Differences for VMware Admins

| Area | VMware | OpenShift Virtualization |
|---|---|---|
| **Definition format** | UI-driven, stored in vCenter DB | Declarative YAML, stored in etcd / Git |
| **Image storage** | VMDK on datastore | PVC on any CSI-backed StorageClass |
| **Image distribution** | Content Library subscription | DataImportCron + registry or HTTP source |
| **Lifecycle management** | Manual: convert template → VM → patch → re-seal → convert back | Pipeline: build image in CI, push to registry, DataImportCron picks it up |
| **Customisation** | Customization Spec (vCenter) | cloud-init / sysprep in VM manifest |
| **Compute sizing** | Per-template hardware settings | Instancetypes (decoupled, reusable) |
| **GitOps compatibility** | Limited | Native — VM definitions are just YAML |

### What Stays the Same

- You still maintain a curated base image per OS.
- You still apply guest customisation at first boot.
- You still clone rather than install from scratch.
- Patching cadence and image hygiene matter just as much.

### What Changes

- **Everything is declarative.** The VM, its disks, its customisation — all defined in YAML. This makes version control, code review, and automated rollout natural.
- **Images travel through registries and HTTP endpoints**, not datastore replication. This fits container-native CI/CD pipelines.
- **Compute and OS preferences are decoupled from the image.** You update sizing policies independently of the golden disk.
- **VMware Tools is replaced by QEMU Guest Agent.** Install `qemu-guest-agent` in your golden image — it's the equivalent of VMware Tools for KubeVirt. Without it, you lose graceful shutdown (falls back to ACPI power-off), filesystem freeze/thaw for consistent snapshots, and guest OS info reporting (`virtctl guestosinfo`). On RHEL/CentOS it's a simple `dnf install qemu-guest-agent && systemctl enable qemu-guest-agent`. For Windows, install the VirtIO guest tools MSI which bundles the QEMU GA service.
- **No GUI required.** The OpenShift console provides a UI, but the CLI and YAML are first-class citizens — automation is the default, not an afterthought.
