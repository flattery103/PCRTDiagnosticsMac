# PCRT Diagnostics for macOS 0.1.0 — Initial Beta

## Overview

This is the initial source release of the native PCRT Diagnostics macOS client. It introduces a SwiftUI user interface, a bundled temporary privileged scanner helper, Universal 2 build configuration, Server 0.1.4 API integration, and the four-report output expected by the current PCRT server.

## Included

- Native SwiftUI GUI for macOS 11 Big Sur or later.
- Apple Silicon ARM64 and Intel x86_64 build settings.
- Five-character session-code validation and automatic uppercase conversion.
- Non-consuming session configuration retrieval.
- Administrator authorization only after Start is clicked.
- Privileged preflight before the session is claimed.
- Same-client idempotent claim retry with a stable client ID for the run.
- Claim-token protected progress, status, and report upload requests.
- Temporary root helper with local authenticated Unix-socket JSON IPC.
- Heartbeat, cancellation, command timeouts, child-process termination, and cleanup.
- CPU, memory, storage, battery, device, GPU/Metal, network, log, security, update, RTC, and thermal-pressure checks.
- Conservative Fail/Warning/Incomplete/Not Available scoring.
- Technician-facing HTML summaries with collapsible evidence.
- Raw JSON and run-log preservation.
- Exact four-file upload acknowledgement before automatic close.
- Retry Upload and Show Reports in Finder after upload failure.
- GitHub Actions workflow for tests, Universal 2 Release builds, ZIP artifacts, and tag releases.
- Conditional future Developer ID signing and notarization support.

## Intentional exclusions

- No permanent privileged helper, daemon, launch agent, or login item.
- No installer or package manager integration.
- No automatic Homebrew or third-party utility installation.
- No App Store sandbox.
- No Metal GPU stress workload in 0.1.0.
- No claim of complete macOS temperature-sensor coverage.
- No macOS lifecycle Pass/Fail result.
- No CMOS-battery diagnostic.
- No destructive disk test.
- No repair, firmware-setting, FileVault, SIP, Gatekeeper, or Secure Boot changes.

## Server compatibility notes

- Uses the existing Server 0.1.4 API and database schema without changes.
- The server currently acknowledges an upload when at least one file is accepted. The macOS client therefore checks the returned `uploaded` list for all four exact filenames before closing.
- Server scan presets contain Windows-oriented test keys. The macOS client uses the server scan type and numeric limits to select a separate macOS diagnostic plan.
- The current server download page is Windows-EXE specific. macOS beta ZIPs are intended to be distributed through GitHub Releases.

## Beta validation required

Before calling this a tested binary release, build and run it on representative systems:

- Apple Silicon laptop and desktop where available.
- Intel laptop and desktop.
- macOS 11 and newer supported versions.
- Battery and non-battery Macs.
- Authorization accepted and cancelled.
- Valid, invalid, expired, and previously used session codes.
- Cancellation during CPU, memory, disk, and log tests.
- Upload interruption and retry.
- FileVault/SIP/Gatekeeper variations.
- APFS internal and external storage.

This source release does not state that the finished macOS app has been compiled, signed, notarized, or physically tested unless a particular workflow run or release explicitly records those results.
