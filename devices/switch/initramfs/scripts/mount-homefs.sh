#!/bin/sh
#
# Assemble and mount homefs from ext4 parts (dynamically expandable)
#

IMAGE_DIR="${1:-/sd/linux_img/switch-linux}"
HOMEFS_MOUNTPOINT="${2:-/rootfs/home}"

# Loop devices for homefs start at 10 to avoid conflict with rootfs
LOOP_START=10

log() {
    echo "[mount-homefs] $1"
}

error() {
    echo "[mount-homefs] ERROR: $1"
    return 1
}

HOMEFS_DIR="$IMAGE_DIR/homefs"

# Create homefs directory if it doesn't exist
mkdir -p "$HOMEFS_DIR"

# Find parts
PARTS=$(ls "$HOMEFS_DIR"/*.part* 2>/dev/null | sort)
PART_COUNT=$(echo "$PARTS" | wc -w)

# Create initial homefs if none exists
if [ "$PART_COUNT" -eq 0 ]; then
    log "No homefs found, creating initial partition..."
    FIRST_PART="$HOMEFS_DIR/homefs.ext4.part000"

    # Create 1.9GB sparse file (within FAT32 4GB limit)
    dd if=/dev/zero of="$FIRST_PART" bs=1M count=0 seek=1900 2>/dev/null

    # Note: Partition should be pre-formatted with mkfs.ext4
    # busybox doesn't have mkfs.ext4, so we skip formatting here
    # The partition will need to be formatted on first boot or pre-created

    PARTS="$FIRST_PART"
    PART_COUNT=1
fi

log "Found $PART_COUNT homefs part(s)"

# Create mountpoint
mkdir -p "$HOMEFS_MOUNTPOINT"

if [ "$PART_COUNT" -eq 1 ]; then
    # Single part - direct losetup mount
    SINGLE_PART=$(echo "$PARTS" | head -1)
    log "Single part mode: $SINGLE_PART"

    /sbin/losetup /dev/loop$LOOP_START "$SINGLE_PART"
    HOMEFS_DEV="/dev/loop$LOOP_START"
else
    # Multiple parts - assemble with device-mapper
    log "Multi-part mode: assembling $PART_COUNT parts"

    LOOP_NUM=$LOOP_START
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

        log "  Part $((LOOP_NUM - LOOP_START)): $PART ($SIZE_SECTORS sectors)"
    done

    # Create combined device
    echo "$DM_TABLE" | /sbin/dmsetup create homefs-combined
    HOMEFS_DEV="/dev/mapper/homefs-combined"
fi

# Mount ext4
log "Mounting ext4 from $HOMEFS_DEV..."
mount -t ext4 -o rw,noatime "$HOMEFS_DEV" "$HOMEFS_MOUNTPOINT"
if [ $? -ne 0 ]; then
    error "Failed to mount homefs!"
    return 1
fi

log "Homefs mounted at $HOMEFS_MOUNTPOINT"

# Save info for expansion daemon (will be used after switch_root)
mkdir -p /rootfs/run
cat > /rootfs/run/homefs-info << EOF
HOMEFS_DIR=$HOMEFS_DIR
LOOP_START=$LOOP_START
PART_COUNT=$PART_COUNT
HOMEFS_DEV=$HOMEFS_DEV
EOF

# Export for other scripts
export HOMEFS_DEV
export HOMEFS_MOUNTPOINT
export HOMEFS_DIR
export PART_COUNT
