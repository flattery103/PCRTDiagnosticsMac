# Reliability Stabilization — macOS 0.1.3

Version 0.1.3 is a client-only stabilization update based on the first completed 0.1.2 Burn-in report.

## Goals

- Eliminate false Wi-Fi and post-workload warnings.
- Correct battery condition and capacity units.
- Avoid Incomplete results when optional historical Unified Log queries are slow or restricted.
- Apply a materially heavier deterministic Metal workload.
- Add non-destructive filesystem verification and disconnect detection for external drives.
- Preserve unattended, portable operation and the existing four-report server contract.

## Status policy

- Benign success messages and zero-valued error fields never create warnings.
- Missing optional historical logs are Info when live or file-based baseline evidence was collected.
- Metal mismatches and command-buffer errors remain Fail.
- External-drive filesystem corruption, short reads, hash mismatches, or new media errors remain Fail.
- External-drive disconnects and unavailable live verification are Warning, not Fail, unless confirmed data-integrity failure is present.
- No throughput threshold alone determines drive failure.

## Unattended behavior

The user interaction remains limited to opening the portable app, entering the session code, clicking Start, and approving the administrator prompt. No interactive camera, microphone, display, speaker, keyboard, trackpad, cable, or port confirmation is introduced.
