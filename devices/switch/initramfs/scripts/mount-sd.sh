#!/bin/sh
#
# Mount SD card (FAT32 partition)
#

SD_MOUNTPOINT="${1:-/sd}"

log() {
    echo "[mount-sd] $1"
}

error() {
    echo "[mount-sd] ERROR: $1"
    return 1
}

# Wait for SD card device
log "Waiting for SD card..."
SD_DEV=""
for i in $(seq 1 30); do
    # Try common SD card device names
    for dev in /dev/mmcblk0p1 /dev/mmcblk1p1 /dev/sda1; do
        if [ -b "$dev" ]; then
            SD_DEV="$dev"
            break 2
        fi
    done
    sleep 0.2
done

if [ -z "$SD_DEV" ]; then
    error "SD card not found after 6 seconds!"
    return 1
fi

log "Found SD card: $SD_DEV"

# Create mountpoint
mkdir -p "$SD_MOUNTPOINT"

# Mount as FAT32 with UTF-8 support
log "Mounting SD card..."
mount -t vfat -o rw,utf8,fmask=0022,dmask=0022 "$SD_DEV" "$SD_MOUNTPOINT"
if [ $? -ne 0 ]; then
    error "Failed to mount SD card!"
    return 1
fi

log "SD card mounted at $SD_MOUNTPOINT"

# Export device for other scripts
export SD_DEV
export SD_MOUNTPOINT
