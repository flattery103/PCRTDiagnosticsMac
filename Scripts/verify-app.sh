#!/bin/bash
set -euo pipefail

APP_PATH="${1:-}"
[[ -n "$APP_PATH" ]] || { echo "Usage: $0 '/path/to/PCRT Diagnostics.app'" >&2; exit 2; }
[[ -d "$APP_PATH" ]] || { echo "App bundle not found: $APP_PATH" >&2; exit 1; }

INFO="$APP_PATH/Contents/Info.plist"
MAIN="$APP_PATH/Contents/MacOS/PCRT Diagnostics"
HELPER="$APP_PATH/Contents/MacOS/PCRTScannerHelper"

[[ -f "$INFO" ]] || { echo "Info.plist is missing" >&2; exit 1; }
[[ -x "$MAIN" ]] || { echo "Main executable is missing or not executable" >&2; exit 1; }
[[ -x "$HELPER" ]] || { echo "PCRTScannerHelper is missing or not executable" >&2; exit 1; }

plutil -lint "$INFO"

verify_architectures() {
  local file="$1"
  local label="$2"
  local architectures
  architectures="$(lipo -archs "$file")"
  echo "$label architectures: $architectures"
  [[ " $architectures " == *" arm64 "* ]] || { echo "$label is missing arm64" >&2; exit 1; }
  [[ " $architectures " == *" x86_64 "* ]] || { echo "$label is missing x86_64" >&2; exit 1; }
}

verify_architectures "$MAIN" "Main executable"
verify_architectures "$HELPER" "Helper executable"

MIN_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO")"
[[ "$MIN_VERSION" == "11.0" ]] || { echo "Unexpected minimum macOS version: $MIN_VERSION" >&2; exit 1; }

if find "$APP_PATH/Contents" -type f \( -name '*.pkg' -o -name '*.dmg' \) | grep -q .; then
  echo "Unexpected installer payload found in app bundle" >&2
  exit 1
fi

if find "$APP_PATH/Contents" -type f \( -path '*/LaunchDaemons/*' -o -path '*/LaunchAgents/*' \) | grep -q .; then
  echo "Unexpected launch service payload found in app bundle" >&2
  exit 1
fi

echo "App bundle structure and Universal 2 architectures verified."
