#!/bin/sh
#
# Setup OverlayFS for /etc and /var
# Allows persistent changes to these directories while keeping rootfs immutable
#

ROOTFS="${1:-/rootfs}"
HOMEFS="${2:-/rootfs/home}"

log() {
    echo "[setup-overlays] $1"
}

error() {
    echo "[setup-overlays] ERROR: $1"
    return 1
}

# Overlay directories are stored on homefs (persistent)
OVERLAY_BASE="$HOMEFS/.overlays"

log "Setting up overlay directories at $OVERLAY_BASE"

# Create overlay directory structure
mkdir -p "$OVERLAY_BASE/etc/upper" "$OVERLAY_BASE/etc/work"
mkdir -p "$OVERLAY_BASE/var/upper" "$OVERLAY_BASE/var/work"

# Mount overlay for /etc
# - lowerdir: read-only squashfs /etc
# - upperdir: writable delta stored on homefs
# - workdir: required by overlayfs (same filesystem as upper)
log "Mounting /etc overlay..."
mount -t overlay overlay \
    -o "lowerdir=$ROOTFS/etc,upperdir=$OVERLAY_BASE/etc/upper,workdir=$OVERLAY_BASE/etc/work" \
    "$ROOTFS/etc"
if [ $? -ne 0 ]; then
    error "Failed to mount /etc overlay!"
    return 1
fi

# Mount overlay for /var
log "Mounting /var overlay..."
mount -t overlay overlay \
    -o "lowerdir=$ROOTFS/var,upperdir=$OVERLAY_BASE/var/upper,workdir=$OVERLAY_BASE/var/work" \
    "$ROOTFS/var"
if [ $? -ne 0 ]; then
    error "Failed to mount /var overlay!"
    return 1
fi

log "Overlays configured successfully"

# Note on overlays:
# - Changes to /etc and /var are stored in .overlays/{etc,var}/upper/
# - Original files from squashfs remain untouched
# - To reset to defaults: rm -rf .overlays/{etc,var}/upper/*
# - .overlays/*/work/ is used internally by overlayfs
