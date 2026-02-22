#!/bin/bash
#
# Switch Linux Builder - Base configuration
#

# Distribution info
DISTRO_NAME="Switch Linux"
DISTRO_VERSION="1.0"

# Ubuntu base image (Noble 24.04 LTS)
IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img"

# QEMU settings
QEMU_RAM="4G"
QEMU_CPUS="4"

# Output image name prefix
OUTPUT_NAME="switch-linux"

# Default services (always include base)
SERVICES="base"

# Part sizes in MB (FAT32 limit is 4GB)
ROOTFS_PART_SIZE_MB=3900   # 3.9 GB per part
HOMEFS_PART_SIZE_MB=1900   # 1.9 GB per part

# Description
DESCRIPTION="Ubuntu Noble ARM64 optimized for Nintendo Switch with EmulationStation"

# Switchroot repository for boot files
SWITCHROOT_REPO="https://download.switchroot.org/ubuntu-noble/"

# L4T debs repository (theofficialgman)
L4T_DEBS_URL="https://ethiquema.github.io/l4t-debs"

# Compression settings
SQUASHFS_COMP="zstd"
SQUASHFS_LEVEL=19