#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CodexBar"
APP_IDENTITY="${APP_IDENTITY:-}"
APP_TEAM_ID="${APP_TEAM_ID:-}"
APP_BUNDLE="CodexBar.app"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/version.env"
ZIP_NAME="${APP_NAME}-${MARKETING_VERSION}.zip"
DSYM_ZIP="${APP_NAME}-${MARKETING_VERSION}.dSYM.zip"
NOTARYTOOL_KEYCHAIN_PROFILE="${NOTARYTOOL_KEYCHAIN_PROFILE:-${NOTARY_KEYCHAIN_PROFILE:-}}"

detect_developer_id_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/^[[:space:]]*[0-9]*) [A-F0-9]* "\(Developer ID Application: .*\)"$/\1/p' \
    | head -n 1
}

has_signing_identity() {
  local identity="$1"
  security find-identity -v -p codesigning 2>/dev/null | grep -F "\"${identity}\"" >/dev/null
}

team_id_for_identity() {
  local identity="$1"
  if [[ -z "$identity" ]]; then
    return 1
  fi
  security find-certificate -c "$identity" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | sed -n 's/.*OU=\([^,]*\).*/\1/p' \
    | head -n 1
}

if [[ -z "$APP_IDENTITY" ]]; then
  APP_IDENTITY="$(detect_developer_id_identity || true)"
fi
if [[ -z "$APP_IDENTITY" ]]; then
  echo "Missing Developer ID Application signing identity. Set APP_IDENTITY or install a Developer ID Application certificate." >&2
  exit 1
fi
if [[ "$APP_IDENTITY" != Developer\ ID\ Application:* ]]; then
  echo "APP_IDENTITY must be a Developer ID Application identity for notarized release signing: $APP_IDENTITY" >&2
  exit 1
fi
if ! has_signing_identity "$APP_IDENTITY"; then
  echo "Signing identity not found in Keychain: $APP_IDENTITY" >&2
  exit 1
fi
if [[ -z "$APP_TEAM_ID" ]]; then
  APP_TEAM_ID="$(team_id_for_identity "$APP_IDENTITY" || true)"
fi
if [[ -z "$APP_TEAM_ID" ]]; then
  echo "Could not determine team ID for signing identity: $APP_IDENTITY. Set APP_TEAM_ID explicitly." >&2
  exit 1
fi
export APP_IDENTITY APP_TEAM_ID

NOTARY_ARGS=()
TMP_API_KEY=""
if [[ -n "$NOTARYTOOL_KEYCHAIN_PROFILE" ]]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE")
else
  if [[ -z "${APP_STORE_CONNECT_API_KEY_P8:-}" || -z "${APP_STORE_CONNECT_KEY_ID:-}" || -z "${APP_STORE_CONNECT_ISSUER_ID:-}" ]]; then
    echo "Missing notarization credentials. Set NOTARYTOOL_KEYCHAIN_PROFILE or APP_STORE_CONNECT_* env vars." >&2
    exit 1
  fi
  TMP_API_KEY="/tmp/codexbar-api-key.p8"
  echo "$APP_STORE_CONNECT_API_KEY_P8" | sed 's/\\n/\n/g' > "$TMP_API_KEY"
  NOTARY_ARGS=(--key "$TMP_API_KEY" --key-id "$APP_STORE_CONNECT_KEY_ID" --issuer "$APP_STORE_CONNECT_ISSUER_ID")
fi

cleanup() {
  if [[ -n "$TMP_API_KEY" ]]; then
    rm -f "$TMP_API_KEY"
  fi
  rm -f "/tmp/${APP_NAME}Notarize.zip"
}
trap cleanup EXIT

# Allow building a universal binary if ARCHES is provided; default to universal (arm64 + x86_64).
ARCHES_VALUE=${ARCHES:-"arm64 x86_64"}
ARCH_LIST=( ${ARCHES_VALUE} )
for ARCH in "${ARCH_LIST[@]}"; do
  swift build -c release --arch "$ARCH"
done
APP_IDENTITY="$APP_IDENTITY" APP_TEAM_ID="$APP_TEAM_ID" ARCHES="${ARCHES_VALUE}" ./Scripts/package_app.sh release

