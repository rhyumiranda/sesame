#!/usr/bin/env bash
#
# build-app.sh — assemble, ad-hoc-sign, and install the Sesame windowed app.
#
# Packaging: builds the SwiftPM `SesameApp` executable in release, wraps it in a
# proper `Sesame.app` bundle with the required Info.plist (LSUIElement=false — a
# Dock icon + a main window), code-signs it, and installs it to ~/Applications —
# where SMAppService can discover it as a login item.
#
# TWO SIGNING MODES:
#   • SIGNED (Secure Enclave / Touch ID works): set SESAME_SIGN_ID to your paid
#     Developer ID Application identity, e.g.
#         SESAME_SIGN_ID="Developer ID Application: Your Company (TEAMID)" \
#             bash scripts/build-app.sh
#     This DERIVES the team id from the identity (never hardcoded), substitutes it
#     into the $(TEAM_ID).dev.sesame.app keychain-access-groups entitlement, and
#     signs with Hardened Runtime (-o runtime) + those entitlements. A Developer ID
#     signature + a team-prefixed keychain group is self-asserted and honored by
#     macOS with NO provisioning profile and NO expiry — the biometric/SE gate
#     needs exactly this; an ad-hoc or bare Apple-Development build cannot carry it
#     (it fails -34018 on add / error 163 on launch).
#   • AD-HOC (advisory only): no SESAME_SIGN_ID → ad-hoc signature, NO
#     keychain-access-groups entitlement. The menu-bar app + advisory storage work;
#     the Secure-Enclave gate does NOT (SecKeyCreateRandomKey fails -34018 without a
#     real Developer-ID identity + the team-prefixed group).
#
# Usage: [SESAME_SIGN_ID="…"] scripts/build-app.sh
set -euo pipefail

APP_NAME="Sesame"
BUNDLE_ID="dev.sesame.app"
EXECUTABLE="Sesame"          # CFBundleExecutable — the binary name inside MacOS/
PRODUCT="SesameApp"          # the SwiftPM executable target/product name
MIN_MACOS="13.0"
VERSION="0.5.0"              # x-release-please-version
ENTITLEMENTS="Sesame.entitlements"

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
	<!-- Windowed app: Dock icon + normal menu bar + a main window (NOT a
	     background agent). The app delegate also sets NSApp activation policy
	     to .regular; keep these two in sync. -->
	<key>LSUIElement</key>
	<false/>
	<key>NSHumanReadableCopyright</key>
	<string>Sesame — a fingerprint-gated vault for your agent's env secrets.</string>
</dict>
</plist>
PLIST

SIGNED_MODE=0
TMP_ENT=""
cleanup() { [ -n "$TMP_ENT" ] && rm -f "$TMP_ENT"; }
trap cleanup EXIT

# Derive the 10-char Apple Team ID for a signed build. Prefer the (TEAMID) suffix
# on the identity string; otherwise look it up from the keychain identities that
# match the requested name. Never hardcoded — the committed entitlements carry a
# literal $(TEAM_ID) placeholder that we substitute here.
derive_team_id() {
    local id="$1" tid
    tid="$(printf '%s' "$id" | grep -oE '\([A-Z0-9]{10}\)' | tr -d '()' | head -1)" || true
    if [ -n "$tid" ]; then printf '%s' "$tid"; return 0; fi
    tid="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -F "$id" | grep -oE '\([A-Z0-9]{10}\)' | tr -d '()' | head -1)" || true
    printf '%s' "$tid"
}

