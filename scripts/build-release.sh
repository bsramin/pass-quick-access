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
distribution_entitlements="Sources/PassQuickAccess/App/PassQuickAccess-Distribution.entitlements"

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

# Xcode signs the app and the Sparkle framework's outer bundle with the chosen
# identity, but leaves the executables nested inside the framework ad-hoc signed
# and without a secure timestamp. Notarization rejects every one of them, and
# `codesign --verify --deep` does not complain, because an ad-hoc signature is
# structurally valid; it is the identity behind it that Apple objects to.
#
# So re-sign them by hand. Order matters: signing something breaks the seal of
# whatever contains it, so this works inside out and re-seals the framework and
# then the app at the end. Existing entitlements are carried over rather than
# dropped, since these are Sparkle's binaries and its own signing is the
# reference for what they need.
if [[ -n "${PQA_SIGN_IDENTITY:-}" ]]; then
    sparkle="$app/Contents/Frameworks/Sparkle.framework"
    version="$(cd "$sparkle/Versions/Current" && pwd -P)"

    for item in \
        "$version/XPCServices/Downloader.xpc" \
        "$version/XPCServices/Installer.xpc" \
        "$version/Updater.app" \
        "$version/Autoupdate"
    do
        if [[ ! -e "$item" ]]; then
            echo "error: expected Sparkle component is missing: $item" >&2
            echo "error: the framework's layout changed, so this re-signing needs revisiting." >&2
            exit 1
        fi
        entitlements="$(mktemp -t pqa-entitlements)"
        codesign -d --entitlements "$entitlements" --xml "$item" 2> /dev/null || true
        if [[ -s "$entitlements" ]]; then
            codesign --force --options runtime --timestamp \
                --sign "$PQA_SIGN_IDENTITY" --entitlements "$entitlements" "$item"
        else
            codesign --force --options runtime --timestamp --sign "$PQA_SIGN_IDENTITY" "$item"
        fi
        rm -f "$entitlements"
    done

    codesign --force --options runtime --timestamp --sign "$PQA_SIGN_IDENTITY" "$sparkle"
    codesign --force --options runtime --timestamp --sign "$PQA_SIGN_IDENTITY" \
        --entitlements "$distribution_entitlements" "$app"
fi

# Structural check. It passes on an ad-hoc bundle too, so it is a guard against a
# broken or missing signature, not against the wrong identity; the loop above
# covers that, and the assertion below confirms it.
codesign --verify --deep --strict --verbose=2 "$app"

# Every executable in the bundle must carry the app's own team and a secure
# timestamp, or notarization fails on it. Checking here turns a slow, opaque
# rejection from Apple into an immediate local failure naming the binary at
# fault. The team is read back off the app rather than taken from the
# environment, so this stays honest even if PQA_TEAM_ID was never set.
#
# codesign's output is captured once and matched with bash patterns rather than
# piped into grep: `grep -q` closes the pipe on its first match, codesign takes
# a SIGPIPE, and under `pipefail` the whole pipeline then reports failure for a
# binary that was perfectly fine.
if [[ -n "${PQA_SIGN_IDENTITY:-}" ]]; then
    app_info="$(codesign -dvv "$app" 2>&1)"
    expected_team="${app_info#*TeamIdentifier=}"
    expected_team="${expected_team%%$'\n'*}"
    if [[ -z "$expected_team" || "$expected_team" == "not set" ]]; then
        echo "error: the app carries no team identifier, so it was not signed as expected." >&2
        exit 1
    fi

    while IFS= read -r macho; do
        info="$(codesign -dvv "$macho" 2>&1)"
        if [[ "$info" != *"TeamIdentifier=${expected_team}"* ]]; then
            echo "error: not signed with team ${expected_team}: ${macho#"$app/"}" >&2
            exit 1
        fi
        # Present only for a secure timestamp; a local-only signature says
        # "Signed Time" instead, which notarization rejects.
        if [[ "$info" != *"Timestamp="* ]]; then
            echo "error: signed without a secure timestamp: ${macho#"$app/"}" >&2
            exit 1
        fi
    done < <(find "$app" -type f -perm -u+x -exec sh -c 'file -b "$1" | grep -q Mach-O' _ {} \; -print)

    echo "All executables signed by team ${expected_team} with a secure timestamp."
fi

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
