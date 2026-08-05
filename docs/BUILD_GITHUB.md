# GitHub Actions Build and Release

Workflow file:

```text
.github/workflows/build-release.yml
```

## Build triggers

- Pull requests.
- Pushes to `main`.
- Manual `workflow_dispatch` runs.
- Version tags matching `v*`.

## Build behavior

The workflow:

1. Uses a GitHub-hosted `macos-15` runner rather than `macos-latest`.
2. Selects Xcode 16.x and fails clearly if it is not present, preserving the macOS 11 deployment target.
3. Prints macOS, architecture, Xcode, and Swift versions into the log.
4. Runs the `PCRTCore` Swift package tests.
5. Runs the Xcode unit-test target.
6. Builds a Release application with ARM64 and x86_64 slices.
7. Verifies the app and helper contain both architectures.
8. Optionally signs and notarizes when every required secret is configured.
9. Creates `PCRTDiagnosticsMac-<version>.zip` and a SHA-256 file.
10. Uploads both as workflow artifacts.
11. Attaches them to a GitHub Release when a version tag is pushed.

## Unsigned build

No secrets are required. When the signing secret set is incomplete, the workflow explicitly creates an unsigned beta ZIP.

## Release tag

After a successful normal workflow run, create a tag matching the project version:

```bash
git tag v0.1.3
git push origin v0.1.3
```

The tag workflow validates that the tag version matches `PCRTProduct.version` before attaching the ZIP to the release.

## Artifact name

```text
PCRTDiagnosticsMac-0.1.3
```

The contained files are:

```text
PCRTDiagnosticsMac-0.1.3.zip
PCRTDiagnosticsMac-0.1.3.zip.sha256
```

## Xcode image maintenance

Do not replace `macos-15` with `macos-latest` without checking the minimum deployment target. If GitHub later removes Xcode 16 from the image, either move to another image that still includes an Xcode version capable of targeting macOS 11 or make a deliberate support-policy decision before raising the deployment target.
