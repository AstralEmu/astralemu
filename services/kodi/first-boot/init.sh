# Kodi first-boot initialization
# Creates data directories for media files

echo "[Kodi] Creating data directories in $DATA_ROOT..."

# Kodi media directories
mkdir -p $DATA_ROOT/kodi/{Videos,Music,Pictures}

chown -R $DEVICE_USER:$DEVICE_USER $DATA_ROOT/kodi

echo "[Kodi] Data directories created"
