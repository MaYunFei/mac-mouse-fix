#!/bin/bash
#
# rebuild-local.sh
#
# Builds, signs and installs a locally-signed "Mac Mouse Fix" build
# using your personal Apple Development certificate while retaining the
# original Bundle Identifier ("com.nuebling.mac-mouse-fix").
#
# Usage:
#   ./rebuild-local.sh
#
# Your settings live in:
#   ~/Library/Application Support/com.nuebling.mac-mouse-fix/config.plist
# and are preserved across rebuilds.

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Configuration & Auto-detection
# ──────────────────────────────────────────────────────────────────────────────

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33mwarning:\033[0m %s\n' "$*"; }
fail()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild not found. Install Xcode."

# Detect Apple Development signing identity
SIGN_IDENTITY="${MMF_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development:" | head -1 | awk -F'"' '{print $2}' || true)"
fi

if [ -z "$SIGN_IDENTITY" ]; then
    fail "No 'Apple Development' signing certificate found in keychain.
Please create one in Xcode → Settings → Accounts."
fi

# Extract Team ID from identity string, e.g. "Apple Development: email (TEAMID)"
TEAM_ID="${MMF_TEAM_ID:-}"
if [ -z "$TEAM_ID" ]; then
    TEAM_ID="$(echo "$SIGN_IDENTITY" | sed -nE 's/.*\(([A-Z0-9]+)\).*/\1/p')"
fi

DERIVED_DATA="${MMF_DERIVED_DATA:-/tmp/mmf-local-build}"
APP_NAME="Mac Mouse Fix.app"
INSTALL_DIR="/Applications"

info "Signing Identity: $SIGN_IDENTITY"
info "Team ID:          ${TEAM_ID:-unknown}"
info "Bundle ID:        com.nuebling.mac-mouse-fix (Original)"
info "Build dir:        $DERIVED_DATA"

# ──────────────────────────────────────────────────────────────────────────────
# Build (without automatic provisioning profiles to avoid App ID conflicts)
# ──────────────────────────────────────────────────────────────────────────────

BUILD_LOG="$(mktemp -t mmf-build).log"
info "Building with xcodebuild (log: $BUILD_LOG) ..."

rm -rf "$DERIVED_DATA"

if ! xcodebuild \
    -scheme "App - Release" \
    -configuration Release \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    build > "$BUILD_LOG" 2>&1
then
    echo
    grep -E "error:" "$BUILD_LOG" | head -20 || true
    fail "Build failed. Full log: $BUILD_LOG"
fi

BUILT_APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME"
HELPER_APP="$BUILT_APP/Contents/Library/LoginItems/Mac Mouse Fix Helper.app"

[[ -d "$BUILT_APP" ]] || fail "Built app not found at '$BUILT_APP'."
[[ -d "$HELPER_APP" ]] || fail "Helper app not found at '$HELPER_APP'."

# ──────────────────────────────────────────────────────────────────────────────
# Manual Code Signing
# ──────────────────────────────────────────────────────────────────────────────

info "Signing frameworks and bundles with your certificate ..."

# 1. Sign any nested frameworks or dylibs
if [ -d "$BUILT_APP/Contents/Frameworks" ]; then
    find "$BUILT_APP/Contents/Frameworks" -mindepth 1 -maxdepth 1 \( -name "*.framework" -o -name "*.dylib" \) | while read -r item; do
        codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$item"
    done
fi

# 2. Sign the Helper app
codesign --force --deep --sign "$SIGN_IDENTITY" --timestamp=none "$HELPER_APP"

# 3. Sign the Main app
codesign --force --deep --sign "$SIGN_IDENTITY" --timestamp=none "$BUILT_APP"

# ──────────────────────────────────────────────────────────────────────────────
# Verify Signatures
# ──────────────────────────────────────────────────────────────────────────────

APP_TEAM="$(codesign -dv --verbose=2 "$BUILT_APP" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}')"
HELPER_TEAM="$(codesign -dv --verbose=2 "$HELPER_APP" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}')"

info "App TeamIdentifier:    $APP_TEAM"
info "Helper TeamIdentifier: $HELPER_TEAM"

if [ -z "$APP_TEAM" ] || [ "$APP_TEAM" != "$HELPER_TEAM" ]; then
    fail "App and Helper signatures must have identical, non-empty TeamIdentifiers for SMAppService."
fi

# ──────────────────────────────────────────────────────────────────────────────
# Config Migration (Restore config if saved under com.yunfei before)
# ──────────────────────────────────────────────────────────────────────────────

YUNFEI_CONFIG="$HOME/Library/Application Support/com.yunfei.mac-mouse-fix/config.plist"
TARGET_CONFIG_DIR="$HOME/Library/Application Support/com.nuebling.mac-mouse-fix"
TARGET_CONFIG="$TARGET_CONFIG_DIR/config.plist"

mkdir -p "$TARGET_CONFIG_DIR"

if [ -f "$YUNFEI_CONFIG" ]; then
    # Check if target config has empty Remaps but yunfei config has remaps
    TARGET_REMAPS="$(/usr/libexec/PlistBuddy -c 'Print Remaps' "$TARGET_CONFIG" 2>/dev/null || echo "Empty")"
    if [ "$TARGET_REMAPS" = "Array {"$'\n'"}" ] || [ ! -f "$TARGET_CONFIG" ]; then
        info "Migrating saved remaps from com.yunfei config to original config location ..."
        cp "$YUNFEI_CONFIG" "$TARGET_CONFIG"
    fi
fi

# ──────────────────────────────────────────────────────────────────────────────
# Install
# ──────────────────────────────────────────────────────────────────────────────

info "Quitting running instances ..."
osascript -e 'quit app "Mac Mouse Fix"' >/dev/null 2>&1 || true
sleep 1
pkill -9 -f "Mac Mouse Fix" >/dev/null 2>&1 || true
sleep 1

info "Installing into $INSTALL_DIR ..."
rm -rf "$INSTALL_DIR/$APP_NAME"
cp -R "$BUILT_APP" "$INSTALL_DIR/"
xattr -dr com.apple.quarantine "$INSTALL_DIR/$APP_NAME" >/dev/null 2>&1 || true

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$INSTALL_DIR/$APP_NAME/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion'          "$INSTALL_DIR/$APP_NAME/Contents/Info.plist")"

info "Launching Mac Mouse Fix $VERSION ($BUILD) ..."
open "$INSTALL_DIR/$APP_NAME"

cat <<EOF

──────────────────────────────────────────────────────────────────────────────
Done! Mac Mouse Fix $VERSION ($BUILD) is installed.
  • Signed with: $SIGN_IDENTITY
  • Team ID:     $APP_TEAM
  • Bundle ID:   com.nuebling.mac-mouse-fix (Original)
  • Config path: $TARGET_CONFIG (Settings preserved)
  • No 7-day provisioning profile expiration!
──────────────────────────────────────────────────────────────────────────────
EOF
