#!/bin/bash

SOURCE_ICON="${1:-app_icon.png}"
DEST_ICNS="${2:-AppIcon.icns}"

if [ ! -f "$SOURCE_ICON" ]; then
    echo "Error: Source icon '$SOURCE_ICON' not found."
    echo "Usage: ./generate_icns.sh [source.png] [output.icns]"
    exit 1
fi

ICONSET_DIR="NetMounter.iconset"
mkdir -p "$ICONSET_DIR"

# Resize to standard icon sizes
sips -s format png -z 16 16     "$SOURCE_ICON" --out "$ICONSET_DIR/icon_16x16.png" > /dev/null
sips -s format png -z 32 32     "$SOURCE_ICON" --out "$ICONSET_DIR/icon_16x16@2x.png" > /dev/null
sips -s format png -z 32 32     "$SOURCE_ICON" --out "$ICONSET_DIR/icon_32x32.png" > /dev/null
sips -s format png -z 64 64     "$SOURCE_ICON" --out "$ICONSET_DIR/icon_32x32@2x.png" > /dev/null
sips -s format png -z 128 128   "$SOURCE_ICON" --out "$ICONSET_DIR/icon_128x128.png" > /dev/null
sips -s format png -z 256 256   "$SOURCE_ICON" --out "$ICONSET_DIR/icon_128x128@2x.png" > /dev/null
sips -s format png -z 256 256   "$SOURCE_ICON" --out "$ICONSET_DIR/icon_256x256.png" > /dev/null
sips -s format png -z 512 512   "$SOURCE_ICON" --out "$ICONSET_DIR/icon_256x256@2x.png" > /dev/null
sips -s format png -z 512 512   "$SOURCE_ICON" --out "$ICONSET_DIR/icon_512x512.png" > /dev/null
sips -s format png -z 1024 1024 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_512x512@2x.png" > /dev/null

# Convert to icns
echo "Converting to ICNS..."
iconutil -c icns "$ICONSET_DIR" -o "$DEST_ICNS"

# Cleanup
rm -rf "$ICONSET_DIR"
echo "Generated $DEST_ICNS"
