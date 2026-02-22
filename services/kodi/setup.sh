#!/bin/bash
# Description: Kodi media center
set -e

echo "=== Installing Kodi ==="

pkg_service_install kodi

# =============================================================================
# KODI SERVICE
# =============================================================================

cat > /etc/systemd/system/kodi.service << EOF
[Unit]
Description=Kodi Media Center
After=graphical.target
Wants=graphical.target
Conflicts=emulationstation.service phosh.service xfce.service waydroid-session.service

[Service]
Type=simple
User=$DEVICE_USER
Group=$DEVICE_USER
PAMName=login

Environment=XDG_RUNTIME_DIR=/run/user/1000
Environment=XDG_SESSION_TYPE=wayland
Environment=WAYLAND_DISPLAY=wayland-1

ExecStart=/usr/bin/setperf -p balanced --oc off /usr/bin/cage -s -- kodi --standalone

Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical.target
EOF

# =============================================================================
# KODI CONFIGURATION (configs in DEVICE_HOME, data paths in DATA_ROOT)
# =============================================================================

mkdir -p $DEVICE_HOME/.kodi/userdata/keymaps

cat > $DEVICE_HOME/.kodi/userdata/advancedsettings.xml << 'EOF'
<advancedsettings version="1.0">
    <video>
        <allowlanczos3>false</allowlanczos3>
    </video>
    <gui>
        <algorithmdirtyregions>3</algorithmdirtyregions>
    </gui>
    <cache>
        <memorysize>52428800</memorysize>
        <buffermode>1</buffermode>
        <readfactor>4</readfactor>
    </cache>
    <network>
        <disableipv6>true</disableipv6>
    </network>
</advancedsettings>
EOF

cat > $DEVICE_HOME/.kodi/userdata/guisettings.xml << 'EOF'
<settings version="2">
    <setting id="lookandfeel.skin">skin.estuary</setting>
    <setting id="locale.language">resource.language.en_gb</setting>
    <setting id="videoplayer.useamcodec">false</setting>
    <setting id="videoplayer.usemediacodec">false</setting>
    <setting id="screensaver.mode">screensaver.xbmc.builtin.dim</setting>
    <setting id="screensaver.time">5</setting>
    <setting id="audiooutput.channels">2</setting>
    <setting id="audiooutput.passthrough">false</setting>
</settings>
EOF

cat > $DEVICE_HOME/.kodi/userdata/sources.xml << EOF
<sources>
    <programs>
        <default pathversion="1"></default>
    </programs>
    <video>
        <default pathversion="1"></default>
        <source>
            <name>Videos</name>
            <path pathversion="1">$DATA_ROOT/kodi/Videos/</path>
            <allowsharing>true</allowsharing>
        </source>
    </video>
    <music>
        <default pathversion="1"></default>
        <source>
            <name>Music</name>
            <path pathversion="1">$DATA_ROOT/kodi/Music/</path>
            <allowsharing>true</allowsharing>
        </source>
    </music>
    <pictures>
        <default pathversion="1"></default>
        <source>
            <name>Pictures</name>
            <path pathversion="1">$DATA_ROOT/kodi/Pictures/</path>
            <allowsharing>true</allowsharing>
        </source>
    </pictures>
    <files>
        <default pathversion="1"></default>
        <source>
            <name>Storage</name>
            <path pathversion="1">$DATA_ROOT/</path>
            <allowsharing>true</allowsharing>
        </source>
    </files>
</sources>
EOF

cat > $DEVICE_HOME/.kodi/userdata/keymaps/joycon.xml << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<keymap>
    <global>
        <joystick name="Nintendo Switch Pro Controller">
            <button id="1">Select</button>
            <button id="2">Back</button>
            <button id="3">ContextMenu</button>
            <button id="4">OSD</button>
            <button id="5">Info</button>
            <button id="6">Home</button>
            <button id="7">SkipPrevious</button>
            <button id="8">SkipNext</button>
        </joystick>
    </global>
</keymap>
EOF

# Note: Data directories are created at first boot via first-boot/init.sh

# =============================================================================
# EMULATIONSTATION LAUNCHER
# =============================================================================

mkdir -p $DEVICE_HOME/.emulationstation/systems

cat > $DEVICE_HOME/.emulationstation/systems/kodi.sh << 'EOF'
#!/bin/bash
# Launch Kodi media center
/usr/local/bin/switch-dm kodi
EOF
chmod +x $DEVICE_HOME/.emulationstation/systems/kodi.sh

chown -R $DEVICE_USER:$DEVICE_USER $DEVICE_HOME/.kodi
chown -R $DEVICE_USER:$DEVICE_USER $DEVICE_HOME/.emulationstation

echo "=== Kodi installation complete ==="
