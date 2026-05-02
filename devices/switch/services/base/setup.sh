#!/bin/bash
# Description: Base system with L4T kernel, zram, Joy-Con support
set -e

echo "=== Installing base system ==="

# =============================================================================
# PACKAGES INSTALLATION
# =============================================================================

echo "=== Installing packages ==="

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
        pacman -Rdd --noconfirm linux-aarch64 linux-aarch64-headers 2>/dev/null || true
        ;;
esac

# Create image_prep flag BEFORE install so postinst sees it and skips boot disk mount
mkdir -p /opt/switchroot
touch /opt/switchroot/image_prep

# Create apport blacklist dir (switch-bsp postinst writes to it)
mkdir -p /etc/apport/blacklist.d

pkg_service_install base

# Copy boot files from switch-bsp to /boot for image extraction (stage 3)
if [[ -d /opt/switchroot/bootstack ]]; then
    cp -a /opt/switchroot/bootstack/* /boot/ 2>/dev/null || true
    cp /opt/switchroot/modules.tar.gz /boot/ 2>/dev/null || true
    cp /opt/switchroot/bootloader.bin /boot/ 2>/dev/null || true
fi

# Stop zram during build (no module in QEMU)
systemctl stop zramswap 2>/dev/null || true

# =============================================================================
# REMOVE BLOAT
# =============================================================================

case "$PKG_MANAGER" in
    apt)
        pkg_remove unattended-upgrades snapd 2>/dev/null || true

        # Prevent snap from being reinstalled
        cat > /etc/apt/preferences.d/nosnap.pref << 'EOF'
Package: snapd
Pin: release a=*
Pin-Priority: -10
EOF
        ;;
    dnf)
        ;;
    pacman)
        ;;
esac

# =============================================================================
# FLATPAK CONFIGURATION
# =============================================================================

echo "=== Configuring Flatpak ==="

# Add Flathub repository
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

# =============================================================================
# SYSTEM CONFIGURATION
# =============================================================================

echo "=== Configuring system ==="

# Configure zram (50% of RAM, zstd compression)
cat > /etc/default/zramswap << 'EOF'
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF

# Create switch user
if ! id -u switch &>/dev/null; then
    useradd -m -G sudo,video,audio,input,render,bluetooth -s /bin/bash switch
    echo "switch:switch" | chpasswd
fi

# Passwordless sudo
echo "switch ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/switch

# Hostname
echo "switch-linux" > /etc/hostname

cat > /etc/hosts << 'EOF'
127.0.0.1   localhost
127.0.1.1   switch-linux
::1         localhost ip6-localhost ip6-loopback
EOF

# Enable services
systemctl enable NetworkManager
systemctl enable bluetooth
systemctl enable zramswap
systemctl enable ssh

# =============================================================================
# WAYLAND ENVIRONMENT VARIABLES (system-wide)
# =============================================================================

echo "=== Configuring Wayland environment ==="

mkdir -p /etc/environment.d
# System-wide environment for Wayland/Qt/SDL
cat > /etc/environment.d/50-wayland.conf << 'EOF'
# Wayland session
WAYLAND_DISPLAY=wayland-0
XDG_SESSION_TYPE=wayland

# Qt Wayland
QT_QPA_PLATFORM=wayland
QT_WAYLAND_DISABLE_WINDOWDECORATION=1

# SDL Wayland
SDL_VIDEODRIVER=wayland

# GTK Wayland
GDK_BACKEND=wayland

# Clutter/Mutter
CLUTTER_BACKEND=wayland

# EGL/Vulkan
__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_nvidia.json
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json
EOF

# Also set in profile.d for login shells
cat > /etc/profile.d/wayland.sh << 'EOF'
# Wayland environment variables
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export XDG_SESSION_TYPE=wayland
export QT_QPA_PLATFORM=wayland
export QT_WAYLAND_DISABLE_WINDOWDECORATION=1
export SDL_VIDEODRIVER=wayland
export GDK_BACKEND=wayland
export CLUTTER_BACKEND=wayland
export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_nvidia.json
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json
EOF
chmod +x /etc/profile.d/wayland.sh

# =============================================================================
# HOMEFS EXPANSION SERVICE
# =============================================================================

echo "=== Installing homefs expansion service ==="

cp /etc/setupfiles/homefs-expand.service /etc/systemd/system/
cp /etc/setupfiles/homefs-expand-daemon.sh /usr/local/bin/
chmod +x /usr/local/bin/homefs-expand-daemon.sh
systemctl enable homefs-expand.service

# =============================================================================
# SERVICES FIRST-BOOT SERVICE
# =============================================================================

echo "=== Installing services first-boot service ==="

cp /etc/setupfiles/services-first-boot.service /etc/systemd/system/
cp /etc/setupfiles/services-first-boot.sh /usr/local/bin/
chmod +x /usr/local/bin/services-first-boot.sh
systemctl enable services-first-boot.service

# =============================================================================
# DISPLAY MANAGER SWITCH SCRIPT
# =============================================================================

cp /etc/setupfiles/switch-dm.sh /usr/local/bin/switch-dm
chmod +x /usr/local/bin/switch-dm

echo "=== Base system installation complete ==="
