#!/bin/bash
#
# /var Dynamic Expansion Daemon
# Monitors /var space and expands by adding new partition files
# Replaces the old homefs-expand daemon — now operates on /var
#

# No set -e — we handle errors explicitly

VARFS_INFO="/run/varfs-info"
MIN_FREE_MB=1900   # Minimum free space before expanding (1.9 GB)
PART_SIZE_MB=1900  # Size of new partitions (1.9 GB, under FAT32 4GB limit)
CHECK_INTERVAL=30  # Check every 30 seconds

log() {
    echo "[varfs-expand] $(date '+%Y-%m-%d %H:%M:%S') $1"
    logger -t varfs-expand "$1"
}

error() {
    log "ERROR: $1"
}

# Load /var filesystem configuration
if [ ! -f "$VARFS_INFO" ]; then
    error "Varfs info file not found: $VARFS_INFO"
    exit 1
fi

source "$VARFS_INFO"

log "Starting /var expansion daemon"
log "  VARFS_DIR: $VARFS_DIR"
log "  PART_COUNT: $PART_COUNT"
log "  VARFS_DEV: $VARFS_DEV"

# Track current state
CURRENT_LOOP=$((LOOP_START + PART_COUNT))
CURRENT_PART_COUNT=$PART_COUNT

# Get current dm offset (if using device-mapper)
if [[ "$VARFS_DEV" == "/dev/mapper/"* ]]; then
    DM_NAME=$(basename "$VARFS_DEV")
    DM_OFFSET=$(dmsetup table "$DM_NAME" 2>/dev/null | tail -1 | awk '{print $1 + $2}')
else
    DM_OFFSET=0
fi

while true; do
    # Check free space on /var
    FREE_KB=$(df --output=avail /var 2>/dev/null | tail -1 | tr -d ' ')
    if [ -z "$FREE_KB" ]; then
        error "Could not read /var free space"
        sleep $CHECK_INTERVAL
        continue
    fi
    FREE_MB=$((FREE_KB / 1024))

    if [ "$FREE_MB" -lt "$MIN_FREE_MB" ]; then
        log "Low space detected: ${FREE_MB}MB free (threshold: ${MIN_FREE_MB}MB)"

        # Calculate next part number (3 digits, zero-padded)
        NEXT_PART_NUM=$(printf "%03d" $CURRENT_PART_COUNT)
        NEW_PART="$VARFS_DIR/var.ext4.part$NEXT_PART_NUM"

        log "Creating new partition: $NEW_PART"

        # Create new file (write full blocks on FAT32 — no sparse files)
        dd if=/dev/zero of="$NEW_PART" bs=1M count="$PART_SIZE_MB" 2>/dev/null
        if [ $? -ne 0 ]; then
            error "Failed to create partition file"
            sleep $CHECK_INTERVAL
            continue
        fi

        # Attach new loop device
        NEW_LOOP="/dev/loop$CURRENT_LOOP"
        if ! losetup "$NEW_LOOP" "$NEW_PART"; then
            error "Failed to attach loop device $NEW_LOOP"
            rm -f "$NEW_PART"
            sleep $CHECK_INTERVAL
            continue
        fi

        # Calculate new partition size in sectors
        NEW_SIZE_SECTORS=$((PART_SIZE_MB * 1024 * 1024 / 512))

        if [[ "$VARFS_DEV" == "/dev/mapper/"* ]]; then
            # Already using device-mapper — extend existing device
            DM_NAME=$(basename "$VARFS_DEV")

            # Suspend, reload, resume (proper dmsetup sequence)
            log "Extending device-mapper: adding segment at offset $DM_OFFSET"
            dmsetup suspend "$DM_NAME"

            # Get current table and add new segment
            CURRENT_TABLE=$(dmsetup table "$DM_NAME")
            NEW_LINE="$DM_OFFSET $NEW_SIZE_SECTORS linear $NEW_LOOP 0"
            echo -e "${CURRENT_TABLE}\n${NEW_LINE}" | dmsetup reload "$DM_NAME"

            dmsetup resume "$DM_NAME"

            DM_OFFSET=$((DM_OFFSET + NEW_SIZE_SECTORS))

        else
            # Convert from single loop device to device-mapper
            CURRENT_LOOP_DEV="$VARFS_DEV"
            CURRENT_SIZE_SECTORS=$(blockdev --getsz "$CURRENT_LOOP_DEV" 2>/dev/null)
            if [ -z "$CURRENT_SIZE_SECTORS" ]; then
                error "Could not read size of $CURRENT_LOOP_DEV"
                losetup -d "$NEW_LOOP" 2>/dev/null || true
                rm -f "$NEW_PART"
                sleep $CHECK_INTERVAL
                continue
            fi

            log "Converting to device-mapper"

            # Unmount /var
            if ! umount /var; then
                error "Failed to unmount /var for conversion"
                losetup -d "$NEW_LOOP" 2>/dev/null || true
                rm -f "$NEW_PART"
                sleep $CHECK_INTERVAL
                continue
            fi

            # Run e2fsck before remounting
            log "Running e2fsck on $CURRENT_LOOP_DEV..."
            e2fsck -p "$CURRENT_LOOP_DEV" 2>/dev/null || true

            # Create device-mapper with both devices
            DM_TABLE="0 $CURRENT_SIZE_SECTORS linear $CURRENT_LOOP_DEV 0
