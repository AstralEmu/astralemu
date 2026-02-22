# Emulations first-boot initialization
# Creates data directories for RetroArch and ROMs

echo "[Emulations] Creating data directories in $DATA_ROOT..."

# RetroArch directories
mkdir -p $DATA_ROOT/retroarch/{saves,states,screenshots,system}

# ROM directories
mkdir -p $DATA_ROOT/roms/{nes,snes,n64,gb,gbc,gba,nds,psp,ps1,gc,wii,3ds,genesis,saturn,dreamcast,xbox}

chown -R $DEVICE_USER:$DEVICE_USER $DATA_ROOT/retroarch $DATA_ROOT/roms

echo "[Emulations] Data directories created"
