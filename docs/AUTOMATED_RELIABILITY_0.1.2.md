# Automated Hardware Reliability — macOS 0.1.2

## Objective

Version 0.1.2 adds the most useful missing automated hardware checks while preserving PCRT Diagnostics as a portable, remote-friendly application. Once the session code is entered, Start is selected, and administrator authorization is approved, no further user interaction is required.

No camera, microphone, display-confirmation, keyboard, trackpad, speaker, or manual port tests are included.

## 1. Metal GPU functional and sustained workload

The helper enumerates Metal devices and creates a deterministic workload using only Apple frameworks already present in macOS.

The functional phase:

- Compiles Metal Shading Language source at runtime.
- Creates a compute pipeline, render pipeline, command queue, buffers, and offscreen texture.
- Runs known compute operations and compares returned values with expected values.
- Renders a deterministic output into an offscreen texture and validates returned pixels.
- Checks command-buffer completion and error state.

The sustained phase repeats command buffers for a duration based on the requested mode:

| Mode | Approximate GPU workload |
|---|---:|
| Quick/default | 30 seconds |
| Full/Deep/Hardware/GPU/Thermal | 3 minutes |
| Burn-in | 10 minutes |

During the workload, the helper samples macOS thermal pressure. When supported, it also runs a bounded `powermetrics` collection with GPU-power and thermal samplers. Missing power telemetry does not turn a successful Metal validation into a failure.

A deterministic compute/render mismatch or Metal command-buffer failure is confirmed functional evidence and can produce Fail. Serious or critical thermal pressure without a calculation failure produces Warning.

## 2. Post-workload hardware event review

The diagnostic context records the first automated workload start time. After CPU, memory, storage, GPU, and external-drive workloads have completed, a targeted Unified Log query reviews only the active test window.

The query searches for evidence involving:

- Storage I/O, NVMe, and APFS errors
- GPU resets, hangs, and command failures
- Serious or critical thermal conditions
- Memory-pressure termination or allocation failures
- Panic and unexpected restart indicators
- USB and Thunderbolt reset/disconnect events

The query has a bounded runtime. Relevant events produce reviewable evidence; a logging restriction does not by itself prove hardware failure.

## 3. Storage temperature, performance, and integrity trend

The existing temporary-file test now records more context around the same safe workload:

- Native physical-drive temperature and health before the test
- Temperature and counters after writing and after reading
- Write/read throughput by bounded intervals
- Average, 95th-percentile, and maximum I/O block latency
- Complete read length
- SHA-256 hash before and after storage
- Native media-error and NVMe error-log counter changes

The test file remains inside PCRT's temporary workspace and is removed after the test. Ordinary speed variation is informational because storage performance varies by model, encryption, free space, caching, thermal state, and competing activity.

Confirmed short reads, I/O errors, hash mismatches, or newly observed media errors can produce Fail. High temperature or new controller/error-log evidence without confirmed data corruption produces Warning.

## 4. Expanded battery and charging health

The battery collector combines `system_profiler`, `pmset`, and AppleSmartBattery I/O Registry data. Depending on the Mac, it can report:

- macOS condition
- Current, full-charge, and design capacity
- Maximum-capacity percentage
- Cycle count
- Voltage and current
- Battery temperature
- External-power and charging state
- Connected adapter rating

When external power is connected and the battery is not already full, the helper performs six additional samples over approximately 60 seconds. This is an observation, not a battery discharge benchmark.

Warnings are limited to evidence such as an explicit service condition, maximum capacity below 80%, high battery temperature, or discharge while adequate external power is reported. Desktop Macs return Not Applicable.

## 5. Wi-Fi and network quality

The network collector performs unattended tests using built-in macOS tools:

- Active interface and default gateway detection
- IPv4 and IPv6 route checks
- Repeated DNS lookups with response timing
- Repeated HTTPS health requests over IPv4 and IPv6 when available
- Gateway and public-target ping latency, jitter, and packet loss
- Wi-Fi RSSI, noise, SNR, rate, channel, and PHY evidence when exposed
- Active `utun` tunnel/VPN detection
- Built-in `networkQuality` measurement in Full, Deep, and Burn-in modes

A successful HTTPS request prevents blocked ICMP alone from being treated as a general Internet outage. Results remain contextual because VPNs, filtering, captive portals, and remote networks can affect measurements.

## 6. External-drive testing

The helper distinguishes external physical devices from synthesized APFS containers. For each supported external disk it collects native drive information and health evidence. For each writable mounted external volume with adequate free space, it creates a PCRT-owned temporary folder and runs a bounded write/read/SHA-256 test.

The temporary workload is:

- 64 MB for normal modes
- 128 MB for Burn-in

PCRT does not erase, repartition, unmount, repair, or surface-scan external media. Every temporary file and directory is removed. Read-only, locked, unsupported, or inaccessible media is reported without assuming failure. No connected external drive returns Not Applicable.

## Raw-device access policy

Direct `/dev/rdisk*` sampling is optional supplemental evidence. When macOS denies access, PCRT reports Not Available instead of Incomplete. That restriction does not change the results of native SMART/NVMe health, partition verification, APFS verification, temperature, or file-integrity checks.

Fail remains possible only after a device opens successfully and a real short read, read error, or other confirmed hardware/data-integrity failure is observed.

## Safety and portability

- No installation is required.
- No command line is required to start the application.
- No third-party package is downloaded or installed.
- No permanent helper, daemon, launch agent, or login item is created.
- No filesystem repair, firmware change, disk unmount, or destructive test is performed.
- The existing temporary privileged helper exits with the scan.
- The app may run from any normal portable location, including Downloads, Desktop, a technician folder, or external media.
