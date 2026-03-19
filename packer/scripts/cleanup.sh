#!/bin/bash
set -euo pipefail
 
echo "=== Image cleanup for capture ==="
 
# Remove SSH host keys — new ones generated on first boot of each VM
rm -f /etc/ssh/ssh_host_*
 
# Clear cloud-init state so it runs on first boot of each deployed VM
cloud-init clean --logs
 
# Remove package manager cache
dnf clean all
 
# Remove shell history
history -c
cat /dev/null > ~/.bash_history
 
# Remove temporary files
rm -rf /tmp/* /var/tmp/*
 
# Remove machine ID — regenerated on first boot
# This is critical — without it, all VMs cloned from this image
# share the same machine ID which causes systemd and other services
# to behave unexpectedly
# Remove machine ID — regenerated on first boot
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
mkdir -p /var/lib/dbus
ln -s /etc/machine-id /var/lib/dbus/machine-id
 
# Sync filesystem
sync
 
echo "=== Cleanup complete. Ready for image capture. ==="
