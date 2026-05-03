#!/bin/bash
#
# Create custom initramfs for Switch Linux
# Handles part assembly, squashfs mount, A/B slot verification, and overlay setup
#

set -e

OUTPUT_FILE="${1:-initramfs.img}"
# Convert to absolute path if relative
if [[ "$OUTPUT_FILE" != /* ]]; then
    OUTPUT_FILE="$(pwd)/$OUTPUT_FILE"
fi
WORK_IMAGE="$2"  # Optional: QEMU work image for extracting ARM64 binaries

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

# Install busybox (static ARM64 binary)
echo "Installing busybox..."
if command -v busybox &> /dev/null; then
    # Check if host busybox is static and ARM64
    HOST_BUSYBOX=$(command -v busybox)
    HOST_ARCH=$(file "$HOST_BUSYBOX" 2>/dev/null | grep -oE 'aarch64|ARM' || true)
    if [[ -n "$HOST_ARCH" ]]; then
        cp "$HOST_BUSYBOX" "$WORKDIR/bin/busybox"
        echo "Using host busybox (ARM64 static)"
    else
        # Host busybox is wrong arch, download ARM64 static
        echo "Host busybox is not ARM64, downloading..."
        curl -sL "https://busybox.net/downloads/binaries/1.35.0-arm64-linux-musl/busybox" -o "$WORKDIR/bin/busybox"
    fi
else
    echo "Downloading busybox (ARM64 static)..."
    curl -sL "https://busybox.net/downloads/binaries/1.35.0-arm64-linux-musl/busybox" -o "$WORKDIR/bin/busybox"
fi
chmod +x "$WORKDIR/bin/busybox"

# Create busybox symlinks
BUSYBOX_CMDS="sh ash mount umount mkdir rmdir cat echo ls stat dd sleep mknod ln rm cp mv chmod chown grep sed awk switch_root sha256sum losetup dmsetup e2fsck resize2fs blkid df"
for cmd in $BUSYBOX_CMDS; do
    ln -sf busybox "$WORKDIR/bin/$cmd"
done

# =============================================================================
# Copy ARM64 binaries from the work image (cross-arch build safe)
# =============================================================================

echo "Extracting ARM64 binaries from work image..."

NEED_UMOUNT=false
CHROOT_DIR=""

if [[ -n "$WORK_IMAGE" && -f "$WORK_IMAGE" ]]; then
    CHROOT_DIR=$(mktemp -d -t initramfs-chroot.XXXXXX)

    # Try to mount the work image
    LOOP_DEV=$(losetup -f --show -P "$WORK_IMAGE" 2>/dev/null || true)

    if [[ -n "$LOOP_DEV" ]]; then
        # Find root partition
        ROOT_PART=""
        for part in "${LOOP_DEV}p1" "${LOOP_DEV}p2" "${LOOP_DEV}p3"; do
            if [[ -b "$part" ]]; then
                fstype=$(blkid -o value -s TYPE "$part" 2>/dev/null || true)
                if [[ "$fstype" == "ext4" || "$fstype" == "squashfs" ]]; then
                    ROOT_PART="$part"
                    break
                fi
            fi
        done

        if [[ -n "$ROOT_PART" ]]; then
            mount "$ROOT_PART" "$CHROOT_DIR" 2>/dev/null && NEED_UMOUNT=true
        fi
    fi
fi

# Copy essential ARM64 binaries (prefer work image, fallback to host)
copy_binary() {
    local name="$1"
    local dest="$WORKDIR/sbin"

    # Try work image first
    if [[ -n "$CHROOT_DIR" && -d "$CHROOT_DIR" ]]; then
        for search_dir in /sbin /usr/sbin /bin /usr/bin; do
            if [[ -f "$CHROOT_DIR$search_dir/$name" ]]; then
                cp "$CHROOT_DIR$search_dir/$name" "$dest/"
                echo "  Copied $name from work image ($search_dir)"
                return 0
            fi
        done
    fi

    # Fallback to host (may be wrong arch — warn)
    for search_dir in /sbin /usr/sbin; do
        if [[ -f "$search_dir/$name" ]]; then
            cp "$search_dir/$name" "$dest/"
            echo "  WARNING: Copied $name from build host (may not be ARM64!)"
            return 0
        fi
    done

    echo "  WARNING: $name not found anywhere"
    return 1
}

copy_binary "losetup"
copy_binary "dmsetup"
copy_binary "e2fsck"
copy_binary "resize2fs"
copy_binary "blkid"

# Copy required shared libraries from the work image
copy_libs() {
    local binary="$1"
    local search_root="${2:-/}"

    if [[ -f "$binary" ]]; then
        # Get the dynamic linker path first
        local interp
        interp=$(readelf -l "$binary" 2>/dev/null | grep "interpreter" | sed 's/.*: \(.*\)]/\1/' || true)

        for lib in $(ldd "$binary" 2>/dev/null | grep -oE '/[^ ]+' || true); do
            local lib_src=""

            # Try work image first
            if [[ -n "$CHROOT_DIR" && -f "$CHROOT_DIR$lib" ]]; then
                lib_src="$CHROOT_DIR$lib"
            elif [[ -f "$lib" ]]; then
                lib_src="$lib"
            fi

            if [[ -n "$lib_src" ]]; then
                local libdir
                libdir=$(dirname "$lib")
                mkdir -p "$WORKDIR$libdir"
                cp -n "$lib_src" "$WORKDIR$libdir/" 2>/dev/null || true
            fi
        done

        # Copy the dynamic linker
        if [[ -n "$interp" ]]; then
            local interp_src=""
            if [[ -n "$CHROOT_DIR" && -f "$CHROOT_DIR$interp" ]]; then
                interp_src="$CHROOT_DIR$interp"
            elif [[ -f "$interp" ]]; then
                interp_src="$interp"
            fi
            if [[ -n "$interp_src" ]]; then
                mkdir -p "$WORKDIR$(dirname "$interp")"
                cp "$interp_src" "$WORKDIR$interp"
            fi
        fi
    fi
}

echo "Copying shared libraries..."
for binary in "$WORKDIR"/sbin/*; do
    if [[ -f "$binary" && -x "$binary" ]]; then
        copy_libs "$binary"
    fi
done

# Cleanup work image mount
if [[ "$NEED_UMOUNT" == "true" ]]; then
    umount "$CHROOT_DIR" 2>/dev/null || true
fi
if [[ -n "$LOOP_DEV" ]]; then
    losetup -d "$LOOP_DEV" 2>/dev/null || true
fi
if [[ -n "$CHROOT_DIR" ]]; then
    rmdir "$CHROOT_DIR" 2>/dev/null || true
fi

# =============================================================================
# Copy init script and helper scripts from source
# =============================================================================

echo "Copying init script..."
if [[ -f "$INITRAMFS_SRC/init" ]]; then
    cp "$INITRAMFS_SRC/init" "$WORKDIR/init"
    chmod +x "$WORKDIR/init"
    echo "Using init from $INITRAMFS_SRC/init"
else
    echo "ERROR: No init script found at $INITRAMFS_SRC/init"
    exit 1
fi

# Copy modular scripts
if [[ -d "$INITRAMFS_SRC/scripts" ]]; then
    echo "Copying scripts from $INITRAMFS_SRC/scripts/"
    cp -r "$INITRAMFS_SRC/scripts"/* "$WORKDIR/scripts/" 2>/dev/null || true
    chmod +x "$WORKDIR/scripts"/*.sh 2>/dev/null || true
fi

# =============================================================================
# Create the initramfs cpio archive
# =============================================================================

echo "Creating initramfs archive..."
cd "$WORKDIR"
find . | cpio -H newc -o 2>/dev/null | gzip -9 > "$OUTPUT_FILE.tmp"
mv "$OUTPUT_FILE.tmp" "$OUTPUT_FILE"

echo "Initramfs created: $OUTPUT_FILE"
ls -lh "$OUTPUT_FILE"