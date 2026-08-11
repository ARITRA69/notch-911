#!/bin/bash
#
# Build, ad-hoc sign, and package notch-911 for a GitHub release.
#
# Usage: ./scripts/release.sh 0.2.0
#
# There is no Developer ID certificate here — the app is ad-hoc signed, so the
# DMG is for GitHub Releases plus the Gatekeeper workaround in the README.

set -euo pipefail

version="${1:-}"
if [[ -z "${version}" ]]; then
    echo "Usage: $(basename "$0") <version>    e.g. $(basename "$0") 0.2.0" >&2
    exit 2
fi
if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Not a semver version: '${version}' — expected X.Y.Z, e.g. 0.2.0" >&2
    exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(dirname "${script_dir}")"
build_dir="${repo_dir}/build/release"
dist_dir="${repo_dir}/dist"
app="${build_dir}/Build/Products/Release/notch-911.app"
dmg="${dist_dir}/notch-911-${version}.dmg"

echo "Building notch-911 ${version} (Release)…"
rm -rf "${build_dir}"
xcodebuild \
    -project "${repo_dir}/notch-911.xcodeproj" \
    -scheme notch-911 \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "${build_dir}" \
    MARKETING_VERSION="${version}" \
    CURRENT_PROJECT_VERSION="${version}" \
    CODE_SIGNING_ALLOWED=NO \
    build

if [[ ! -d "${app}" ]]; then
    echo "Build did not produce ${app}" >&2
    exit 1
fi

echo "Ad-hoc signing…"
codesign --force --deep --sign - "${app}"
codesign --verify --deep --strict --verbose=2 "${app}"

# Stage only the app. create-dmg adds the Applications link itself; the
# hdiutil fallback gets an explicit symlink so both layouts drag-to-install.
stage_dir="${build_dir}/dmg-stage"
rm -rf "${stage_dir}"
mkdir -p "${stage_dir}" "${dist_dir}"
cp -R "${app}" "${stage_dir}/"
rm -f "${dmg}"

if command -v create-dmg >/dev/null 2>&1; then
    echo "Packaging with create-dmg…"
    create-dmg \
        --volname "notch-911 ${version}" \
        --window-size 540 380 \
        --icon-size 128 \
        --icon "notch-911.app" 140 190 \
        --app-drop-link 400 190 \
        --hide-extension "notch-911.app" \
        "${dmg}" \
        "${stage_dir}"
else
    echo "create-dmg not on PATH; packaging with hdiutil…"
    ln -s /Applications "${stage_dir}/Applications"
    hdiutil create \
        -volname "notch-911 ${version}" \
        -srcfolder "${stage_dir}" \
        -format UDZO \
        -ov \
        "${dmg}"
fi

if [[ ! -f "${dmg}" ]]; then
    echo "No DMG was produced at ${dmg}" >&2
    exit 1
fi

echo
echo "DMG:    ${dmg}"
echo "sha256: $(shasum -a 256 "${dmg}" | awk '{print $1}')"
