#!/bin/zsh
set -euo pipefail

identity_name="notch-911 Local Development"
bundle_identifier="com.aritra360.notch-911"
script_directory="${0:A:h}"
repository_directory="${script_directory:h}"
installed_app="/Applications/notch-911.app"
backup_directory="${HOME}/Library/Application Support/notch-911/Backups"
reset_accessibility=false
configuration=Debug

# Both flags, in any order, so --release --reset-accessibility works the way
# you would expect it to.
for argument in "$@"; do
    case "${argument}" in
        --reset-accessibility) reset_accessibility=true ;;
        --release) configuration=Release ;;
        *)
            print -u2 "Usage: ${0:t} [--release] [--reset-accessibility]"
            exit 2
            ;;
    esac
done

# Separate derived data per configuration. Sharing one would make every switch
# between Debug and Release a full rebuild.
derived_data="${TMPDIR%/}/notch-911-local-signed-derived-data-${configuration:l}"
source_app="${derived_data}/Build/Products/${configuration}/notch-911.app"

if ! /usr/bin/security find-identity -v -p codesigning \
    | /usr/bin/grep -Fq "${identity_name}"; then
    print -u2 "Missing code-signing identity: ${identity_name}"
    print -u2 "Run scripts/install-local-signing-identity.sh once, then retry."
    exit 1
fi

print "Building notch-911 (${configuration})…"
/usr/bin/xcodebuild \
    -project "${repository_directory}/notch-911.xcodeproj" \
    -scheme notch-911 \
    -configuration "${configuration}" \
    -derivedDataPath "${derived_data}" \
    CODE_SIGNING_ALLOWED=NO \
    ENABLE_DEBUG_DYLIB=NO \
    clean build

if [[ ! -d "${source_app}" ]]; then
    print -u2 "Build did not produce ${source_app}"
    exit 1
fi

print "Signing with ${identity_name}…"
# The build above ran with CODE_SIGNING_ALLOWED=NO, so whatever Xcode would
# have applied from CODE_SIGN_ENTITLEMENTS never made it into the binary — this
# signature is the only one the installed app ever gets. Passing the file
# explicitly is what keeps the microphone reachable under `--options runtime`;
# without it ⇧⌘M records silence in /Applications and works fine from Xcode,
# which is the most confusing possible way for this to break.
/usr/bin/codesign \
    --force \
    --deep \
    --keychain "${HOME}/Library/Keychains/login.keychain-db" \
    --options runtime \
    --entitlements "${repository_directory}/notch-911/notch-911.entitlements" \
    --timestamp=none \
    --sign "${identity_name}" \
    "${source_app}"

/usr/bin/codesign --verify --deep --strict --verbose=2 "${source_app}"
designated_requirement="$(/usr/bin/codesign --display --requirements - "${source_app}" 2>&1)"
if [[ "${designated_requirement}" != *"identifier \"${bundle_identifier}\""* ]]; then
    print -u2 "Unexpected designated requirement: ${designated_requirement}"
    exit 1
fi

/bin/mkdir -p "${backup_directory}"
timestamp="$(/bin/date +%Y%m%d-%H%M%S)"
backup_app="${backup_directory}/notch-911-${timestamp}.app"

/usr/bin/pkill -x notch-911 2>/dev/null || true
if [[ -d "${installed_app}" ]]; then
    /bin/mv "${installed_app}" "${backup_app}"
    print "Previous app backed up to ${backup_app}"
fi

if ! /usr/bin/ditto "${source_app}" "${installed_app}"; then
    failed_app="${backup_directory}/notch-911-failed-${timestamp}.app"
    if [[ -e "${installed_app}" ]]; then
        /bin/mv "${installed_app}" "${failed_app}"
    fi
    if [[ -d "${backup_app}" ]]; then
        /bin/mv "${backup_app}" "${installed_app}"
    fi
    print -u2 "Install failed; the previous app was restored."
    exit 1
fi

if ! /usr/bin/codesign --verify --deep --strict --verbose=2 "${installed_app}"; then
    invalid_app="${backup_directory}/notch-911-invalid-${timestamp}.app"
    /bin/mv "${installed_app}" "${invalid_app}"
    if [[ -d "${backup_app}" ]]; then
        /bin/mv "${backup_app}" "${installed_app}"
    fi
    print -u2 "Signature verification failed; the previous app was restored."
    exit 1
fi

# Backups only need to be restorable, not launchable. A bootable .app left
# here can be reopened by Launch Services — login-time window restoration, a
# stray double-click, Spotlight — and then two copies fight over the notch
# (the app's single-instance guard now catches that, but a backup shouldn't
# be inviting it). Once the new install has verified, flatten every backup
# into a zip; this also sweeps launchable backups left by earlier runs. The
# error paths above keep their .app form on purpose — they restore by `mv`.
for app in "${backup_directory}"/*.app(N); do
    if /usr/bin/ditto -c -k --keepParent "${app}" "${app%.app}.zip"; then
        /bin/rm -rf "${app}"
    fi
done

if [[ "${reset_accessibility}" == true ]]; then
    /usr/bin/tccutil reset Accessibility "${bundle_identifier}"
    print "Reset only ${bundle_identifier}'s stale Accessibility record."
fi

/usr/bin/open "${installed_app}"
print "Installed and launched ${installed_app}"
print "Designated requirement: ${designated_requirement}"