$CURRENT_SIZE_SECTORS $NEW_SIZE_SECTORS linear $NEW_LOOP 0"

            if ! echo "$DM_TABLE" | dmsetup create varfs-combined; then
                error "Failed to create device-mapper device"
                # Try to remount the old way
                mount -t ext4 -o rw,noatime "$CURRENT_LOOP_DEV" /var 2>/dev/null || true
                losetup -d "$NEW_LOOP" 2>/dev/null || true
                rm -f "$NEW_PART"
                sleep $CHECK_INTERVAL
                continue
            fi

            # Remount
            if ! mount -t ext4 -o rw,noatime /dev/mapper/varfs-combined /var; then
                error "Failed to remount /var after conversion"
                dmsetup remove varfs-combined 2>/dev/null || true
                mount -t ext4 -o rw,noatime "$CURRENT_LOOP_DEV" /var 2>/dev/null || true
                losetup -d "$NEW_LOOP" 2>/dev/null || true
                rm -f "$NEW_PART"
                sleep $CHECK_INTERVAL
                continue
            fi

            VARFS_DEV="/dev/mapper/varfs-combined"
            DM_OFFSET=$((CURRENT_SIZE_SECTORS + NEW_SIZE_SECTORS))
        fi

        # Resize filesystem to use new space
        log "Resizing filesystem on $VARFS_DEV..."
        e2fsck -f -p "$VARFS_DEV" 2>/dev/null || true
        if ! resize2fs "$VARFS_DEV"; then
            error "resize2fs failed!"
            # Filesystem is still usable, just not expanded yet
            # The space will be used on next expansion
        fi

        # Update state
        CURRENT_PART_COUNT=$((CURRENT_PART_COUNT + 1))
        CURRENT_LOOP=$((CURRENT_LOOP + 1))

        # Update info file
        cat > "$VARFS_INFO" << EOF
VARFS_DIR=$VARFS_DIR
LOOP_START=$LOOP_START
PART_COUNT=$CURRENT_PART_COUNT
VARFS_DEV=$VARFS_DEV
EOF

        # Report new size
        NEW_SIZE=$(df -h /var | tail -1 | awk '{print $2}')
        NEW_FREE=$(df -h /var | tail -1 | awk '{print $4}')
        log "Expansion complete. Size: $NEW_SIZE, Free: $NEW_FREE"
    fi

    sleep $CHECK_INTERVAL
done