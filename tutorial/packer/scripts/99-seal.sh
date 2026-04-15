#!/usr/bin/env bash
set -euo pipefail

# Seal the image so every clone boots as a fresh instance.

echo "==> Sealing image for golden template use"

# Remove the Packer build user — cloud-init creates the real user on first boot
userdel -r packer 2>/dev/null || true

# Reset cloud-init so it runs on next boot
cloud-init clean --logs --seed

# Remove SSH host keys — regenerated on first boot
rm -f /etc/ssh/ssh_host_*

# Clear machine-id — systemd regenerates this on boot
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id

# Clear authorized_keys for all users
find /home -name authorized_keys -delete 2>/dev/null || true
rm -f /root/.ssh/authorized_keys

# Clear logs
journalctl --rotate 2>/dev/null || true
journalctl --vacuum-time=1s 2>/dev/null || true
rm -rf /var/log/*.log /var/log/*.old /var/log/anaconda

# Clear temp and caches
rm -rf /tmp/* /var/tmp/*
dnf clean all
rm -rf /var/cache/dnf

# Zero free space for better compression
dd if=/dev/zero of=/EMPTY bs=1M 2>/dev/null || true
rm -f /EMPTY
sync

echo "==> Image sealed"
