#!/bin/sh
#
# Assemble and mount rootfs from squashfs parts (A/B slot aware)
# The slot directory is passed as argument (e.g. /sd/linux_img/<name>/slot/a)
#

SLOT_DIR="${1:-/sd/linux_img/switch-linux/slot/a}"
ROOTFS_MOUNTPOINT="${2:-/rootfs}"

log() {
    echo "[mount-rootfs] $1"
}

error() {
    echo "[mount-rootfs] ERROR: $1"
    return 1
}

# Check slot directory exists
if [ ! -d "$SLOT_DIR" ]; then
    error "Slot directory not found: $SLOT_DIR"
    return 1
fi

# Find parts
PARTS=$(ls "$SLOT_DIR"/rootfs.squashfs.part* 2>/dev/null | sort)
PART_COUNT=$(echo "$PARTS" | wc -w)

if [ "$PART_COUNT" -eq 0 ]; then
    error "No rootfs parts found in $SLOT_DIR"
    return 1
fi

log "Found $PART_COUNT rootfs part(s)"

# Create mountpoint
mkdir -p "$ROOTFS_MOUNTPOINT"

# Loop devices for rootfs start at 0
LOOP_START=0

if [ "$PART_COUNT" -eq 1 ]; then
    # Single part - direct losetup mount
    SINGLE_PART=$(echo "$PARTS" | head -1)
    log "Single part mode: $SINGLE_PART"

    /sbin/losetup /dev/loop$LOOP_START "$SINGLE_PART"
    ROOTFS_DEV="/dev/loop$LOOP_START"
else
    # Multiple parts - assemble with device-mapper
    log "Multi-part mode: assembling $PART_COUNT parts"

    LOOP_NUM=$LOOP_START
    DM_TABLE=""
    OFFSET=0

    for PART in $PARTS; do
        LOOP_DEV="/dev/loop$LOOP_NUM"
        /sbin/losetup "$LOOP_DEV" "$PART"

        SIZE_BYTES=$(stat -c %s "$PART")
        SIZE_SECTORS=$((SIZE_BYTES / 512))

        if [ -n "$DM_TABLE" ]; then
            DM_TABLE="$DM_TABLE
"
        fi
        DM_TABLE="${DM_TABLE}${OFFSET} ${SIZE_SECTORS} linear ${LOOP_DEV} 0"

        OFFSET=$((OFFSET + SIZE_SECTORS))
        LOOP_NUM=$((LOOP_NUM + 1))

        log "  Part $((LOOP_NUM - LOOP_START)): $PART ($SIZE_SECTORS sectors)"
    done

    # Create combined device
    echo "$DM_TABLE" | /sbin/dmsetup create rootfs-combined
    ROOTFS_DEV="/dev/mapper/rootfs-combined"
fi

# Mount squashfs read-only
log "Mounting squashfs from $ROOTFS_DEV..."
mount -t squashfs -o ro "$ROOTFS_DEV" "$ROOTFS_MOUNTPOINT"
if [ $? -ne 0 ]; then
    error "Failed to mount squashfs!"
    return 1
fi

log "Rootfs mounted at $ROOTFS_MOUNTPOINT"

# Export for other scripts
export ROOTFS_DEV
export ROOTFS_MOUNTPOINT
export SLOT_DIR