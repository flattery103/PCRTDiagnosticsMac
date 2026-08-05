# Architecture

## Components

### PCRT Diagnostics.app

The GUI runs as the logged-in user and owns all network communication. It is responsible for:

- Session-code validation.
- Configuration retrieval.
- Local unprivileged preflight.
- Administrator authorization.
- Session claim and claim-token retention.
- Progress/status updates.
- Uploading and verifying the four report files.
- Keeping the window open after upload failure.
- Closing automatically only after complete acknowledgement.

The GUI never sends the session code, claim token, customer name, technician name, or server URL to the root helper.

### PCRTScannerHelper

`PCRTScannerHelper` is embedded in `PCRT Diagnostics.app/Contents/MacOS/`. It is launched as a one-time root process after administrator authorization. It:

- Validates the workspace and socket peer.
- Performs privileged preflight.
- Waits for the GUI to claim the server session.
- Receives only a sanitized scan configuration.
- Runs Apple-provided collectors and application-level workloads.
- Creates the four reports.
- Returns ownership of report files to the logged-in user.
- Exits after completion, cancellation, GUI disconnect, or heartbeat timeout.

It does not contact the PCRT server and is never installed into `/Library`, `/Library/PrivilegedHelperTools`, LaunchDaemons, LaunchAgents, or login items.

### PCRTCore

The local static Swift package provides:

- Codable result, inventory, session, and report models.
- Scan planning.
- Status/domain scoring.
- Deterministic diagnostic algorithms.
- SHA-256 implementation.
- Newline-delimited JSON IPC envelopes.
- Unix-domain socket support on macOS.
- HTML and raw JSON report generation.

Using a static package keeps the final application independent of an embedded third-party runtime or separately installed framework.

## Run sequence

```text
User enters code
      |
      v
GET session configuration (does not claim)
      |
      v
Unprivileged preflight
      |
      v
Administrator authorization
      |
      v
Root helper validates socket/workspace and reports READY
      |
      v
GUI claims session and receives claim token
      |
      v
GUI sends sanitized BEGIN message
      |
      v
Helper runs diagnostics and streams progress
      |
      v
Helper generates four reports and exits
      |
      v
GUI uploads reports and checks all four returned filenames
      |
      +-- incomplete acknowledgement or error --> remain open, retry available
      |
      v
Server status COMPLETE, success shown, app closes
```

## State model

The main view model uses explicit states:

```text
idle
loadingConfiguration
unprivilegedPreflight
awaitingAuthorization
privilegedPreflight
claimingSession
running
cancelling
generatingReports
uploading
uploadFailed
complete
cancelled
error
```

This prevents accidental early claiming, duplicate starts, and automatic close before upload acknowledgement.

## Report ownership

The GUI creates a mode-0700 run directory under the current user's home directory. The root helper writes reports there and then recursively returns ownership to the caller UID. Workload files beginning with `.pcrt-` are temporary and removed by `defer` paths before the helper exits.
