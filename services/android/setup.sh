#!/bin/bash
# Description: Waydroid Android container with GApps
set -e

echo "=== Installing Waydroid (Android) ==="

# =============================================================================
# REPOSITORY (Waydroid needs its own repo)
# =============================================================================

case "$PKG_MANAGER" in
    apt)
        # Detect codename for Waydroid repo suite (noble, trixie, bookworm, etc.)
        DISTRO_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")

        curl -fsSL https://repo.waydro.id/waydroid.gpg | \
            gpg --dearmor -o /usr/share/keyrings/waydroid-archive-keyring.gpg

        cat > /etc/apt/sources.list.d/waydroid.sources << EOF
Types: deb
URIs: https://repo.waydro.id/
Suites: $DISTRO_CODENAME
Components: main
Signed-By: /usr/share/keyrings/waydroid-archive-keyring.gpg
EOF
        pkg_update
        ;;
    dnf)
        curl -fsSL "https://copr.fedorainfracloud.org/coprs/aleasto/waydroid/repo/fedora-$(rpm -E %fedora)/aleasto-waydroid-fedora-$(rpm -E %fedora).repo" \
            -o /etc/yum.repos.d/aleasto-waydroid.repo
        ;;
    pacman)
        # Waydroid is in the official extra repository
        ;;
esac

# =============================================================================
# PACKAGES
# =============================================================================

pkg_service_install android

# =============================================================================
# WAYDROID FIRST-BOOT SERVICE
# =============================================================================

cat > /etc/systemd/system/waydroid-first-boot.service << EOF
[Unit]
Description=Waydroid First Boot Setup (GApps)
After=network-online.target
Wants=network-online.target
ConditionPathExists=!$DEVICE_HOME/.waydroid-initialized

[Service]
Type=oneshot
User=root
ExecStart=/usr/local/bin/waydroid-first-boot.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat > /usr/local/bin/waydroid-first-boot.sh << FBEOF
#!/bin/bash
LOG_FILE="/var/log/waydroid-first-boot.log"

log() {
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" | tee -a "\$LOG_FILE"
}

log "Starting Waydroid first boot setup..."

# Wait for network
for i in \$(seq 1 30); do
    if ping -c 1 google.com &>/dev/null; then
        log "Network available"
        break
    fi
    sleep 2
done

# Initialize Waydroid with GAPPS
log "Initializing Waydroid with GApps..."
waydroid init -s GAPPS -c https://ota.waydro.id/system -v https://ota.waydro.id/vendor

if [ \$? -eq 0 ]; then
    log "Waydroid initialized successfully"
    touch $DEVICE_HOME/.waydroid-initialized
    chown $DEVICE_USER:$DEVICE_USER $DEVICE_HOME/.waydroid-initialized
else
    log "ERROR: Waydroid initialization failed"
    exit 1
fi
FBEOF

chmod +x /usr/local/bin/waydroid-first-boot.sh

# =============================================================================
# WAYDROID SESSION SERVICE
# =============================================================================

cat > /etc/systemd/system/waydroid-session.service << EOF
[Unit]
Description=Waydroid Android Session
After=waydroid-first-boot.service waydroid-container.service
Wants=waydroid-container.service
Conflicts=emulationstation.service phosh.service xfce.service kodi.service

[Service]
Type=simple
User=$DEVICE_USER
Group=$DEVICE_USER
PAMName=login

Environment=XDG_RUNTIME_DIR=/run/user/1000
Environment=XDG_SESSION_TYPE=wayland
Environment=WAYLAND_DISPLAY=wayland-1

ExecStart=/usr/bin/setperf -p performance --oc oc -n 4 /usr/bin/cage -s -- waydroid show-full-ui

Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical.target
EOF

systemctl enable waydroid-container.service 2>/dev/null || true
systemctl enable waydroid-first-boot.service

# =============================================================================
# WAYDROID CONFIGURATION
# =============================================================================

mkdir -p $DEVICE_HOME/.local/share/waydroid
mkdir -p /var/lib/waydroid

cat > /var/lib/waydroid/waydroid.cfg << 'EOF'
[waydroid]
vendor_type = MAINLINE
system_datetime = 1970-01-01
suspend_action = freeze
auto_adb = True

[properties]
ro.hardware.gralloc = gbm
ro.hardware.egl = mesa
persist.waydroid.multi_windows = false
persist.waydroid.cursor_on_subsurface = true
EOF

# Return to ES shortcut
mkdir -p $DEVICE_HOME/.local/share/applications

cat > $DEVICE_HOME/.local/share/applications/waydroid-exit.desktop << 'EOF'
[Desktop Entry]
Name=Exit to EmulationStation
Comment=Close Waydroid and return to EmulationStation
Exec=/usr/local/bin/switch-dm emulationstation
Icon=application-exit
Terminal=false
Type=Application
Categories=System;
EOF

# =============================================================================
# EMULATIONSTATION LAUNCHER
# =============================================================================

mkdir -p $DEVICE_HOME/.emulationstation/systems

cat > $DEVICE_HOME/.emulationstation/systems/waydroid.sh << 'EOF'
#!/bin/bash
# Launch Waydroid (Android)
/usr/local/bin/switch-dm waydroid
EOF
chmod +x $DEVICE_HOME/.emulationstation/systems/waydroid.sh

chown -R $DEVICE_USER:$DEVICE_USER $DEVICE_HOME/.local
chown -R $DEVICE_USER:$DEVICE_USER $DEVICE_HOME/.waydroid 2>/dev/null || true
chown -R $DEVICE_USER:$DEVICE_USER $DEVICE_HOME/.emulationstation

echo "=== Waydroid installation complete ==="
echo "Note: GApps will be downloaded on first boot (requires internet)"