ENTITLEMENTS_DIR="$ROOT/.build/entitlements"
APP_ENTITLEMENTS="${ENTITLEMENTS_DIR}/CodexBar.entitlements"
WIDGET_ENTITLEMENTS="${ENTITLEMENTS_DIR}/CodexBarWidget.entitlements"

echo "Signing with $APP_IDENTITY (team $APP_TEAM_ID)"
if [[ -f "$APP_BUNDLE/Contents/Helpers/CodexBarCLI" ]]; then
  codesign --force --timestamp --options runtime --sign "$APP_IDENTITY" \
    "$APP_BUNDLE/Contents/Helpers/CodexBarCLI"
fi
if [[ -f "$APP_BUNDLE/Contents/Helpers/CodexBarClaudeWatchdog" ]]; then
  codesign --force --timestamp --options runtime --sign "$APP_IDENTITY" \
    "$APP_BUNDLE/Contents/Helpers/CodexBarClaudeWatchdog"
fi
if [[ -d "$APP_BUNDLE/Contents/PlugIns/CodexBarWidget.appex" ]]; then
  codesign --force --timestamp --options runtime --sign "$APP_IDENTITY" \
    --entitlements "$WIDGET_ENTITLEMENTS" \
    "$APP_BUNDLE/Contents/PlugIns/CodexBarWidget.appex/Contents/MacOS/CodexBarWidget"
  codesign --force --timestamp --options runtime --sign "$APP_IDENTITY" \
    --entitlements "$WIDGET_ENTITLEMENTS" \
    "$APP_BUNDLE/Contents/PlugIns/CodexBarWidget.appex"
fi
codesign --force --timestamp --options runtime --sign "$APP_IDENTITY" \
  --entitlements "$APP_ENTITLEMENTS" \
  "$APP_BUNDLE"

DITTO_BIN=${DITTO_BIN:-/usr/bin/ditto}
"$DITTO_BIN" --norsrc -c -k --keepParent "$APP_BUNDLE" "/tmp/${APP_NAME}Notarize.zip"

echo "Submitting for notarization"
xcrun notarytool submit "/tmp/${APP_NAME}Notarize.zip" \
  "${NOTARY_ARGS[@]}" \
  --wait

echo "Stapling ticket"
xcrun stapler staple "$APP_BUNDLE"

# Strip any extended attributes that would create AppleDouble files when zipping
xattr -cr "$APP_BUNDLE"
find "$APP_BUNDLE" -name '._*' -delete

"$DITTO_BIN" --norsrc -c -k --keepParent "$APP_BUNDLE" "$ZIP_NAME"

spctl -a -t exec -vv "$APP_BUNDLE"
stapler validate "$APP_BUNDLE"

echo "Packaging dSYM"
FIRST_ARCH="${ARCH_LIST[0]}"
PREFERRED_ARCH_DIR=".build/${FIRST_ARCH}-apple-macosx/release"
DSYM_PATH="${PREFERRED_ARCH_DIR}/${APP_NAME}.dSYM"
if [[ ! -d "$DSYM_PATH" ]]; then
  echo "Missing dSYM at $DSYM_PATH" >&2
  exit 1
fi
if [[ ${#ARCH_LIST[@]} -gt 1 ]]; then
  MERGED_DSYM="${PREFERRED_ARCH_DIR}/${APP_NAME}.dSYM-universal"
  rm -rf "$MERGED_DSYM"
  cp -R "$DSYM_PATH" "$MERGED_DSYM"
  DWARF_PATH="${MERGED_DSYM}/Contents/Resources/DWARF/${APP_NAME}"
  BINARIES=()
  for ARCH in "${ARCH_LIST[@]}"; do
    ARCH_DSYM=".build/${ARCH}-apple-macosx/release/${APP_NAME}.dSYM/Contents/Resources/DWARF/${APP_NAME}"
    if [[ ! -f "$ARCH_DSYM" ]]; then
      echo "Missing dSYM for ${ARCH} at $ARCH_DSYM" >&2
      exit 1
    fi
    BINARIES+=("$ARCH_DSYM")
  done
  lipo -create "${BINARIES[@]}" -output "$DWARF_PATH"
  DSYM_PATH="$MERGED_DSYM"
fi
"$DITTO_BIN" --norsrc -c -k --keepParent "$DSYM_PATH" "$DSYM_ZIP"

echo "Done: $ZIP_NAME"
