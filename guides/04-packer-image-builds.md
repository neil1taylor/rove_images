# Building Golden Images with Packer

## Why Packer?

In VMware, golden images are typically hand-built: install the OS, configure it, seal it, convert to template. This works, but it's manual, hard to reproduce, and impossible to code-review.

**HashiCorp Packer** automates the entire process. You define the image as code — OS install, packages, hardening, sealing — and Packer produces an identical qcow2 every time. The output plugs directly into OpenShift Virtualization via CDI import or a container registry.

For VMware admins, think of Packer as a scriptable version of your template build process — but version-controlled, repeatable, and CI-ready.

---

## How Packer Works with OpenShift-Virt

Packer doesn't run inside the OpenShift cluster. It runs on a build machine (local workstation, CI runner, or dedicated build server) and produces a disk image that you then import into the cluster.

```
Packer (build machine)
    │
    ├── Downloads ISO / cloud image
    ├── Boots a temporary QEMU VM
    ├── Runs the installer (kickstart / autoinstall / autounattend)
    ├── Runs provisioners (shell scripts, Ansible, etc.)
    ├── Shuts down and exports qcow2
    │
    ▼
qcow2 image ──→ Push to registry or HTTP server ──→ CDI import into OpenShift
```

### Build Machine Requirements

| Requirement | Detail |
|---|---|
| **Packer** | v1.9+ (HCL2 config format) |
| **QEMU/KVM** | `qemu-system-x86_64` with KVM acceleration (`/dev/kvm` must be available) |
| **Disk space** | Enough for the ISO + output image (plan 60–80 GB for Windows, 10–20 GB for Ubuntu) |
| **Network** | Outbound access to download ISOs, packages, updates |

```bash
# RHEL/Fedora
sudo dnf install -y qemu-kvm packer

# Ubuntu/Debian
sudo apt-get install -y qemu-kvm qemu-utils
# Install Packer from HashiCorp repo: https://developer.hashicorp.com/packer/install
```

> **Note:** If your build machine is itself a VM (e.g. a CI runner in the cloud), it must support nested virtualisation for KVM acceleration. Without KVM, builds will fall back to software emulation and be extremely slow.

---

## Ubuntu 24.04: Cloud Image + Packer

The fastest path for Ubuntu — start from the vendor cloud image and layer your customisations.

### Directory Structure

```
ubuntu-2404/
├── ubuntu-2404.pkr.hcl        # Packer template
├── http/
│   └── user-data               # autoinstall config (ISO method only)
├── scripts/
│   ├── base.sh                 # Base packages and config
│   ├── hardening.sh            # CIS hardening, firewall rules
│   ├── qemu-guest-agent.sh     # Install and enable qemu-ga
│   └── seal.sh                 # Clean up for cloning
└── files/
    └── 99-custom-motd          # Any files to inject
```

### Packer Template (Cloud Image Source)

```hcl
packer {
  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

variable "ubuntu_image_url" {
  type    = string
  default = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

variable "ubuntu_image_checksum" {
  type    = string
  default = "file:https://cloud-images.ubuntu.com/noble/current/SHA256SUMS"
}

source "qemu" "ubuntu-2404" {
  iso_url          = var.ubuntu_image_url
  iso_checksum     = var.ubuntu_image_checksum
  disk_image       = true
  disk_size        = "30G"
  format           = "qcow2"
  accelerator      = "kvm"
  vm_name          = "ubuntu-2404-golden.qcow2"
  net_device       = "virtio-net"
  disk_interface   = "virtio"
  headless         = true
  ssh_username     = "ubuntu"
  ssh_password     = "ubuntu"
  ssh_timeout      = "10m"
  shutdown_command  = "sudo shutdown -h now"

  # cloud-init datasource to set the password and enable SSH
  cd_content = {
    "meta-data" = ""
    "user-data" = <<-EOF
      #cloud-config
      password: ubuntu
      chpasswd:
        expire: false
      ssh_pwauth: true
    EOF
  }
  cd_label = "cidata"
}

build {
  sources = ["source.qemu.ubuntu-2404"]

  provisioner "shell" {
    scripts = [
      "scripts/base.sh",
      "scripts/qemu-guest-agent.sh",
      "scripts/hardening.sh",
      "scripts/seal.sh"
    ]
    execute_command = "sudo bash '{{ .Path }}'"
  }

  provisioner "file" {
    source      = "files/99-custom-motd"
    destination = "/tmp/99-custom-motd"
  }

  provisioner "shell" {
    inline = ["sudo mv /tmp/99-custom-motd /etc/update-motd.d/99-custom-motd && sudo chmod 755 /etc/update-motd.d/99-custom-motd"]
  }

  post-processor "checksum" {
    checksum_types = ["sha256"]
    output         = "output-ubuntu-2404/ubuntu-2404-golden.sha256"
  }
}
```

