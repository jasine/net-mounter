#!/bin/bash
set -euo pipefail

# Explicit developer check: sends one synthetic error and a transaction to Sentry.
# The DEBUG-only app path bypasses configuration, Keychain, mounts and network scans.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$ROOT/NetMounter"
BIN_DIR="$(swift build --package-path "$ROOT/NetMounter" --show-bin-path)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp/}netmounter-sentry-verify.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
APP="$TEMP_DIR/NetMounter.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/NetMounter" "$APP/Contents/MacOS/NetMounter"
cp -R "$BIN_DIR/NetMounter_NetMounter.bundle" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NetMounter</string>
<key>CFBundleIdentifier</key><string>com.netmounter.diagnostics-verification</string>
<key>CFBundleShortVersionString</key><string>0.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
NETMOUNTER_SENTRY_VERIFY=1 "$APP/Contents/MacOS/NetMounter"
echo "Verification finished. Confirm error and transaction receipt in context-tech-gq/net-mounter (development, net-mounter@0.0.0)."
