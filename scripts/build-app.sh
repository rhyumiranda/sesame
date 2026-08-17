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

# Raw "  N) <40-hex-SHA> "<name>"" lines for the valid codesigning identities
# (the trailing "N valid identities found" summary line has no hash, so it drops).
_identity_lines() {
    security find-identity -v -p codesigning 2>/dev/null \
        | grep -E '^[[:space:]]*[0-9]+\)[[:space:]]+[0-9A-Fa-f]{40}[[:space:]]+"'
}

# Resolve $1 (a full name, a name SUBSTRING, or a 40-char SHA-1 hash — the three
# forms `codesign --sign` accepts) to the UNIQUE matching identity's full name in
# RESOLVED_ID_NAME. Returns 0 unique · 1 none · 2 ambiguous. macOS bash 3.2 safe:
# the loop runs in this shell (here-doc, not a pipe) so the counters persist.
RESOLVED_ID_NAME=""
resolve_signing_identity() {
    local id="$1" id_uc lines line rest hash name count=0 first=""
    id_uc="$(printf '%s' "$id" | tr '[:lower:]' '[:upper:]')" || id_uc="$id"
    lines="$(_identity_lines)" || lines=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        rest="${line#*) }"          # strip "  N) "  -> '<hash> "<name>"'
        hash="${rest%% *}"          # first token = the 40-hex hash
        name="${line#*\"}"          # text after the first double-quote …
        name="${name%\"*}"          # … up to the last double-quote = the name
        # Hash match is case-insensitive; the name match is a LITERAL substring
        # (quoting $id in the case pattern keeps any glob metachars literal).
        if [ "$id_uc" = "$(printf '%s' "$hash" | tr '[:lower:]' '[:upper:]')" ] \
            || case "$name" in *"$id"*) true ;; *) false ;; esac; then
            count=$((count + 1))
            [ -n "$first" ] || first="$name"
        fi
    done <<EOF
$lines
EOF
    RESOLVED_ID_NAME="$first"
    if [ "$count" -eq 0 ]; then return 1; fi
    if [ "$count" -gt 1 ]; then return 2; fi
    return 0
}

# Derive the 10-char Team ID from a RESOLVED identity name (always carries the
# `(TEAMID)` suffix). Never hardcoded — the committed entitlements keep a literal
# $(TEAM_ID) placeholder that we substitute at sign time.
derive_team_id() {
    local id="$1" tid
    tid="$(printf '%s' "$id" | grep -oE '\([A-Z0-9]{10}\)' | tr -d '()' | head -1)" || true
    printf '%s' "$tid"
}

if [ -n "${SESAME_SIGN_ID:-}" ]; then
    SIGNED_MODE=1
    if [ ! -f "$REPO_ROOT/$ENTITLEMENTS" ]; then
        echo "error: $ENTITLEMENTS not found — required for signed mode" >&2
        exit 1
    fi

    # Resolve the SPECIFIC identity the user passed, then require it to be a
    # Developer ID Application cert. Merely having SOME Developer ID cert in the
    # keychain is NOT enough: signing with an Apple Development identity builds an
    # app that INSTALLS fine but fails at RUNTIME with -34018 when it creates the
    # Secure-Enclave key (macOS only honors the keychain/biometry entitlement under
    # a Developer-ID signature). Catch that wrong-type case here, not days later.
    resolve_rc=0
    resolve_signing_identity "$SESAME_SIGN_ID" || resolve_rc=$?
    if [ "$resolve_rc" -eq 1 ]; then
        echo "error: SESAME_SIGN_ID='$SESAME_SIGN_ID' matched no codesigning identity." >&2
        echo "       Available Developer ID Application identities in your keychain:" >&2
        if ! _identity_lines | sed -E 's/^[^"]*"([^"]*)".*/\1/' \
                | grep 'Developer ID Application' | sed 's/^/           /' >&2; then
            echo "           (none — install the company Developer ID Application cert)" >&2
        fi
        echo "       Pass the full name or the 40-char SHA-1 hash from that list." >&2
        exit 1
    elif [ "$resolve_rc" -eq 2 ]; then
        echo "error: SESAME_SIGN_ID='$SESAME_SIGN_ID' is AMBIGUOUS — it matches more than" >&2
        echo "       one identity. Pass the FULL identity name or its 40-char SHA-1 hash" >&2
        echo "       (from 'security find-identity -v -p codesigning') to disambiguate." >&2
        exit 1
    fi
    case "$RESOLVED_ID_NAME" in
        "Developer ID Application: "*) : ;;
        *)
            echo "error: SESAME_SIGN_ID resolved to '$RESOLVED_ID_NAME', which is NOT a" >&2
            echo "       'Developer ID Application' identity. The Touch ID / Secure-Enclave" >&2
            echo "       gate requires Developer ID signing; an 'Apple Development' cert" >&2
            echo "       builds fine but fails at RUNTIME with -34018 (and needs a" >&2
            echo "       provisioning profile + expires weekly). Install/select the company" >&2
            echo "       Developer ID Application cert." >&2
            exit 1
            ;;
    esac

    # Derive the team id from the RESOLVED name (works even when the user passed a
    # bare SHA hash — the name always carries the (TEAMID) suffix).
    TEAM_ID="$(derive_team_id "$RESOLVED_ID_NAME")"
    if [ -z "$TEAM_ID" ]; then
        echo "error: could not derive the Team ID from identity '$RESOLVED_ID_NAME'." >&2
        echo "       Expected a trailing '(TEAMID)'; check" >&2
        echo "       'security find-identity -v -p codesigning'." >&2
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

    echo "==> code-sign (Hardened Runtime + entitlements) with: $RESOLVED_ID_NAME"
    echo "    team id: $TEAM_ID  ·  keychain group: $TEAM_ID.$BUNDLE_ID"
    # Sign with the RESOLVED full name (unique per the check above), not the raw
    # input, so codesign uses exactly the identity we validated as Developer ID.
    codesign --force --deep \
        --options runtime \
        --entitlements "$TMP_ENT" \
        --sign "$RESOLVED_ID_NAME" \
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
