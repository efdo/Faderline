# App-only releases

The repository is named AudioMixer; the current app is **Faderline.app**.
Release packaging preserves that name and the `com.faderline.app` bundle
identifier. It builds only the mixer app: no virtual microphone driver is
built, packaged, embedded, installed, updated, or removed. There is no
installer, driver lifecycle change, automatic updater, or Sparkle integration.

## Requirements

- **macOS 15.0 (Sequoia) or later and Apple Silicon (arm64)**. These packages
  do not support Intel Macs or earlier macOS versions.
- Microphone permission is requested by the app on first launch.
- Building requires full Xcode with the macOS SDK and Swift 6 tooling,
  not just Command Line Tools. Select that Xcode installation as the active
  developer directory, or set `DEVELOPER_DIR` for the command.
- Packaging uses macOS's built-in `xcodebuild`, `ditto`, `codesign`, `hdiutil`,
  and `shasum`; no system-wide packaging tools need to be installed.

## Local unsigned development packaging

From the repository root:

```bash
bash scripts/package-app.sh --version 1.2.3 --build-number 42 --unsigned-development
```

The script builds the shared Faderline Xcode scheme in **Release**, explicitly
targeting arm64/macOS 15.0, then produces:

```text
dist/Faderline-1.2.3-arm64-unsigned-development/
  Faderline.app
  Faderline-1.2.3-arm64-unsigned-development.dmg
  Faderline-1.2.3-arm64-unsigned-development.sha256
```

The compressed, read-only DMG contains `Faderline.app`, an `Applications`
shortcut pointing to `/Applications`, and installation/signing information
in `README.txt`. Packaging verifies bundle metadata, architecture, signatures,
the image integrity, and the mounted app/shortcut before returning success.
It does not install or launch the app. Build scratch data is removed on exit.
`dist/`, disk images, archives, and `.build/` are ignored by Git.

Use `--output /path/to/artifacts` to change the output parent directory.
Existing version/mode directories are **not overwritten**; use another output
directory for a repeat build. Run `bash scripts/package-app.sh --help` for options.
With the same source, version, build number and Xcode/SDK, this repeats the
same build/packaging procedure. DMG filesystem metadata and signing/notarization
timestamps mean artifacts are **not guaranteed byte-for-byte identical**;
checksums describe the actual final downloadable DMG.

**Unsigned development artifacts are not public-distribution builds.**
Apple Silicon requires executable signatures, so the script applies an
**ad-hoc** signature, not a Developer ID certificate. These artifacts are not
notarized and Gatekeeper may refuse to open a downloaded copy. Checksums prove
file integrity, not publisher identity or Gatekeeper approval. Only use these
builds for trusted development; do not disable Gatekeeper system-wide.

## Versioning

Use numeric **`vMAJOR.MINOR.PATCH`** release tags, for example `v1.2.3`.
The local command takes `1.2.3`, **without** the `v` prefix. Suffixes such as
`-beta.1` are not accepted; use GitHub's prerelease flag for development releases.

Packaging sets `CFBundleShortVersionString` from that version and
`CFBundleVersion` from the positive integer `--build-number` (default `1`).
CI uses `GITHUB_RUN_NUMBER`, which remains the same on a workflow rerun.
These are build-setting overrides; no source edits are needed for each release.
Ordinary Xcode builds still use the project's `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION` defaults.

## Publishing from GitHub Releases

As requested, [the release workflow](../.github/workflows/release.yml) runs
when a **GitHub Release is published**, not when a tag is pushed alone.
Nothing is published by the local packaging command.

1. Merge the intended app code and this workflow into the default branch.
2. In GitHub, open **Releases → Draft a new release**. Choose an existing
   `vX.Y.Z` tag or create one targeting the intended app commit. That commit
   must contain the packaging script and workflow.
3. Add release notes and publish. For unsigned builds, mark it as a
   **prerelease** and identify it as unsigned development.
4. Actions builds on `macos-15`, runs the SPM and standalone tests, invokes
   the same packaging script (including its Xcode Release build and DMG
   inspection), and attaches the `.dmg` and `.sha256` under the release's
   **Assets**. It also retains those two files as workflow artifacts.

The release is visible while Actions runs; assets appear only after successful
packaging. Check the Actions run if they are missing. Publishing a draft
triggers packaging; saving a draft or pushing a tag without a published
release does not. The workflow token needs permission to write release assets;
no personal access token is required.

The repository variable **`RELEASE_SIGNING_MODE`** controls the mode:

