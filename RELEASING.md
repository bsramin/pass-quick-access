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
artifact and attaches `PassQuickAccess.zip` to that same Release. To build the
zip locally instead:

```sh
./scripts/build-release.sh
```

This writes `dist/PassQuickAccess.zip`.

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
