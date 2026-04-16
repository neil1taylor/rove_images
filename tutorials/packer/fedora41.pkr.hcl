packer {
  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

# ──────────────────────────────────────────────
# Variables
# ──────────────────────────────────────────────

variable "cloud_image_url" {
  type    = string
  default = "https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2"
}

variable "cloud_image_checksum" {
  type    = string
  default = "sha256:6205ae0c524b4d1816dbd3573ce29b5c44ed26c9fbc874fbe48c41c89dd0bac2"
}

variable "disk_size" {
  type    = string
  default = "10G"
}

variable "memory" {
  type    = number
  default = 2048
}

variable "cpus" {
  type    = number
  default = 2
}

variable "ssh_password" {
  type      = string
  default   = "packer"
  sensitive = true
}

variable "output_directory" {
  type    = string
  default = "output"
}

variable "accelerator" {
  type        = string
  default     = "hvf"
  description = "QEMU accelerator: hvf (macOS Intel), kvm (Linux), tcg (software emulation)"
}

variable "qemu_binary" {
  type        = string
  default     = "qemu-system-x86_64"
  description = "QEMU binary: qemu-system-x86_64 or qemu-system-aarch64"
}

variable "machine_type" {
  type        = string
  default     = ""
  description = "QEMU machine type. Leave empty for x86_64 default. Set to 'virt,gic-version=max' for aarch64."
}

variable "efi_boot" {
  type        = bool
  default     = false
  description = "Enable EFI boot. Required for aarch64, optional for x86_64."
}

variable "efi_firmware_code" {
  type        = string
  default     = ""
  description = "Path to EFI firmware CODE file (e.g. edk2-aarch64-code.fd)."
}

variable "efi_firmware_vars" {
  type        = string
  default     = ""
  description = "Path to EFI firmware VARS file (e.g. edk2-arm-vars.fd)."
}

variable "cpu_model" {
  type        = string
  default     = ""
  description = "CPU model. Set to 'host' for HVF/KVM acceleration. Leave empty for default."
}

# ──────────────────────────────────────────────
# Source: QEMU builder (cloud image customisation)
# ──────────────────────────────────────────────

source "qemu" "fedora41" {
  # Boot from the cloud image directly — no ISO, no installer, no GRUB editing.
  # Packer copies the image, boots it, SSHes in, runs provisioners, and outputs
  # the modified qcow2.
  iso_url      = var.cloud_image_url
  iso_checksum = var.cloud_image_checksum
  disk_image   = true

  output_directory = var.output_directory
  vm_name          = "fedora41-golden.qcow2"

  format         = "qcow2"
  disk_size      = var.disk_size
  disk_interface = "virtio"
  net_device     = "virtio-net"
  memory         = var.memory
  cpus           = var.cpus
  accelerator    = var.accelerator
  qemu_binary    = var.qemu_binary
  machine_type   = var.machine_type != "" ? var.machine_type : null
  cpu_model      = var.cpu_model != "" ? var.cpu_model : null

  # EFI boot — required for aarch64
  efi_boot          = var.efi_boot
  efi_firmware_code = var.efi_firmware_code != "" ? var.efi_firmware_code : null
  efi_firmware_vars = var.efi_firmware_vars != "" ? var.efi_firmware_vars : null

  headless = true

  # Cloud-init user-data: create a 'packer' user with password auth for SSH.
  # This is injected via a secondary CD (NoCloud datasource).
  cd_content = {
    "meta-data" = ""
    "user-data" = <<-USERDATA
      #cloud-config
      users:
        - name: packer
          sudo: ALL=(ALL) NOPASSWD:ALL
          shell: /bin/bash
          lock_passwd: false
          plain_text_passwd: ${var.ssh_password}
      ssh_pwauth: true
      USERDATA
  }
  cd_label = "cidata"

  # No boot_command needed — the cloud image boots directly with cloud-init.
  boot_wait    = "30s"
  boot_command = []

  # SSH connection — matches cloud-init user config above
  communicator    = "ssh"
  ssh_username    = "packer"
  ssh_password    = var.ssh_password
  ssh_timeout     = "10m"
  shutdown_command = "sudo shutdown -P now"
}

# ──────────────────────────────────────────────
# Build
# ──────────────────────────────────────────────

build {
  sources = ["source.qemu.fedora41"]

  # Phase 1: Base hardening and packages
  provisioner "shell" {
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    scripts = [
      "scripts/01-packages.sh",
      "scripts/02-cloud-init.sh",
      "scripts/03-harden.sh",
      "scripts/99-seal.sh",
    ]
  }

  # Compress the output image
  post-processor "shell-local" {
    inline = [
      "qemu-img convert -c -O qcow2 ${var.output_directory}/fedora41-golden.qcow2 ${var.output_directory}/fedora41-golden-compressed.qcow2",
      "mv ${var.output_directory}/fedora41-golden-compressed.qcow2 ${var.output_directory}/fedora41-golden.qcow2",
      "echo '==> Image ready: ${var.output_directory}/fedora41-golden.qcow2'",
    ]
  }
}
