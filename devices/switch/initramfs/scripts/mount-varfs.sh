#!/bin/sh
#
# Assemble and mount /var (persistent ext4, replaces homefs)
# Uses same dm-linear expansion mechanism as the old homefs
#

VARFS_DIR="${1:-/sd/linux_img/switch-linux/var}"
VARFS_MOUNTPOINT="${2:-/rootfs/var}"

# Loop devices for /var start at 10 to avoid conflict with rootfs
LOOP_START=10

log() {
    echo "[mount-varfs] $1"
}

error() {
    echo "[mount-varfs] ERROR: $1"
    return 1
}

# Check varfs directory exists
if [ ! -d "$VARFS_DIR" ]; then
    error "Varfs directory not found: $VARFS_DIR"
    return 1
fi

# Find parts
PARTS=$(ls "$VARFS_DIR"/var.ext4.part* 2>/dev/null | sort)
PART_COUNT=$(echo "$PARTS" | wc -w)

if [ "$PART_COUNT" -eq 0 ]; then
    error "No /var partition parts found! Cannot boot without persistent /var"
    return 1
fi

log "Found $PART_COUNT varfs part(s)"

# Create mountpoint
mkdir -p "$VARFS_MOUNTPOINT"

if [ "$PART_COUNT" -eq 1 ]; then
    # Single part - direct losetup mount
    SINGLE_PART=$(echo "$PARTS" | head -1)
    log "Single part mode: $SINGLE_PART"

    /sbin/losetup /dev/loop$LOOP_START "$SINGLE_PART"
    VARFS_DEV="/dev/loop$LOOP_START"
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

    echo "$DM_TABLE" | /sbin/dmsetup create varfs-combined
    VARFS_DEV="/dev/mapper/varfs-combined"
fi

# Run e2fsck before mounting (repair journal replay, fix minor errors)
log "Running e2fsck on /var..."
if command -v e2fsck >/dev/null 2>&1; then
    e2fsck -p "$VARFS_DEV" 2>/dev/null
    e2fsck_rc=$?
    if [ $e2fsck_rc -gt 1 ]; then
        log "e2fsck returned $e2fsck_rc, attempting forced repair..."
        e2fsck -y "$VARFS_DEV" 2>/dev/null || true
    fi
else
    log "e2fsck not available, skipping filesystem check"
fi

# Mount ext4
log "Mounting ext4 from $VARFS_DEV..."
mount -t ext4 -o rw,noatime "$VARFS_DEV" "$VARFS_MOUNTPOINT"
if [ $? -ne 0 ]; then
    error "Failed to mount /var!"
    return 1
fi

log "/var mounted at $VARFS_MOUNTPOINT"

# Save info for expansion daemon (used after switch_root)
mkdir -p "$VARFS_MOUNTPOINT/run" 2>/dev/null || true
cat > /rootfs/run/varfs-info << EOF
VARFS_DIR=$VARFS_DIR
LOOP_START=$LOOP_START
PART_COUNT=$PART_COUNT
VARFS_DEV=$VARFS_DEV
EOF

# Export for other scripts
export VARFS_DEV
export VARFS_MOUNTPOINT
export VARFS_DIR
export PART_COUNT