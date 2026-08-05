# Diagnostic Check Matrix

| Area | macOS 0.1.2 implementation | Typical status policy |
|---|---|---|
| macOS inventory | `sw_vers`, `sysctl`, uptime, install history | Info; Incomplete on collector failure |
| Mac hardware | `system_profiler SPHardwareDataType` | Info; Incomplete if unavailable |
| CPU inventory | `sysctl` architecture/core/model values | Info; Incomplete if insufficient data |
| CPU prime validation | Known count of 78,498 primes through 1,000,000 | Fail only on mismatch |
| CPU sustained workload | Per-core deterministic sum-of-squares workload plus thermal-state sampling | Fail on calculation mismatch; Warning on serious/critical pressure; Incomplete on internal stop |
| Memory inventory | `hw.memsize`, `vm_stat`, `memory_pressure`, profiler | Info/Incomplete |
| Memory patterns | 11 deterministic patterns in allocated application memory | Fail only on verified mismatch |
| Memory pressure | Repeated allocation write/read verification | Fail on verified mismatch; Incomplete if allocation refused |
| Disk/APFS inventory | Physical-only disk mapping plus `diskutil ... -plist` APFS/container/volume data | Info/Incomplete |
| Filesystem capacity and APFS | URL resource values, `df`, mount state, live `diskutil verifyVolume /` | Fail on confirmed corruption; Warning for maintenance condition; Incomplete if verification cannot run |
| Storage workload | Temperature/counter snapshots, interval throughput, block latency, complete read, SHA-256 compare | Fail on short read/hash mismatch/new media errors; Warning on high temperature or new controller evidence; speed alone is informational |
| Physical raw sampling | 64-bit distributed offsets on validated physical `/dev/rdisk*` devices | Fail only after successful open and real short/read error; Not Available on macOS access restriction |
| SMART/native health | `diskutil` SMART/NVMe fields, partition-map verification, optional already-installed `smartctl` | Fail on explicit native failure; Warning for reviewable wear/temperature/counter evidence; Not Available where unsupported |
| External drives | Physical external media inventory plus bounded temporary write/read/SHA-256 test on writable mounted volumes | Fail on confirmed integrity/I/O error; Warning for native health evidence; N/A when none connected; no repair/unmount |
| Battery and charging | Power profiler, `pmset`, AppleSmartBattery details, optional 60-second charge observation | Warning on service condition, capacity below 80%, high temperature, or unexpected discharge on external power; N/A without battery |
| USB/Thunderbolt/PCI | `system_profiler` data types | Info/Incomplete/Not Available |
| GPU/display/Metal inventory | Display profiler and Metal device enumeration | Info/Incomplete/Not Available |
| Metal GPU functional workload | Runtime MSL compute validation, offscreen rendering/pixel validation, sustained command buffers, concurrent thermal/power telemetry | Fail on deterministic mismatch or command-buffer error; Warning on serious/critical pressure; telemetry absence does not fail the workload |
| Network and Wi-Fi | IPv4/IPv6 routes, repeated DNS/HTTPS, gateway/Internet latency, Wi-Fi evidence, VPN detection, optional `networkQuality` | Warning for verified connectivity/quality findings; blocked ICMP alone does not imply failure when HTTPS works; Incomplete on collector failure |
| Post-workload events | Targeted Unified Log query from first workload start through review time | Warning for relevant storage/GPU/thermal/memory/USB/TB events; Incomplete/Not Available on logging restriction |
| Panic/shutdown/hardware history | Bounded seven-day Unified Log and DiagnosticReports review | Warning for reviewable evidence; Incomplete on access/timeout |
| Services | Bounded repeated launchd abnormal-exit review | Warning only when repeated; Incomplete if unavailable |
| Updates | `softwareupdate --list` | Warning as maintenance only; never hardware failure |
| Security/configuration | FileVault, SIP, Gatekeeper, available Secure Boot evidence | Warning for disabled controls; Incomplete/Not Available where unsupported |
| RTC progression | Wall clock compared with monotonic continuous time | Warning on short-term inconsistency; not a CMOS test |
| Numerical temperatures | Native storage and battery temperatures plus other reliable values macOS exposes | Info when values exist; Not Available when a category is hidden; no guessed values |
| Thermal pressure/power | Process thermal state, `pmset`, supported `powermetrics` samplers | Warning for serious/critical pressure; Not Available when evidence is hidden |

## Unattended behavior

All checks run automatically after Start and administrator approval. No display, camera, microphone, speaker, keyboard, trackpad, or manual device-confirmation test is included.

## Raw evidence

Full command output, exit codes, timeouts, parsed structures, workload measurements, and categorized event evidence are stored in `raw-data.json`. The HTML report presents concise evidence and expands Fail, Warning, Incomplete, and Deferred sections by default.
