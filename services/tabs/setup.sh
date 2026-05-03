#!/bin/bash
# Description: Plasma Mobile shell (tablet mode)
set -e

echo "=== Installing Plasma Mobile ==="

pkg_service_install tabs

# =============================================================================
# PLASMA MOBILE SERVICE
# =============================================================================

cat > /etc/systemd/system/plasma-mobile.service << EOF
[Unit]
Description=Plasma Mobile Shell
After=graphical.target
Wants=graphical.target
Conflicts=emulationstation.service xfce.service waydroid-session.service kodi.service

[Service]
Type=simple
User=$DEVICE_USER
Group=$DEVICE_USER
PAMName=login

Environment=XDG_RUNTIME_DIR=/run/user/1000
Environment=XDG_SESSION_TYPE=wayland
Environment=WAYLAND_DISPLAY=wayland-1
Environment=XDG_CURRENT_DESKTOP=KDE
Environment=XDG_SESSION_DESKTOP=plasma-mobile
Environment=QT_QPA_PLATFORM=wayland
Environment=QT_WAYLAND_DISABLE_WINDOWDECORATION=1

ExecStart=/usr/bin/setperf -p balanced --oc off /usr/bin/dbus-run-session /usr/bin/startplasmamobile

Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical.target
EOF

# =============================================================================
# KWIN PERFORMANCE OPTIMIZATION (disable blur, transparency, keep animations)
# =============================================================================

echo "Configuring KWin for performance..."

mkdir -p $DEVICE_HOME/.config

# KWin config - disable blur and transparency effects
cat > $DEVICE_HOME/.config/kwinrc << 'EOF'
[Compositing]
Backend=OpenGL
GLCore=true
GLPreferBufferSwap=a
HiddenPreviews=5
OpenGLIsUnsafe=false
WindowsBlockCompositing=true

[Effect-blur]
BlurStrength=0
NoiseStrength=0

[Effect-slidingpopups]
SlideInTime=150
SlideOutTime=150

[Plugins]
blurEnabled=false
contrastEnabled=false
kwin4_effect_fadeEnabled=true
kwin4_effect_translucencyEnabled=false
slidingpopupsEnabled=true
slideEnabled=true
scaleEnabled=true
zoomEnabled=false

[Windows]
BorderlessMaximizedWindows=true

[org.kde.kdecoration2]
BorderSize=None
BorderSizeAuto=false
EOF

# Plasma desktop effects - minimal for performance
cat > $DEVICE_HOME/.config/plasmarc << 'EOF'
[Theme]
name=breeze-dark

[Wallpapers]
usersWallpapers=
EOF

# KDE globals - disable animations that are too heavy
cat > $DEVICE_HOME/.config/kdeglobals << 'EOF'
[General]
TerminalApplication=konsole
TerminalService=org.kde.konsole.desktop

[KDE]
AnimationDurationFactor=0.5
ShowDeleteCommand=true
SingleClick=false
widgetStyle=Breeze

[KScreen]
ScaleFactor=1.5
ScreenScaleFactors=

[Icons]
Theme=breeze-dark
EOF

# Disable desktop search/indexing for performance
cat > $DEVICE_HOME/.config/baloofilerc << 'EOF'
[Basic Settings]
Indexing-Enabled=false
EOF

# Plasma shell config
cat > $DEVICE_HOME/.config/plasmashellrc << 'EOF'
[PlasmaViews][Panel 2]
floating=0

[Updates]
CheckForUpdates=false
EOF

# Discover config - Flatpak only (rootfs is read-only)
mkdir -p $DEVICE_HOME/.config/discoverrc
cat > $DEVICE_HOME/.config/discoverrc << 'EOF'
[Software]
UseOfflineUpdates=false

[Backends]
FlatpakBackend=true
PackageKitBackend=false
SnapBackend=false
FwupdBackend=false
EOF

# =============================================================================
# RETURN TO ES SHORTCUT
# =============================================================================

mkdir -p $DEVICE_HOME/.local/share/applications

cat > $DEVICE_HOME/.local/share/applications/return-to-es.desktop << 'EOF'
[Desktop Entry]
Name=Return to EmulationStation
Comment=Close Plasma Mobile and return to EmulationStation
Exec=/usr/local/bin/switch-dm emulationstation
Icon=go-home
Terminal=false
Type=Application
Categories=System;
EOF

# =============================================================================
# EMULATIONSTATION LAUNCHER
# =============================================================================

mkdir -p $DEVICE_HOME/.emulationstation/systems

cat > $DEVICE_HOME/.emulationstation/systems/plasma.sh << 'EOF'
#!/bin/bash
# Launch Plasma Mobile
/usr/local/bin/switch-dm plasma-mobile
EOF
chmod +x $DEVICE_HOME/.emulationstation/systems/plasma.sh

chown -R $DEVICE_USER:$DEVICE_USER $DEVICE_HOME/.config
chown -R $DEVICE_USER:$DEVICE_USER $DEVICE_HOME/.local
chown -R $DEVICE_USER:$DEVICE_USER $DEVICE_HOME/.emulationstation

# Disable SDDM (we use our own service)
systemctl disable sddm 2>/dev/null || true

echo "=== Plasma Mobile installation complete ==="
