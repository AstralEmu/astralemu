#!/bin/bash
set -e

echo "====== Running services first-boot setup... ======"

# Wait for DATA_ROOT to be available (if it's a separate mountpoint)
if [ "$DATA_ROOT" != "$DEVICE_HOME" ]; then
    timeout=60
    counter=0
    while [ ! -d "$DATA_ROOT" ] || ! mountpoint -q "$DATA_ROOT" 2>/dev/null; do
        sleep 1
        counter=$((counter + 1))
        if [ $counter -ge $timeout ]; then
            echo "Warning: $DATA_ROOT not mounted after ${timeout}s, continuing anyway..."
            break
        fi
    done

    if mountpoint -q "$DATA_ROOT" 2>/dev/null; then
        echo "Data root mounted at $DATA_ROOT"
    fi
fi

# ====== SERVICES INITIALIZATION ======

# ====== END SERVICES INITIALIZATION ======

echo "====== Services first-boot setup complete! ======"

# Disable this service (one-shot)
systemctl disable services-first-boot.service

exit 0
