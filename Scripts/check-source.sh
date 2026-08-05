#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' Packages/PCRTCore/Sources/PCRTCore/Utilities/Product.swift | head -1)"
[[ -n "$VERSION" ]] || { echo "Unable to determine PCRTProduct.version" >&2; exit 1; }

python3 - "$VERSION" <<'PY_CHECK_VERSION'
from pathlib import Path
import importlib.util
import plistlib
import sys
sys.dont_write_bytecode = True

version = sys.argv[1]
spec = importlib.util.spec_from_file_location("pbxvalidator", "Scripts/validate-pbx.py")
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
path = Path("PCRTDiagnosticsMac.xcodeproj/project.pbxproj")
data = path.read_bytes()
stripped = data.lstrip()
if stripped.startswith(b"<?xml") or data.startswith(b"bplist"):
    root = plistlib.loads(data)
else:
    root = module.Parser(module.tokenize(data.decode("utf-8"))).value()
versions = set()
for obj in root.get("objects", {}).values():
    if isinstance(obj, dict) and obj.get("isa") == "XCBuildConfiguration":
        settings = obj.get("buildSettings")
        if isinstance(settings, dict) and settings.get("MARKETING_VERSION"):
            versions.add(str(settings["MARKETING_VERSION"]))
if version not in versions:
    raise SystemExit(f"Xcode MARKETING_VERSION does not match {version}; found {sorted(versions)}")
PY_CHECK_VERSION

RELEASE_NOTES="RELEASE_NOTES_${VERSION}.md"
[[ -f "$RELEASE_NOTES" ]] || { echo "Missing $RELEASE_NOTES" >&2; exit 1; }
grep -q "# PCRT Diagnostics for macOS $VERSION" "$RELEASE_NOTES" || {
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


# Regression guards for the 0.1.3 stabilization fixes.
grep -q 'spairport_current_network_information' PCRTScannerHelper/Collectors/SystemCollectors.swift || {
  echo "Connected-network Wi-Fi parsing is missing" >&2
  exit 1
}
grep -q 'AppleRawCurrentCapacity' PCRTScannerHelper/Collectors/HardwareCollectors.swift || {
  echo "Raw battery current-capacity parsing is missing" >&2
  exit 1
}
grep -q 'AppleRawMaxCapacity' PCRTScannerHelper/Collectors/HardwareCollectors.swift || {
  echo "Raw battery full-charge-capacity parsing is missing" >&2
  exit 1
}
grep -q 'isBenignZeroOrSuccessLine' PCRTScannerHelper/Collectors/SystemCollectors.swift || {
  echo "Post-workload benign-event filtering is missing" >&2
  exit 1
}
grep -q 'let computeRounds = 256' PCRTScannerHelper/Collectors/HardwareCollectors.swift || {
  echo "The strengthened Metal compute workload is missing" >&2
  exit 1
}
grep -q 'let elementCount = 1_048_576' PCRTScannerHelper/Collectors/HardwareCollectors.swift || {
  echo "The strengthened Metal buffer size is missing" >&2
  exit 1
}
grep -q 'external-verify-volume-' PCRTScannerHelper/Collectors/HardwareCollectors.swift || {
  echo "External-volume filesystem verification is missing" >&2
  exit 1
}
if grep -q 'currentCapacity: numericInt64(dictionary\["CurrentCapacity"\])' PCRTScannerHelper/Collectors/HardwareCollectors.swift; then
  echo "Percentage-style CurrentCapacity is still being treated as mAh" >&2
  exit 1
fi
if grep -q 'maximumCapacity: numericInt64(dictionary\["MaxCapacity"\])' PCRTScannerHelper/Collectors/HardwareCollectors.swift; then
  echo "Percentage-style MaxCapacity is still being treated as mAh" >&2
  exit 1
fi

swiftc -frontend -parse $(find PCRTDiagnosticsMac PCRTScannerHelper -name '*.swift' -print | sort)
python3 Scripts/validate-pbx.py PCRTDiagnosticsMac.xcodeproj/project.pbxproj

echo "Source checks passed for version $VERSION."
