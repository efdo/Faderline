# Releasing Faderline

This document describes how to cut a signed, notarized release build of
Faderline as a `.pkg` installer. The heavy lifting is automated by
[`.github/workflows/release.yml`](../.github/workflows/release.yml), which
runs whenever a GitHub Release is published (or via manual dispatch for an
existing tag).

## One-time setup: repository secrets

The workflow needs a **Developer ID Application** certificate (to sign
`Faderline.app`) and a **Developer ID Installer** certificate (to sign the
`.pkg`), plus credentials for Apple's notarization service. All of these come
from an active Apple Developer Program membership.

### 1. Export your Developer ID certificates as `.p12` files

In Xcode: **Settings → Accounts → [your Apple ID] → Manage Certificates →
+ → Developer ID Application** (and again for **Developer ID Installer**).
Then in **Keychain Access**, find each certificate, right-click → **Export**,
and save as `.p12` with a password.

If you don't already have these certificate types, you can request them
directly at <https://developer.apple.com/account/resources/certificates/list>
(requires a paid Apple Developer Program membership, since Developer ID
certificates are not available on the free tier).

### 2. Base64-encode the certificates

```bash
base64 -i DeveloperIDApplication.p12 | pbcopy   # paste into DEVELOPER_ID_APPLICATION_P12
base64 -i DeveloperIDInstaller.p12   | pbcopy   # paste into DEVELOPER_ID_INSTALLER_P12
```

### 3. Create an app-specific password for notarization

Generate one at <https://account.apple.com/account/manage> under
**Sign-In and Security → App-Specific Passwords**. This is **not** your Apple
ID password.

### 4. Add the following repository secrets

Go to **Settings → Secrets and variables → Actions** in the GitHub repo and
add:

| Secret | Value |
|---|---|
| `DEVELOPER_ID_APPLICATION_P12` | Base64 of the Developer ID Application `.p12` |
| `DEVELOPER_ID_APPLICATION_PASSWORD` | Password used when exporting that `.p12` |
| `DEVELOPER_ID_INSTALLER_P12` | Base64 of the Developer ID Installer `.p12` |
| `DEVELOPER_ID_INSTALLER_PASSWORD` | Password used when exporting that `.p12` |
| `KEYCHAIN_PASSWORD` | Any random string — used only to protect the temporary CI keychain |
| `APPLE_TEAM_ID` | Your 10-character Apple Developer Team ID |
| `APPLE_ID` | The Apple ID email used for notarization |
| `APPLE_APP_SPECIFIC_PASSWORD` | The app-specific password from step 3 |

## Cutting a release

1. Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION` if you track
   build numbers) in the Xcode project settings, commit, and merge to `main`.
2. Create and publish a GitHub Release with a tag like `v1.1.0` (the workflow
   strips the leading `v` to derive the `.pkg` version).
3. Publishing the release triggers `.github/workflows/release.yml`, which:
   - archives `Faderline.app` in Release configuration, signed with your
     Developer ID Application identity;
   - exports it via `xcodebuild -exportArchive` (method `developer-id`);
   - packages it into `Faderline-<version>.pkg` with `pkgbuild`, signed with
     your Developer ID Installer identity;
   - submits the `.pkg` to Apple notarization (`xcrun notarytool`) and waits
     for approval;
   - staples the notarization ticket (`xcrun stapler staple`) so the
     installer works offline/Gatekeeper-verified with no network call;
   - uploads the `.pkg` as a workflow artifact and attaches it to the GitHub
     Release.
4. Once the workflow succeeds, the signed `.pkg` is downloadable from the
   Release page — users can install it with no Gatekeeper warnings.

### Re-running for an already-published release

Use **Actions → Release → Run workflow** and supply the existing tag name in
the `tag` input. This re-runs the whole build/sign/notarize/upload pipeline
and re-attaches (`--clobber`) the asset to that release.

## Troubleshooting

- **`No signing certificate "Developer ID Application" found`** — the `.p12`
  secrets are missing/incorrect, or the certificate has expired. Re-export
  and re-encode it.
- **`errors from notarytool`** — check the log ID it prints and run
  `xcrun notarytool log <id> --apple-id ... --team-id ... --password ...`
  locally for the detailed rejection reason (commonly: hardened runtime not
  enabled, or an unsigned nested binary).
- **`gh release upload` fails with 404** — the `tag` input (manual dispatch)
  doesn't match an existing release; create the release first or check the
  tag name.
