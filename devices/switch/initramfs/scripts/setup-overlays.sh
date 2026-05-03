#!/bin/sh
#
# Setup OverlayFS for /etc only
# /var is now a real persistent ext4 partition, no overlay needed.
# Lower layer: squashfs /etc (from active slot)
# Upper layer: /var/astralemu/etc-overlay/upper (persisted across boots)
# Work dir: /var/astralemu/etc-overlay/work
#

ROOTFS="${1:-/rootfs}"
VARFS="${2:-/rootfs/var}"

log() {
    echo "[setup-overlays] $1"
}

error() {
    echo "[setup-overlays] ERROR: $1"
    return 1
}

# Overlay upper/work directories are stored on /var (persistent)
OVERLAY_BASE="$VARFS/astralemu/etc-overlay"

log "Setting up overlay directories at $OVERLAY_BASE"

# Create overlay directory structure on /var
mkdir -p "$OVERLAY_BASE/upper" "$OVERLAY_BASE/work"

# Mount overlay for /etc
# - lowerdir: read-only squashfs /etc from the active slot
# - upperdir: writable delta stored on /var (survives reboots and slot switches)
# - workdir: required by overlayfs (same filesystem as upper)
log "Mounting /etc overlay..."
mount -t overlay overlay \
    -o "lowerdir=$ROOTFS/etc,upperdir=$OVERLAY_BASE/upper,workdir=$OVERLAY_BASE/work" \
    "$ROOTFS/etc"
if [ $? -ne 0 ]; then
    error "Failed to mount /etc overlay!"
    return 1
fi

log "/etc overlay configured successfully"
log "  Lower: $ROOTFS/etc (squashfs, read-only)"
log "  Upper: $OVERLAY_BASE/upper (persistent, on /var)"
log "  Work:  $OVERLAY_BASE/work"

# Note on overlays:
# - /etc changes are stored in /var/astralemu/etc-overlay/upper/
# - Original files from squashfs remain untouched
# - /var is a real ext4 partition (no overlay)
# - To reset /etc to defaults: rm -rf /var/astralemu/etc-overlay/upper/*
# - This overlay survives slot switches (A/B) since /var is shared