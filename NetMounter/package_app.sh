#!/bin/bash

# Configuration
APP_NAME="NetMounter"
BUILD_DIR=".build/release"
BINARY_PATH="$BUILD_DIR/$APP_NAME"
OUTPUT_DIR="."
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"

# Ensure release build exists
if [ ! -f "$BINARY_PATH" ]; then
    echo "Release binary not found. Building..."
    swift build -c release
fi

# Create App Bundle Structure
echo "Creating App Bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy Binary
cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Process Icon
if [ -f "app_icon.png" ]; then
    echo "Processing App Icon..."
    chmod +x generate_icns.sh
    ./generate_icns.sh "app_icon.png" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
else
    echo "Warning: app_icon.png not found, skipping icon generation."
fi

# Create Info.plist
echo "Creating Info.plist..."
cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.netmounter.app</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/> <!-- This makes it a menu bar app (hidden from dock) if desired, set to false if you want dock icon -->
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Copy Icon (If available, otherwise skip)
# if [ -f "AppIcon.icns" ]; then
#     cp "AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
# fi

# Ad-hoc Code Sign to allow running locally
echo "Signing App..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Done! App created at $APP_BUNDLE"
echo "You can move this to /Applications to install it."
