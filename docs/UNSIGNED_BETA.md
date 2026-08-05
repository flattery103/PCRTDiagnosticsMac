# Opening an Unsigned Beta Build

Unsigned beta builds are intended only for trusted testers who obtained the ZIP from the PCRT Diagnostics project workflow or release page.

## First opening

1. Extract `PCRTDiagnosticsMac-0.1.1.zip`.
2. Move `PCRT Diagnostics.app` to a normal writable location such as `/Applications` or the Desktop.
3. Control-click or right-click `PCRT Diagnostics.app`.
4. Choose **Open**.
5. Review the macOS warning and choose **Open** again.

## If macOS does not show the Open option

1. Attempt to open the app once normally.
2. Open **System Settings**.
3. Choose **Privacy & Security**.
4. Find the message that `PCRT Diagnostics` was blocked.
5. Choose **Open Anyway**.
6. Confirm that you want to open the trusted beta.

Do not disable Gatekeeper globally.

## Administrator prompt

The app should not ask for administrator authorization merely by opening. The prompt appears only after a valid five-character session code is entered, Start is clicked, server configuration is retrieved, and unprivileged preflight succeeds.

The authorization dialog is used to run the bundled helper for the current scan. It does not install a daemon or permanent helper.

## Verify the ZIP checksum

From Terminal in the download folder:

```bash
shasum -a 256 PCRTDiagnosticsMac-0.1.1.zip
cat PCRTDiagnosticsMac-0.1.1.zip.sha256
```

The values should match exactly.
