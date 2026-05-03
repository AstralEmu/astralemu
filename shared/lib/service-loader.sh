#!/usr/bin/env bash
# service-loader.sh — discovers services and resolves dependency order
# Universal for all build formats (cloud-init, tarball, docker)

set -euo pipefail

LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=${REPO_ROOT:-$(cd -- "$LIB_DIR/../.." && pwd)}
SERVICES_DIR=${SERVICES_DIR:-$REPO_ROOT/services}
DEVICES_DIR=${DEVICES_DIR:-$REPO_ROOT/devices}

# Source yaml helpers
# shellcheck source=yaml.sh
source "$LIB_DIR/yaml.sh"

# Resolve service path: device-specific takes priority over shared
resolve_service_path() {
    local device_id="$1" service_name="$2"
    
    # 1. Device-specific
    if [[ -d "$DEVICES_DIR/$device_id/services/$service_name" ]]; then
        echo "$DEVICES_DIR/$device_id/services/$service_name"
        return
    fi
    
    # 2. Shared
    if [[ -d "$SERVICES_DIR/$service_name" ]]; then
        echo "$SERVICES_DIR/$service_name"
        return
    fi
    
    echo ""
}

# List all service names for a device (raw, no sorting)
services_list_raw() {
    local device_id="$1"
    local -a services=()
    
    # Device-specific services
    for dir in "$DEVICES_DIR/$device_id/services/"*/; do
        [[ -d "$dir" ]] || continue
        local name=$(basename "$dir")
        [[ "$name" == "base" ]] && continue
        services+=("$name")
    done
    
    # Shared services (not already listed)
    for dir in "$SERVICES_DIR/"*/; do
        [[ -d "$dir" ]] || continue
        local name=$(basename "$dir")
        [[ "$name" == "prepare" ]] && continue
        if [[ ! " ${services[*]} " =~ " $name " ]]; then
            services+=("$name")
        fi
    done
    
    printf '%s\n' "${services[@]}"
}

# Get dependencies for a service
service_depends_on() {
    local device_id="$1" service_name="$2"
    local service_path
    service_path=$(resolve_service_path "$device_id" "$service_name")
    
    if [[ -n "$service_path" && -f "$service_path/depends.sh" ]]; then
        local DEPENDS_ON=""
        source "$service_path/depends.sh"
        echo "$DEPENDS_ON"
    fi
}

# Topological sort of services (resolves dependencies)
services_list_topo() {
    local device_id="$1"
    shift
    local requested_services=("$@")
    
    local -A seen=() temp=()
    local -a ordered=()
    
    _visit() {
        local svc="$1"
        
        [[ ${seen[$svc]:-0} == 1 ]] && return 0
        
        if [[ ${temp[$svc]:-0} == 1 ]]; then
            echo "service-loader: dependency cycle involving '$svc'" >&2
            exit 2
        fi
        
        temp[$svc]=1
        
        local dep
        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue
            local dep_path
            dep_path=$(resolve_service_path "$device_id" "$dep")
            if [[ -z "$dep_path" ]]; then
                echo "service-loader: '$svc' depends on unknown service '$dep'" >&2
                exit 2
            fi
            _visit "$dep"
        done < <(service_depends_on "$device_id" "$svc")
        
        temp[$svc]=0
        seen[$svc]=1
        ordered+=("$svc")
    }
    
    for svc in "${requested_services[@]}"; do
        _visit "$svc"
    done
    
    printf '%s\n' "${ordered[@]}"
}

# Get service manifest field
service_get_field() {
    local device_id="$1" service_name="$2" field="$3"
    local service_path
    service_path=$(resolve_service_path "$device_id" "$service_name")
    
    if [[ -f "$service_path/service.yaml" ]]; then
        yaml_get "$service_path/service.yaml" "$field"
    fi
}

# Get service manifest array
service_get_array() {
    local device_id="$1" service_name="$2" field="$3"
    local service_path
    service_path=$(resolve_service_path "$device_id" "$service_name")
    
    if [[ -f "$service_path/service.yaml" ]]; then
        yaml_get_array "$service_path/service.yaml" "$field"
    fi
}
