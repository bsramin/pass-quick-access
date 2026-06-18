#!/usr/bin/env bash
#
# Build a Release .app and zip it into dist/. Without an Apple Developer ID
# certificate the build is ad-hoc signed and not notarized, so anyone who
# downloads the zip has to allow it through Gatekeeper (see RELEASING.md).

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

xcodegen generate

# The CI release job passes the tag's build number so Sparkle sees a version
# that climbs with every release; a local build keeps the project's default.
build_settings=()
if [[ -n "${PQA_BUILD_VERSION:-}" ]]; then
    build_settings+=("CURRENT_PROJECT_VERSION=${PQA_BUILD_VERSION}")
fi

rm -rf dist
xcodebuild -scheme PassQuickAccess -configuration Release \
    -derivedDataPath dist/dd -destination 'generic/platform=macOS' build \
    ${build_settings[@]+"${build_settings[@]}"}

app="dist/dd/Build/Products/Release/PassQuickAccess.app"
ditto -c -k --keepParent "$app" dist/PassQuickAccess.zip

echo
echo "Built $app"
echo "Zipped dist/PassQuickAccess.zip"
codesign -dvv "$app" 2>&1 | grep -E "Signature|Authority|TeamIdentifier" || true
