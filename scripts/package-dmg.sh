#!/usr/bin/env bash
#
# Build Sesame.app and package it as a versioned DMG release asset.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

VERSION="$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' scripts/build-app.sh)"
if [ -z "$VERSION" ]; then
    echo "error: could not read VERSION from scripts/build-app.sh" >&2
    exit 1
fi

EXPECTED_VERSION="${1:-$VERSION}"
if [ "$VERSION" != "$EXPECTED_VERSION" ]; then
    echo "error: app version $VERSION does not match release version $EXPECTED_VERSION" >&2
    exit 1
fi

BUILD_INSTALL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sesame-app.XXXXXX")"
DMG_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sesame-dmg.XXXXXX")"
trap 'rm -rf "$BUILD_INSTALL_DIR" "$DMG_ROOT"' EXIT

SESAME_DEST_DIR="$BUILD_INSTALL_DIR" scripts/build-app.sh

APP_PATH="$BUILD_INSTALL_DIR/Sesame.app"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
if [ "$PLIST_VERSION" != "$EXPECTED_VERSION" ]; then
    echo "error: bundled app version $PLIST_VERSION does not match release version $EXPECTED_VERSION" >&2
    exit 1
fi

mkdir -p dist
cp -R "$APP_PATH" "$DMG_ROOT/Sesame.app"

DMG_PATH="$REPO_ROOT/dist/Sesame-$EXPECTED_VERSION.dmg"
rm -f "$DMG_PATH"
hdiutil create \
    -volname "Sesame $EXPECTED_VERSION" \
    -srcfolder "$DMG_ROOT" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

echo "$DMG_PATH"
