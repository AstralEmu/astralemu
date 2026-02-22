#!/bin/bash
# Description: Universal package manager wrappers + repository setup from devices.yml
set -e

echo "=== Preparing build environment ==="

# =============================================================================
# PACKAGE MANAGER DETECTION
# =============================================================================

if command -v apt &> /dev/null; then
    export PKG_MANAGER="apt"
    export DEBIAN_FRONTEND=noninteractive
elif command -v dnf &> /dev/null; then
    export PKG_MANAGER="dnf"
elif command -v pacman &> /dev/null; then
    export PKG_MANAGER="pacman"
else
    echo "ERROR: No supported package manager found (apt, dnf, pacman)"
    exit 1
fi

echo "  Package manager: $PKG_MANAGER"

# =============================================================================
# UNIVERSAL PACKAGE MANAGER WRAPPERS
# Available to all subsequent services (scripts are concatenated by autobuild)
# =============================================================================

pkg_update() {
    case "$PKG_MANAGER" in
        apt)    apt update ;;
        dnf)    dnf check-update || true ;;
        pacman) pacman -Sy --noconfirm ;;
    esac
}

pkg_install() {
    case "$PKG_MANAGER" in
        apt)    apt install --no-install-recommends -y "$@" ;;
        dnf)    dnf install -y "$@" ;;
        pacman) pacman -S --noconfirm "$@" ;;
    esac
}

pkg_remove() {
    case "$PKG_MANAGER" in
        apt)    apt purge -y "$@" ;;
        dnf)    dnf remove -y "$@" ;;
        pacman) pacman -Rns --noconfirm "$@" ;;
    esac
}

pkg_upgrade() {
    case "$PKG_MANAGER" in
        apt)    apt upgrade -y ;;
        dnf)    dnf upgrade -y ;;
        pacman) pacman -Syu --noconfirm ;;
    esac
}