### Provisioner Scripts

**scripts/base.sh**

```bash
#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get upgrade -y
apt-get install -y \
  openssh-server \
  curl \
  vim \
  ca-certificates \
  gnupg \
  lsb-release

# Enable SSH
systemctl enable ssh
```

**scripts/qemu-guest-agent.sh**

```bash
#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get install -y qemu-guest-agent
systemctl enable qemu-guest-agent
```

**scripts/hardening.sh**

```bash
#!/bin/bash
set -euo pipefail

# Disable root login
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config

# Disable password auth (keys only in production)
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

# Remove the build-time password
passwd -d ubuntu
passwd -l ubuntu

# Add your organisation's hardening steps here
```

**scripts/seal.sh**

```bash
#!/bin/bash
set -euo pipefail

# Clean cloud-init state
cloud-init clean --logs

# Clear machine identity
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id

# Clear apt cache
apt-get clean
rm -rf /var/lib/apt/lists/*

# Clear shell history
unset HISTFILE
rm -f /root/.bash_history /home/ubuntu/.bash_history

# Zero free space for better compression
dd if=/dev/zero of=/EMPTY bs=1M 2>/dev/null || true
rm -f /EMPTY
sync
```

### Build

```bash
cd ubuntu-2404/
packer init .
packer build .
```

Output: `output-ubuntu-2404/ubuntu-2404-golden.qcow2`

---

## Ubuntu 24.04: ISO + Autoinstall + Packer

For full control over partitioning, filesystem layout, and the installation process itself.

### Packer Template (ISO Source)

```hcl
variable "ubuntu_iso_url" {
  type    = string
  default = "https://releases.ubuntu.com/24.04/ubuntu-24.04-live-server-amd64.iso"
}

variable "ubuntu_iso_checksum" {
  type    = string
  default = "file:https://releases.ubuntu.com/24.04/SHA256SUMS"
}

source "qemu" "ubuntu-2404-iso" {
  iso_url           = var.ubuntu_iso_url
  iso_checksum      = var.ubuntu_iso_checksum
  disk_size         = "30G"
  format            = "qcow2"
  accelerator       = "kvm"
  vm_name           = "ubuntu-2404-golden.qcow2"
  net_device        = "virtio-net"
  disk_interface    = "virtio"
  headless          = true
  ssh_username      = "admin"
  ssh_password      = "packer"
  ssh_timeout       = "30m"
  shutdown_command   = "sudo shutdown -h now"
  boot_wait         = "5s"
  boot_command = [
    "c<wait>",
    "linux /casper/vmlinuz --- autoinstall ds='nocloud-net;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/'<enter><wait>",
    "initrd /casper/initrd<enter><wait>",
    "boot<enter>"
  ]
  http_directory    = "http"
  memory            = 4096
  cpus              = 2
}

build {
  sources = ["source.qemu.ubuntu-2404-iso"]

  provisioner "shell" {
    scripts = [
      "scripts/base.sh",
      "scripts/qemu-guest-agent.sh",
      "scripts/hardening.sh",
      "scripts/seal.sh"
    ]
    execute_command = "sudo bash '{{ .Path }}'"
  }
}
```

