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

version = sys.argv[1]

spec = importlib.util.spec_from_file_location(
    "pbxvalidator",
    "Scripts/validate-pbx.py"
)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

path = Path("PCRTDiagnosticsMac.xcodeproj/project.pbxproj")
data = path.read_bytes()
stripped = data.lstrip()

if stripped.startswith(b"<?xml") or data.startswith(b"bplist"):
    root = plistlib.loads(data)
else:
    root = module.Parser(
        module.tokenize(data.decode("utf-8"))
    ).value()

objects = root.get("objects", {})
versions = set()

for obj in objects.values():
    if not isinstance(obj, dict):
        continue
    if obj.get("isa") != "XCBuildConfiguration":
        continue

    settings = obj.get("buildSettings")
    if isinstance(settings, dict):
        found = settings.get("MARKETING_VERSION")
        if found:
            versions.add(found)

if version not in versions:
    raise SystemExit(
        f"Xcode MARKETING_VERSION does not match {version}; "
        f"found {sorted(versions)}"
    )
PY_CHECK_VERSION
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
