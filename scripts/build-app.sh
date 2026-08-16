#!/usr/bin/env bash
#
# build-app.sh — assemble, ad-hoc-sign, and install the Sesame menu-bar app.
#
# Stage A packaging (no Xcode, no Apple Developer account): builds the SwiftPM
# `SesameApp` executable in release, wraps it in a proper `Sesame.app` bundle
# with the required Info.plist, ad-hoc code-signs it, and installs it to
# ~/Applications — where SMAppService can discover it as a login item.
#
# Usage: scripts/build-app.sh
set -euo pipefail

APP_NAME="Sesame"
BUNDLE_ID="dev.sesame.app"
EXECUTABLE="Sesame"          # CFBundleExecutable — the binary name inside MacOS/
PRODUCT="SesameApp"          # the SwiftPM executable target/product name
MIN_MACOS="13.0"
VERSION="0.2.0"              # Milestone 2, Stage A

# Repo root = parent of this script's dir (works from any CWD).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

echo "==> swift build -c release"
swift build -c release --product "$PRODUCT"

BIN_DIR="$(swift build -c release --show-bin-path)"
BIN_PATH="$BIN_DIR/$PRODUCT"
if [ ! -x "$BIN_PATH" ]; then
    echo "error: built product not found at $BIN_PATH" >&2
    exit 1
fi

# Assemble the bundle in a staging dir, then install atomically.
STAGE_APP="$REPO_ROOT/.build/$APP_NAME.app"
rm -rf "$STAGE_APP"
mkdir -p "$STAGE_APP/Contents/MacOS" "$STAGE_APP/Contents/Resources"

echo "==> copy binary -> $APP_NAME.app/Contents/MacOS/$EXECUTABLE"
cp "$BIN_PATH" "$STAGE_APP/Contents/MacOS/$EXECUTABLE"
chmod +x "$STAGE_APP/Contents/MacOS/$EXECUTABLE"

echo "==> write Info.plist"
cat > "$STAGE_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundleExecutable</key>
	<string>$EXECUTABLE</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>$MIN_MACOS</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Sesame — a fingerprint-gated vault for your agent's env secrets.</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc code-sign (no Apple Developer account needed for Stage A)"
codesign -s - --force --deep "$STAGE_APP"
codesign -dv "$STAGE_APP" 2>&1 | sed 's/^/    /'

# Install to ~/Applications (SMAppService discovers mainApp login items
# reliably only in ~/Applications or /Applications — a .app left in .build/
# will NOT auto-launch at login).
DEST_DIR="$HOME/Applications"
DEST_APP="$DEST_DIR/$APP_NAME.app"
mkdir -p "$DEST_DIR"
echo "==> install -> $DEST_APP"
rm -rf "$DEST_APP"
cp -R "$STAGE_APP" "$DEST_APP"

echo
echo "Done. Launch it with:"
echo "    open \"$DEST_APP\""
