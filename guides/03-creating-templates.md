# Creating VM Templates in OpenShift Virtualization

In VMware, you build a VM, install the OS, configure it, and convert it to a template. In OpenShift Virtualization the end result is the same — a golden disk image ready for cloning — but there are more ways to get there.

This guide covers five methods for creating new VM templates. Pick the one that fits your workflow and OS.

---

## Method 1: From Vendor Cloud Images

**Best for:** Getting a working golden image fast, with minimal manual effort.

Cloud images are pre-built, cloud-init-enabled disk images published by OS vendors. They're the closest thing to a ready-made template — import one, customise via cloud-init, and you're done.

### Sources

| OS | Image | Format |
|---|---|---|
| Ubuntu 22.04 | [cloud-images.ubuntu.com](https://cloud-images.ubuntu.com/jammy/current/) | qcow2 |
| Ubuntu 24.04 | [cloud-images.ubuntu.com](https://cloud-images.ubuntu.com/noble/current/) | qcow2 |
| Windows Server 2022 | No official cloud image — use Method 2 (ISO install) or build with Packer | — |

> **Windows note:** Microsoft does not publish cloud-init-enabled images. For Windows, start from an ISO (Method 2) or use a Packer-built image. The remaining examples in this method focus on Ubuntu.

### Import the Cloud Image

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ubuntu-2404-golden
  namespace: golden-images
spec:
  source:
    http:
      url: "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  storage:
    resources:
      requests:
        storage: 30Gi
```

CDI downloads the image and writes it to a PVC. Once the DataVolume reaches `Succeeded`, the disk is ready.

```bash
oc get dv ubuntu-2404-golden -n golden-images -w
```

### Boot and Customise with cloud-init

Spin up a one-off VM to validate the image and apply any configuration that cloud-init can't handle:

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ubuntu-2404-build
  namespace: golden-images
spec:
  running: true
  instancetype:
    name: u1.medium
  preference:
    name: ubuntu
  dataVolumeTemplates:
    - metadata:
        name: ubuntu-2404-build-root
      spec:
        sourceRef:
          kind: DataSource
          name: ubuntu-2404-golden
        storage:
          resources:
            requests:
              storage: 30Gi
  template:
    spec:
      volumes:
        - dataVolume:
            name: ubuntu-2404-build-root
          name: rootdisk
        - cloudInitNoCloud:
            userData: |
              #cloud-config
              hostname: golden-build
              package_update: true
              packages:
                - qemu-guest-agent
                - openssh-server
              runcmd:
                - systemctl enable --now qemu-guest-agent
          name: cloudinit
```

### Seal and Convert to Golden Image

Once the VM is configured:

```bash
# Connect to the VM
virtctl ssh ubuntu-2404-build -n golden-images

# Inside the VM — clean up for cloning
sudo cloud-init clean --logs
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id
sudo shutdown -h now
```

Stop the VM, then create a DataSource from the root PVC:

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataSource
metadata:
  name: ubuntu-2404-golden
  namespace: golden-images
spec:
  source:
    pvc:
      name: ubuntu-2404-build-root
      namespace: golden-images
```

New VMs can now clone from this DataSource.

### Deep Dive: Automating Updates

To keep cloud images current without manual rebuilds, use a `DataImportCron`:

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataImportCron
metadata:
  name: ubuntu-2404-updates
  namespace: golden-images
spec:
  schedule: "0 4 * * 1"
  managedDataSource: ubuntu-2404-golden
  template:
    spec:
      source:
        http:
          url: "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
      storage:
        resources:
          requests:
            storage: 30Gi
```

Every Monday at 04:00, CDI pulls the latest image and updates the DataSource. New VMs automatically get the freshest image — no manual intervention.

For environments where you want more control (custom packages, agents, hardening), combine DataImportCron with a post-import customisation pipeline rather than relying on the raw vendor image.

---

## Method 2: From ISO (Fresh Install)

**Best for:** Windows templates, or any OS where you need full control over the installation.

This is the most familiar workflow for VMware admins: boot from an ISO, install the OS, configure, seal.

### Upload or Import the ISO

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: win2022-iso
  namespace: golden-images
spec:
  source:
    http:
      url: "https://your-repo.example.com/isos/windows-server-2022.iso"
  storage:
    resources:
      requests:
        storage: 6Gi
  contentType: archive
```

Or upload directly:

```bash
virtctl image-upload dv ubuntu-2404-iso \
  --size=2Gi \
  --image-path=./ubuntu-24.04-live-server-amd64.iso \
  --uploadproxy-url=https://cdi-uploadproxy-openshift-cnv.apps.cluster.example.com \
  --insecure \
  --namespace=golden-images
```

### Create an Empty Boot Disk

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: win2022-golden-root
  namespace: golden-images
spec:
  source:
    blank: {}
  storage:
    resources:
      requests:
        storage: 60Gi
```

### Boot the Installer VM

#### Windows Server 2022

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: win2022-build
  namespace: golden-images
spec:
  running: true
  template:
    spec:
      domain:
        cpu:
          cores: 4
        memory:
          guest: 8Gi
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
            - name: iso
              cdrom:
                bus: sata
            - name: virtio-drivers
              cdrom:
                bus: sata
          interfaces:
            - name: default
              masquerade: {}
        features:
          hyperv:
            spinlocks:
              spinlocks: 8191
            relaxed: {}
            vapic: {}
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          dataVolume:
            name: win2022-golden-root
        - name: iso
          dataVolume:
            name: win2022-iso
        - name: virtio-drivers
          containerDisk:
            image: registry.redhat.io/container-native-virtualization/virtio-win-rhel9:latest
```

> **Key points:**
> - The `virtio-win` container disk provides VirtIO storage and network drivers. During Windows Setup, click *Load Driver* and browse the CD drive to `viostor\w2k22\amd64` for the storage driver, then `NetKVM\w2k22\amd64` for the network driver.
> - Hyper-V enlightenments (`hyperv` features) are recommended for Windows performance.

#### Ubuntu 24.04

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ubuntu-2404-build
  namespace: golden-images
spec:
  running: true
  template:
    spec:
      domain:
        cpu:
          cores: 2
        memory:
          guest: 4Gi
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
            - name: iso
              cdrom:
                bus: sata
          interfaces:
            - name: default
              masquerade: {}
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          dataVolume:
            name: ubuntu-2404-golden-root
        - name: iso
          dataVolume:
            name: ubuntu-2404-iso
```

### Access the Console

```bash
virtctl console win2022-build -n golden-images   # serial
virtctl vnc win2022-build -n golden-images        # graphical (needed for Windows)
```

Or use the **VNC console** in the OpenShift web console under Virtualization → VirtualMachines.

### Install the OS

Walk through the installer as you would in VMware. For unattended installs:

- **Windows:** Provide an `autounattend.xml` via a ConfigMap mounted as a secondary disk or floppy.
- **Ubuntu:** Use `autoinstall` via a user-data source on a secondary `cloudInitNoCloud` volume or served over HTTP.

### Post-Install: Prepare the Golden Image

**Windows:**

```powershell
# Install QEMU Guest Agent + VirtIO drivers (from the virtio-win ISO)
D:\virtio-win-gt-x64.msi /quiet /norestart

# Verify the QEMU GA service is running
Get-Service QEMU-GA

# Enable RDP if needed
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0

# Generalise
C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown
```

**Ubuntu:**

```bash
sudo apt-get install -y qemu-guest-agent
sudo systemctl enable qemu-guest-agent

# Clean up for cloning
sudo cloud-init clean --logs
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id
sudo shutdown -h now
```

### Deep Dive: Unattended Windows Install with autounattend.xml

For repeatable Windows builds, embed an answer file:

**1. Create a ConfigMap with the answer file:**

```bash
oc create configmap win2022-autounattend \
  --from-file=autounattend.xml=./autounattend.xml \
  -n golden-images
```

**2. Mount it as a SATA CD-ROM in the VM spec:**

```yaml
- name: sysprep
  cdrom:
    bus: sata
```

With a corresponding volume:

```yaml
- name: sysprep
  sysprep:
    configMap:
      name: win2022-autounattend
```

OpenShift-Virt's `sysprep` volume type is purpose-built for this — it presents the ConfigMap contents as a filesystem that Windows Setup auto-discovers.

**3.** The answer file drives the entire installation — locale, partitioning, product key, admin password, driver injection, and the final `sysprep /generalize /oobe /shutdown` — producing a sealed golden image with zero manual interaction.

### Deep Dive: Kickstart / Autoinstall for Ubuntu

**Ubuntu autoinstall** can be served via a secondary cloud-init volume:

```yaml
- cloudInitNoCloud:
    userData: |
      #cloud-config
      autoinstall:
        version: 1
        locale: en_US.UTF-8
        keyboard:
          layout: us
        storage:
          layout:
            name: lvm
        identity:
          hostname: golden-build
          username: admin
          password: "$6$rounds=4096$..."
        ssh:
          install-server: true
        packages:
          - qemu-guest-agent
        late-commands:
          - curtin in-target -- systemctl enable qemu-guest-agent
  name: cloudinit
```

This eliminates the interactive installer entirely.

---

## Method 3: Using libguestfs Tools (Offline Customisation)

**Best for:** Modifying existing disk images without booting a VM. Fast, scriptable, CI-friendly.

`virt-customize` and `virt-builder` operate directly on disk images — no running VM needed. Think of it as editing a VMDK offline, but with package installation, file injection, and script execution built in.

### Prerequisites

These tools run on a Linux workstation or in a CI pipeline — not inside the OpenShift cluster.

```bash
# RHEL/Fedora
sudo dnf install -y libguestfs-tools

# Ubuntu/Debian
sudo apt-get install -y libguestfs-tools
```

### Customise an Existing Image

Start with a vendor cloud image and layer your changes:

**Ubuntu:**

```bash
# Download the base image
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

# Customise it
virt-customize -a noble-server-cloudimg-amd64.img \
  --install qemu-guest-agent,openssh-server,curl,vim \
  --run-command 'systemctl enable qemu-guest-agent' \
  --run-command 'systemctl enable ssh' \
  --run-command 'echo "PermitRootLogin no" >> /etc/ssh/sshd_config' \
  --copy-in ./custom-motd:/etc/ \
  --truncate /etc/machine-id \
  --run-command 'cloud-init clean --logs'
```

**Windows:**

libguestfs has limited Windows support — it can inject files and edit the registry, but cannot run PowerShell or install MSIs. For Windows, use `virt-customize` for file injection only:

```bash
virt-customize -a win2022-golden.qcow2 \
  --copy-in ./unattend.xml:/Windows/Panther/ \
  --copy-in ./setup-scripts/:/Scripts/
```

For anything beyond file operations on Windows, use Method 2 (ISO install) or Packer.

### Build from Scratch with virt-builder

`virt-builder` downloads a base image from a repository and customises it in one step:

```bash
virt-builder ubuntu-24.04 \
  --size 30G \
  --format qcow2 \
  --output ubuntu-2404-golden.qcow2 \
  --install qemu-guest-agent,openssh-server \
  --run-command 'systemctl enable qemu-guest-agent' \
  --truncate /etc/machine-id \
  --run-command 'cloud-init clean --logs'
```

### Upload to OpenShift

Once the image is ready, push it into the cluster:

```bash
virtctl image-upload dv ubuntu-2404-golden \
  --size=30Gi \
  --image-path=./ubuntu-2404-golden.qcow2 \
  --storage-class=ocs-storagecluster-ceph-rbd \
  --uploadproxy-url=https://cdi-uploadproxy-openshift-cnv.apps.cluster.example.com \
  --insecure \
  --namespace=golden-images
```

Or import via CDI from an HTTP/S3 endpoint if you've published the image to an internal artefact server.

Then create a DataSource as with any other method:

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataSource
metadata:
  name: ubuntu-2404-golden
  namespace: golden-images
spec:
  source:
    pvc:
      name: ubuntu-2404-golden
      namespace: golden-images
```

### When to Use This vs. Other Methods

| Scenario | Use libguestfs? |
|---|---|
| Adding packages, agents, config files to a Linux image | Yes — fast and scriptable |
| Full OS install from scratch | No — use Method 2 (ISO) or virt-builder |
| Windows customisation beyond file injection | No — use Method 2 or Packer |
| CI pipeline that produces golden images on a schedule | Yes — ideal for headless automation |
| One-off image tweaks | Yes — quicker than booting a VM |

---

## Method 4: ContainerDisk (Ephemeral Boot Images)

**Best for:** Stateless VMs, test/dev environments, or immutable infrastructure patterns.

A `containerDisk` is a disk image packaged inside a container image and stored in a standard container registry. Unlike PVC-based boot sources, containerDisks are **ephemeral** — the disk is pulled fresh on every VM start, and any changes are lost on shutdown.

### How It Differs from PVC-Based Templates

| Aspect | PVC-based golden image | containerDisk |
|---|---|---|
| **Persistence** | Cloned PVC retains state across reboots | Ephemeral — reset on every boot |
| **Storage** | Requires cluster storage (CSI) | Pulled from registry, stored in memory/emptyDir |
| **Distribution** | CDI import or DataImportCron | Standard container registry (pull, tag, push) |
| **Use case** | Stateful workloads, traditional VMs | Stateless services, CI runners, test environments |
| **Live migration** | Supported | Supported (image cached on node) |

### Build a containerDisk Image

**1. Start with a qcow2 image** (from any method above or a vendor cloud image):

```dockerfile
FROM scratch
ADD --chown=107:107 ubuntu-2404-golden.qcow2 /disk/
```

> The `107:107` UID/GID is required — this is the `qemu` user that KubeVirt uses to run the VM process.

**2. Build and push:**

```bash
podman build -t registry.example.com/golden/ubuntu-2404:latest .
podman push registry.example.com/golden/ubuntu-2404:latest
```

### Use in a VirtualMachine

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: stateless-worker-01
  namespace: workloads
spec:
  running: true
  instancetype:
    name: u1.medium
  preference:
    name: ubuntu
  template:
    spec:
      volumes:
        - containerDisk:
            image: registry.example.com/golden/ubuntu-2404:latest
          name: rootdisk
        - cloudInitNoCloud:
            userData: |
              #cloud-config
              hostname: worker-01
              packages:
                - qemu-guest-agent
              runcmd:
                - systemctl enable --now qemu-guest-agent
          name: cloudinit
      domain:
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
            - name: cloudinit
              disk:
                bus: virtio
```

Every time this VM starts, it boots from a clean copy of the image. Configuration is applied via cloud-init on each boot.

### Windows containerDisks

Windows images are large (10–30 GB compressed). containerDisks work but consider:

- **Pull time** — large images take longer to pull; pre-cache on nodes if latency matters.
- **Registry storage** — ensure your registry can handle the size.
- **Persistence** — Windows VMs almost always need persistent state (activation, domain join, profiles). A containerDisk with a separate persistent data PVC is possible, but Method 1 or 2 with PVC cloning is usually a better fit.

### Updating containerDisk Images

Update the image in your CI pipeline, push a new tag, and restart the VM — it picks up the new image. This fits a GitOps model well: the image tag is part of the VM manifest, so updates flow through the same review and deployment process as application containers.

---

## Method 5: Customising Red Hat-Provided Templates

**Best for:** Quick starts with sensible defaults. Avoids defining VM specs from scratch.

OpenShift Virtualization ships with a library of **pre-built templates** for common operating systems. These templates define recommended CPU, memory, disk, and device configurations — similar to VMware's "Guest OS Type" but with more opinionated defaults.

### What Ships Out of the Box

```bash
oc get templates -n openshift | grep vm-template
```

You'll find templates for RHEL, CentOS, Fedora, Windows Server, and Windows Desktop variants. Each template includes:

- CPU and memory defaults sized for the OS
- VirtIO disk and network configuration
- Hyper-V enlightenments (Windows templates)
- cloud-init or sysprep volume stubs
- Recommended instancetype and preference

### Listing Available Templates

```bash
# All VM templates
oc get templates -n openshift -l template.kubevirt.io/type=base

# Filter by OS
oc get templates -n openshift -l os.template.kubevirt.io/win2k22=true
oc get templates -n openshift -l os.template.kubevirt.io/ubuntu=true
```

### Deep Dive: Clone and Customise for Ubuntu

The Red Hat-provided templates are read-only in the `openshift` namespace. To customise, clone into your own namespace:

```bash
oc get template ubuntu-server-medium -n openshift -o yaml > ubuntu-golden-template.yaml
```

Edit the template to suit your standards:

```yaml
apiVersion: template.openshift.io/v1
kind: Template
metadata:
  name: ubuntu-2404-golden
  namespace: golden-images
  labels:
    os.template.kubevirt.io/ubuntu: "true"
    workload.template.kubevirt.io/server: "true"
  annotations:
    description: "Ubuntu 24.04 golden image — org standard build"
objects:
  - apiVersion: kubevirt.io/v1
    kind: VirtualMachine
    metadata:
      name: "${NAME}"
    spec:
      running: false
      instancetype:
        name: u1.medium
      preference:
        name: ubuntu
      dataVolumeTemplates:
        - metadata:
            name: "${NAME}-root"
          spec:
            sourceRef:
              kind: DataSource
              name: ubuntu-2404-golden
              namespace: golden-images
            storage:
              resources:
                requests:
                  storage: "${DISK_SIZE}"
      template:
        spec:
          volumes:
            - dataVolume:
                name: "${NAME}-root"
              name: rootdisk
            - cloudInitNoCloud:
                userData: |
                  #cloud-config
                  hostname: ${NAME}
                  packages:
                    - qemu-guest-agent
                  runcmd:
                    - systemctl enable --now qemu-guest-agent
              name: cloudinit
parameters:
  - name: NAME
    description: VM name
    required: true
  - name: DISK_SIZE
    description: Root disk size
    value: "30Gi"
```

Apply the template:

```bash
oc apply -f ubuntu-golden-template.yaml
```

Deploy a VM from it:

```bash
oc process ubuntu-2404-golden -n golden-images \
  -p NAME=webserver-01 \
  -p DISK_SIZE=50Gi \
  | oc apply -f -
```

### Deep Dive: Clone and Customise for Windows

Windows templates include Hyper-V enlightenments, VirtIO driver references, and recommended resource sizing. Clone and extend:

```bash
oc get template windows2k22-server-medium -n openshift -o yaml > win2022-golden-template.yaml
```

Key customisations for a Windows golden template:

```yaml
apiVersion: template.openshift.io/v1
kind: Template
metadata:
  name: win2022-golden
  namespace: golden-images
  labels:
    os.template.kubevirt.io/win2k22: "true"
    workload.template.kubevirt.io/server: "true"
  annotations:
    description: "Windows Server 2022 golden image — org standard build"
objects:
  - apiVersion: kubevirt.io/v1
    kind: VirtualMachine
    metadata:
      name: "${NAME}"
    spec:
      running: false
      instancetype:
        name: u1.large
      preference:
        name: windows.2k22
      dataVolumeTemplates:
        - metadata:
            name: "${NAME}-root"
          spec:
            sourceRef:
              kind: DataSource
              name: win2022-golden
              namespace: golden-images
            storage:
              resources:
                requests:
                  storage: "${DISK_SIZE}"
      template:
        spec:
          domain:
            features:
              hyperv:
                spinlocks:
                  spinlocks: 8191
                relaxed: {}
                vapic: {}
                synic: {}
                synictimer:
                  direct: {}
                frequencies: {}
                reenlightenment: {}
                tlbflush: {}
                ipi: {}
          volumes:
            - dataVolume:
                name: "${NAME}-root"
              name: rootdisk
            - sysprep:
                configMap:
                  name: "${SYSPREP_CONFIG}"
              name: sysprep
parameters:
  - name: NAME
    description: VM name
    required: true
  - name: DISK_SIZE
    description: Root disk size
    value: "60Gi"
  - name: SYSPREP_CONFIG
    description: ConfigMap containing unattend.xml for Windows customisation
    value: "win2022-default-sysprep"
```

This gives teams a self-service deployment model: `oc process win2022-golden -p NAME=sqlserver-01 -p SYSPREP_CONFIG=sql-sysprep | oc apply -f -`

### Deep Dive: Instancetypes and Preferences vs. Templates

OpenShift-Virt offers two complementary systems:

| Mechanism | What it defines | Analogy |
|---|---|---|
| **Template** (OpenShift Template) | Full VM spec with parameters — disk sources, volumes, cloud-init, everything | VMware template (complete VM blueprint) |
| **Instancetype** | CPU, memory, IO threads | VM sizing policy / t-shirt size |
| **Preference** | Guest OS defaults — disk bus, NIC model, EFI/BIOS, machine type | VMware "Guest OS Type" |

**Templates** are end-to-end blueprints. **Instancetypes + Preferences** are building blocks that templates (or standalone VM manifests) reference. For most organisations, the combination is:

- Define a small set of **instancetypes** (small/medium/large per workload class)
- Define **preferences** per OS family (ubuntu, rhel9, win2022)
- Build **templates** that wire together a golden image + instancetype + preference + cloud-init/sysprep

This separation means you can update compute sizing (instancetype) without touching the image, and update OS defaults (preference) without touching the sizing — clean separation of concerns that VMware's monolithic templates don't offer.

---

## Choosing the Right Method

| Method | Ubuntu | Windows | Automation-friendly | Persistent state | When to use |
|---|---|---|---|---|---|
| **Cloud image** | Yes | No | High | Yes | Fast start, standard images |
| **ISO install** | Yes | Yes | Medium (with autoinstall/autounattend) | Yes | Full control, Windows builds |
| **libguestfs** | Yes | Limited | High | Yes | CI pipelines, offline customisation |
| **containerDisk** | Yes | Possible | High | No | Stateless/ephemeral VMs |
| **Red Hat templates** | Yes | Yes | High | Yes | Self-service deployment with guardrails |

### Common Post-Creation Steps (All Methods)

Regardless of which method you use, every golden image should:

1. **Have the QEMU Guest Agent installed and enabled** — this is the KubeVirt equivalent of VMware Tools (see the [golden images guide](01-golden-images.md) for details)
2. **Be sealed** — `cloud-init clean` + truncate `/etc/machine-id` for Linux; `sysprep /generalize /oobe /shutdown` for Windows
3. **Be registered as a DataSource** — so VMs can clone from it via `sourceRef`
4. **Be tested** — boot a VM from the image, verify the guest agent reports in, confirm cloud-init/sysprep customisation works, then stop and discard the test VM
