#!/bin/bash
# Creates a certificate to sign Nimbus with, once per Mac that builds it.
#
# Why: the Keychain remembers which app may read an item by the app's signature. Without a
# certificate, a build's signature is a fingerprint of that exact build, so every new build is
# a stranger and the Keychain asks for your password again. Signed with the same certificate,
# every build is the same app to the Keychain, and "Always Allow" keeps counting.
#
# The certificate is made here, signed by itself, and carries no name but "Nimbus Code Signing".
# It doesn't make Nimbus notarized: other Macs still ask to allow the app the first time.
#
# macOS asks for your password once, to trust the certificate for signing code.
set -euo pipefail

NAME="Nimbus Code Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo "✓ \"$NAME\" is already there."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/certificate.conf" <<CONF
[ req ]
distinguished_name = name
x509_extensions = extensions
prompt = no

[ name ]
CN = $NAME

[ extensions ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONF

echo "› Making the certificate"
# The openssl that comes with macOS, whose files the Keychain reads.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$WORK/certificate.conf" \
    -keyout "$WORK/key.pem" -out "$WORK/certificate.pem" 2> /dev/null
/usr/bin/openssl pkcs12 -export -name "$NAME" -passout pass:nimbus \
    -inkey "$WORK/key.pem" -in "$WORK/certificate.pem" -out "$WORK/identity.p12"

echo "› Adding it to your login keychain"
# -T lets codesign use the key without asking each time.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P nimbus -T /usr/bin/codesign > /dev/null

echo "› Trusting it for signing code (macOS asks for your password)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/certificate.pem"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo "✓ \"$NAME\" is ready. Build Nimbus again to use it: ./scripts/build.sh"
else
    echo "The certificate was added, but macOS doesn't list it as usable for signing." >&2
    exit 1
fi