| Value | Behavior |
|---|---|
| Unset or `unsigned-development` | Clearly labeled, ad-hoc-signed development DMG. The workflow marks the release as a prerelease, appends `(unsigned development)` to its title, and adds an explicit unsigned/not-notarized warning while preserving release notes. |
| `developer-id` | Requires all credentials below. Signs, notarizes, staples, and verifies the app and DMG. Any failure stops the job; there is **no unsigned fallback**. |

Choose the signing mode **before** publishing. Do not mix modes on the same
release/tag; use a new version for a subsequent signed public release.
To retry a failed run, use **Actions → Release app DMG → Run workflow** and
provide the existing published release tag. The selected workflow ref should
contain this workflow, and the tag must contain the packaging script.
Retries replace same-named assets (`--clobber`); they do not create a release
or push a tag. The workflow serializes runs for the same tag.

## Developer ID signing and notarization for public distribution

Public distribution requires an active Apple Developer Program membership,
a valid **Developer ID Application** certificate **and its private key**,
hardened runtime, secure timestamps, and acceptance by Apple's notarization
service. A Developer ID Installer certificate is **not needed** for this
app-only DMG flow. The former `.pkg` pipeline has been replaced.

For local signed packaging, import your certificate into your own keychain
using Apple's tooling. Store notarization credentials in a keychain profile:

```bash
xcrun notarytool store-credentials faderline-notary \
  --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
# Supply an app-specific password at the prompt; do not commit credentials.

bash scripts/package-app.sh --version 1.2.3 --build-number 42 \
  --developer-id "Developer ID Application: Your Name (YOUR_TEAM_ID)" \
  --notary-profile faderline-notary
```

The script first checks the identity/profile, builds the app, signs with
hardened runtime and a secure timestamp, submits an app ZIP to Apple,
requires `Accepted`, and staples/validates the app ticket. It then creates
and signs the DMG, notarizes it, staples/validates its ticket, and performs
Gatekeeper assessments. The copied app retains its ticket for offline
verification after installation. Successful output uses
`Faderline-1.2.3-arm64-developer-id-notarized` in the directory/asset names.
No credentials means this verification path is **blocked**, not implicitly
successful. Apple submissions send the app/DMG to Apple's service.

For CI, set `RELEASE_SIGNING_MODE=developer-id` under repository
**Settings → Secrets and variables → Actions → Variables**, and configure:

| Repository secret | Value |
|---|---|
| `DEVELOPER_ID_APPLICATION_P12` | Base64 of the certificate/private-key `.p12` export (`base64 -i DeveloperIDApplication.p12`) |
| `DEVELOPER_ID_APPLICATION_PASSWORD` | Export password for that `.p12` |
| `DEVELOPER_ID_APPLICATION_IDENTITY` | Exact signing identity, e.g. `Developer ID Application: Your Name (TEAMID)` |
| `KEYCHAIN_PASSWORD` | Random password protecting the temporary runner keychain |
| `APPLE_TEAM_ID` | Apple Developer Team ID owning the certificate |
| `APPLE_ID` | Apple ID authorized for notarization |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for that Apple ID |

The runner imports only the application certificate into a temporary keychain,
stores the notary profile there, and removes the keychain/export even after
failure. Never commit certificates, private keys, or passwords.
Existing `DEVELOPER_ID_INSTALLER_*` secrets are unused by this workflow.

If signing fails, check the identity, private key, certificate validity, and
secrets. If notarization is rejected, use the submission ID printed by the
script with `xcrun notarytool log ID --keychain-profile PROFILE` to inspect
Apple's rejection log. Common causes include unsigned nested code or missing
hardened runtime. Do not relabel an unsigned artifact as signed to bypass a
failed release.

## Installation and manual updates

Download the `.dmg` and matching `.sha256` from the same release. In their
download directory, verify integrity:

```bash
shasum -a 256 -c Faderline-1.2.3-arm64-unsigned-development.sha256
```

For a signed public release, use its `developer-id-notarized.sha256` filename.
Open the DMG and drag **Faderline.app** onto the **Applications** shortcut.
Eject the DMG and launch the app from Applications, granting microphone
permission when prompted.

To update, first choose **Faderline → Quit** or press **Command-Q**, and wait
for the app to exit cleanly. Then drag the new app to Applications and confirm
replacement of the old app. **Do not replace a running app or force-kill it**:
clean shutdown stops/disposes its CoreAudio units. Existing mix preferences
remain associated with the unchanged bundle identifier. Relaunch from
Applications after replacing it.

Updates are manual; nothing updates or removes a separately installed virtual
microphone driver, and this flow does not change audio routing or device setup.
