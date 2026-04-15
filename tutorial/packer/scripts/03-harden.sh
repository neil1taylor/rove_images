#!/usr/bin/env bash
set -euo pipefail

echo "==> Applying basic hardening"

# Disable root SSH login — cloud-init creates the default user
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config

# Disable password authentication — SSH keys only
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

# Lock root password
passwd -l root

echo "==> Hardening complete"
