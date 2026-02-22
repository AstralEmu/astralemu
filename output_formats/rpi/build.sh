#!/bin/bash
#
# Output format: rpi
# Produces a flashable .img.xz for Raspberry Pi devices
#
# Pipeline:
#   1. Download RaspiOS vendor image
#   2. Merge with merge-debian-raspios.sh
#   3. PiShrink + xz compression
#
# Required variables (set by autobuild):
#   $WORK_IMAGE      - QEMU work image (raw) with configured rootfs
#   $WORKDIR_ROOT    - Project root directory
#   $DEVICE_ID       - Device identifier (e.g. rpi4)
#   $OUTPUT_IMAGE    - Output image filename
#   $IMAGE_SIZE      - Final image size
#
# Required config.sh variables (from devices/<device>/config.sh):
#   $RASPIOS_URL     - URL to RaspiOS vendor image
#   $RASPIOS_IMAGE   - Filename for the downloaded RaspiOS image
#

output_rpi() {
    echo_step "=== OUTPUT FORMAT: rpi ==="
    echo "  Producing flashable Raspberry Pi image"

    # Verify required variables
    if [ -z "$RASPIOS_URL" ]; then
        echo_error "RASPIOS_URL not defined in config.sh"
        exit 1
    fi

    if [ -z "$RASPIOS_IMAGE" ]; then
        echo_error "RASPIOS_IMAGE not defined in config.sh"
        exit 1
    fi

    # --- Step 1: Download RaspiOS vendor image ---
    echo_step "Downloading Raspberry Pi OS vendor image..."

    if [ ! -f "$RASPIOS_IMAGE" ]; then
        if [ ! -f "${RASPIOS_IMAGE}.xz" ]; then
            echo "  Downloading Raspberry Pi OS..."
            wget -c "$RASPIOS_URL" -O "${RASPIOS_IMAGE}.xz"
        fi
        echo "  Decompressing Raspberry Pi OS..."
        unxz -k "${RASPIOS_IMAGE}.xz"
        rm -f "${RASPIOS_IMAGE}.xz"
    else
        echo_success "Raspberry Pi OS already present"
    fi

    # --- Step 2: Merge with merge-debian-raspios.sh ---
    echo_step "Creating hybrid Raspberry Pi image..."
    echo "  Output: $OUTPUT_IMAGE"
    echo "  Size: $IMAGE_SIZE"

    "$(dirname "${BASH_SOURCE[0]}")/merge-debian-raspios.sh" \
        -o "$OUTPUT_IMAGE" \
        -s "$IMAGE_SIZE" \
        "$RASPIOS_IMAGE" \
        "$WORK_IMAGE"

    # --- Step 3: PiShrink + xz compression ---
    echo_step "Compressing image with PiShrink..."

    # Install PiShrink if needed
    if ! command -v pishrink.sh &> /dev/null; then
        echo_warn "PiShrink not found. Installing..."
        wget -q https://raw.githubusercontent.com/Drewsif/PiShrink/master/pishrink.sh -O /tmp/pishrink.sh
        chmod +x /tmp/pishrink.sh
        sudo mv /tmp/pishrink.sh /usr/local/bin/
        echo_success "PiShrink installed"
    fi

    sudo rm -f "$OUTPUT_IMAGE.xz"
    sudo pishrink.sh -aZ "$OUTPUT_IMAGE"

    COMPRESSED="${OUTPUT_IMAGE}.xz"
    if [ -f "$COMPRESSED" ]; then
        SIZE_ORIGINAL=$(du -h "$OUTPUT_IMAGE" 2>/dev/null | cut -f1 || echo "N/A")
        SIZE_COMPRESSED=$(du -h "$COMPRESSED" | cut -f1)
        echo_success "Image compressed: $COMPRESSED"
        echo "  Original size  : $SIZE_ORIGINAL"
        echo "  Compressed size: $SIZE_COMPRESSED"
    else
        echo_error "Compression failed"
        exit 1
    fi

    echo_success "Output format rpi complete: ${OUTPUT_IMAGE}.xz"
    echo ""
    echo "  To flash:"
    echo "  xz -dc ${OUTPUT_IMAGE}.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync"
}
