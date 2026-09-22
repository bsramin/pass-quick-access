# Releasing

Releases are signed with a Developer ID certificate and notarized by Apple, so
the download opens without a Gatekeeper prompt. All of it happens in the
`Release` workflow when a GitHub Release is published; the one-time credential
setup is at the bottom of this file.

Release tags use the format `vYYYY-MM-DD.X`, where `X` counts the releases made
that day starting at 1 (for example `v2026-06-11.1`). The app's
`MARKETING_VERSION` is a separate numeric version, since the tag's dashes aren't
valid in `CFBundleShortVersionString`.

## Cutting a release

1. Bump `MARKETING_VERSION` in `project.yml` if you want a new app version, and
   move the entries under `## [Unreleased]` in `CHANGELOG.md` into a section
   headed by the new tag.
2. Commit and push.
3. On GitHub, draft a new Release. Create a tag for it with today's date and the
   next sequence number (for example `v2026-06-11.1`), target `main`, and paste
   the changelog entries as the notes. Publishing it creates the tag.

Publishing the Release triggers the `Release` workflow, which signs and notarizes
the build, attaches `PassQuickAccess.zip` to that same Release, signs it with the
Sparkle EdDSA key, and publishes the new version to `docs/appcast.xml` (served by
GitHub Pages). The release notes you wrote become the changelog the app shows.

The job refuses to run if the signing or notarization secrets are missing, rather
than quietly publishing an ad-hoc build that every user would have to right-click
past.

## Dry run

The same workflow can be started by hand from the Actions tab (*Run workflow*).
It builds, signs and notarizes exactly as a real release does, but skips the two
steps that publish: nothing is attached to a release and nothing is pushed to
`main`. The Sparkle signing step still runs, so a dry run exercises every secret.

This is the only way to find out whether the credentials work without cutting a
release and watching it fail, so run it after changing any of them, and after
touching the workflow or the build script.

## Building locally

`scripts/build-release.sh` does the whole artifact: build, signature check, zip,
notarize, staple, re-zip, and a final Gatekeeper assessment. It is the same
script CI runs, so a local build is the real thing rather than an approximation.

```sh
./scripts/build-release.sh
```

With nothing configured that builds ad-hoc and warns that the result is not
distributable, which is fine for testing a Release build. To produce a signed,
notarized zip:

```sh
export PQA_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export PQA_TEAM_ID="TEAMID"
export NOTARY_KEYCHAIN_PROFILE="NOTARY"
./scripts/build-release.sh
```

`security find-identity -v -p codesigning` prints the identity string to use. The
notarization profile is created once with:

```sh
xcrun notarytool store-credentials NOTARY \
    --key ~/private_keys/AuthKey_XXXXXXXXXX.p8 \
    --key-id XXXXXXXXXX --issuer 00000000-0000-0000-0000-000000000000
```

Either way it writes `dist/PassQuickAccess.zip`.

## Signing and notarization (one-time setup)

### 1. Developer ID Application certificate

In Xcode, *Settings → Accounts → Manage Certificates → + → Developer ID
Application*, or create it in the Apple Developer portal under *Certificates,
Identifiers & Profiles*. Note that Apple allows a limited number of Developer ID
certificates per account and they cannot be revoked casually, so keep the export
below somewhere safe: losing it means asking Apple to reset.

Export it from Keychain Access (the certificate together with its private key) as
a `.p12` with a strong password, then load both into the repository:

```sh
base64 -i DeveloperID.p12 | gh secret set MACOS_CERTIFICATE_P12
gh secret set MACOS_CERTIFICATE_PASSWORD
gh secret set MACOS_SIGN_IDENTITY   # "Developer ID Application: Your Name (TEAMID)"
gh secret set APPLE_TEAM_ID         # TEAMID
```

Delete the `.p12` from disk afterwards, or move it into your password manager.

### 2. App Store Connect API key for notarization

An API key is preferred over an app-specific password: it is scoped to a role, it
can be revoked on its own without touching the Apple ID, and it never exposes
account credentials to CI. In App Store Connect, *Users and Access → Integrations
→ App Store Connect API*, create a key with the **Developer** role. The `.p8`
downloads once and cannot be downloaded again.