### Autoinstall Config (http/user-data)

```yaml
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
  network:
    network:
      version: 2
      ethernets:
        id0:
          match:
            driver: virtio*
          dhcp4: true
  storage:
    layout:
      name: lvm
      sizing-policy: all
  identity:
    hostname: packer-build
    username: admin
    password: "$6$rounds=4096$randomsalt$hashedpassword"
  ssh:
    install-server: true
    allow-pw: true
  packages:
    - qemu-guest-agent
    - openssh-server
  late-commands:
    - curtin in-target -- systemctl enable qemu-guest-agent
```

You'll also need an empty `http/meta-data` file:

```bash
touch http/meta-data
```

---

## Windows Server 2022: ISO + Autounattend + Packer

Windows golden images require an ISO install — there are no vendor cloud images. Packer handles the full lifecycle: mount the ISO, inject drivers, run the unattended installer, execute post-install scripts, and sysprep.

### Directory Structure

```
windows-2022/
├── windows-2022.pkr.hcl
├── drivers/
│   └── virtio-win.iso          # Download from Red Hat (or Fedora)
├── scripts/
│   ├── install-virtio-ga.ps1
│   ├── enable-winrm.ps1
│   ├── configure-base.ps1
│   ├── install-updates.ps1
│   └── seal.ps1
└── answer_files/
    └── autounattend.xml
```

### Download VirtIO Drivers

```bash
curl -L -o drivers/virtio-win.iso \
  https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso
```

### Packer Template

```hcl
packer {
  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

variable "windows_iso_path" {
  type    = string
  default = "./isos/windows-server-2022.iso"
}

variable "virtio_iso_path" {
  type    = string
  default = "./drivers/virtio-win.iso"
}

source "qemu" "windows-2022" {
  iso_url          = var.windows_iso_path
  iso_checksum     = "none"
  disk_size        = "60G"
  format           = "qcow2"
  accelerator      = "kvm"
  vm_name          = "win2022-golden.qcow2"
  net_device       = "virtio-net"
  disk_interface   = "virtio"
  headless         = true
  memory           = 8192
  cpus             = 4

  # Communicate via WinRM, not SSH
  communicator     = "winrm"
  winrm_username   = "Administrator"
  winrm_password   = "Packer@Build!"
  winrm_timeout    = "60m"
  winrm_use_ssl    = false

  # Mount the VirtIO driver ISO as a second CD-ROM
  cd_files = []
  qemuargs = [
    ["-drive", "file=${var.virtio_iso_path},media=cdrom,index=1"],
    ["-drive", "file=answer_files/autounattend.xml,format=raw,media=cdrom,index=2"],
  ]

  # Use a floppy for the answer file (more reliable for Windows)
  floppy_files = [
    "answer_files/autounattend.xml"
  ]

  shutdown_command  = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer build complete\""
  shutdown_timeout  = "30m"
}

build {
  sources = ["source.qemu.windows-2022"]

  provisioner "powershell" {
    script = "scripts/install-virtio-ga.ps1"
  }

  provisioner "powershell" {
    script = "scripts/configure-base.ps1"
  }

  provisioner "powershell" {
    script = "scripts/install-updates.ps1"
  }

  provisioner "powershell" {
    script = "scripts/seal.ps1"
  }
}
```

### Autounattend.xml (Key Sections)

