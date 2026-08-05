# Opening an Unsigned Portable Beta Build

Unsigned beta builds are intended for users who obtained the ZIP from the official PCRT Diagnostics download location, GitHub workflow, or GitHub release.

The app is portable. It does not need to be installed or moved into `/Applications`, and Terminal is not required to start it.

## First opening

1. Download `PCRTDiagnosticsMac-0.1.2.zip`.
2. Double-click the ZIP if macOS does not extract it automatically.
3. Leave `PCRT Diagnostics.app` in Downloads, Desktop, a technician tools folder, or external media.
4. Control-click or right-click `PCRT Diagnostics.app` and choose **Open**.
5. Review the macOS warning and choose **Open** again when offered.

After macOS approves the app once, future launches normally use the standard double-click workflow.

## When macOS blocks the app without an Open button

1. Double-click the app once so macOS records the blocked launch.
2. Open **System Settings**.
3. Choose **Privacy & Security**.
4. Find the message that `PCRT Diagnostics` was blocked.
5. Choose **Open Anyway**.
6. Confirm **Open**.

Do not disable Gatekeeper globally.

## Running a diagnostic

1. Enter the five-character session code.
2. Click **Start**.
3. Approve the normal administrator authorization dialog.
4. Leave the application running until it reports completion and closes after all four reports are acknowledged by the server.

No additional hardware-test interaction is required after the authorization dialog. The temporary privileged helper is not installed and exits with the scan.

## Optional checksum verification for technicians

Checksum verification is optional and is not required for normal users. A technician may verify the download from Terminal:

```bash
shasum -a 256 PCRTDiagnosticsMac-0.1.2.zip
cat PCRTDiagnosticsMac-0.1.2.zip.sha256
```

The values should match exactly.
