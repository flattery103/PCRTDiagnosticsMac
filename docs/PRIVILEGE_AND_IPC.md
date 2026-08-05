# Privilege and IPC Design

## Authorization

The GUI constructs a fixed, safely single-quoted command for the embedded helper and launches it through `NSAppleScript` using `do shell script ... with administrator privileges`.

Administrator authorization is requested only after:

1. Session configuration was retrieved without claiming.
2. The helper exists in the bundle.
3. A private report workspace was created.
4. Local capacity preflight succeeded.
5. The local IPC listener was created.

The helper performs root/workspace/socket validation and sends `ready`. The GUI does not claim the session until that `ready` message is received.

Cancelling the password prompt, failing to launch the helper, failing workspace validation, or failing socket peer validation therefore leaves the session code unconsumed.

## No persistent helper

The helper is not installed or registered. No `SMJobBless`, LaunchDaemon, LaunchAgent, login item, package, or installer is used. The process is started once, scans, returns report ownership, and exits.

## Socket protection

For each run the GUI creates:

- A random run ID.
- A long random nonce assembled from two independently generated UUID values.
- A random private directory under `/private/tmp` with mode `0700`.
- A Unix-domain socket with mode `0600`.
- A report workspace with mode `0700` owned by the GUI user.

Both sides use `getpeereid`:

- GUI requires the socket peer UID to be root.
- Helper requires the socket peer UID to match the caller UID passed at launch.

The first helper message must contain the expected run ID, protocol version, and nonce. Later messages with a different run ID or protocol version are rejected.

## Message format

Messages are UTF-8 JSON, one object per line:

```json
{
  "protocolVersion": 1,
  "runID": "B173...",
  "sequence": 12,
  "type": "progress",
  "message": "Running memory pattern test",
  "test": "Application-level memory pattern test",
  "completed": 7,
  "total": 22,
  "percent": 31
}
```

Supported message types include:

```text
hello
privilegedPreflight
ready
begin
status
progress
result
warning
log
reportPaths
heartbeat
cancel
cancelled
fatalError
complete
```

## Claim-token boundary

The claim token remains only in the GUI process. The root helper receives only:

- Scan type and display name.
- Customer and technician labels used in local reports.
- Numeric workload limits.

It does not receive server credentials or endpoints.

## Cancellation and watchdog

The GUI sends a heartbeat every five seconds. If the helper has not received a heartbeat for 35 seconds, it cancels itself. Closing the socket also triggers cancellation.

Cancellation or timeout sends termination to the active child process, waits briefly, and then uses `SIGKILL` if needed. Application-level tests check cancellation inside their work loops. Apple collectors used by the first release are direct executable invocations rather than arbitrary shell pipelines.

## Threat limitations

This design protects against accidental cross-user connection and stale/mismatched helper sessions. It is not an App Sandbox design and does not attempt to defend against a fully compromised root account or malicious code already running as the same user before authorization.
