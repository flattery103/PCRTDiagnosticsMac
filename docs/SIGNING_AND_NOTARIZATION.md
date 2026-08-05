# Future Developer ID Signing and Notarization

Unsigned builds work without Apple credentials. Signing and notarization are conditional and are not required for source, pull-request, or internal beta builds.

## GitHub secrets

Configure all of the following repository or environment secrets to enable the signing step:

```text
APPLE_DEVELOPER_ID_P12_BASE64
APPLE_CERTIFICATE_PASSWORD
APPLE_TEAM_ID
APPLE_NOTARY_KEY_ID
APPLE_NOTARY_ISSUER_ID
APPLE_NOTARY_PRIVATE_KEY_BASE64
```

The P12 must contain a valid **Developer ID Application** certificate and private key. The notarization key must be an App Store Connect API private key authorized for notarization.

## Workflow order

The workflow:

1. Creates a temporary keychain.
2. Imports the P12.
3. Finds the Developer ID Application identity.
4. Writes the API private key to a temporary file.
5. Signs `PCRTScannerHelper` first.
6. Signs the enclosing app with hardened runtime and timestamp.
7. Verifies the nested and outer signatures.
8. Creates a temporary ZIP for notarization.
9. Submits it with `xcrun notarytool ... --wait`.
10. Staples the accepted ticket to the application.
11. Re-verifies the app.
12. Creates the final distribution ZIP.
13. Deletes the temporary keychain and key files.

## Local signing

After an unsigned Release build:

```bash
export PCRT_SIGNING_IDENTITY='Developer ID Application: Company Name (TEAMID)'
export PCRT_TEAM_ID='TEAMID'
export PCRT_NOTARY_KEY_PATH="$HOME/private/AuthKey_ABC123.p8"
export PCRT_NOTARY_KEY_ID='ABC123'
export PCRT_NOTARY_ISSUER_ID='00000000-0000-0000-0000-000000000000'

./Scripts/sign-and-notarize.sh \
  "build/DerivedData/Build/Products/Release/PCRT Diagnostics.app"
```

## Entitlements

The first release uses no App Sandbox entitlement and no permanent privileged-helper entitlement. Hardened runtime is enabled only for the signed distribution step. Add entitlements only when a specific tested capability requires them; do not add broad exceptions merely to silence a signing problem.

## Verification commands

```bash
codesign --verify --deep --strict --verbose=2 "PCRT Diagnostics.app"
spctl --assess --type execute --verbose=4 "PCRT Diagnostics.app"
xcrun stapler validate "PCRT Diagnostics.app"
```
