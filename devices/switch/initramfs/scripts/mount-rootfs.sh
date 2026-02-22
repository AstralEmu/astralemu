#!/bin/sh
#
# Assemble and mount rootfs from squashfs parts
#

IMAGE_DIR="${1:-/sd/linux_img/switch-linux}"
ROOTFS_MOUNTPOINT="${2:-/rootfs}"

log() {
    echo "[mount-rootfs] $1"
}

error() {
    echo "[mount-rootfs] ERROR: $1"
    return 1
}

ROOTFS_DIR="$IMAGE_DIR/rootfs"

# Check rootfs directory exists
if [ ! -d "$ROOTFS_DIR" ]; then
    error "Rootfs directory not found: $ROOTFS_DIR"
    return 1
fi

# Find parts
PARTS=$(ls "$ROOTFS_DIR"/*.part* 2>/dev/null | sort)
PART_COUNT=$(echo "$PARTS" | wc -w)

if [ "$PART_COUNT" -eq 0 ]; then
    error "No rootfs parts found in $ROOTFS_DIR"
    return 1
fi

log "Found $PART_COUNT rootfs part(s)"

# Create mountpoint
mkdir -p "$ROOTFS_MOUNTPOINT"

if [ "$PART_COUNT" -eq 1 ]; then
    # Single part - direct losetup mount
    SINGLE_PART=$(echo "$PARTS" | head -1)
    log "Single part mode: $SINGLE_PART"

    /sbin/losetup /dev/loop0 "$SINGLE_PART"
    ROOTFS_DEV="/dev/loop0"
else
    # Multiple parts - assemble with device-mapper
    log "Multi-part mode: assembling $PART_COUNT parts"

    LOOP_NUM=0
    DM_TABLE=""
    OFFSET=0

    for PART in $PARTS; do
        LOOP_DEV="/dev/loop$LOOP_NUM"
        /sbin/losetup "$LOOP_DEV" "$PART"

        # Get size in sectors (512 bytes each)
        SIZE_BYTES=$(stat -c %s "$PART")
        SIZE_SECTORS=$((SIZE_BYTES / 512))

        # Build dm-linear table
        if [ -n "$DM_TABLE" ]; then
            DM_TABLE="$DM_TABLE
"
        fi
        DM_TABLE="${DM_TABLE}${OFFSET} ${SIZE_SECTORS} linear ${LOOP_DEV} 0"

        OFFSET=$((OFFSET + SIZE_SECTORS))
        LOOP_NUM=$((LOOP_NUM + 1))

        log "  Part $LOOP_NUM: $PART ($SIZE_SECTORS sectors)"
    done

    # Create combined device
    echo "$DM_TABLE" | /sbin/dmsetup create rootfs-combined
    ROOTFS_DEV="/dev/mapper/rootfs-combined"
fi

# Mount squashfs
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
