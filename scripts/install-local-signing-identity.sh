#!/bin/zsh
set -euo pipefail

identity_name="notch-911 Local Development"
login_keychain="${HOME}/Library/Keychains/login.keychain-db"

configure_codesign_access() {
    print "Authorizing Apple signing tools for this private key."
    print "Enter the login Keychain password if macOS requests it."
    /usr/bin/security set-key-partition-list \
        -S "apple-tool:,apple:" \
        -s \
        -l "${identity_name}" \
        "${login_keychain}"
}

if /usr/bin/security find-identity -v -p codesigning "${login_keychain}" 2>/dev/null \
    | /usr/bin/grep -Fq "${identity_name}"; then
    print "Code-signing identity already exists: ${identity_name}"
    configure_codesign_access
    exit 0
fi

temporary_directory="$(/usr/bin/mktemp -d "${TMPDIR%/}/notch-911-signing.XXXXXX")"
cleanup() {
    if [[ -n "${temporary_directory}" && -d "${temporary_directory}" ]]; then
        /bin/rm -rf -- "${temporary_directory}"
    fi
}
trap cleanup EXIT

private_key="${temporary_directory}/notch-911-local.key"
certificate="${temporary_directory}/notch-911-local.crt"
archive="${temporary_directory}/notch-911-local.p12"
archive_password="$(/usr/bin/openssl rand -hex 24)"

# If an earlier import succeeded but its trust confirmation was interrupted,
# finish that exact identity instead of creating a duplicate certificate.
if /usr/bin/security find-certificate -c "${identity_name}" "${login_keychain}" >/dev/null 2>&1; then
    /usr/bin/security find-certificate \
        -c "${identity_name}" \
        -p "${login_keychain}" > "${certificate}"
    print "Applying code-signing trust to the imported identity."
    /usr/bin/security add-trusted-cert \
        -r trustRoot \
        -p codeSign \
        -k "${login_keychain}" \
        "${certificate}"
    if /usr/bin/security find-identity -v -p codesigning "${login_keychain}" \
        | /usr/bin/grep -Fq "${identity_name}"; then
        configure_codesign_access
        print "Created persistent code-signing identity: ${identity_name}"
        exit 0
    fi
    print -u2 "The existing certificate is still not usable for code signing."
    exit 1
fi

/usr/bin/openssl req \
    -newkey rsa:3072 \
    -nodes \
    -x509 \
    -sha256 \
    -days 3650 \
    -subj "/CN=${identity_name}/O=notch-911 Local Development" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,digitalSignature,keyCertSign" \
    -addext "extendedKeyUsage=codeSigning" \
    -keyout "${private_key}" \
    -out "${certificate}"

/usr/bin/openssl pkcs12 \
    -export \
    -name "${identity_name}" \
    -inkey "${private_key}" \
    -in "${certificate}" \
    -passout "pass:${archive_password}" \
    -out "${archive}"

print "Importing ${identity_name} into the login keychain. macOS may ask for Keychain confirmation."
/usr/bin/security import "${archive}" \
    -k "${login_keychain}" \
    -P "${archive_password}" \
    -T /usr/bin/codesign \
    -T /usr/bin/security

/usr/bin/security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "${login_keychain}" \
    "${certificate}"

if ! /usr/bin/security find-identity -v -p codesigning "${login_keychain}" \
    | /usr/bin/grep -Fq "${identity_name}"; then
    print -u2 "The certificate was imported but is not available as a code-signing identity."
    exit 1
fi

configure_codesign_access
print "Created persistent code-signing identity: ${identity_name}"
