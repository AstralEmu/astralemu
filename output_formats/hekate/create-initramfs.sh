#!/bin/bash
#
# Create custom initramfs for Switch Linux
# Handles part assembly, squashfs mount, and overlay setup
#

set -e

OUTPUT_FILE="${1:-initramfs.img}"
# Convert to absolute path if relative
if [[ "$OUTPUT_FILE" != /* ]]; then
    OUTPUT_FILE="$(pwd)/$OUTPUT_FILE"
fi
KERNEL_IMAGE="$2"  # Optional: extract modules from this image

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
INITRAMFS_SRC="$PROJECT_ROOT/devices/switch/initramfs"

WORKDIR=$(mktemp -d -t initramfs-build.XXXXXX)

cleanup() {
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "Building initramfs..."
echo "Work directory: $WORKDIR"

# Create directory structure
mkdir -p "$WORKDIR"/{bin,sbin,lib/modules,scripts,proc,sys,dev,run}
mkdir -p "$WORKDIR"/{sd,rootfs,newroot}
mkdir -p "$WORKDIR"/lib/{x86_64-linux-gnu,aarch64-linux-gnu}

# Install busybox
echo "Installing busybox..."
if command -v busybox &> /dev/null; then
    cp "$(command -v busybox)" "$WORKDIR/bin/"
else
    # Download static busybox for ARM64
    echo "Downloading busybox..."
    curl -sL "https://busybox.net/downloads/binaries/1.35.0-arm64-linux-musl/busybox" -o "$WORKDIR/bin/busybox"
fi
chmod +x "$WORKDIR/bin/busybox"

# Create busybox symlinks
BUSYBOX_CMDS="sh ash mount umount mkdir rmdir cat echo ls stat dd sleep mknod ln rm cp mv chmod chown grep sed awk switch_root"
for cmd in $BUSYBOX_CMDS; do
    ln -sf busybox "$WORKDIR/bin/$cmd"
done

# Copy essential binaries
echo "Copying essential binaries..."

# losetup
if [ -f /sbin/losetup ]; then
    cp /sbin/losetup "$WORKDIR/sbin/"
elif [ -f /usr/sbin/losetup ]; then
    cp /usr/sbin/losetup "$WORKDIR/sbin/"
fi

# dmsetup
if [ -f /sbin/dmsetup ]; then
    cp /sbin/dmsetup "$WORKDIR/sbin/"
elif [ -f /usr/sbin/dmsetup ]; then
    cp /usr/sbin/dmsetup "$WORKDIR/sbin/"
fi

# Copy required shared libraries
copy_libs() {
    local binary="$1"
    if [ -f "$binary" ]; then
        for lib in $(ldd "$binary" 2>/dev/null | grep -oE '/[^ ]+' || true); do
            if [ -f "$lib" ]; then
                local libdir=$(dirname "$lib")
                mkdir -p "$WORKDIR$libdir"
                cp -n "$lib" "$WORKDIR$libdir/" 2>/dev/null || true
            fi
        done
    fi
}

copy_libs "$WORKDIR/sbin/losetup"
copy_libs "$WORKDIR/sbin/dmsetup"

# Copy ld-linux
for ld in /lib/ld-linux-aarch64.so.1 /lib64/ld-linux-aarch64.so.1; do
    if [ -f "$ld" ]; then
        mkdir -p "$WORKDIR$(dirname "$ld")"
        cp "$ld" "$WORKDIR$ld"
    fi
done

# Copy kernel modules (if kernel image provided)
if [ -n "$KERNEL_IMAGE" ] && [ -f "$KERNEL_IMAGE" ]; then
    echo "Extracting kernel modules..."
    # This would require mounting the image and extracting modules
    # For now, we'll rely on built-in modules or skip this
    echo "Note: Module extraction from image not yet implemented"
fi

# Create init script
echo "Creating init script..."
cat > "$WORKDIR/init" << 'INIT_SCRIPT'
#!/bin/sh
# Switch Linux initramfs init script

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# Create necessary device nodes
mknod -m 660 /dev/loop0 b 7 0 2>/dev/null || true
mknod -m 660 /dev/loop1 b 7 1 2>/dev/null || true
mknod -m 660 /dev/loop2 b 7 2 2>/dev/null || true
mknod -m 660 /dev/loop3 b 7 3 2>/dev/null || true
mknod -m 660 /dev/loop4 b 7 4 2>/dev/null || true
mknod -m 660 /dev/loop5 b 7 5 2>/dev/null || true
mknod -m 660 /dev/loop6 b 7 6 2>/dev/null || true
mknod -m 660 /dev/loop7 b 7 7 2>/dev/null || true

for i in $(seq 10 20); do
    mknod -m 660 /dev/loop$i b 7 $i 2>/dev/null || true
done

# Parse kernel command line
IMAGE_NAME="switch-linux"
DEBUG=false

for param in $(cat /proc/cmdline); do
    case $param in
        swlinux.image=*)
            IMAGE_NAME="${param#swlinux.image=}"
            ;;
        swlinux.debug=*)
            DEBUG=true
            ;;
    esac
done

log() {
    echo "[initramfs] $1"
}

error() {
    echo "[initramfs] ERROR: $1"
    if $DEBUG; then
        echo "Dropping to shell for debugging..."
        exec /bin/sh
    fi
    sleep 5
}

log "Booting image: $IMAGE_NAME"
log "Debug mode: $DEBUG"

# Wait for SD card
log "Waiting for SD card..."
SD_DEV=""
for i in $(seq 1 30); do
    for dev in /dev/mmcblk0p1 /dev/mmcblk1p1 /dev/sda1; do
        if [ -b "$dev" ]; then
            SD_DEV="$dev"
            break 2
        fi
    done
    sleep 0.2
done

if [ -z "$SD_DEV" ]; then
    error "SD card not found!"
    exec /bin/sh
fi

log "Found SD card: $SD_DEV"

# Mount SD card
log "Mounting SD card..."
mount -t vfat -o rw,utf8 "$SD_DEV" /sd
if [ $? -ne 0 ]; then
    error "Failed to mount SD card!"
    exec /bin/sh
fi

# Check image directory exists
IMAGE_DIR="/sd/linux_img/$IMAGE_NAME"
if [ ! -d "$IMAGE_DIR" ]; then
    error "Image directory not found: $IMAGE_DIR"
    ls -la /sd/linux_img/ 2>/dev/null || true
    exec /bin/sh
fi

log "Image directory: $IMAGE_DIR"

# =============================================================================
# MOUNT ROOTFS (squashfs from parts)
# =============================================================================

log "Assembling rootfs..."

ROOTFS_DIR="$IMAGE_DIR/rootfs"
PARTS=$(ls "$ROOTFS_DIR"/*.part* 2>/dev/null | sort)
PART_COUNT=$(echo "$PARTS" | wc -w)

if [ "$PART_COUNT" -eq 0 ]; then
    error "No rootfs parts found in $ROOTFS_DIR"
    exec /bin/sh
fi

log "Found $PART_COUNT rootfs part(s)"

if [ "$PART_COUNT" -eq 1 ]; then
    # Single part - direct mount
    SINGLE_PART=$(echo "$PARTS" | head -1)
    /sbin/losetup /dev/loop0 "$SINGLE_PART"
    ROOTFS_DEV="/dev/loop0"
else
    # Multiple parts - use device mapper
    LOOP_NUM=0
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
    done

    echo "$DM_TABLE" | /sbin/dmsetup create rootfs-combined
    ROOTFS_DEV="/dev/mapper/rootfs-combined"
fi

log "Mounting squashfs from $ROOTFS_DEV..."
mount -t squashfs -o ro "$ROOTFS_DEV" /rootfs
if [ $? -ne 0 ]; then
    error "Failed to mount squashfs!"
    exec /bin/sh
fi

# =============================================================================
# MOUNT HOMEFS (ext4 from parts, expandable)
# =============================================================================

log "Assembling homefs..."

HOMEFS_DIR="$IMAGE_DIR/homefs"
mkdir -p "$HOMEFS_DIR"

PARTS=$(ls "$HOMEFS_DIR"/*.part* 2>/dev/null | sort)
PART_COUNT=$(echo "$PARTS" | wc -w)

# Create initial homefs if none exists
if [ "$PART_COUNT" -eq 0 ]; then
    log "Creating initial homefs partition..."
    FIRST_PART="$HOMEFS_DIR/homefs.ext4.part000"

    # Create 1.9GB sparse file
    dd if=/dev/zero of="$FIRST_PART" bs=1M count=0 seek=1900 2>/dev/null

    # Format
    /sbin/losetup /dev/loop10 "$FIRST_PART"
    # Note: mkfs.ext4 not in busybox, will be pre-formatted
    /sbin/losetup -d /dev/loop10

    PARTS="$FIRST_PART"
    PART_COUNT=1
fi

log "Found $PART_COUNT homefs part(s)"

LOOP_START=10

if [ "$PART_COUNT" -eq 1 ]; then
    SINGLE_PART=$(echo "$PARTS" | head -1)
    /sbin/losetup /dev/loop$LOOP_START "$SINGLE_PART"
    HOMEFS_DEV="/dev/loop$LOOP_START"
else
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
    done

    echo "$DM_TABLE" | /sbin/dmsetup create homefs-combined
    HOMEFS_DEV="/dev/mapper/homefs-combined"
fi

log "Mounting ext4 from $HOMEFS_DEV..."
mkdir -p /rootfs/home
mount -t ext4 "$HOMEFS_DEV" /rootfs/home
if [ $? -ne 0 ]; then
    error "Failed to mount homefs!"
    exec /bin/sh
fi

# Save homefs info for expansion service
mkdir -p /rootfs/run
cat > /rootfs/run/homefs-info << EOF
HOMEFS_DIR=$HOMEFS_DIR
LOOP_START=$LOOP_START
PART_COUNT=$PART_COUNT
HOMEFS_DEV=$HOMEFS_DEV
EOF

# =============================================================================
# SETUP OVERLAYS for /etc and /var
# =============================================================================

log "Setting up overlays..."

OVERLAY_BASE="/rootfs/home/.overlays"
mkdir -p "$OVERLAY_BASE/etc/upper" "$OVERLAY_BASE/etc/work"
mkdir -p "$OVERLAY_BASE/var/upper" "$OVERLAY_BASE/var/work"

# Mount overlay for /etc
mount -t overlay overlay \
    -o lowerdir=/rootfs/etc,upperdir=$OVERLAY_BASE/etc/upper,workdir=$OVERLAY_BASE/etc/work \
    /rootfs/etc

# Mount overlay for /var
mount -t overlay overlay \
    -o lowerdir=/rootfs/var,upperdir=$OVERLAY_BASE/var/upper,workdir=$OVERLAY_BASE/var/work \
    /rootfs/var

# =============================================================================
# MOUNT SD CARD IN FINAL SYSTEM
# =============================================================================

log "Setting up SD card access..."
mkdir -p /rootfs/sd
mount --move /sd /rootfs/sd

# =============================================================================
# SWITCH ROOT
# =============================================================================

log "Switching to real root filesystem..."

# Cleanup
umount /proc
umount /sys

# Switch root
exec switch_root /rootfs /sbin/init

# If switch_root fails
error "switch_root failed!"
exec /bin/sh
INIT_SCRIPT

chmod +x "$WORKDIR/init"

# Copy init script from source (if exists, use it instead of embedded)
if [ -f "$INITRAMFS_SRC/init" ]; then
    echo "Using init script from $INITRAMFS_SRC/init"
    cp "$INITRAMFS_SRC/init" "$WORKDIR/init"
    chmod +x "$WORKDIR/init"
fi

# Copy additional scripts from source
if [ -d "$INITRAMFS_SRC/scripts" ]; then
    echo "Copying scripts from $INITRAMFS_SRC/scripts/"
    cp -r "$INITRAMFS_SRC/scripts"/* "$WORKDIR/scripts/" 2>/dev/null || true
    chmod +x "$WORKDIR/scripts"/*.sh 2>/dev/null || true
fi

# Create the initramfs cpio archive
echo "Creating initramfs archive..."
cd "$WORKDIR"
find . | cpio -H newc -o 2>/dev/null | gzip -9 > "$OUTPUT_FILE.tmp"
mv "$OUTPUT_FILE.tmp" "$OUTPUT_FILE"

echo "Initramfs created: $OUTPUT_FILE"
ls -lh "$OUTPUT_FILE"