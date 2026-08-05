# PCRT Diagnostics for macOS 0.1.1

Native SwiftUI macOS client for the PCRT Diagnostics Server 0.1.4 API.

This repository contains the complete source project for the first macOS client. It is designed as a portable `PCRT Diagnostics.app` with a bundled, temporary privileged scanner helper. The helper is launched only after the user clicks **Start** and approves the macOS administrator prompt. It is not installed as a daemon, launch agent, login item, or permanent privileged helper.

## 0.1.1 focus: thermals and physical-drive health

Version 0.1.1 corrects APFS synthesized-device counting, maps actual physical drives, parses native Apple NVMe health fields and storage temperature, verifies physical partition maps and the live root APFS volume, and limits raw sampling to validated physical media. Thermal reporting now separates numerical temperature coverage from macOS thermal-pressure status and records thermal state throughout the sustained CPU workload. See [`docs/THERMAL_STORAGE_0.1.1.md`](docs/THERMAL_STORAGE_0.1.1.md).

## Configured deployment targets

- macOS 11 Big Sur or later
- Apple Silicon ARM64
- Intel x86_64
- One Universal 2 application bundle when built with the included Release workflow

## Server

The production server URL is compiled into the client and is not shown or editable:

```text
https://scan.pcrtdiag.com:8443/
```

The client uses the existing Server 0.1.4 flow:

1. Fetch session configuration without consuming the code.
2. Perform unprivileged preflight.
3. Request administrator authorization.
4. Perform privileged preflight.
5. Claim the session and retain the claim token.
6. Run diagnostics while sending status updates.
7. Create and upload all four required reports.
8. Close only after the server acknowledges all four filenames.

## Reports

Each completed run creates:

- `system-info.html`
- `test-results.html`
- `raw-data.json`
- `run-log.txt`

Reports are retained under:

```text
~/PCRTDiagnostics/<computer>_<date-time>/
```

An upload error leaves the app open and provides **Retry Upload** and **Show Reports in Finder**.

## Project layout

```text
PCRTDiagnosticsMac/       SwiftUI GUI and server client
PCRTScannerHelper/        Temporary privileged diagnostic executable
Packages/PCRTCore/        Shared models, algorithms, IPC, scoring, and reports
PCRTDiagnosticsMacTests/  Xcode unit tests
.github/workflows/        Universal 2 build and release workflow
Scripts/                  Build, verification, signing, and source checks
docs/                     Architecture, security, build, and diagnostic documents
```

## Build

See:

- [`docs/BUILD_LOCAL.md`](docs/BUILD_LOCAL.md)
- [`docs/BUILD_GITHUB.md`](docs/BUILD_GITHUB.md)
- [`docs/UNSIGNED_BETA.md`](docs/UNSIGNED_BETA.md)
- [`docs/SIGNING_AND_NOTARIZATION.md`](docs/SIGNING_AND_NOTARIZATION.md)

Quick local Release build on a Mac with Xcode 16:

```bash
chmod +x Scripts/*.sh
./Scripts/build-release.sh
```

The expected output is:

```text
build/release/PCRTDiagnosticsMac-0.1.1.zip
```

## Status policy

- **Fail** is reserved for confirmed calculation mismatches, data-integrity mismatches, confirmed short/raw read failures, or explicit native failure evidence.
- Access restrictions, missing optional tools, unsupported hardware, and collector errors are **Incomplete** or **Not Available**.
- macOS updates and configuration findings remain separate from hardware conclusions.
- No repairs or firmware changes are performed.

## Current validation status

The shared `PCRTCore` Swift package contains platform-independent unit tests. The macOS application and helper require Xcode and a macOS test system for compilation and runtime validation. See `RELEASE_NOTES_0.1.1.md` for the beta validation scope.

## License

GPL-3.0. See [`LICENSE`](LICENSE).
