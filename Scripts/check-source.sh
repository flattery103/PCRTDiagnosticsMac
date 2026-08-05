#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' Packages/PCRTCore/Sources/PCRTCore/Utilities/Product.swift | head -1)"
[[ -n "$VERSION" ]] || { echo "Unable to determine PCRTProduct.version" >&2; exit 1; }

grep -q "MARKETING_VERSION = $VERSION;" PCRTDiagnosticsMac.xcodeproj/project.pbxproj || {
  echo "Xcode MARKETING_VERSION does not match $VERSION" >&2
  exit 1
}
grep -q "# PCRT Diagnostics for macOS $VERSION" RELEASE_NOTES_0.1.0.md || {
  echo "Release notes version does not match $VERSION" >&2
  exit 1
}

for name in system-info.html test-results.html raw-data.json run-log.txt; do
  grep -R -q --exclude-dir=.build --exclude='*.zip' "$name" Packages/PCRTCore PCRTDiagnosticsMac || {
    echo "Required report name not present in source: $name" >&2
    exit 1
  }
done

grep -R -q "https://scan.pcrtdiag.com:8443/" Packages/PCRTCore || {
  echo "Hardcoded server URL is missing" >&2
  exit 1
}

if grep -R -n -E 'brew (install|upgrade)|port install|launchctl (load|bootstrap)|/Library/LaunchDaemons|/Library/PrivilegedHelperTools' PCRTDiagnosticsMac PCRTScannerHelper Packages/PCRTCore --include='*.swift'; then
  echo "Persistent install or package-manager behavior was found in Swift source" >&2
  exit 1
fi

swiftc -frontend -parse $(find PCRTDiagnosticsMac PCRTScannerHelper -name '*.swift' -print | sort)
python3 Scripts/validate-pbx.py PCRTDiagnosticsMac.xcodeproj/project.pbxproj

echo "Source checks passed for version $VERSION."
