# PCRT Diagnostics for macOS 0.1.2

Native SwiftUI macOS client for the PCRT Diagnostics Server 0.1.4 API.

This repository contains the complete source project for a portable `PCRT Diagnostics.app` with a bundled, temporary privileged scanner helper. The helper is launched only after the user clicks **Start** and approves the normal macOS administrator prompt. It is not installed as a daemon, launch agent, login item, or permanent privileged helper.

After Start and administrator approval, every diagnostic is automated. The client contains no camera, microphone, display-confirmation, keyboard, trackpad, speaker, or other interactive hardware checks.

## 0.1.2 focus: unattended hardware reliability

Version 0.1.2 adds:

- Deterministic Metal compute and offscreen-render validation with a sustained GPU workload.
- Post-workload hardware-event review limited to the active diagnostic window.
- Storage temperature, throughput, latency, native-error-counter, and SHA-256 trending.
- Expanded battery health and an automatic charging observation when applicable.
- Wi-Fi, IPv4, IPv6, DNS, VPN, gateway, and Internet-quality evidence.
- Safe temporary integrity testing for writable mounted external drives.
- Correct **Not Available** handling when macOS blocks optional raw-device access.

See [`docs/AUTOMATED_RELIABILITY_0.1.2.md`](docs/AUTOMATED_RELIABILITY_0.1.2.md) and [`docs/THERMAL_STORAGE_0.1.1.md`](docs/THERMAL_STORAGE_0.1.1.md).

## Configured deployment targets

- macOS 11 Big Sur or later
- Apple Silicon ARM64
- Intel x86_64
- One Universal 2 application bundle when built with the included Release workflow

## Portable user workflow

1. Download and extract the ZIP.
2. Open `PCRT Diagnostics.app` from Downloads, Desktop, a technician tools folder, or external media.
3. Complete macOS's first-run approval for the unsigned beta when required.
4. Enter the five-character session code.
5. Click **Start** and approve the administrator prompt.
6. Leave the scan unattended until it finishes and uploads its reports.

The app does not need to be moved to `/Applications`, and users do not need Terminal to start it.

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
build/release/PCRTDiagnosticsMac-0.1.2.zip
```

## Status policy

- **Fail** is reserved for confirmed calculation mismatches, data-integrity mismatches, successful-device short/read failures, Metal command failures, or explicit native failure evidence.
- Optional raw-device access denied by macOS is **Not Available**, not Incomplete and not Fail.
- Unsupported hardware and optional capabilities are **Not Available** or **Not Applicable**.
- Unexpected collector failures may be **Incomplete** when a check that should have run could not finish.
- macOS updates and configuration findings remain separate from hardware conclusions.
- No repairs, firmware changes, destructive disk tests, or forced unmounts are performed.

## Current validation status

The shared `PCRTCore` Swift package contains platform-independent unit tests. Linux-hosted source checks can validate Swift syntax and project structure. The SwiftUI application, Metal workload, helper authorization, Universal 2 output, and hardware behavior require Xcode compilation and runtime validation on macOS. See `RELEASE_NOTES_0.1.2.md` for the beta validation scope.

## License

GPL-3.0. See [`LICENSE`](LICENSE).
