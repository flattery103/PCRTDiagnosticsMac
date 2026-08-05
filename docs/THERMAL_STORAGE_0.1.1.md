# Thermal and Storage Reliability — macOS 0.1.1

## Capability capture reviewed

The 0.1.1 changes were guided by a read-only capability capture from an Apple M3 Mac (`Mac15,13`) running macOS 26.6.

The capture showed:

- One physical internal Apple SSD: `/dev/disk0`, model `APPLE SSD AP0512Z`.
- Three additional top-level `diskutil` entries were synthesized APFS containers, not additional physical drives.
- Native SMART status was `Verified`.
- NVMe media/data-integrity errors: `0`.
- NVMe error-log entries: `0`.
- NVMe percentage used: `0`.
- Apple NVMe temperature field: `306 K`, or approximately `32.9 °C`.
- Physical partition-map verification completed successfully.
- Live root-volume APFS verification completed successfully.
- A read-only 1 MiB raw read from `/dev/rdisk0` completed successfully.
- The built-in Apple Silicon `powermetrics` samplers exposed thermal pressure and CPU/GPU power/frequency information.
- The `smc` powermetrics sampler was not available on that Apple Silicon model.
- Sensor-service names were visible in I/O Registry, but reliable CPU/GPU Celsius readings were not available through the supported command-line interfaces.

## 0.1.1 storage behavior

The physical-disk collector now separates real physical media from APFS synthesized devices. Each validated physical disk can report:

- Device identifier, model, capacity, protocol, media type, and location.
- Native SMART status.
- NVMe critical warning.
- Available spare and threshold.
- Percentage used.
- Media/data-integrity errors.
- Error-log entry count.
- Unsafe shutdowns.
- Power-on hours and power cycles.
- Numerical storage temperature when macOS exposes it.
- Read-only partition-map verification.
- Distributed raw-device read sampling.
- Live root-volume APFS/filesystem verification.
- Temporary-file write, flush, read, and SHA-256 verification.

No storage check repairs, unmounts, erases, or changes a disk.

## 0.1.1 thermal behavior

Thermal reporting is split into two independent results:

1. **Numerical temperature coverage**
   - Reports storage temperature from native NVMe health data when exposed.
   - Attempts Intel SMC temperature output on Intel Macs.
   - Explicitly reports CPU/GPU numerical temperatures as unavailable on Apple Silicon when supported interfaces do not expose them.
   - Missing numerical coverage is never marked Pass.

2. **Thermal pressure, power, and throttling evidence**
   - Uses the supported `thermal` powermetrics sampler.
   - Collects CPU/GPU power and frequency evidence where available.
   - Records `pmset` thermal-warning history.
   - Samples `ProcessInfo.thermalState` throughout the sustained CPU workload.
   - Serious or critical thermal pressure produces Warning unless a separate functional calculation failure justifies Fail.

## Status policy

Storage Fail remains reserved for confirmed evidence such as:

- Explicit SMART failure.
- Nonzero NVMe critical warning.
- Nonzero NVMe media/data-integrity errors.
- Available spare below the controller threshold.
- Confirmed partition-map or filesystem corruption.
- Repeatable short or failed raw reads after the device opened successfully.
- Temporary-file data or SHA-256 mismatch.

Missing SMART support, inaccessible optional fields, and unsupported numerical sensors remain Incomplete or Not Available rather than Fail.
