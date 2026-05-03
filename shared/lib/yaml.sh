#!/usr/bin/env bash
# yaml.sh — YAML helpers using yq
# Used by service-loader.sh and generate scripts
# Universal for all build formats (cloud-init, tarball, docker)

set -euo pipefail

# Get a single value from YAML
yaml_get() {
    local file="$1" path="$2"
    yq -r "$path // \"\"" "$file"
}

# Get array from YAML (one item per line)
yaml_get_array() {
    local file="$1" path="$2"
    yq -r "$path // [] | .[]" "$file"
}

# Check if YAML path exists
yaml_has() {
    local file="$1" path="$2"
    local val
    val=$(yq -r "$path // \"null\"" "$file")
    [[ "$val" != "null" && -n "$val" ]]
}