if [ -n "${SESAME_SIGN_ID:-}" ]; then
    SIGNED_MODE=1
    if [ ! -f "$REPO_ROOT/$ENTITLEMENTS" ]; then
        echo "error: $ENTITLEMENTS not found — required for signed mode" >&2
        exit 1
    fi

    # A signed build for the biometric/SE gate needs a paid Developer ID
    # Application identity — fail with a clear message, not a cryptic codesign one.
    if ! security find-identity -v -p codesigning 2>/dev/null \
            | grep -q "Developer ID Application"; then
        echo "error: no 'Developer ID Application' identity found in the keychain." >&2
        echo "       The Touch ID / Secure-Enclave gate requires a paid Developer ID" >&2
        echo "       Application cert (an 'Apple Development' cert is not enough — it" >&2
        echo "       needs a provisioning profile and expires weekly)." >&2
        echo "       Install the company Developer ID Application cert, then re-run:" >&2
        echo "           SESAME_SIGN_ID=\"Developer ID Application: <Company> (TEAMID)\" $0" >&2
        exit 1
    fi

    TEAM_ID="$(derive_team_id "$SESAME_SIGN_ID")"
    if [ -z "$TEAM_ID" ]; then
        echo "error: could not derive the Team ID from SESAME_SIGN_ID='$SESAME_SIGN_ID'." >&2
        echo "       Pass the identity WITH its team suffix, e.g." >&2
        echo "           SESAME_SIGN_ID=\"Developer ID Application: <Company> (TEAMID)\"" >&2
        echo "       or check 'security find-identity -v -p codesigning'." >&2
        exit 1
    fi

    # Substitute the derived team id into a TEMP copy of the entitlements; the
    # committed file keeps the $(TEAM_ID) placeholder. Bash string replacement (not
    # sed) so no entitlement content is treated as a regex.
    TMP_ENT="$(mktemp "${TMPDIR:-/tmp}/sesame-entitlements.XXXXXX")"
    ent_contents="$(cat "$REPO_ROOT/$ENTITLEMENTS")"
    # shellcheck disable=SC2016  # single quotes are intentional: '$(TEAM_ID)' is a
    # LITERAL placeholder to match, not a command substitution to expand.
    ent_contents="${ent_contents//'$(TEAM_ID)'/$TEAM_ID}"
    printf '%s' "$ent_contents" > "$TMP_ENT"

    echo "==> code-sign (Hardened Runtime + entitlements) with: $SESAME_SIGN_ID"
    echo "    team id: $TEAM_ID  ·  keychain group: $TEAM_ID.$BUNDLE_ID"
    codesign --force --deep \
        --options runtime \
        --entitlements "$TMP_ENT" \
        --sign "$SESAME_SIGN_ID" \
        "$STAGE_APP"
else
    echo "==> ad-hoc code-sign (NO Apple Developer identity — advisory only)"
    echo "    NOTE: the Secure-Enclave gate will NOT work under an ad-hoc signature."
    echo "    Set SESAME_SIGN_ID=\"Developer ID Application: <name> (<team>)\" to enable it."
    codesign -s - --force --deep "$STAGE_APP"
fi
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

if [ "$SIGNED_MODE" = 1 ]; then
    cat <<VERIFY

==> Post-signing verification (prove the Secure-Enclave gate is real)
  1. Confirm the identity + entitlements landed:
         codesign -d --entitlements - "$DEST_APP"
     (expect keychain-access-groups = '$TEAM_ID.$BUNDLE_ID',
      'com.apple.security.app-sandbox = false', and the runtime flag set —
      the literal '\$(TEAM_ID)' placeholder must NOT appear)
  2. Launch the agent, then flip on the SE backend:
         open "$DEST_APP"
         # in ~/Library/Application Support/Sesame/config.json set:
         #   "storage_backend": "secure-enclave"   (data_source stays "agent")
         # then relaunch the app so the agent owns the SE store.
  3. Migrate + prove the cryptographic gate:
         sesame migrate                 # re-wraps advisory secrets (Touch ID per secret)
         sesame get SOME_SECRET         # the APP's Touch ID prompt must fire, then the value prints
         xxd ~/Library/Application\\ Support/Sesame/vault/SOME_SECRET.bin | head
         #   ^ must be ciphertext (garbage) — proof the blob on disk is encrypted
         sesame run SOME_SECRET -- printenv SOME_SECRET   # injected into the child
  4. After verifying, drop the old advisory copies:
         sesame rm SOME_SECRET --advisory --confirm
VERIFY
else
    echo
    echo "Ad-hoc build: advisory storage only. Re-run with SESAME_SIGN_ID set to enable the SE gate."
fi
