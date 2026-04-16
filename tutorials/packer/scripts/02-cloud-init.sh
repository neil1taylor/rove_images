#!/usr/bin/env bash
set -euo pipefail

echo "==> Configuring cloud-init for OCP Virtualization (NoCloud datasource)"

cat > /etc/cloud/cloud.cfg.d/99-ocp-virt.cfg <<'CLOUD'
# OCP Virtualization provides user-data via NoCloud (cloudInitNoCloud volume).
# Disable datasources that will never be present and slow down boot.
datasource_list: [NoCloud, None]

system_info:
  default_user:
    name: fedora
    lock_passwd: true
    gecos: Fedora
    groups: [wheel, adm, systemd-journal]
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    shell: /bin/bash

# Grow the root filesystem on first boot to fill the PVC
growpart:
  mode: auto
  devices: ['/']

# Reset the hostname so cloud-init can set it from user-data
preserve_hostname: false
CLOUD

echo "==> cloud-init configured"
