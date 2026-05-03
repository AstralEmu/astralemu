#!/bin/bash
#
# AstralEmu Slot Verification Service
# Marks the current boot slot as successfully booted.
# Called after multi-user.target to confirm the system is stable.
#
# This clears the "tries" counter for the current slot, preventing
# fallback on the next boot. If this service never runs (because the
# system crashed before reaching multi-user.target), the tries counter
# will decrement until it reaches 0, triggering a fallback to the
# other slot.
#

INFO_FILE="/run/astralemu-info"

if [ ! -f "$INFO_FILE" ]; then
    echo "[astralemu-slot-verify] No boot info file found, skipping slot verification"
    exit 0
fi

source "$INFO_FILE"

if [ -z "$BOOT_SLOT" ] || [ -z "$IMAGE_DIR" ]; then
    echo "[astralemu-slot-verify] Missing boot info, skipping slot verification"
    exit 0
fi

echo "[astralemu-slot-verify] Boot slot: $BOOT_SLOT"
echo "[astralemu-slot-verify] Image directory: $IMAGE_DIR"

# The SD card is mounted at /sd
SD_MOUNT="/sd"

SLOT_DIR="$SD_MOUNT$IMAGE_DIR/slot/$BOOT_SLOT"
TRIES_FILE="$SD_MOUNT$IMAGE_DIR/slot-$BOOT_SLOT.tries"

# Check if the SD is mounted at /sd
if ! mountpoint -q "$SD_MOUNT" 2>/dev/null; then
    echo "[astralemu-slot-verify] /sd not mounted, trying to find it..."
    # Try to find the SD card mount
    for mnt in /sd /mnt/sd; do
        if mountpoint -q "$mnt" 2>/dev/null; then
            SD_MOUNT="$mnt"
            TRIES_FILE="$SD_MOUNT$IMAGE_DIR/slot-$BOOT_SLOT.tries"
            break
        fi
    done
fi

# Clear the tries counter — this slot is confirmed bootable
if [ -f "$TRIES_FILE" ]; then
    OLD_TRIES=$(cat "$TRIES_FILE" 2>/dev/null | tr -d '[:space:]')
    echo "[astralemu-slot-verify] Slot $BOOT_SLOT tries was: $OLD_TRIES"
    # Set tries to a high value (9) to indicate "good" slot
    echo "9" > "$TRIES_FILE" 2>/dev/null || {
        echo "[astralemu-slot-verify] WARNING: Could not write tries file (read-only?)"
    }
    echo "[astralemu-slot-verify] Slot $BOOT_SLOT marked as successfully booted"
else
    echo "[astralemu-slot-verify] No tries file for slot $BOOT_SLOT (first boot?)"
    # Create tries file with high value
    echo "9" > "$TRIES_FILE" 2>/dev/null || true
fi

echo "[astralemu-slot-verify] Done"