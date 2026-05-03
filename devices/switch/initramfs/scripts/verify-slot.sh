#!/bin/sh
#
# Verify and select A/B boot slot
# Returns the slot to boot ("a" or "b") on stdout
# Exit code 0 = valid slot found, 1 = no valid slot
#
# Usage: verify-slot.sh <image_dir> <preferred_slot> <fallback_slot>
#

IMAGE_DIR="$1"
PREFERRED_SLOT="$2"
FALLBACK_SLOT="$3"

log() {
    echo "[verify-slot] $1"
}

# Verify a single slot
# Returns 0 if valid, 1 if invalid
verify_single_slot() {
    local slot="$1"
    local slot_dir="$IMAGE_DIR/slot/$slot"

    if [ ! -d "$slot_dir" ]; then
        log "Slot $slot: directory not found ($slot_dir)"
        return 1
    fi

    # Check tries counter
    local tries_file="$IMAGE_DIR/slot-$slot.tries"
    if [ -f "$tries_file" ]; then
        local tries
        tries=$(cat "$tries_file" 2>/dev/null | tr -d '[:space:]')
        if [ -n "$tries" ] && [ "$tries" -le 0 ] 2>/dev/null; then
            log "Slot $slot: no tries remaining (tries=$tries)"
            return 1
        fi
        log "Slot $slot: tries remaining = $tries"
    fi

    # Verify SHA256 checksums
    local sha256_file="$slot_dir/rootfs.squashfs.sha256"
    if [ -f "$sha256_file" ]; then
        log "Slot $slot: verifying SHA256 checksums..."
        if command -v sha256sum >/dev/null 2>&1; then
            if ! (cd "$slot_dir" && sha256sum -c "$sha256_file" >/dev/null 2>&1); then
                log "Slot $slot: SHA256 verification FAILED"
                return 1
            fi
            log "Slot $slot: SHA256 OK"
        else
            log "Slot $slot: sha256sum not available, skipping verification"
        fi
    else
        log "Slot $slot: no SHA256 file found, booting without verification"
    fi

    # Check that at least one squashfs part exists
    if ! ls "$slot_dir"/rootfs.squashfs.part* >/dev/null 2>&1; then
        log "Slot $slot: no squashfs parts found"
        return 1
    fi

    local part_count
    part_count=$(ls "$slot_dir"/rootfs.squashfs.part* 2>/dev/null | wc -w)
    log "Slot $slot: valid ($part_count part(s))"

    return 0
}

# Try preferred slot first
if verify_single_slot "$PREFERRED_SLOT"; then
    echo "$PREFERRED_SLOT"
    exit 0
fi

log "Preferred slot $PREFERRED_SLOT invalid, trying fallback $FALLBACK_SLOT"

# Try fallback slot
if verify_single_slot "$FALLBACK_SLOT"; then
    # Update slot file to fallback
    echo "$FALLBACK_SLOT" > "$IMAGE_DIR/slot" 2>/dev/null || true
    echo "$FALLBACK_SLOT"
    exit 0
fi

log "No valid boot slot found!"
exit 1