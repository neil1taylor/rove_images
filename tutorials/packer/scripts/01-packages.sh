#!/usr/bin/env bash
set -euo pipefail

echo "==> Updating packages"
dnf -y update

echo "==> Installing additional packages for OCP Virtualization"
dnf -y install \
  cloud-init \
  cloud-utils-growpart \
  qemu-guest-agent \
  bash-completion \
  vim-minimal

echo "==> Cleaning dnf cache"
dnf clean all
