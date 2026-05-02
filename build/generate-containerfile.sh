#!/usr/bin/env bash
# generate-containerfile.sh — produces build/Containerfile from YAML manifests
# 
# Usage:
#   ./build/generate-containerfile.sh <device_id> <distro_id> <services...>
#
# This script:
# 1. Reads device/distro config from devices.yml
# 2. Resolves service dependencies
# 3. Generates a multi-stage Containerfile with one stage per service
# 4. Outputs to build/Containerfile

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

# Source libraries
source "$REPO_ROOT/shared/lib/yaml.sh"
source "$REPO_ROOT/shared/lib/service-loader.sh"

# Arguments
DEVICE_ID="${1:-}"
DISTRO_ID="${2:-}"
shift 2 || true
SERVICES=("$@")

if [[ -z "$DEVICE_ID" || -z "$DISTRO_ID" ]]; then
    echo "Usage: $0 <device_id> <distro_id> <services...>" >&2
    exit 1
fi

# Get base image URL from devices.yml
BASE_IMAGE_URL=$(yq -r ".devices[] | select(.id == \"$DEVICE_ID\") | .distros[] | select(.id == \"$DISTRO_ID\") | .base_image_url" "$REPO_ROOT/devices.yml")

if [[ -z "$BASE_IMAGE_URL" || "$BASE_IMAGE_URL" == "null" ]]; then
    echo "Error: base_image_url not found for $DEVICE_ID/$DISTRO_ID" >&2
    exit 1
fi

echo "Generating Containerfile for $DEVICE_ID/$DISTRO_ID"
echo "  Base image: $BASE_IMAGE_URL"
echo "  Services: ${SERVICES[*]}"

# Resolve service dependencies (topological order)
mapfile -t ORDERED_SERVICES < <(services_list_topo "$DEVICE_ID" "${SERVICES[@]}")
echo "  Build order: ${ORDERED_SERVICES[*]}"

# Get base packages from prepare service
PREPARE_PATH=$(resolve_service_path "$DEVICE_ID" "prepare")
BASE_PACKAGES=""
if [[ -f "$PREPARE_PATH/packages.yml" ]]; then
    BASE_PACKAGES=$(yq -r '.packages.fedora // [] | .[]' "$PREPARE_PATH/packages.yml" 2>/dev/null | tr '\n' ' ' | xargs)
fi
[[ -z "$BASE_PACKAGES" ]] && BASE_PACKAGES="curl gnupg2"
echo "  Base packages: $BASE_PACKAGES"

# Read template
TEMPLATE="$REPO_ROOT/build/templates/Containerfile.tmpl"
if [[ ! -f "$TEMPLATE" ]]; then
    echo "Error: Template not found: $TEMPLATE" >&2
    exit 1
fi

CONTAINERFILE_CONTENT=$(cat "$TEMPLATE")

# Substitute base values
CONTAINERFILE_CONTENT="${CONTAINERFILE_CONTENT//__BASE_IMAGE_URL__/$BASE_IMAGE_URL}"
CONTAINERFILE_CONTENT="${CONTAINERFILE_CONTENT//__DEVICE_ID__/$DEVICE_ID}"
CONTAINERFILE_CONTENT="${CONTAINERFILE_CONTENT//__DISTRO_ID__/$DISTRO_ID}"
CONTAINERFILE_CONTENT="${CONTAINERFILE_CONTENT//__BASE_PACKAGES__/$BASE_PACKAGES}"

# Generate service stages
SERVICE_STAGES=""
FINAL_PARENT="base-common"
COPY_PACKAGES_YML=""

for svc in "${ORDERED_SERVICES[@]}"; do
    svc_path=$(resolve_service_path "$DEVICE_ID" "$svc")
    
    if [[ -z "$svc_path" ]]; then
        echo "Warning: Service '$svc' not found, skipping" >&2
        continue
    fi
    
    # Copy packages.yml for this service
    if [[ -f "$svc_path/packages.yml" ]]; then
        COPY_PACKAGES_YML+="COPY setupfiles/packages/${svc}.yml /etc/setupfiles/packages/${svc}.yml"$'\n'
    fi
    
    # Get packages for this service (fedora section for rpm-ostree)
    svc_packages=""
    if [[ -f "$svc_path/packages.yml" ]]; then
        svc_packages=$(yq -r '.packages.fedora // [] | .[]' "$svc_path/packages.yml" 2>/dev/null | tr '\n' ' ' | xargs)
    fi
    
    # Generate stage
    SERVICE_STAGES+="FROM ${FINAL_PARENT} AS service-${svc}"$'\n'
    SERVICE_STAGES+="# Service: $svc"$'\n'
    
    if [[ -n "$svc_packages" ]]; then
        SERVICE_STAGES+="RUN rpm-ostree install -y ${svc_packages} || true"$'\n'
    fi
    
    # Copy service files (configs, systemd units, etc.)
    if [[ -d "$svc_path/files" ]]; then
        SERVICE_STAGES+="COPY setupfiles/services/${svc}/ /etc/astralemu/services/${svc}/"$'\n'
    fi
    
    # Run service install script if exists
    if [[ -f "$svc_path/install.sh" ]]; then
        SERVICE_STAGES+="COPY setupfiles/services/${svc}/install.sh /tmp/${svc}-install.sh"$'\n'
        SERVICE_STAGES+="RUN chmod +x /tmp/${svc}-install.sh && /tmp/${svc}-install.sh && rm -f /tmp/${svc}-install.sh"$'\n'
    fi
    
    FINAL_PARENT="service-${svc}"
done

[[ -z "$SERVICE_STAGES" ]] && FINAL_PARENT="base-common"

# Substitute service stages
CONTAINERFILE_CONTENT="${CONTAINERFILE_CONTENT//__SERVICE_STAGES__/$SERVICE_STAGES}"
CONTAINERFILE_CONTENT="${CONTAINERFILE_CONTENT//__FINAL_PARENT__/$FINAL_PARENT}"
CONTAINERFILE_CONTENT="${CONTAINERFILE_CONTENT//__COPY_PACKAGES_YML__/$COPY_PACKAGES_YML}"
CONTAINERFILE_CONTENT="${CONTAINERFILE_CONTENT//__SERVICE_LIST__/$(echo "${ORDERED_SERVICES[*]}" | tr ' ' ',')}"

# Write output
OUTPUT="$REPO_ROOT/build/Containerfile"
echo "$CONTAINERFILE_CONTENT" > "$OUTPUT"

echo "Generated: $OUTPUT"
echo "  Stages: base-common → ${ORDERED_SERVICES[*]} → final"
