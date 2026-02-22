#!/bin/bash
#
# Output format: hekate
# Produces a complete SD card directory structure for Nintendo Switch via Hekate
#
# Pipeline:
#   1. Extract rootfs from QEMU image → SquashFS + FAT32 split
#   2. Create homefs ext4 partition
#   3. Generate custom initramfs
#   4. Extract kernel + DTB + download coreboot
#   5. Generate Hekate config + assemble final structure
#
# Required variables (set by autobuild):
#   $WORK_IMAGE      - QEMU work image (raw) with configured rootfs
#   $WORKDIR_ROOT    - Project root directory
#   $DEVICE_ID       - Device identifier (e.g. switch)
#   $OUTPUT_IMAGE    - Output name (used as build name)
#   $SERVICES        - Space-separated list of services installed
#
# Required config.sh variables (from devices/<device>/config.sh):
#   $ROOTFS_PART_SIZE_MB  - Max size per rootfs part (FAT32 limit)
#   $HOMEFS_PART_SIZE_MB  - Size of initial homefs partition
#   $SQUASHFS_COMP        - Compression algorithm (zstd)
#   $SQUASHFS_LEVEL       - Compression level (19)
#   $SWITCHROOT_REPO      - URL for Switchroot boot files
#

output_hekate() {
    echo_step "=== OUTPUT FORMAT: hekate ==="
    echo "  Producing Hekate SD card structure for Nintendo Switch"

    # Derive build name from OUTPUT_IMAGE (strip .img extension if present)
    local BUILD_NAME="${OUTPUT_IMAGE%.img}"
    BUILD_NAME="${BUILD_NAME##*/}"  # Remove any path prefix

    # Default values if not set in config.sh
    : "${ROOTFS_PART_SIZE_MB:=3900}"
    : "${HOMEFS_PART_SIZE_MB:=1900}"
    : "${SQUASHFS_COMP:=zstd}"
    : "${SQUASHFS_LEVEL:=19}"

    # Determine sudo prefix
    local SUDO_PREFIX=""
    if [ "$EUID" -ne 0 ]; then
        SUDO_PREFIX="sudo"
    fi

    # Create work directory for hekate output
    local HEKATE_WORKDIR
    HEKATE_WORKDIR=$(mktemp -d -t hekate-build.XXXXXX)

    # Cleanup on exit
    hekate_cleanup() {
        local exit_code=$?
        # Unmount any mounted filesystems
        for mount in $(mount | grep "$HEKATE_WORKDIR" | awk '{print $3}' | sort -r); do
            $SUDO_PREFIX umount "$mount" 2>/dev/null || true
        done
        # Detach loop devices
        for loop in $(losetup -a 2>/dev/null | grep "$HEKATE_WORKDIR" | cut -d: -f1); do
            $SUDO_PREFIX losetup -d "$loop" 2>/dev/null || true
        done
        rm -rf "$HEKATE_WORKDIR" 2>/dev/null || $SUDO_PREFIX rm -rf "$HEKATE_WORKDIR" 2>/dev/null || true
    }
    trap hekate_cleanup EXIT

    # =========================================================================
    # STAGE 1: Extract rootfs → SquashFS + split
    # =========================================================================
    echo_step "Creating rootfs SquashFS..."

    local ROOTFS_DIR="$HEKATE_WORKDIR/rootfs"
    mkdir -p "$ROOTFS_DIR"

    # Mount the work image
    echo "  Mounting work image..."
    local LOOP_DEV
    LOOP_DEV=$($SUDO_PREFIX losetup -f --show -P "$WORK_IMAGE")

    # Find root partition (ext4)
    local ROOT_PART=""
    for part in "${LOOP_DEV}p1" "${LOOP_DEV}p2" "${LOOP_DEV}p3"; do
        if [ -b "$part" ]; then
            local fstype
            fstype=$($SUDO_PREFIX blkid -o value -s TYPE "$part" 2>/dev/null || true)
            if [ "$fstype" = "ext4" ]; then
                ROOT_PART="$part"
                break
            fi
        fi
    done

    if [ -z "$ROOT_PART" ]; then
        echo_error "Could not find root partition in image"
        $SUDO_PREFIX losetup -d "$LOOP_DEV"
        exit 1
    fi

    local MOUNT_POINT="$HEKATE_WORKDIR/mnt"
    mkdir -p "$MOUNT_POINT"
    $SUDO_PREFIX mount "$ROOT_PART" "$MOUNT_POINT"

    # Copy rootfs excluding /home (will be on homefs)
    echo "  Copying rootfs (excluding /home)..."
    $SUDO_PREFIX rsync -aAX --exclude='/home/*' --exclude='/tmp/*' --exclude='/var/tmp/*' \
        --exclude='/var/cache/apt/archives/*.deb' \
        "$MOUNT_POINT/" "$ROOTFS_DIR/"

    # Save /home contents for homefs
    local HOMEFS_CONTENT="$HEKATE_WORKDIR/home-content"
    mkdir -p "$HOMEFS_CONTENT"
    if [ -d "$MOUNT_POINT/home" ]; then
        $SUDO_PREFIX cp -a "$MOUNT_POINT/home/"* "$HOMEFS_CONTENT/" 2>/dev/null || true
    fi

    # Clean up rootfs
    echo "  Cleaning rootfs..."
    $SUDO_PREFIX rm -rf "$ROOTFS_DIR"/var/cache/apt/archives/*.deb
    $SUDO_PREFIX rm -rf "$ROOTFS_DIR"/var/lib/apt/lists/*
    $SUDO_PREFIX rm -rf "$ROOTFS_DIR"/tmp/*
    $SUDO_PREFIX rm -rf "$ROOTFS_DIR"/var/tmp/*
    $SUDO_PREFIX mkdir -p "$ROOTFS_DIR/home"
    $SUDO_PREFIX mkdir -p "$ROOTFS_DIR/sd"

    # Create SquashFS
    echo "  Creating SquashFS ($SQUASHFS_COMP level $SQUASHFS_LEVEL)..."
    local SQUASHFS_FILE="$HEKATE_WORKDIR/rootfs.squashfs"
    $SUDO_PREFIX mksquashfs "$ROOTFS_DIR" "$SQUASHFS_FILE" \
        -comp "$SQUASHFS_COMP" -Xcompression-level "$SQUASHFS_LEVEL" -progress
    $SUDO_PREFIX chown "$(id -u):$(id -g)" "$SQUASHFS_FILE"

    # Split into FAT32-compatible parts
    echo "  Splitting SquashFS into parts..."
    "$(dirname "${BASH_SOURCE[0]}")/split-image.sh" "$SQUASHFS_FILE" "$HEKATE_WORKDIR/rootfs-parts" "$ROOTFS_PART_SIZE_MB"

    echo_success "Rootfs SquashFS created and split"

    # =========================================================================
    # STAGE 2: Create homefs ext4
    # =========================================================================
    echo_step "Creating homefs partition..."

    local HOMEFS_FILE="$HEKATE_WORKDIR/homefs.ext4.part000"

    # Create sparse file
    dd if=/dev/zero of="$HOMEFS_FILE" bs=1M count=0 seek="$HOMEFS_PART_SIZE_MB" 2>/dev/null
    $SUDO_PREFIX mkfs.ext4 -q -L SWLINUX_HOME "$HOMEFS_FILE"

    # Mount and populate
    local HOMEFS_MOUNT="$HEKATE_WORKDIR/homefs-mount"
    mkdir -p "$HOMEFS_MOUNT"
    local LOOP_HOMEFS
    LOOP_HOMEFS=$($SUDO_PREFIX losetup -f --show "$HOMEFS_FILE")
    $SUDO_PREFIX mount "$LOOP_HOMEFS" "$HOMEFS_MOUNT"

    # Copy home content from QEMU build
    if [ -d "$HOMEFS_CONTENT" ] && [ "$(ls -A "$HOMEFS_CONTENT" 2>/dev/null)" ]; then
        echo "  Copying home content..."
        $SUDO_PREFIX cp -a "$HOMEFS_CONTENT/"* "$HOMEFS_MOUNT/" 2>/dev/null || true
    fi

    # Create overlay directories
    $SUDO_PREFIX mkdir -p "$HOMEFS_MOUNT/.overlays/etc/upper" "$HOMEFS_MOUNT/.overlays/etc/work"
    $SUDO_PREFIX mkdir -p "$HOMEFS_MOUNT/.overlays/var/upper" "$HOMEFS_MOUNT/.overlays/var/work"
    $SUDO_PREFIX mkdir -p "$HOMEFS_MOUNT/switch"
    $SUDO_PREFIX chown 1000:1000 "$HOMEFS_MOUNT/switch"

    $SUDO_PREFIX umount "$HOMEFS_MOUNT"
    $SUDO_PREFIX losetup -d "$LOOP_HOMEFS"

    echo_success "Homefs created"

    # =========================================================================
    # STAGE 3: Create initramfs
    # =========================================================================
    echo_step "Creating initramfs..."

    "$(dirname "${BASH_SOURCE[0]}")/create-initramfs.sh" "$HEKATE_WORKDIR/initramfs.img" "$WORK_IMAGE"

    echo_success "Initramfs created"

    # =========================================================================
    # STAGE 4: Extract kernel + boot files
    # =========================================================================
    echo_step "Extracting boot files..."

    local BOOTFILES_DIR="$HEKATE_WORKDIR/bootfiles"
    mkdir -p "$BOOTFILES_DIR"

    # Image is still mounted from stage 1
    # Copy kernel Image (prefer switch-bsp bootstack, then L4T kernel)
    local NEED_SWITCHROOT_KERNEL=false
    if [ -f "$MOUNT_POINT/opt/switchroot/bootstack/uImage" ]; then
        $SUDO_PREFIX cp "$MOUNT_POINT/opt/switchroot/bootstack/uImage" "$BOOTFILES_DIR/Image"
        echo_success "Found switch-bsp kernel: uImage"
    elif $SUDO_PREFIX ls "$MOUNT_POINT/boot/vmlinuz-"*l4t* 2>/dev/null | head -1; then
        local vmlinuz
        vmlinuz=$($SUDO_PREFIX ls "$MOUNT_POINT/boot/vmlinuz-"*l4t* 2>/dev/null | head -1)
        $SUDO_PREFIX cp "$vmlinuz" "$BOOTFILES_DIR/Image"
        echo_success "Found L4T kernel: $vmlinuz"
    elif [ -f "$MOUNT_POINT/boot/uImage" ]; then
        $SUDO_PREFIX cp "$MOUNT_POINT/boot/uImage" "$BOOTFILES_DIR/Image"
        echo_success "Found kernel: uImage"
    elif [ -f "$MOUNT_POINT/boot/Image" ]; then
        $SUDO_PREFIX cp "$MOUNT_POINT/boot/Image" "$BOOTFILES_DIR/"
        echo_success "Found kernel: Image"
    elif $SUDO_PREFIX ls "$MOUNT_POINT/boot/vmlinuz-"* 2>/dev/null | head -1; then
        local vmlinuz
        vmlinuz=$($SUDO_PREFIX ls "$MOUNT_POINT/boot/vmlinuz-"* 2>/dev/null | head -1)
        $SUDO_PREFIX cp "$vmlinuz" "$BOOTFILES_DIR/Image"
        echo_warn "Using generic kernel: $vmlinuz (may not work on Switch)"
        NEED_SWITCHROOT_KERNEL=true
    else
        echo_warn "No kernel found in image"
        NEED_SWITCHROOT_KERNEL=true
    fi

    # Copy device tree (prefer switch-bsp bootstack, then L4T debs)
    local NEED_SWITCHROOT_DTB=false
    if [ -f "$MOUNT_POINT/opt/switchroot/bootstack/nx-plat.dtimg" ]; then
        $SUDO_PREFIX cp "$MOUNT_POINT/opt/switchroot/bootstack/nx-plat.dtimg" "$BOOTFILES_DIR/"
        echo_success "Found switch-bsp DTB: nx-plat.dtimg"
    elif $SUDO_PREFIX ls "$MOUNT_POINT/boot/"*nx-plat*.dtimg 2>/dev/null | head -1; then
        local dtimg
        dtimg=$($SUDO_PREFIX ls "$MOUNT_POINT/boot/"*nx-plat*.dtimg 2>/dev/null | head -1)
        $SUDO_PREFIX cp "$dtimg" "$BOOTFILES_DIR/nx-plat.dtimg"
        echo_success "Found L4T DTB image: $dtimg"
    elif [ -d "$MOUNT_POINT/boot/dtb-l4t" ]; then
        if $SUDO_PREFIX ls "$MOUNT_POINT/boot/dtb-l4t/"*nx-plat*.dtimg 2>/dev/null | head -1; then
            local dtimg
            dtimg=$($SUDO_PREFIX ls "$MOUNT_POINT/boot/dtb-l4t/"*nx-plat*.dtimg 2>/dev/null | head -1)
            $SUDO_PREFIX cp "$dtimg" "$BOOTFILES_DIR/nx-plat.dtimg"
            echo_success "Found L4T DTB image: $dtimg"
        fi
    elif [ -f "$MOUNT_POINT/boot/dtb/tegra210-icosa.dtb" ]; then
        $SUDO_PREFIX cp "$MOUNT_POINT/boot/dtb/tegra210-icosa.dtb" "$BOOTFILES_DIR/"
        echo_success "Found DTB: tegra210-icosa.dtb"
    else
        echo_warn "No device tree found in image"
        NEED_SWITCHROOT_DTB=true
    fi

    # Copy additional bootstack files
    if [ -d "$MOUNT_POINT/opt/switchroot/bootstack" ]; then
        for f in bl31.bin bl33.bin boot.scr initramfs bootlogo_ubuntu.bmp; do
            if [ -f "$MOUNT_POINT/opt/switchroot/bootstack/$f" ]; then
                $SUDO_PREFIX cp "$MOUNT_POINT/opt/switchroot/bootstack/$f" "$BOOTFILES_DIR/"
                echo_success "Copied bootstack: $f"
            fi
        done
    fi
    if [ -f "$MOUNT_POINT/opt/switchroot/bootloader.bin" ]; then
        $SUDO_PREFIX cp "$MOUNT_POINT/opt/switchroot/bootloader.bin" "$BOOTFILES_DIR/"
    fi

    # Cleanup mount
    $SUDO_PREFIX umount "$MOUNT_POINT"
    $SUDO_PREFIX losetup -d "$LOOP_DEV"
    $SUDO_PREFIX chown -R "$(id -u):$(id -g)" "$BOOTFILES_DIR"

    # Download Switchroot boot files as fallback if needed
    if [ "$NEED_SWITCHROOT_KERNEL" = "true" ] || [ "$NEED_SWITCHROOT_DTB" = "true" ]; then
        echo_step "Downloading Switch boot files from Switchroot..."
        local cache_dir="$WORKDIR_ROOT/.cache"
        mkdir -p "$cache_dir"

        local SWITCHROOT_7Z="$cache_dir/switchroot-ubuntu-noble.7z"
        local SWITCHROOT_URL="${SWITCHROOT_REPO:-https://download.switchroot.org/ubuntu-noble/}theofficialgman-ubuntu-unity-noble-5.1.2-2025-08-16.7z"

        # Check cached file validity
        if [ -f "$SWITCHROOT_7Z" ]; then
            local file_size
            file_size=$(stat -c %s "$SWITCHROOT_7Z" 2>/dev/null || echo 0)
            if [ "$file_size" -lt 500000000 ]; then
                echo_warn "Cached Switchroot archive is corrupted, re-downloading..."
                rm -f "$SWITCHROOT_7Z"
            fi
        fi

        if [ ! -f "$SWITCHROOT_7Z" ]; then
            echo "  Downloading Switchroot Ubuntu Noble (~2GB)..."
            curl -L --progress-bar -o "$SWITCHROOT_7Z" "$SWITCHROOT_URL" || {
                echo_error "Failed to download Switchroot archive"
                rm -f "$SWITCHROOT_7Z"
                SWITCHROOT_7Z=""
            }
        fi

        if [ -f "$SWITCHROOT_7Z" ]; then
            local switchroot_extract="$HEKATE_WORKDIR/switchroot-extract"
            mkdir -p "$switchroot_extract"

            if command -v 7z &> /dev/null; then
                7z x -o"$switchroot_extract" "$SWITCHROOT_7Z" "switchroot/ubuntu-noble/*" -y >/dev/null 2>&1 || true
                local ubuntu_noble_dir="$switchroot_extract/switchroot/ubuntu-noble"

                if [ "$NEED_SWITCHROOT_KERNEL" = "true" ] && [ -f "$ubuntu_noble_dir/uImage" ]; then
                    cp "$ubuntu_noble_dir/uImage" "$BOOTFILES_DIR/Image"
                    echo_success "Copied Switchroot L4T kernel"
                fi
                if [ "$NEED_SWITCHROOT_DTB" = "true" ] && [ -f "$ubuntu_noble_dir/nx-plat.dtimg" ]; then
                    cp "$ubuntu_noble_dir/nx-plat.dtimg" "$BOOTFILES_DIR/"
                    echo_success "Copied nx-plat.dtimg from Switchroot"
                fi
                for f in bl31.bin bl33.bin boot.scr; do
                    [ -f "$ubuntu_noble_dir/$f" ] && cp "$ubuntu_noble_dir/$f" "$BOOTFILES_DIR/"
                done
                rm -rf "$switchroot_extract"
            else
                echo_error "p7zip not installed! Install with: sudo apt install p7zip-full"
            fi
        fi
    fi

    # Download coreboot.rom
    echo_step "Downloading coreboot.rom..."
    local cache_dir="$WORKDIR_ROOT/.cache"
    mkdir -p "$cache_dir"

    if [ ! -f "$cache_dir/coreboot.rom" ]; then
        curl -L -o "$cache_dir/coreboot.rom" \
            "https://github.com/lakka-switch/boot-scripts/raw/master/payloads/coreboot.rom" || \
            echo_warn "Failed to download coreboot.rom"
    fi
    [ -f "$cache_dir/coreboot.rom" ] && cp "$cache_dir/coreboot.rom" "$BOOTFILES_DIR/"

    # Create boot.scr
    echo_step "Creating boot.scr..."

    local BOOT_TXT="$BOOTFILES_DIR/boot.txt"
    cat > "$BOOT_TXT" << BOOTSCR
# U-Boot boot script for Switch Linux
# Based on Switchroot boot chain, adapted for initramfs root

echo "=========================================="
echo "       AstralEmu Boot Loader"
echo "=========================================="

# Set defaults
test -n \${boot_dir} || setenv boot_dir /switchroot/${BUILD_NAME}
test -n \${devnum} || setenv devnum 1
test -n \${distro_bootpart} || setenv distro_bootpart 1

# Memory addresses
setenv kernload 0xA0000000
setenv fdtrload 0xA8000000
setenv fdtraddr 0xA8100000
setenv initaddr 0xB0000000

# Detect Switch model SKU
test -n \${sku} || setenv sku 0

# Load kernel
echo "Loading kernel..."
if load mmc \${devnum}:\${distro_bootpart} \${kernload} \${boot_dir}/Image; then
    echo "Kernel loaded"
else
    echo "ERROR: Failed to load kernel!"
    sleep 5
    reset
fi

# Load initramfs
echo "Loading initramfs..."
if load mmc \${devnum}:\${distro_bootpart} \${initaddr} \${boot_dir}/initramfs.img; then
    echo "Initramfs loaded"
else
    echo "ERROR: Failed to load initramfs!"
    sleep 5
    reset
fi

# Load device tree image
echo "Loading device tree..."
if load mmc \${devnum}:\${distro_bootpart} \${fdtrload} \${boot_dir}/nx-plat.dtimg; then
    echo "Device tree image loaded"
    if dtimg load \${fdtrload} \${sku} \${fdtraddr} fdtrsize; then
        echo "Device tree for SKU \${sku} extracted"
    else
        echo "WARNING: Could not extract DTB for SKU, using default"
        setenv fdtraddr \${fdtrload}
    fi
else
    if load mmc \${devnum}:\${distro_bootpart} \${fdtraddr} \${boot_dir}/tegra210-icosa.dtb; then
        echo "Fallback DTB loaded"
    else
        echo "ERROR: No device tree found!"
        sleep 5
        reset
    fi
fi

# Set boot arguments
setenv bootargs "root=/dev/ram0 rw rootwait fbcon=rotate:3 consoleblank=0 quiet"
setenv bootargs "\${bootargs} swlinux.image=${BUILD_NAME} \${bootargs_extra}"

echo "Boot arguments: \${bootargs}"

# Boot
echo "Booting AstralEmu..."
bootm \${kernload} \${initaddr}:\${filesize} \${fdtraddr}
BOOTSCR

    if command -v mkimage &> /dev/null; then
        mkimage -A arm64 -T script -C none -n "AstralEmu" \
            -d "$BOOT_TXT" "$BOOTFILES_DIR/boot.scr"
        rm "$BOOT_TXT"
        echo_success "boot.scr compiled"
    else
        mv "$BOOT_TXT" "$BOOTFILES_DIR/boot.scr.txt"
        echo_warn "mkimage not found - boot.scr not compiled (install u-boot-tools)"
    fi

    # =========================================================================
    # STAGE 5: Assemble final output
    # =========================================================================
    echo_step "Assembling final Hekate package..."

    local OUTPUT_DIR="$WORKDIR_ROOT/output"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local services_suffix
    services_suffix=$(echo "$SERVICES" | tr ' ' '-')
    local FINAL_OUTPUT="$OUTPUT_DIR/${BUILD_NAME}-${services_suffix}-${timestamp}"
    mkdir -p "$FINAL_OUTPUT"

    # Create directory structure (Switchroot layout)
    mkdir -p "$FINAL_OUTPUT/bootloader/ini"
    mkdir -p "$FINAL_OUTPUT/switchroot/${BUILD_NAME}"
    mkdir -p "$FINAL_OUTPUT/linux_img/${BUILD_NAME}/rootfs"
    mkdir -p "$FINAL_OUTPUT/linux_img/${BUILD_NAME}/homefs"

    # Copy boot files
    echo "  Copying boot files..."
    for f in Image nx-plat.dtimg tegra210-icosa.dtb bl31.bin bl33.bin coreboot.rom boot.scr boot.scr.txt bootloader.bin; do
        [ -f "$BOOTFILES_DIR/$f" ] && cp "$BOOTFILES_DIR/$f" "$FINAL_OUTPUT/switchroot/${BUILD_NAME}/"
    done

    # Copy initramfs
    [ -f "$HEKATE_WORKDIR/initramfs.img" ] && \
        cp "$HEKATE_WORKDIR/initramfs.img" "$FINAL_OUTPUT/switchroot/${BUILD_NAME}/"

    # Copy filesystem images
    echo "  Copying rootfs parts..."
    cp "$HEKATE_WORKDIR/rootfs-parts"/* "$FINAL_OUTPUT/linux_img/${BUILD_NAME}/rootfs/"

    echo "  Copying homefs..."
    cp "$HEKATE_WORKDIR/homefs.ext4.part000" "$FINAL_OUTPUT/linux_img/${BUILD_NAME}/homefs/"

    # Create Hekate configuration
    echo "  Creating Hekate config..."
    local hekate_id
    hekate_id=$(echo "${BUILD_NAME}" | tr '[:lower:]-' '[:upper:]_' | cut -c1-8)

    # Copy template if exists, otherwise generate
    local DEVICE_DIR="$WORKDIR_ROOT/devices/$DEVICE_ID"
    if [ -f "$DEVICE_DIR/bootloader/ini/switch-linux.ini.template" ]; then
        sed -e "s|{{BUILD_NAME}}|${BUILD_NAME}|g" \
            -e "s|{{HEKATE_ID}}|${hekate_id}|g" \
            "$DEVICE_DIR/bootloader/ini/switch-linux.ini.template" \
            > "$FINAL_OUTPUT/bootloader/ini/${BUILD_NAME}.ini"
    else
        cat > "$FINAL_OUTPUT/bootloader/ini/${BUILD_NAME}.ini" << EOF
[${BUILD_NAME}]
l4t=1
boot_prefixes=/switchroot/${BUILD_NAME}/
id=${hekate_id}

; Boot arguments passed to kernel
bootargs_extra=quiet swlinux.image=${BUILD_NAME}
EOF
    fi

    # Copy hekate_ipl.ini.example if exists
    if [ -f "$DEVICE_DIR/bootloader/hekate_ipl.ini.example" ]; then
        cp "$DEVICE_DIR/bootloader/hekate_ipl.ini.example" "$FINAL_OUTPUT/bootloader/"
    fi

    # Build summary
    echo_success "Output format hekate complete!"
    echo ""
    echo "  Output: $FINAL_OUTPUT"
    echo "  Structure:"
    find "$FINAL_OUTPUT" -type f | sed "s|$FINAL_OUTPUT|  .|" | sort
    echo ""
    echo "  Copy all folders to SD card root, then boot via Hekate."
}
