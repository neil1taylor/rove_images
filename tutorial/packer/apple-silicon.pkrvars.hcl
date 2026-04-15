# Variable overrides for building on Apple Silicon (M1/M2/M3/M4) Macs.
# Uses aarch64 Fedora Cloud image with HVF hardware acceleration and EFI boot.
#
# Usage:
#   packer build -var-file=apple-silicon.pkrvars.hcl fedora41.pkr.hcl
#
# Note: This produces an aarch64 image. For x86_64 cluster images,
# build on a Linux x86_64 host or in CI with accelerator = "kvm".

cloud_image_url      = "https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/aarch64/images/Fedora-Cloud-Base-Generic-41-1.4.aarch64.qcow2"
cloud_image_checksum = "sha256:085883b42c7e3b980e366a1fe006cd0ff15877f7e6e984426f3c6c67c7cc2faa"
accelerator          = "hvf"
qemu_binary          = "qemu-system-aarch64"
machine_type         = "virt,gic-version=max"
cpu_model            = "host"
efi_boot             = true
efi_firmware_code    = "/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
efi_firmware_vars    = "/opt/homebrew/share/qemu/edk2-arm-vars.fd"
