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
project_file="${repo_dir}/notch-911.xcodeproj/project.pbxproj"

# Write the version down, don't just pass it in. The xcodebuild override below
# only governs *this* build; every other one — Xcode, the local install script,
# a plain `xcodebuild` — falls back to what the project file says. Left behind,
# that number outranks the newest tag and the update check goes silent on every
# non-release build.
echo "Setting project version to ${version}…"
sed -i '' \
    -e "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = ${version};/g" \
    -e "s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = ${version};/g" \
    "${project_file}"

# A rewrite that quietly matched nothing would ship a DMG whose name and
# contents disagree, which is the exact failure this is here to prevent.
version_pattern="${version//./\\.}"
settings_total="$(grep -cE '(MARKETING_VERSION|CURRENT_PROJECT_VERSION) = ' "${project_file}" || true)"
settings_set="$(grep -cE "(MARKETING_VERSION|CURRENT_PROJECT_VERSION) = ${version_pattern};" "${project_file}" || true)"
if [[ "${settings_set}" -eq 0 || "${settings_set}" -ne "${settings_total}" ]]; then
    echo "Version rewrite missed: ${settings_set}/${settings_total} settings say ${version}" >&2
    exit 1
fi

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
# Ad-hoc and no `--options runtime`, so the microphone entitlement isn't what
# gates ⇧⌘M here — TCC is. Passing it anyway keeps this signature the same
# shape as the local signed install's, so the two builds can't disagree about
# what the app is allowed to do.
codesign --force --deep \
    --entitlements "${repo_dir}/notch-911/notch-911.entitlements" \
    --sign - "${app}"
codesign --verify --deep --strict --verbose=2 "${app}"

# The window layout — size, icon positions, backdrop — lives in a .DS_Store
# inside the volume, which is why packaging straight to a compressed image gets
# you the default Finder window that 0.6.0 shipped. dmgbuild writes that file
# directly, headlessly, and gets all of it right except the backdrop: macOS 26's
# Finder ignores a background image referenced by an alias it did not write
# itself. So the image is applied in a second pass, by Finder, over the
# read-write volume, and only then compressed.
mkdir -p "${dist_dir}" "${build_dir}"

if command -v dmgbuild >/dev/null 2>&1; then
    dmgbuild_cmd=(dmgbuild)
elif command -v uvx >/dev/null 2>&1; then
    dmgbuild_cmd=(uvx --quiet dmgbuild)
else
    echo "dmgbuild not found — 'uv tool install dmgbuild' or 'pipx install dmgbuild'" >&2
    exit 1
fi

volname="notch-911 ${version}"
rw_dmg="${build_dir}/rw.dmg"
mount_point="/Volumes/${volname}"

echo "Packaging ${volname}…"
hdiutil detach "${mount_point}" >/dev/null 2>&1 || true
rm -f "${rw_dmg}" "${dmg}"
"${dmgbuild_cmd[@]}" \
    -s "${script_dir}/dmg-settings.py" \
    -D app="${app}" \
    -D background="${repo_dir}/assets/dmg/background.png" \
    "${volname}" \
    "${rw_dmg}"

hdiutil attach "${rw_dmg}" -noautoopen >/dev/null

# Finder will not take a dot-prefixed file as a backdrop unless it happens to be
# displaying hidden files — it cannot even coerce one to an alias, and fails with
# -1700. So the file is visible while Finder looks at it and hidden again after;
# the recorded bookmark resolves by inode, so the rename does not break it.
mv "${mount_point}/.background.png" "${mount_point}/background.png"

# Automation permission is a one-time local prompt. Where it is denied — a CI
# runner with no login session, most obviously — the DMG still builds and still
# installs; it just opens with a plain window instead of the backdrop.
if ! osascript "${script_dir}/dmg-window.applescript" \
        "${volname}" "${mount_point}/background.png" >/dev/null; then
    echo "warning: Finder would not apply the backdrop — shipping a plain window" >&2
fi

mv "${mount_point}/background.png" "${mount_point}/.background.png"

# After the Finder pass: fseventsd recreates itself on every read-write mount,
# so an earlier delete is simply undone.
rm -rf "${mount_point}/.fseventsd" 2>/dev/null || true
chflags hidden "${mount_point}/.background.png" 2>/dev/null || true

# Finder assigns an icon position to every file it *lists*, so a build machine
# browsing with hidden files revealed (Cmd-Shift-Period) writes positions for
# .background.png too, below the window. A default Mac never lists that file and
# so never sees it, but anyone else browsing hidden gets a stray icon and a
# scrollable window. Nothing here can suppress it, so say so instead.
strays="$(python3 - "${mount_point}/.DS_Store" <<'PYEOF'
import os, struct, sys
data = open(sys.argv[1], "rb").read()
volume = os.path.dirname(sys.argv[1])
expected = {"notch-911.app", "Applications"}
i, strays = 0, []
while True:
    i = data.find(b"Iloc", i + 1)
    if i < 0:
        break
    for length in range(1, 64):
        start = i - 2 * length - 4
        if start >= 0 and struct.unpack(">I", data[start:start + 4])[0] == length:
            name = data[start + 4:i].decode("utf-16-be", "replace")
            # A position for a name nothing answers to is inert — the backdrop
            # is renamed out from under its own entry on purpose.
            if name not in expected and os.path.exists(os.path.join(volume, name)):
                strays.append(name)
            break
print(" ".join(strays))
PYEOF
)"
if [[ -n "${strays}" ]]; then
    echo "warning: Finder recorded icon positions for ${strays}" >&2
    echo "         This machine is browsing with hidden files shown. Default Macs" >&2
    echo "         will not see them, but to ship a clean .DS_Store turn hidden" >&2
    echo "         files off in Finder (Cmd-Shift-Period) and re-run." >&2
fi

# Finder writes the .DS_Store lazily; detaching too early throws the layout away.
sync
hdiutil detach "${mount_point}" >/dev/null 2>&1 \
    || hdiutil detach "${mount_point}" -force >/dev/null

hdiutil convert "${rw_dmg}" -format UDZO -imagekey zlib-level=9 -o "${dmg}" >/dev/null
rm -f "${rw_dmg}"

if [[ ! -f "${dmg}" ]]; then
    echo "No DMG was produced at ${dmg}" >&2
    exit 1
fi

echo
echo "DMG:    ${dmg}"
echo "sha256: $(shasum -a 256 "${dmg}" | awk '{print $1}')"

# The rewrite above is a working-tree change. Releasing without committing it
# puts the tag on a commit that still claims the previous version.
if command -v git >/dev/null 2>&1 \
    && ! git -C "${repo_dir}" diff --quiet -- "${project_file}" 2>/dev/null; then
    echo
    echo "note:   project.pbxproj now says ${version} — commit it with the release."
fi
