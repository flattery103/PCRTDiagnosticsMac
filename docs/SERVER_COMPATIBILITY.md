# PCRT Server 0.1.4 Compatibility

The macOS client uses the existing API and does not require a server or database change.

## Endpoints

```text
GET  /api/v1/sessions/{code}
POST /api/v1/sessions/{code}/claim
POST /api/v1/sessions/{code}/status
POST /api/v1/sessions/{code}/reports
```

## Claim behavior

- Configuration retrieval happens before authorization and does not claim the code.
- The helper must report privileged-preflight readiness before claim.
- The GUI generates one `client_id` for the run.
- A retry reuses that same ID, preserving Server 0.1.4 same-client idempotency.
- The returned `claim_token` remains in the GUI and is sent in `X-PCRT-Claim-Token` for status and report requests.

## Configuration mapping

Server presets include Windows-oriented test keys. The macOS client does not execute those names. It uses:

- `scan_type`
- `display_name`
- `upload_reports`
- supported numeric limits and overrides

The shared scan type is mapped to a macOS-specific scan plan.

## Report upload acknowledgement

Server 0.1.4 sets `acknowledged` true when at least one file was accepted. The client therefore requires both:

- `acknowledged == true`
- The returned `uploaded` list contains all four exact names:
  - `system-info.html`
  - `test-results.html`
  - `raw-data.json`
  - `run-log.txt`

The app remains open when any acknowledgement is missing.

## API-token option

Server 0.1.4 can optionally require a static `X-PCRT-Token`. The macOS app intentionally does not embed a long-lived shared API secret. Production deployment must keep the public client API compatible with the current Windows/Linux client model or define a separate secure provisioning design before enabling that gate for desktop clients.

## Download hosting

The current server upload/download administration is Windows-EXE specific. The macOS ZIP is distributed through GitHub Actions artifacts and GitHub Releases in 0.1.0. Adding a separate macOS download to the website can be handled later without changing the diagnostic API.
