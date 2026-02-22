#!/bin/bash
# Base services-first-boot script
# This script runs once on first boot after network is available
# Additional services will append their initialization code here

set -e

echo "======================================"
echo "Running services first-boot setup..."
echo "======================================"

# ====== SERVICES INITIALIZATION ======
# Additional service initialization code will be appended here by autobuild

# ====== END SERVICES INITIALIZATION ======

echo "======================================"
echo "Services first-boot setup complete!"
echo "======================================"

# Disable this service after first run
systemctl disable services-first-boot.service

exit 0