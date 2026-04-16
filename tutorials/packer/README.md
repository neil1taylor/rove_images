# Packer Tutorial: Building Golden Images for OCP Virtualization

Customise a Fedora 41 cloud image with Packer's QEMU builder, then upload it to OCP Virtualization as a golden template.

This covers building clean images natively rather than migrating from VMware. For the full Packer reference, see the [Packer guide](../../guides/04-packer-image-builds.md).

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Packer | >= 1.10 | `brew install packer` |
| QEMU | >= 8.0 | `brew install qemu` |
| virtctl | matches cluster | `brew install virtctl` or via OCP console |
| oc | matches cluster | `brew install openshift-cli` |

Verify:

```bash
packer version
qemu-system-x86_64 --version
virtctl version --client
```

## What's in this tutorial

```
tutorial/packer/
  fedora41.pkr.hcl           # Packer template — QEMU builder + provisioners
  apple-silicon.pkrvars.hcl   # Variable overrides for Apple Silicon Macs
  scripts/
    01-packages.sh            # Install packages for OCP Virt (qemu-guest-agent, cloud-init)
    02-cloud-init.sh          # Configure cloud-init for NoCloud datasource
    03-harden.sh              # Lock root, disable password SSH
    99-seal.sh                # Wipe machine-id, SSH keys, cloud-init state
  manifests/
    datavolume.yaml           # CDI DataVolume (upload target)
    instancetype.yaml         # VirtualMachineInstancetype
    preference.yaml           # VirtualMachinePreference (VirtIO, EFI, q35)
    consumer-vm.yaml          # Example VM that clones the golden image
```

## How it works

Unlike an ISO-based install, this template starts from a pre-built Fedora Cloud image:

1. Packer downloads the Fedora Cloud Base qcow2 (cloud-init enabled, VirtIO native)
2. Boots it in QEMU with a cloud-init NoCloud CD that creates a temporary `packer` user
3. SSHes in as `packer` and runs provisioner scripts (packages, hardening, seal)
4. Shuts down the VM and compresses the output qcow2

This approach avoids the complexity of kickstart files and GRUB boot editing, and works identically on x86_64 and aarch64.

## Step 1: Build the image

```bash
cd tutorial/packer

# Initialise Packer plugins (first time only)
packer init fedora41.pkr.hcl

# Validate the template
packer validate fedora41.pkr.hcl

# Build (x86_64 on Intel Mac or Linux with KVM)
packer build fedora41.pkr.hcl
```

### Apple Silicon Macs

On M1/M2/M3/M4 Macs, use the aarch64 variant with HVF acceleration:

```bash
packer build -var-file=apple-silicon.pkrvars.hcl fedora41.pkr.hcl
```

This produces an aarch64 image. For x86_64 cluster images, build on a Linux x86_64 host or in CI with `accelerator = "kvm"`.

### Linux with KVM

```bash
packer build -var 'accelerator=kvm' fedora41.pkr.hcl
```

The build takes roughly 10-15 minutes depending on network speed.

## Step 2: Inspect the image

```bash
qemu-img info output/fedora41-golden.qcow2
```

## Step 3: Upload to OCP Virtualization

### Option A: virtctl image-upload (direct)

```bash
oc whoami
oc project vm-golden-images

virtctl image-upload dv fedora41-packer-v1 \
  --namespace vm-golden-images \
  --size 10Gi \
  --image-path output/fedora41-golden.qcow2 \
  --storage-class ocs-storagecluster-ceph-rbd-virtualization \
  --insecure
```

### Option B: CDI HTTP source (GitOps-friendly)

Host the qcow2 on an HTTP server and update `manifests/datavolume.yaml`:

```yaml
spec:
  source:
    http:
      url: "https://artifacts.example.com/images/fedora41-golden.qcow2"
```

Then apply:

```bash
oc apply -f manifests/datavolume.yaml
```

## Step 4: Create the InstanceType and Preference

```bash
oc apply -f manifests/instancetype.yaml
oc apply -f manifests/preference.yaml
```

## Step 5: Spin up a VM from the golden image

```bash
# Edit manifests/consumer-vm.yaml — replace the SSH key placeholder
oc apply -f manifests/consumer-vm.yaml

# Watch it come up
oc get vm packer-demo-vm -n tutorial-consumer -w

# Once running
virtctl console packer-demo-vm -n tutorial-consumer
virtctl ssh fedora@packer-demo-vm -n tutorial-consumer
```

## How it fits together

```
                    ┌──────────────────────────┐
                    │  Packer + QEMU           │
                    │  (local or CI)           │
                    │                          │
                    │  Cloud qcow2 ─► Boot     │
                    │  ─► cloud-init SSH       │
                    │  ─► Provisioners         │
                    │  ─► Sealed qcow2         │
                    └──────────┬───────────────┘
                               │
                    virtctl image-upload
                     or CDI HTTP source
                               │
                    ┌──────────▼───────────────┐
                    │  PVC in                  │
                    │  vm-golden-images         │
                    │  namespace               │
                    └──────────┬───────────────┘
                               │
                    DataVolume clone
                               │
                    ┌──────────▼───────────────┐
                    │  Consumer VM             │
                    │  (InstanceType +         │
                    │   Preference +           │
                    │   cloud-init)            │
                    └──────────────────────────┘
```

## What the provisioner scripts do

| Script | Purpose |
|--------|---------|
| `01-packages.sh` | `dnf update`, install cloud-init, qemu-guest-agent, growpart |
| `02-cloud-init.sh` | Configure NoCloud datasource, default user, growpart |
| `03-harden.sh` | Disable root SSH, disable password auth, lock root password |
| `99-seal.sh` | Remove packer user, wipe machine-id, SSH host keys, cloud-init state, zero free space |

The seal step is critical — without it, every VM cloned from this image would share the same machine-id and SSH host keys.

## Customising the build

### Adding packages

Edit `scripts/01-packages.sh` or add a new script between 03 and 99. Keep the numbering — scripts run in order.

### Larger disk

```bash
packer build -var 'disk_size=20G' fedora41.pkr.hcl
```

Update the DataVolume `storage.resources.requests.storage` to match.

### Different OS

Replace the cloud image URL and checksum. Most distributions publish cloud images with cloud-init pre-installed:

- **RHEL**: `Fedora-Cloud-Base-Generic` → RHEL KVM Guest Image from Red Hat CDN
- **Ubuntu**: Use the Ubuntu Cloud Image (`.img` format, rename to `.qcow2`)
- **CentOS Stream**: Available from CentOS mirrors

## Comparison with CDI HTTP import

| | Packer build | CDI HTTP import (existing tutorial) |
|---|---|---|
| **Input** | Cloud image (qcow2) | Cloud image (qcow2) |
| **Customisation** | Full control — provisioner scripts | Limited to cloud-init on first boot |
| **Reproducibility** | Fully reproducible from source | Depends on upstream image |
| **Build time** | ~10-15 min | Minutes (download only) |
| **Best for** | Custom hardened images, compliance requirements | Standard images where upstream is trusted |

Use Packer when you need packages, hardening, or configuration baked into the image. Use CDI HTTP import (the `golden-images/images/fedora41` tutorial) when upstream cloud images are sufficient and cloud-init handles first-boot customisation.

## Next steps

- Run this in CI (GitHub Actions, Tekton) for automated image builds
- Add image versioning with date-stamped DataVolume names
- Integrate with ArgoCD for GitOps-managed golden images (see `tutorial/argocd/`)
- Build a RHEL or Windows variant
