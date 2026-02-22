#!/bin/bash
# Base service - Common system configuration for all images
# This script installs essential packages, RaspiOS kernel/firmware, and sets up basic system configuration
set -e

echo "====== BASE SERVICE ======"

# System update
echo "[BASE] Updating system..."
pkg_upgrade

# Remove default distro kernel BEFORE installing device-specific kernel
echo "[BASE] Removing default kernel..."
case "$PKG_MANAGER" in
    apt)
        apt purge -y 'linux-image-*' 'linux-headers-*' 'linux-kbuild-*' || true
        ;;
    dnf)
        dnf remove -y 'kernel' 'kernel-core' 'kernel-modules' 'kernel-modules-core' 'kernel-modules-extra' || true
        ;;
    pacman)
        pacman -Rdd --noconfirm linux-aarch64 linux-aarch64-headers uboot-raspberrypi 2>/dev/null || true
        ;;
esac

# Install essential packages + kernel/firmware + WiFi drivers
echo "[BASE] Installing packages..."
pkg_service_install base

pkg_upgrade

# System configuration
echo "[BASE] System configuration..."

# Timezone
timedatectl set-timezone Europe/Paris || true

# Locale
locale-gen fr_FR.UTF-8 || true

# Install services-first-boot service (will be populated by other services)
echo "Installing services-first-boot service..."
if [ -f /etc/setupfiles/services-first-boot.sh ] && [ -f /etc/setupfiles/services-first-boot.service ]; then
    mv /etc/setupfiles/services-first-boot.sh /usr/local/bin/services-first-boot.sh
    chmod +x /usr/local/bin/services-first-boot.sh
    mv /etc/setupfiles/services-first-boot.service /etc/systemd/system/services-first-boot.service
    systemctl daemon-reload
    systemctl enable services-first-boot.service
    echo "  services-first-boot installed"
else
    echo "  Warning: services-first-boot files not found in setupfiles"
fi

# Enable SSH and NetworkManager at boot
echo "[BASE] Enabling SSH and NetworkManager..."
systemctl enable NetworkManager
systemctl enable ssh

echo "====== BASE SERVICE COMPLETE ======"
