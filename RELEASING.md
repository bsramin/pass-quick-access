# Releasing

The recommended way to install the app is to build it from source (see the
README). A pre-built binary can be attached to a GitHub Release, but without an
Apple Developer ID certificate it is ad-hoc signed and not notarized, so it has
to be allowed through Gatekeeper by hand.

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

Publishing the Release triggers the `Release` workflow, which builds the
artifact, attaches `PassQuickAccess.zip` to that same Release, signs it with the
Sparkle EdDSA key, and publishes the new version to `docs/appcast.xml` (served by
GitHub Pages). The release notes you wrote become the changelog the app shows.
To build the zip locally instead:

```sh
./scripts/build-release.sh
```

This writes `dist/PassQuickAccess.zip`.

## Sparkle update signing (one-time setup)

The app updates itself through [Sparkle](https://sparkle-project.org), and every
update is verified against an EdDSA key. Set this up once:

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

## Installing an ad-hoc build

A downloaded ad-hoc app is quarantined. The user opens it once with right-click
to "Open", or clears the quarantine attribute:

```sh
xattr -dr com.apple.quarantine /Applications/PassQuickAccess.app
```

## Notarized releases

Once an Apple Developer ID Application certificate is available, sign the Release
build with it (set it in `Config/Local.xcconfig`), enable the hardened runtime,
then notarize and staple:

```sh
xcrun notarytool submit dist/PassQuickAccess.zip --keychain-profile NOTARY --wait
xcrun stapler staple dist/dd/Build/Products/Release/PassQuickAccess.app
```

A notarized, stapled build opens without the Gatekeeper prompt.
