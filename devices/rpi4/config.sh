#!/bin/bash
# AstralEmu - Raspberry Pi 4 device configuration
#
# Variables specific to this device that are NOT in devices.yml.
# QEMU settings, base_image_url, repos are all in devices.yml.

# RaspiOS vendor image (used by output_formats/rpi/ for merge)
RASPIOS_URL="https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2025-11-24/2025-11-24-raspios-trixie-arm64-lite.img.xz"
RASPIOS_IMAGE="2025-11-24-raspios-trixie-arm64-lite.img"
