#!/bin/bash
#
# Split a large file into FAT32-compatible parts (< 4GB)
#

set -e

INPUT_FILE="$1"
OUTPUT_DIR="$2"
PART_SIZE_MB="${3:-3900}"  # Default 3.9GB

if [ -z "$INPUT_FILE" ] || [ -z "$OUTPUT_DIR" ]; then
    echo "Usage: $0 <input_file> <output_dir> [part_size_mb]"
    echo "Example: $0 rootfs.squashfs ./parts 3900"
    exit 1
fi

if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: Input file not found: $INPUT_FILE"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# Get file size in bytes
FILE_SIZE=$(stat -c %s "$INPUT_FILE")
PART_SIZE_BYTES=$((PART_SIZE_MB * 1024 * 1024))

# Calculate number of parts needed
NUM_PARTS=$(( (FILE_SIZE + PART_SIZE_BYTES - 1) / PART_SIZE_BYTES ))

# Get base name
BASENAME=$(basename "$INPUT_FILE")

echo "Splitting $BASENAME ($FILE_SIZE bytes) into $NUM_PARTS parts of ${PART_SIZE_MB}MB each..."

if [ "$NUM_PARTS" -eq 1 ]; then
    # File is small enough, just copy with part000 suffix
    cp "$INPUT_FILE" "$OUTPUT_DIR/${BASENAME}.part000"
    echo "File is small enough, copied as single part"
else
    # Split the file
    split -b "${PART_SIZE_MB}M" -d -a 3 --additional-suffix=".tmp" "$INPUT_FILE" "$OUTPUT_DIR/${BASENAME}.part"

    # Rename to proper format (part000, part001, etc.)
    for f in "$OUTPUT_DIR/${BASENAME}.part"*.tmp; do
        if [ -f "$f" ]; then
            # Extract the number part
            num=$(echo "$f" | grep -oE '[0-9]{3}\.tmp$' | cut -d. -f1)
            mv "$f" "$OUTPUT_DIR/${BASENAME}.part$num"
        fi
    done
fi

# List created parts
echo ""
echo "Created parts:"
ls -lh "$OUTPUT_DIR/"

# Verify total size matches
TOTAL_SIZE=0
for part in "$OUTPUT_DIR/${BASENAME}.part"*; do
    if [ -f "$part" ]; then
        PART_SIZE=$(stat -c %s "$part")
        TOTAL_SIZE=$((TOTAL_SIZE + PART_SIZE))
    fi
done

if [ "$TOTAL_SIZE" -eq "$FILE_SIZE" ]; then
    echo ""
    echo "Verification: OK (total size matches original)"
else
    echo ""
    echo "WARNING: Size mismatch! Original: $FILE_SIZE, Parts total: $TOTAL_SIZE"
    exit 1
fi