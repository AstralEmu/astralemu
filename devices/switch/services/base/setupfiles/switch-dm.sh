#!/bin/bash
#
# Switch Display Manager
# Launches alternative DMs from EmulationStation and returns when they close
#

DM="$1"
CURRENT_DM=""

log() {
    echo "[switch-dm] $1"
    logger -t switch-dm "$1"
}

show_help() {
    cat << EOF
Usage: switch-dm <dm_name>

Available display managers:
  emulationstation  - EmulationStation (default)
  plasma-mobile     - Plasma Mobile shell
  xfce              - XFCE desktop
  waydroid          - Waydroid Android container
  kodi              - Kodi media center

Example:
  switch-dm plasma-mobile
EOF
}

stop_current_dm() {
    # Stop all DM services
    for dm in emulationstation plasma-mobile xfce waydroid-session kodi; do
        if systemctl is-active --quiet "${dm}.service" 2>/dev/null; then
            log "Stopping $dm"
            systemctl stop "${dm}.service"
            CURRENT_DM="$dm"
        fi
    done
}

start_dm() {
    local dm="$1"
    local service=""

    case "$dm" in
        emulationstation|es)
            service="emulationstation.service"
            ;;
        plasma-mobile|plasma|tabs)
            service="plasma-mobile.service"
            ;;
        xfce|desktop)
            service="xfce.service"
            ;;
        waydroid|android)
            service="waydroid-session.service"
            ;;
        kodi)
            service="kodi.service"
            ;;
        *)
            log "Unknown display manager: $dm"
            show_help
            return 1
            ;;
    esac

    log "Starting $dm ($service)"
    systemctl start "$service"

    # Wait for service to exit
    while systemctl is-active --quiet "$service" 2>/dev/null; do
        sleep 1
    done

    log "$dm stopped"
}

return_to_es() {
    log "Returning to EmulationStation"
    systemctl start emulationstation.service
}

# Main
if [ -z "$DM" ]; then
    show_help
    exit 1
fi

if [ "$DM" = "-h" ] || [ "$DM" = "--help" ]; then
    show_help
    exit 0
fi

# Stop current DM
stop_current_dm

# Start requested DM
start_dm "$DM"

# If we started something other than ES, return to ES when it closes
if [ "$DM" != "emulationstation" ] && [ "$DM" != "es" ]; then
    return_to_es
fi