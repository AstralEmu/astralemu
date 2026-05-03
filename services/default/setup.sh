#!/bin/bash
# Description: Wayland + cage + EmulationStation (default UI)
set -e

echo "=== Installing default UI (EmulationStation) ==="

# Wayland stack from packages.yml
pkg_service_install default

# ES-DE package name is dynamic (uses $PKG_DEVICE_ID from device repo)
pkg_install emulationstation-de-$PKG_DEVICE_ID

# Install setperf if available, otherwise create a pass-through wrapper
if pkg_install setperf 2>/dev/null; then
    echo "  setperf installed"
else
    echo "  setperf not available for this device, creating pass-through wrapper"
    cat > /usr/local/bin/setperf << 'WRAPPER'
#!/bin/bash
# setperf not available on this device — skip perf flags and exec the command
while [ $# -gt 0 ]; do
    case "$1" in
        -p|--oc|-n) shift 2 ;;
        -*) shift ;;
        *) break ;;
    esac
done
exec "$@"
WRAPPER
    chmod +x /usr/local/bin/setperf
fi


# =============================================================================
# EMULATIONSTATION SERVICE
# =============================================================================

cat > /etc/systemd/system/emulationstation.service << EOF
[Unit]
Description=EmulationStation Frontend
After=graphical.target
Wants=graphical.target
Conflicts=phosh.service xfce.service waydroid-session.service kodi.service

[Service]
Type=simple
User=$DEVICE_USER
Group=$DEVICE_USER
PAMName=login

Environment=XDG_RUNTIME_DIR=/run/user/1000
Environment=XDG_SESSION_TYPE=wayland
Environment=WAYLAND_DISPLAY=wayland-1
Environment=SDL_VIDEODRIVER=wayland

ExecStart=/usr/bin/setperf -p battery --oc battery /usr/bin/cage -s -- emulationstation --no-splash

Restart=on-failure
RestartSec=3
SuccessExitStatus=0 1

[Install]
WantedBy=graphical.target
EOF

# User runtime directory
mkdir -p /etc/tmpfiles.d
echo "d /run/user/1000 0700 $DEVICE_USER $DEVICE_USER -" > /etc/tmpfiles.d/user-runtime.conf

# =============================================================================
# EMULATIONSTATION CONFIGURATION
# =============================================================================

mkdir -p $DEVICE_HOME/.emulationstation/systems

# System switcher config
cat > $DEVICE_HOME/.emulationstation/es_systems.cfg << EOF
<?xml version="1.0"?>
<systemList>
    <system>
        <name>switch</name>
        <fullname>System Menu</fullname>
        <path>$DEVICE_HOME/.emulationstation/systems</path>
        <extension>.sh</extension>
        <command>%ROM%</command>
        <platform>switch</platform>
        <theme>switch</theme>
    </system>
</systemList>
EOF

# Note: Each service (tabs, desktop, android, kodi) creates its own launcher script

# ES settings
cat > $DEVICE_HOME/.emulationstation/es_settings.cfg << 'EOF'
<?xml version="1.0"?>
<config>
    <string name="AudioDevice" value="default" />
    <bool name="EnableSounds" value="true" />
    <string name="TransitionStyle" value="instant" />
    <bool name="VSync" value="true" />
</config>
EOF

chown -R $DEVICE_USER:$DEVICE_USER $DEVICE_HOME/.emulationstation

# Enable as default
systemctl enable emulationstation.service
systemctl set-default graphical.target

echo "=== Default UI installation complete ==="
