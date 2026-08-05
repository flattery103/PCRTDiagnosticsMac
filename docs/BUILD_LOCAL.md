# Local Build Directions

## Requirements

- A Mac running a supported macOS version.
- Xcode 16.x installed.
- Xcode command-line tools selected.
- No third-party packages are required.

Xcode 16 is intentionally used for the initial build because the project deployment target is macOS 11.0.

## Xcode GUI build

1. Open `PCRTDiagnosticsMac.xcodeproj`.
2. Select the shared `PCRTDiagnosticsMac` scheme.
3. Select **My Mac** as the destination.
4. For an unsigned test build, open the app target's Signing & Capabilities settings and leave a development team unset if Xcode permits, or build from the command line with code signing disabled.
5. Choose **Product > Test**.
6. Choose **Product > Build**.

The helper target is a dependency of the app target and is copied into `Contents/MacOS`.

## Copyable command-line build

From the repository root:

```bash
chmod +x Scripts/*.sh
./Scripts/build-release.sh
```

The script performs:

- Swift package tests.
- Xcode unit tests.
- Release build with `ARCHS="arm64 x86_64"` and `ONLY_ACTIVE_ARCH=NO`.
- App/helper architecture and bundle verification.
- ZIP packaging with `ditto`.
- SHA-256 checksum generation.

Expected output:

```text
build/release/PCRTDiagnosticsMac-0.1.2.zip
build/release/PCRTDiagnosticsMac-0.1.2.zip.sha256
```

## Manual build command

```bash
xcodebuild \
  -project PCRTDiagnosticsMac.xcodeproj \
  -scheme PCRTDiagnosticsMac \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Then verify:

```bash
./Scripts/verify-app.sh "build/DerivedData/Build/Products/Release/PCRT Diagnostics.app"
```

## Important limitation

A successful build is not the same as hardware validation. Test administrator authorization, helper cleanup, every diagnostic mode, cancellation, report creation, upload, and upload retry on representative Intel and Apple Silicon Macs before publishing a production release.