```sh
gh secret set APPLE_API_KEY_P8 < AuthKey_XXXXXXXXXX.p8
gh secret set APPLE_API_KEY_ID      # the key ID, e.g. XXXXXXXXXX
gh secret set APPLE_API_ISSUER_ID   # the issuer UUID shown above the key list
```

### 3. What the workflow does with them

The certificate is imported into a keychain created for the job and deleted when
it ends, and the `.p8` is written outside the workspace and removed on the way
out. Neither is ever placed in the built artifact. The workflow only runs on a
published release, never from a pull request, so a fork cannot reach the secrets.

## Sparkle update signing (one-time setup)

The app updates itself through [Sparkle](https://sparkle-project.org), and every
update is verified against an EdDSA key, independently of Apple's notarization.
Set this up once:

1. Generate the key pair with Sparkle's tool (it stores the private key in your
   login Keychain and prints the public key):

   ```sh
   ./bin/generate_keys
   ```

2. Put the printed public key in `Sources/PassQuickAccess/App/Info.plist` as
   `SUPublicEDKey`, replacing the placeholder. Commit it.
3. Export the private key and add it to the repository as the
   `SPARKLE_ED_PRIVATE_KEY` Actions secret, so the release job can sign:

   ```sh
   ./bin/generate_keys -x sparkle_private_key.txt
   gh secret set SPARKLE_ED_PRIVATE_KEY < sparkle_private_key.txt
   rm sparkle_private_key.txt
   ```

The `generate_keys` and `sign_update` tools ship in the Sparkle distribution
tarball (`bin/`). The feed URL the app checks is `SUFeedURL` in the Info.plist;
the app probes it at launch and every two hours, and only ever installs after the
user picks "Update Now" (see [SECURITY.md](SECURITY.md)).

`CFBundleVersion` is set by the release job from the tag (for example
`v2026-06-19.1` → `20260619.1`), so it always climbs and Sparkle treats each
release as an upgrade. `MARKETING_VERSION` is still the human version you bump in
`project.yml`.

## Provisioning profiles (one-time setup)

Most of the app's entitlements are free for the taking: you write them in a file
and sign. The AutoFill credential provider is not. Apple allowlists
`com.apple.developer.authentication-services.autofill-credential-provider` per
App ID, and a build only gets it by embedding a provisioning profile that grants
it. The app and the extension are separate code identities, so they need one
each.

In *Certificates, Identifiers & Profiles*:

1. Register an App Group. `Y3T76BW4DZ.pqa` is what the entitlements name; the
   portal wants a `group.`-prefixed identifier of its own, and a Developer ID
   profile ends up granting the whole `TEAMID.*` range anyway.
2. Register two explicit App IDs, `it.ramin.PassQuickAccess` and
   `it.ramin.PassQuickAccess.AutoFill`, each with **AutoFill Credential
   Provider** and **App Groups** enabled.
3. Create a **Developer ID** profile for each, bound to the Developer ID
   Application certificate. Despite what older forum threads say, the capability
   is available for Developer ID profiles: this app ships with two.

Check what you got before building, because a profile missing the entitlement
fails in the least obvious way possible, which is a provider macOS silently
never offers:

```sh
security cms -D -i PQA_Developer_ID.provisionprofile \
  | plutil -extract Entitlements xml1 -o - -
```

Install both under `~/Library/Developer/Xcode/UserData/Provisioning Profiles`
and name them to the build by UUID or by profile name:

```sh
export PQA_APP_PROFILE="d8cdd90e-…" PQA_AUTOFILL_PROFILE="573c29a0-…"
```

For CI, load them as secrets; the job installs them and derives each UUID from
the profile itself, so regenerating one means replacing one secret and nothing
else:

```sh
base64 -i PQA_Developer_ID.provisionprofile | gh secret set MACOS_PROVISIONING_PROFILE_APP
base64 -i PQA_AutoFill_Developer_ID.provisionprofile | gh secret set MACOS_PROVISIONING_PROFILE_AUTOFILL
```

