# PCRT Diagnostics for macOS 0.1.3 — Reliability Parsing and Workload Stabilization

Version 0.1.3 corrects false warnings and incomplete results found during the first real-world 0.1.2 Burn-in run. It preserves the portable, fully unattended workflow: after the session code is entered, **Start** is selected, and the normal administrator authorization is approved, no further interaction is required.

## Corrected Wi-Fi evidence

- Reads RSSI, noise, transmit rate, channel, and PHY mode from the connected network object in `system_profiler SPAirPortDataType` rather than flattening nearby-network entries together.
- Uses the active route interface to prefer the correct Wi-Fi interface.
- Uses anchored `wdutil` connected-interface fields only as a fallback for values not exposed by `system_profiler`.
- Calculates SNR only from a valid RSSI/noise pair.
- Prevents a nearby network or duplicated RSSI value from creating a false low-SNR warning.

## Corrected battery field mapping

- Reads macOS battery condition and maximum-capacity percentage from the structured `SPPowerDataType` battery-health section.
- Uses `AppleRawCurrentCapacity` and `AppleRawMaxCapacity` for mAh values instead of percentage-style `CurrentCapacity` and `MaxCapacity` fields.
- Keeps cycle count, design capacity, voltage, amperage, temperature, charging state, and adapter evidence separate.
- Prevents cycle count or charge percentage from being mislabeled as condition or mAh capacity.

## More precise post-workload event review

- Filters expected `error = 0`, successful filesystem checks, cache-management messages, and benign `GetAPFSVolumeRole` output.
- Ignores PCRT-triggered `fsck_apfs` lines unless they contain explicit corruption, invalid metadata, checksum, failure, or I/O evidence.
- Warns only for actionable storage, GPU, serious thermal, critical memory-pressure, panic, USB, or Thunderbolt evidence.
- Reports candidate and actionable line counts so technicians can see what was filtered.

## Split panic and service-history queries

- Replaces broad long-running log searches with separate bounded 24-hour queries.
- Panic and shutdown-cause queries have independent limits and are supplemented by recent DiagnosticReports and boot/shutdown history.
- Launchd abnormal-exit, crash, and respawn searches have independent limits and group repeated service evidence.
- When historical Unified Log access is unavailable but live baseline evidence exists, the result is informational rather than incorrectly Incomplete.

## Stronger Metal workload

- Increases the deterministic compute buffer to 1,048,576 elements.
- Increases each compute element to 256 arithmetic rounds and submits four compute dispatches per command buffer.
- Increases the offscreen render target to 2048×2048 and performs four full-screen draws per command buffer.
- Continues validating compute output, rendered pixels, command-buffer completion, thermal pressure, and available `powermetrics` telemetry.

## Expanded external-drive validation

- Runs a live, non-repairing `diskutil verifyVolume` check for mounted external volumes.
- Retains the bounded temporary write/read/SHA-256 verification and cleanup.
- Compares native health counters before and after the workload.
- Warns when a physical external drive disappears during the test, which can indicate a cable, enclosure, port, or power problem.
- Does not erase, repair, repartition, unmount, or write outside PCRT-owned temporary files.

## Server scope

No PCRT Diagnostics Server code or API behavior is changed in 0.1.3. The transient portal Internal Server Error observed during the 0.1.2 test remains a monitoring item only.

## Validation status

Linux-hosted static source checks and the shared `PCRTCore` tests validate syntax, project structure, report contracts, and platform-independent behavior. GitHub Actions on macOS/Xcode remains the authoritative compile and Universal 2 build test. A real external USB or Thunderbolt drive is still required to validate the complete external-drive runtime path before production release.
