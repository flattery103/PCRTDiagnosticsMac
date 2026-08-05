#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' Packages/PCRTCore/Sources/PCRTCore/Utilities/Product.swift | head -1)"
[[ -n "$VERSION" ]] || { echo "Unable to determine version" >&2; exit 1; }

DERIVED_DATA="$ROOT/build/DerivedData"
RELEASE_DIR="$ROOT/build/release"
APP_PATH="$DERIVED_DATA/Build/Products/Release/PCRT Diagnostics.app"
ZIP_PATH="$RELEASE_DIR/PCRTDiagnosticsMac-$VERSION.zip"

rm -rf "$DERIVED_DATA" "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

./Scripts/check-source.sh
swift test --package-path Packages/PCRTCore

xcodebuild \
  -project PCRTDiagnosticsMac.xcodeproj \
  -scheme PCRTDiagnosticsMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  test

xcodebuild \
  -project PCRTDiagnosticsMac.xcodeproj \
  -scheme PCRTDiagnosticsMac \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

./Scripts/verify-app.sh "$APP_PATH"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
(
  cd "$RELEASE_DIR"
  shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$ZIP_PATH").sha256"
)

echo "Created: $ZIP_PATH"
echo "Created: $ZIP_PATH.sha256"
