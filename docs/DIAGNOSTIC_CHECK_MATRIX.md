# Diagnostic Check Matrix

| Area | Initial macOS 0.1.0 implementation | Typical status policy |
|---|---|---|
| macOS inventory | `sw_vers`, `sysctl`, uptime, install history | Info; Incomplete on collector failure |
| Mac hardware | `system_profiler SPHardwareDataType` | Info; Incomplete if unavailable |
| CPU inventory | `sysctl` architecture/core/model values | Info; Incomplete if insufficient data |
| CPU prime validation | Known count of 78,498 primes through 1,000,000 | Fail only on mismatch |
| CPU sustained workload | Per-core deterministic sum-of-squares workload | Fail on calculation mismatch; Incomplete on internal stop |
| Memory inventory | `hw.memsize`, `vm_stat`, `memory_pressure`, profiler | Info/Incomplete |
| Memory patterns | 11 deterministic patterns in allocated application memory | Fail only on verified mismatch |
| Memory pressure | Repeated allocation write/read verification | Fail on verified mismatch; Incomplete if allocation refused |
| Disk/APFS inventory | `diskutil ... -plist` | Info/Incomplete |
| Filesystem capacity/mount state | URL resource values, `df`, `mount` | Warning for maintenance condition; Incomplete if unknown |
| Temporary file verification | Write, flush, complete read, SHA-256 compare | Fail on short read/hash mismatch; Incomplete on collector/access error |
| Physical read sampling | 64-bit distributed offsets on `/dev/rdisk*` | Fail only after successful open and real/short read error; Incomplete on access restriction or zero valid samples |
| SMART/native health | `diskutil`, NVMe profiler, optional already-installed `smartctl` | Fail on explicit failure; Incomplete/Not Available otherwise |
| Battery/power | Power profiler and `pmset` | Warning on reported service condition; N/A without battery |
| USB/Thunderbolt/PCI | `system_profiler` data types | Info/Incomplete/Not Available |
| GPU/display/Metal | Display profiler and Metal device enumeration | Info/Incomplete/Not Available; no GPU stress test |
| Network | route, interface, DNS, HTTPS, ping, counters | Warning for connectivity/packet-loss findings; Incomplete on collector failure |
| Panic/shutdown/hardware logs | Unified log and DiagnosticReports | Warning for reviewable evidence; Incomplete on access/timeout |
| Services | Repeated launchd abnormal-exit patterns | Warning only when repeated; Incomplete if unavailable |
| Updates | `softwareupdate --list` | Warning as maintenance only; never hardware failure |
| Security/configuration | FileVault, SIP, Gatekeeper, available Secure Boot evidence | Warning for disabled controls; Incomplete/Not Available where unsupported |
| RTC progression | Wall clock compared with monotonic continuous time | Warning on short-term inconsistency; not a CMOS test |
| Thermals | Process thermal state, `pmset`, available `powermetrics` evidence | Warning for serious/critical pressure; Not Available when sensors are hidden |

## Raw evidence

Full command output, exit codes, timeouts, and parsed raw structures are stored in `raw-data.json`. The HTML report presents concise evidence and expands Fail, Warning, Incomplete, and Deferred sections by default.