```xml
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE">
      <SetupUILanguage>
        <UILanguage>en-US</UILanguage>
      </SetupUILanguage>
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup">
      <DiskConfiguration>
        <Disk wcm:action="add">
          <CreatePartitions>
            <CreatePartition wcm:action="add">
              <Order>1</Order>
              <Size>500</Size>
              <Type>EFI</Type>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>2</Order>
              <Extend>true</Extend>
              <Type>Primary</Type>
            </CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add">
              <Order>1</Order>
              <PartitionID>1</PartitionID>
              <Format>FAT32</Format>
              <Label>EFI</Label>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>2</Order>
              <PartitionID>2</PartitionID>
              <Format>NTFS</Format>
              <Label>Windows</Label>
              <Letter>C</Letter>
            </ModifyPartition>
          </ModifyPartitions>
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
        </Disk>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>2</PartitionID>
          </InstallTo>
        </OSImage>
      </ImageInstall>
      <!-- Load VirtIO storage driver from the driver CD -->
      <DriverPaths>
        <PathAndCredentials wcm:action="add" wcm:keyValue="1">
          <Path>E:\viostor\w2k22\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="2">
          <Path>E:\NetKVM\w2k22\amd64</Path>
        </PathAndCredentials>
      </DriverPaths>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup">
      <ComputerName>*</ComputerName>
      <TimeZone>UTC</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value>Packer@Build!</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>Administrator</Username>
        <Password>
          <Value>Packer@Build!</Value>
          <PlainText>true</PlainText>
        </Password>
        <LogonCount>3</LogonCount>
      </AutoLogon>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>powershell -ExecutionPolicy Bypass -File A:\enable-winrm.ps1</CommandLine>
          <Description>Enable WinRM</Description>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
```

### PowerShell Scripts

**scripts/enable-winrm.ps1**

```powershell
# Enable WinRM for Packer communication
Set-ExecutionPolicy Bypass -Scope LocalMachine -Force

winrm quickconfig -force
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/service/auth '@{Basic="true"}'

# Open firewall
netsh advfirewall firewall add rule name="WinRM-HTTP" dir=in localport=5985 protocol=TCP action=allow

# Ensure the service starts automatically
Set-Service -Name WinRM -StartupType Automatic
Restart-Service WinRM
```

**scripts/install-virtio-ga.ps1**

```powershell
# Install VirtIO guest tools + QEMU Guest Agent from the driver CD
$virtioMsi = Get-ChildItem -Path D:\,E:\,F:\ -Filter "virtio-win-gt-x64.msi" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1

if ($virtioMsi) {
    Start-Process msiexec.exe -ArgumentList "/i `"$($virtioMsi.FullName)`" /quiet /norestart" -Wait -NoNewWindow
    Write-Host "VirtIO guest tools installed from $($virtioMsi.FullName)"
} else {
    Write-Warning "VirtIO guest tools MSI not found — install manually"
}

# Verify QEMU GA service exists
Get-Service "QEMU-GA" -ErrorAction SilentlyContinue
```

**scripts/configure-base.ps1**

```powershell
# Enable RDP
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"

# Disable Server Manager at logon
Get-ScheduledTask -TaskName ServerManager | Disable-ScheduledTask

# Set power plan to High Performance
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c

# Add your organisation's base configuration here
```

**scripts/install-updates.ps1**

```powershell
# Install Windows updates (requires PSWindowsUpdate module or WSUS)
Install-PackageProvider -Name NuGet -Force
Install-Module -Name PSWindowsUpdate -Force -Confirm:$false
Import-Module PSWindowsUpdate

Get-WindowsUpdate -Install -AcceptAll -AutoReboot:$false

Write-Host "Windows updates installed"
```

**scripts/seal.ps1**

```powershell
# Disable WinRM (it was only needed for Packer communication)
Stop-Service WinRM
Set-Service -Name WinRM -StartupType Disabled
netsh advfirewall firewall delete rule name="WinRM-HTTP"

# Clear auto-logon credentials
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name AutoAdminLogon -ErrorAction SilentlyContinue
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name DefaultPassword -ErrorAction SilentlyContinue

# Clean up temp files
Remove-Item -Recurse -Force $env:TEMP\* -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force C:\Windows\Temp\* -ErrorAction SilentlyContinue