`build-release.sh` asserts after signing that both bundles carry a profile and
the entitlement, so a mistake here fails locally in seconds rather than after a
release.

### Building this fork under your own account

Nothing here is secret: a Team ID appears in every signed binary. But it is
*specific*, so a fork that wants a working AutoFill extension has to substitute
its own. Three places name `Y3T76BW4DZ` or `it.ramin.…`:

- `project.yml` — `bundleIdPrefix` and the two `PRODUCT_BUNDLE_IDENTIFIER`s.
- `Sources/PassQuickAccess/App/PassQuickAccess-Distribution.entitlements`
- `Sources/PassQuickAccessAutoFill/PassQuickAccessAutoFill-Distribution.entitlements`

They are written out rather than composed from `$(AppIdentifierPrefix)` and
friends because Xcode does not expand build-setting variables in an entitlements
file under manual signing: the placeholders survive into the signature verbatim,
and the result is a build that signs, notarizes and then refuses to launch the
extension.

Only the `-Distribution` files carry any of this. Building from source without a
Developer ID identity uses the plain entitlements, which name no team and claim
no provisioned capability, so a contributor needs none of the above — they just
get an app whose AutoFill extension the system will not offer.

## Entitlements

There are two entitlement files per target, and which one is used follows the
signing mode. For the app:

- `PassQuickAccess-Distribution.entitlements` for a Developer ID build, selected
  by `build-release.sh` when `PQA_SIGN_IDENTITY` is set.
- `PassQuickAccess.entitlements` everywhere else (development, ad-hoc), which
  additionally disables library validation.

The AutoFill extension has the same pair under
`Sources/PassQuickAccessAutoFill/`, differing the other way round: its
`-Distribution` file adds the provisioned entitlements, and its plain one claims
only the sandbox. That asymmetry is deliberate. An ad-hoc or Development
signature cannot be granted a provisioned entitlement, and an extension that
claims one anyway is not offered-but-limited, it is killed at launch by AMFI.

The switch is the `PQA_ENTITLEMENTS_SUFFIX` variable, interpolated into
`CODE_SIGN_ENTITLEMENTS` on each target in `project.yml`. Overriding the path
itself on the `xcodebuild` command line does not work: a command-line setting
applies to every target, so the SPM packages inherit it and fail the build
looking for the file inside their own checkout. `PROVISIONING_PROFILE_SPECIFIER`
is fed through `PQA_APP_PROFILE` and `PQA_AUTOFILL_PROFILE` for the same reason.

The exemption exists because Xcode re-signs the embedded Sparkle.framework with
the app's own identity: under a Developer ID both carry the same team and library
validation passes, while an ad-hoc signature has no team for anything to match
and the app would crash at launch. A shipped build therefore keeps the hardened
runtime intact.

## Upgrading from an ad-hoc build

Releases up to and including `v2026-06-30.1` were ad-hoc signed, so the first
signed release is the one update where the app's code signing identity changes
underneath an existing install. The EdDSA key is unchanged, but Sparkle also
compares the incoming build's signature against the running app's, and how it
treats ad-hoc as the starting point is not obvious from the outside.

This was tested before the first signed release, against a local appcast signed
with the real EdDSA key: an ad-hoc build updated itself to a Developer ID signed
one and came back with the new team identifier. **Sparkle accepts the
transition**, so existing installs update themselves with nothing to announce.

Worth redoing if the signing identity ever changes again, since it is the same
question in a new form. The harness is three parts: an ad-hoc build whose
`SUFeedURL` is repointed at a local server (which breaks its seal, so re-sign the
bundle ad-hoc afterwards), a Developer ID build with a much higher
`CFBundleVersion`, and an appcast signed with `sign_update`. Note that a build
that is signed but not notarized can still be refused at relaunch by Gatekeeper,
which looks like a Sparkle failure and is not one.

Anyone still holding an old ad-hoc build can also just download the new one.
Those older builds are quarantined until opened once with right-click → *Open*,
or cleared with:

```sh
xattr -dr com.apple.quarantine /Applications/PassQuickAccess.app
```
