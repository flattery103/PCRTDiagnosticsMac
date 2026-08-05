# PCRT Diagnostics for macOS 0.1.2 — Unattended Hardware Reliability Update

Version 0.1.2 expands the portable macOS client with unattended GPU, storage, battery, network, external-drive, and post-workload event testing. After the session code is entered, **Start** is selected, and the normal administrator authorization is approved, the scan requires no further user interaction.

## New automated tests

### Metal GPU functional and sustained workload

- Compiles a deterministic Metal compute kernel at runtime.
- Verifies known compute-buffer results.
- Performs offscreen rendering and validates returned texture pixels.
- Checks Metal command-buffer completion and errors.
- Runs concurrent GPU power, frequency, and thermal telemetry when `powermetrics` exposes it.
- Uses mode-specific durations: approximately 30 seconds for Quick, 3 minutes for Full/Hardware/GPU/Thermal, and 10 minutes for Burn-in.

### Post-workload hardware event review

- Records the first workload start time.
- Searches only the current test window for relevant storage/APFS, GPU, thermal, memory-pressure, panic, USB, and Thunderbolt events.
- Uses a bounded targeted Unified Log query rather than an unbounded historical search.

### Storage temperature, performance, and integrity trend

- Captures physical-drive health and temperature before, during, and after the temporary-file workload.
- Records interval write/read throughput and block latency, including average, 95th percentile, and maximum latency.
- Retains full-file SHA-256 verification.
- Compares native media-error and NVMe error-log counters before and after the workload.
- Does not classify ordinary throughput variation alone as a hardware failure.

### Expanded battery and charging health

- Collects macOS battery condition, capacity, cycle count, voltage, current, temperature, power-source state, and available adapter information.
- Performs a bounded 60-second charge observation only when external power is connected and the battery is not already full.
- Warns on explicit service conditions, low reported maximum capacity, high battery temperature, or unexpected discharge while connected to external power.

### Wi-Fi and network quality

- Separately reviews IPv4 and IPv6 routing and reachability.
- Collects repeated DNS and HTTPS timing samples.
- Records gateway and Internet latency, packet loss, and jitter.
- Collects Wi-Fi signal/noise/rate/channel evidence when macOS exposes it.
- Identifies active tunnel/VPN interfaces that can affect routing.
- Runs the built-in `networkQuality` test only for Full, Deep, and Burn-in modes.
- Does not treat blocked ICMP by itself as Internet failure when HTTPS succeeds.

### External-drive health and integrity

- Detects actual external physical media and mounted external volumes.
- Collects native SMART/NVMe evidence where available.
- Performs a bounded temporary write/read/SHA-256 verification only on writable mounted external volumes with adequate free space.
- Uses 64 MB normally and 128 MB for Burn-in.
- Removes every temporary test file and folder after the check.
- Reports Not Applicable when no external drive is connected.

## Raw-device status correction

When macOS denies optional direct access to a physical raw device with `Operation not permitted` or another access restriction, PCRT now reports **Not Available** rather than **Incomplete**. Native SMART/NVMe health, partition-map verification, APFS verification, storage temperature, and temporary-file integrity evidence remain available and are reported independently.

A raw device that opens successfully but returns a genuine short read or read error can still produce a confirmed failure.

## Unattended and portable behavior

- No interactive display, camera, microphone, keyboard, trackpad, speaker, or port-confirmation checks were added.
- The app remains portable and may be opened from Downloads, Desktop, a technician tools folder, or external media.
- No installer, Homebrew dependency, daemon, login item, or permanent privileged helper is used.
- The existing administrator authorization prompt remains the only authorization interaction after Start.
- Exactly four reports are generated and uploaded: `system-info.html`, `test-results.html`, `raw-data.json`, and `run-log.txt`.

## Validation status

The shared Swift package tests and Linux-hosted Swift syntax checks pass. The SwiftUI application, Metal implementation, privileged helper, Universal 2 output, and hardware behavior must still be compiled through the included GitHub Actions Xcode workflow and validated on representative Apple Silicon and Intel Macs before production release.