pkg_clean() {
    case "$PKG_MANAGER" in
        apt)
            apt autoremove -y --purge
            apt clean
            rm -rf /var/lib/apt/lists/*
            ;;
        dnf)
            dnf autoremove -y
            dnf clean all
            ;;
        pacman)
            pacman -Sc --noconfirm
            ;;
    esac
}

repo_add() {
    local name="$1" url="$2" key_url="$3" suites="$4" components="$5" signed_by="$6"
    echo "  Adding repo: $name"

    case "$PKG_MANAGER" in
        apt)
            local signed_by_line=""

            # GPG key: download from URL or use local path
            if [ -n "$signed_by" ] && [ "$signed_by" != "null" ]; then
                signed_by_line="Signed-By: $signed_by"
            elif [ -n "$key_url" ] && [ "$key_url" != "null" ]; then
                mkdir -p /usr/share/keyrings
                curl -fsSL "$key_url" | gpg --dearmor -o "/usr/share/keyrings/astralemu-${name}.gpg"
                signed_by_line="Signed-By: /usr/share/keyrings/astralemu-${name}.gpg"
            fi

            # Suites and components from YAML
            local suites_line="Suites: ./"
            local components_line=""
            if [ -n "$suites" ] && [ "$suites" != "null" ]; then
                suites_line="Suites: $suites"
                if [ -n "$components" ] && [ "$components" != "null" ]; then
                    components_line="Components: $components"
                fi
            fi

            # Write DEB822 sources file
            {
                echo "Types: deb"
                echo "URIs: $url"
                echo "$suites_line"
                [ -n "$components_line" ] && echo "$components_line"
                [ -n "$signed_by_line" ] && echo "$signed_by_line"
            } > "/etc/apt/sources.list.d/astralemu-${name}.sources"
            ;;
        dnf)
            cat > "/etc/yum.repos.d/astralemu-${name}.repo" << REPOEOF
[astralemu-${name}]
name=AstralEmu - ${name}
baseurl=${url}
enabled=1
gpgcheck=0
REPOEOF
            ;;
        pacman)
            if ! grep -q "\[astralemu-${name}\]" /etc/pacman.conf 2>/dev/null; then
                cat >> /etc/pacman.conf << REPOEOF

[astralemu-${name}]
Server = ${url}
SigLevel = Optional TrustAll
REPOEOF
            fi
            ;;
    esac
}

# =============================================================================
# YAML-BASED PACKAGE INSTALLER
# Reads packages from /etc/setupfiles/packages/<service>.yml
# YAML format: packages.apt[] + packages.<distro_id>[] merged for apt,
#              packages.fedora[] for dnf, packages.arch[] for pacman
# =============================================================================

pkg_service_install() {
    local service="$1"
    local yml="/etc/setupfiles/packages/${service}.yml"

    if [ ! -f "$yml" ]; then
        echo "ERROR: packages.yml not found for service: $service"
        return 1
    fi

    local packages=""
    case "$PKG_MANAGER" in
        apt)
            local apt_pkgs=$(yq -r '.packages.apt // [] | .[]' "$yml" 2>/dev/null | tr '\n' ' ')
            local distro_pkgs=$(yq -r ".packages.${DISTRO_ID} // [] | .[]" "$yml" 2>/dev/null | tr '\n' ' ')
            packages="$apt_pkgs $distro_pkgs"
            ;;
        dnf)
            packages=$(yq -r '.packages.fedora // [] | .[]' "$yml" 2>/dev/null | tr '\n' ' ')
            ;;
        pacman)
            packages=$(yq -r '.packages.arch // [] | .[]' "$yml" 2>/dev/null | tr '\n' ' ')
            ;;
    esac

    packages=$(echo "$packages" | xargs)
    if [ -z "$packages" ]; then
        echo "  No packages defined for $service ($PKG_MANAGER/$DISTRO_ID)"
        return 0
    fi

    echo "  Installing $service packages..."
    pkg_install $packages
}

# =============================================================================
# BOOTSTRAP: minimal packages needed for repo setup
# =============================================================================

pkg_update

case "$PKG_MANAGER" in
    apt)    pkg_install ca-certificates curl gnupg ;;
    dnf)    pkg_install ca-certificates curl gnupg2 ;;
    pacman) pkg_install ca-certificates curl gnupg ;;
esac

# =============================================================================
# INSTALL YQ (YAML parser — single static binary)
# =============================================================================

if ! command -v yq &> /dev/null; then
    echo "  Installing yq for YAML parsing..."
    case "$(uname -m)" in
        aarch64) YQ_ARCH="arm64" ;;
        x86_64)  YQ_ARCH="amd64" ;;
        armv7l)  YQ_ARCH="arm" ;;
        *)       YQ_ARCH="$(uname -m)" ;;
    esac
    curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${YQ_ARCH}" \
        -o /usr/local/bin/yq
    chmod +x /usr/local/bin/yq
fi

# =============================================================================
# REPOSITORY SETUP FROM devices.yml
# =============================================================================

echo "=== Configuring repositories from devices.yml ==="

DEVICES_YML="/etc/setupfiles/devices.yml"

if [ ! -f "$DEVICES_YML" ]; then
    echo "WARNING: $DEVICES_YML not found, skipping repo setup"
else
    YQ_PREFIX=".devices[] | select(.id == \"$DEVICE_ID\") | .distros[] | select(.id == \"$DISTRO_ID\")"
    REPO_COUNT=$(yq "$YQ_PREFIX | .repos | length" "$DEVICES_YML")

    if [ -n "$REPO_COUNT" ] && [ "$REPO_COUNT" != "null" ] && [ "$REPO_COUNT" -gt 0 ]; then
        for i in $(seq 0 $((REPO_COUNT - 1))); do
            REPO_NAME=$(yq "$YQ_PREFIX | .repos[$i].name" "$DEVICES_YML")
            REPO_URL=$(yq "$YQ_PREFIX | .repos[$i].url" "$DEVICES_YML")
            REPO_KEY=$(yq "$YQ_PREFIX | .repos[$i].key_url" "$DEVICES_YML")
            REPO_SUITES=$(yq "$YQ_PREFIX | .repos[$i].suites" "$DEVICES_YML")
            REPO_COMPONENTS=$(yq "$YQ_PREFIX | .repos[$i].components" "$DEVICES_YML")
            REPO_SIGNED_BY=$(yq "$YQ_PREFIX | .repos[$i].signed_by" "$DEVICES_YML")
            repo_add "$REPO_NAME" "$REPO_URL" "$REPO_KEY" "$REPO_SUITES" "$REPO_COMPONENTS" "$REPO_SIGNED_BY"
        done
    else
        echo "  No repos defined for $DEVICE_ID/$DISTRO_ID"
    fi
fi

# Final update after all repos added
pkg_update

echo "=== Build environment ready ==="
