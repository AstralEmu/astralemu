#!/bin/bash
#
# Homefs Dynamic Expansion Daemon
# Monitors /home space and expands by adding new partition files
#

set -e

HOMEFS_INFO="/run/homefs-info"
MIN_FREE_MB=1900  # Minimum free space before expanding (1.9 GB)
PART_SIZE_MB=1900 # Size of new partitions (1.9 GB)
CHECK_INTERVAL=30 # Check every 30 seconds

log() {
    echo "[homefs-expand] $(date '+%Y-%m-%d %H:%M:%S') $1"
    logger -t homefs-expand "$1"
}

error() {
    log "ERROR: $1"
}

# Load homefs configuration
if [ ! -f "$HOMEFS_INFO" ]; then
    error "Homefs info file not found: $HOMEFS_INFO"
    exit 1
fi

source "$HOMEFS_INFO"

log "Starting homefs expansion daemon"
log "  HOMEFS_DIR: $HOMEFS_DIR"
log "  PART_COUNT: $PART_COUNT"
log "  HOMEFS_DEV: $HOMEFS_DEV"

# Track current state
CURRENT_LOOP=$((LOOP_START + PART_COUNT))
CURRENT_PART_COUNT=$PART_COUNT

# Get current dm offset (if using device-mapper)
if [[ "$HOMEFS_DEV" == "/dev/mapper/"* ]]; then
    DM_NAME=$(basename "$HOMEFS_DEV")
    DM_OFFSET=$(dmsetup table "$DM_NAME" 2>/dev/null | tail -1 | awk '{print $1 + $2}')
else
    DM_OFFSET=0
fi

while true; do
    # Check free space on /home
    FREE_KB=$(df --output=avail /home 2>/dev/null | tail -1)
    FREE_MB=$((FREE_KB / 1024))

    if [ "$FREE_MB" -lt "$MIN_FREE_MB" ]; then
        log "Low space detected: ${FREE_MB}MB free (threshold: ${MIN_FREE_MB}MB)"

        # Calculate next part number (3 digits, zero-padded)
        NEXT_PART_NUM=$(printf "%03d" $CURRENT_PART_COUNT)
        NEW_PART="$HOMEFS_DIR/homefs.ext4.part$NEXT_PART_NUM"

        log "Creating new partition: $NEW_PART"

        # Create new sparse file
        dd if=/dev/zero of="$NEW_PART" bs=1M count=0 seek=$PART_SIZE_MB 2>/dev/null
        if [ $? -ne 0 ]; then
            error "Failed to create partition file"
            sleep $CHECK_INTERVAL
            continue
        fi

        # Attach new loop device
        NEW_LOOP="/dev/loop$CURRENT_LOOP"
        losetup "$NEW_LOOP" "$NEW_PART"
        if [ $? -ne 0 ]; then
            error "Failed to attach loop device"
            rm -f "$NEW_PART"
            sleep $CHECK_INTERVAL
            continue
        fi

        # Calculate new partition size in sectors
        NEW_SIZE_BYTES=$((PART_SIZE_MB * 1024 * 1024))
        NEW_SIZE_SECTORS=$((NEW_SIZE_BYTES / 512))

        if [[ "$HOMEFS_DEV" == "/dev/mapper/"* ]]; then
            # Extend existing device-mapper device
            DM_NAME=$(basename "$HOMEFS_DEV")

            # Get current table
            CURRENT_TABLE=$(dmsetup table "$DM_NAME")

            # Add new segment
            NEW_LINE="$DM_OFFSET $NEW_SIZE_SECTORS linear $NEW_LOOP 0"

            # Suspend, reload, resume
            log "Extending device-mapper: adding segment at offset $DM_OFFSET"

            # Create new table
            echo -e "${CURRENT_TABLE}\n${NEW_LINE}" | dmsetup reload "$DM_NAME"
            dmsetup resume "$DM_NAME"

            DM_OFFSET=$((DM_OFFSET + NEW_SIZE_SECTORS))

        else
            # Convert from single loop device to device-mapper
            CURRENT_LOOP_DEV="$HOMEFS_DEV"
            CURRENT_SIZE_SECTORS=$(blockdev --getsz "$CURRENT_LOOP_DEV")

            log "Converting to device-mapper"

            # Unmount current
            umount /home

            # Create device-mapper with both devices
            DM_TABLE="0 $CURRENT_SIZE_SECTORS linear $CURRENT_LOOP_DEV 0
$CURRENT_SIZE_SECTORS $NEW_SIZE_SECTORS linear $NEW_LOOP 0"

            echo "$DM_TABLE" | dmsetup create homefs-combined

            # Remount
            mount -t ext4 /dev/mapper/homefs-combined /home

            HOMEFS_DEV="/dev/mapper/homefs-combined"
            DM_OFFSET=$((CURRENT_SIZE_SECTORS + NEW_SIZE_SECTORS))
        fi

        # Resize filesystem to use new space
        log "Resizing filesystem..."
        resize2fs "$HOMEFS_DEV"

        # Update state
        CURRENT_PART_COUNT=$((CURRENT_PART_COUNT + 1))
        CURRENT_LOOP=$((CURRENT_LOOP + 1))

        # Update info file
        cat > "$HOMEFS_INFO" << EOF
HOMEFS_DIR=$HOMEFS_DIR
LOOP_START=$LOOP_START
PART_COUNT=$CURRENT_PART_COUNT
HOMEFS_DEV=$HOMEFS_DEV
EOF

        # Report new size
        NEW_SIZE=$(df -h /home | tail -1 | awk '{print $2}')
        NEW_FREE=$(df -h /home | tail -1 | awk '{print $4}')
        log "Expansion complete. New size: $NEW_SIZE, Free: $NEW_FREE"
    fi

    sleep $CHECK_INTERVAL
done