# PCRT Diagnostics for macOS 0.1.1 — Thermal and Storage Reliability Update

## Overview

This source update focuses on two common hardware trouble areas: thermals and physical-drive failure detection. It incorporates evidence captured from an Apple M3 Mac running macOS 26.6 while preserving the existing Server 0.1.4 API, temporary-helper model, and exact four-report upload contract.

## Major improvements

- Corrected physical-drive mapping so synthesized APFS container devices are not counted as separate physical disks.
- Added richer physical-drive inventory: protocol, media type, location, SMART state, and numerical storage temperature when exposed.
- Parses Apple NVMe health fields exposed by `diskutil info -plist`, including critical warning, available spare, spare threshold, percentage used, media/data-integrity errors, error-log entries, power-on hours, power cycles, unsafe shutdowns, and temperature.
- Converts Apple NVMe temperature values from Kelvin when required and reports them in Celsius.
- Runs read-only partition-map verification for every validated physical drive.
- Runs live root-volume APFS/filesystem verification without repairing, unmounting, or modifying the disk.
- Limits raw-device sampling to validated physical media rather than APFS synthesized devices.
- Separates numerical temperature coverage from thermal-pressure status so missing Celsius readings are never shown as Pass.
- Uses the macOS `thermal` powermetrics sampler on Apple Silicon instead of the unsupported `smc` sampler.
- Collects CPU/GPU power, frequency, pressure, and limiting evidence when the model exposes it.
- Samples macOS thermal state throughout the sustained CPU workload and records the highest observed state.
- Treats serious or critical pressure during a completed workload as Warning, not a confirmed hardware Fail.
- Preserves Fail for confirmed calculation errors, short/raw read errors, filesystem corruption, explicit SMART failure, NVMe critical warnings, media/data-integrity errors, or other confirmed functional failure.

## M3 capability-capture conclusions

The reviewed M3 system exposed one physical Apple SSD (`/dev/disk0`) and three synthesized APFS whole-disk representations. Native data reported SMART Verified, zero media errors, zero NVMe error-log entries, zero percent used, and a numerical SSD temperature. The partition map, live APFS check, temporary-file hash verification, and read-only raw-device access all completed successfully in the capture.

Apple Silicon exposed thermal pressure, CPU/GPU power, frequency, and sensor-service names through built-in interfaces, but did not expose reliable CPU/GPU Celsius values through the supported command-line samplers. Version 0.1.1 states that limitation explicitly while still reporting storage temperature and workload thermal pressure.

## Safety and architecture

- No disk repairs, unmounts, firmware changes, or destructive surface tests.
- No permanent privileged helper, daemon, launch agent, login item, or package-manager installation.
- The helper remains bundled and temporary.
- Existing optional `smartctl` is used only when already installed; PCRT does not install it.
- Uses the existing Server 0.1.4 endpoints and claim-token flow without server changes.
- Produces exactly `system-info.html`, `test-results.html`, `raw-data.json`, and `run-log.txt`.

## Validation status

The shared Swift package and static source checks can be run on Linux. The full GUI/helper targets must still be compiled by the included GitHub Actions macOS runner and runtime-tested on Apple Silicon and Intel Macs before publishing a final signed release.
