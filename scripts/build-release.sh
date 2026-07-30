#!/usr/bin/env bash
#
# Build a Release .app, sign it, notarize it, and zip it into dist/.
#
# With no identity configured the build is ad-hoc signed and not notarized,
# which is enough to build from source but leaves the download behind a
# Gatekeeper prompt. Set the variables below to produce the artifact we actually
# ship. The release workflow sets all of them; see RELEASING.md.
#
#   PQA_SIGN_IDENTITY   Developer ID identity to sign with, e.g.
#                       "Developer ID Application: Jane Doe (ABCDE12345)"
#   PQA_TEAM_ID         the team that identity belongs to
#
# Notarization is attempted only for a signed build, with either a profile saved
# by `notarytool store-credentials`:
#
#   NOTARY_KEYCHAIN_PROFILE
#
# or an App Store Connect API key:
#
#   NOTARY_KEY_PATH / NOTARY_KEY_ID / NOTARY_ISSUER_ID
#
#   PQA_BUILD_VERSION   CFBundleVersion, passed by the release workflow

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

app="dist/dd/Build/Products/Release/PassQuickAccess.app"
zip="dist/PassQuickAccess.zip"

xcodegen generate

build_settings=()

# The CI release job passes the tag's build number so Sparkle sees a version
# that climbs with every release; a local build keeps the project's default.
if [[ -n "${PQA_BUILD_VERSION:-}" ]]; then
    build_settings+=("CURRENT_PROJECT_VERSION=${PQA_BUILD_VERSION}")
fi

# Signing goes on the command line rather than into an xcconfig because
# command-line settings outrank the target's own, so this reliably replaces the
# ad-hoc default instead of losing to it.
if [[ -n "${PQA_SIGN_IDENTITY:-}" ]]; then
    build_settings+=(
        "CODE_SIGN_STYLE=Manual"
        "CODE_SIGN_IDENTITY=${PQA_SIGN_IDENTITY}"
        # Switches the app target to the entitlements without the
        # library-validation exemption. Only that target reads the variable, so
        # unlike overriding CODE_SIGN_ENTITLEMENTS outright this doesn't reach
        # the SPM packages, which would look for the file in their own checkout.
        "PQA_ENTITLEMENTS_SUFFIX=-Distribution"
        # Notarization rejects a signature without a secure timestamp.
        "OTHER_CODE_SIGN_FLAGS=--timestamp"
    )
    if [[ -n "${PQA_TEAM_ID:-}" ]]; then
        build_settings+=("DEVELOPMENT_TEAM=${PQA_TEAM_ID}")
    fi
fi

rm -rf dist
xcodebuild -scheme PassQuickAccess -configuration Release \
    -derivedDataPath dist/dd -destination 'generic/platform=macOS' build \
    ${build_settings[@]+"${build_settings[@]}"}

# Catches an unsigned or partially signed nested bundle (Sparkle ships an
# Updater.app and two XPC services) here, rather than at notarization, where the
# same problem comes back as a far less obvious error.
codesign --verify --deep --strict --verbose=2 "$app"

ditto -c -k --keepParent "$app" "$zip"

notary_args=()
if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    notary_args=(--keychain-profile "${NOTARY_KEYCHAIN_PROFILE}")
elif [[ -n "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]]; then
    notary_args=(--key "${NOTARY_KEY_PATH}" --key-id "${NOTARY_KEY_ID}" --issuer "${NOTARY_ISSUER_ID}")
fi

if [[ -z "${PQA_SIGN_IDENTITY:-}" ]]; then
    echo
    echo "warning: no PQA_SIGN_IDENTITY, so this build is ad-hoc signed and cannot be notarized." >&2
    echo "warning: whoever downloads it has to allow it through Gatekeeper by hand." >&2
elif [[ ${#notary_args[@]} -eq 0 ]]; then
    echo
    echo "warning: signed, but no notarization credentials were given, so there is no ticket." >&2
    echo "warning: Gatekeeper still blocks this build on first launch." >&2
else
    echo
    echo "Notarizing (this waits on Apple, usually a few minutes)…"
    result="$(xcrun notarytool submit "$zip" "${notary_args[@]}" --wait --output-format json)"
    status="$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')"
    if [[ "$status" != "Accepted" ]]; then
        # The submission log is the only place that says what Apple objected to,
        # and it is awkward to reach once this job has exited, so fetch it now.
        id="$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"
        echo "Notarization failed with status: ${status:-unknown}" >&2
        [[ -n "$id" ]] && xcrun notarytool log "$id" "${notary_args[@]}" >&2
        exit 1
    fi

    # Stapling writes the ticket into the .app on disk, which leaves the zip that
    # was submitted stale. Rebuild it, or the download arrives ticketless and is
    # refused on a Mac that can't reach Apple to check.
    xcrun stapler staple "$app"
    rm -f "$zip"
    ditto -c -k --keepParent "$app" "$zip"

    xcrun stapler validate "$app"
    # The last word on whether the app opens on someone else's Mac without a prompt.
    spctl --assess --type exec --verbose=4 "$app"
fi

echo
echo "Built $app"
echo "Zipped $zip"
codesign -dvv "$app" 2>&1 | grep -E "Signature|Authority|TeamIdentifier" || true
