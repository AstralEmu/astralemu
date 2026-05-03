#!/bin/bash
set -e

echo "=== AstralEmu first-boot setup ==="

# Mount setup ISO
mkdir -p /mnt/setup
MOUNTED=false
for dev in /dev/vdc /dev/sr0 /dev/sr1 /dev/cdrom; do
    if [ -b "$dev" ]; then
        if mount -o ro "$dev" /mnt/setup 2>/dev/null; then
            MOUNTED=true
            break
        fi
    fi
done

if [ "$MOUNTED" = false ]; then
    echo "ERROR: Could not mount setup ISO"
    exit 1
fi

# Copy setupfiles
mkdir -p /etc/setupfiles
cp -r /mnt/setup/setupfiles/* /etc/setupfiles/ 2>/dev/null || true

# Execute setup
if [ -x /mnt/setup/setup ]; then
    /mnt/setup/setup 2>&1 | tee /var/log/astralemu-setup.log
else
    echo "ERROR: /mnt/setup/setup not found!"
    umount /mnt/setup || true
    exit 1
fi

# Cleanup
umount /mnt/setup || true

# Poweroff after setup
poweroff
