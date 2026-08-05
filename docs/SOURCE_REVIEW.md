# Source Review Basis

The macOS 0.1.0 design was based on a static review of:

- PCRT Diagnostics Windows client 0.0.25 source.
- PCRT Diagnostics Linux client 0.1.0 source.
- PCRT Diagnostics Server 0.1.4 source.
- The supplied Windows GUI and technician report example.

## Reused concepts

- Server configuration, claim, status, claim-token, and upload flow.
- Same-client idempotent claim retry.
- Four required report filenames.
- Domain-based scoring and concise action summary.
- Collapsible technical evidence.
- Known prime count and deterministic CPU checks.
- Application-level memory patterns and pressure workload.
- Distributed physical-drive sample positions using 64-bit offsets.
- Temporary file write/read/hash verification.
- Conservative access/error handling.

## Rewritten for macOS

- All user interface code.
- Privilege request and temporary-helper lifecycle.
- Local IPC.
- System, hardware, disk/APFS, battery, device, GPU/Metal, network, log, security, update, and thermal collection.
- Command execution, timeout, and child-process cancellation.
- macOS report terminology and domains.
- Universal 2 Xcode and GitHub Actions build structure.
