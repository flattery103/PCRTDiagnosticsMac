#!/bin/bash
set -euo pipefail

APP_PATH="${1:-}"
[[ -d "$APP_PATH" ]] || { echo "Usage: $0 '/path/to/PCRT Diagnostics.app'" >&2; exit 2; }
: "${PCRT_SIGNING_IDENTITY:?PCRT_SIGNING_IDENTITY is required}"
: "${PCRT_TEAM_ID:?PCRT_TEAM_ID is required}"
: "${PCRT_NOTARY_KEY_PATH:?PCRT_NOTARY_KEY_PATH is required}"
: "${PCRT_NOTARY_KEY_ID:?PCRT_NOTARY_KEY_ID is required}"
: "${PCRT_NOTARY_ISSUER_ID:?PCRT_NOTARY_ISSUER_ID is required}"

[[ "$PCRT_SIGNING_IDENTITY" == *"($PCRT_TEAM_ID)"* ]] || { echo "Signing identity does not contain the expected team ID: $PCRT_TEAM_ID" >&2; exit 1; }

HELPER="$APP_PATH/Contents/MacOS/PCRTScannerHelper"
[[ -x "$HELPER" ]] || { echo "Bundled helper not found: $HELPER" >&2; exit 1; }

codesign --force --options runtime --timestamp --sign "$PCRT_SIGNING_IDENTITY" "$HELPER"
codesign --force --options runtime --timestamp --sign "$PCRT_SIGNING_IDENTITY" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

TEMP_ZIP="$(mktemp -t pcrt-notarization).zip"
trap 'rm -f "$TEMP_ZIP"' EXIT
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$TEMP_ZIP"

xcrun notarytool submit "$TEMP_ZIP" \
  --key "$PCRT_NOTARY_KEY_PATH" \
  --key-id "$PCRT_NOTARY_KEY_ID" \
  --issuer "$PCRT_NOTARY_ISSUER_ID" \
  --wait

xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"

echo "Developer ID signing, notarization, and stapling completed."