# Run sysprep
& "$env:SystemRoot\System32\Sysprep\sysprep.exe" /generalize /oobe /shutdown /quiet
```

### Build

```bash
cd windows-2022/
packer init .
packer build .
```

Output: `output-windows-2022/win2022-golden.qcow2`

Build time: expect 30–60 minutes depending on Windows Update volume.

---

## Importing Packer Output into OpenShift

Once Packer produces the qcow2, you need to get it into the cluster. Two main paths:

### Option A: Push to a Container Registry

Wrap the qcow2 in a container image for registry-based distribution:

```dockerfile
FROM scratch
ADD --chown=107:107 ubuntu-2404-golden.qcow2 /disk/
```

```bash
podman build -t registry.example.com/golden/ubuntu-2404:v2024.04.16 .
podman push registry.example.com/golden/ubuntu-2404:v2024.04.16
podman tag registry.example.com/golden/ubuntu-2404:v2024.04.16 registry.example.com/golden/ubuntu-2404:latest
podman push registry.example.com/golden/ubuntu-2404:latest
```

Then import into OpenShift via CDI:

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ubuntu-2404-golden
  namespace: golden-images
spec:
  source:
    registry:
      url: "docker://registry.example.com/golden/ubuntu-2404:latest"
  storage:
    resources:
      requests:
        storage: 30Gi
```

### Option B: Host on HTTP/S3 and Import Directly

Upload the qcow2 to an HTTP server, S3 bucket, or artefact repository:

```bash
# Example: upload to an S3-compatible store
aws s3 cp output-ubuntu-2404/ubuntu-2404-golden.qcow2 s3://golden-images/ubuntu-2404/latest.qcow2
```

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ubuntu-2404-golden
  namespace: golden-images
spec:
  source:
    http:
      url: "https://artefacts.example.com/golden-images/ubuntu-2404/latest.qcow2"
  storage:
    resources:
      requests:
        storage: 30Gi
```

### Option C: Direct Upload via virtctl

For one-off imports from a workstation:

```bash
virtctl image-upload dv ubuntu-2404-golden \
  --size=30Gi \
  --image-path=./output-ubuntu-2404/ubuntu-2404-golden.qcow2 \
  --storage-class=ocs-storagecluster-ceph-rbd \
  --uploadproxy-url=https://cdi-uploadproxy-openshift-cnv.apps.cluster.example.com \
  --insecure \
  --namespace=golden-images
```

After import, create a DataSource so VMs can clone from the image:

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

---

## Versioning Strategy

Packer images should be versioned. A naming convention that works well:

```
registry.example.com/golden/<os>:<YYYY.MM.DD>     # dated build
registry.example.com/golden/<os>:latest            # most recent
registry.example.com/golden/<os>:<git-short-sha>   # traceable to source
```

The `DataImportCron` pattern from the [golden images guide](01-golden-images.md) pairs well here — point it at the `:latest` tag, and new VMs automatically pick up the most recent Packer build.

---

## Tips for VMware Admins

| VMware Habit | Packer Equivalent |
|---|---|
| Build VM manually, then convert to template | Define everything in HCL — `packer build` produces the template |
| "I'll just update the template in place" | Rebuild from source — images are immutable artefacts |
| Store templates on a datastore | Push to a registry or artefact server — images are portable |
| Customization Spec for per-VM config | Still use cloud-init/sysprep at deploy time — Packer builds the *base*, not the per-instance config |
| One golden image per team/use case | Compose Packer templates — shared base + per-team provisioner scripts |

### What Packer Replaces

Packer replaces the **manual build-and-seal** process. It does not replace:

- **cloud-init / sysprep** — per-VM customisation still happens at deploy time
- **DataImportCron** — still needed to pull updated images into the cluster
- **Instancetypes / Preferences** — still define compute and OS defaults separately

### When to Use Packer vs. Other Methods

| Scenario | Use Packer? |
|---|---|
| Repeatable, auditable image builds | Yes — this is what Packer was built for |
| One-off image for a quick test | No — use a cloud image (Method 1) or ISO (Method 2) |
| Windows golden images | Yes — handles the full autounattend + driver injection + sysprep cycle |
| Images that must pass compliance audits | Yes — the HCL source is reviewable and the build is reproducible |
| Team already uses Ansible for config management | Yes — Packer has an Ansible provisioner, use your existing playbooks |
