#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# One-time setup: create a self-signed code-signing certificate "Pave Dev" in the
# login keychain, so every build of Pave.app has the same signing requirement
# and keeps its Accessibility permission (see bundle.sh).
#
# macOS will ask for your session password to trust the certificate for code
# signing. Run it yourself:  ! scripts/make-dev-cert.sh
set -euo pipefail

NAME="Pave Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "'$NAME' already exists in the login keychain, nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS="$(/usr/bin/openssl rand -hex 16)"

cat >"$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -passout "pass:$PASS" -out "$TMP/cert.p12"

security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo
security find-identity -v -p codesigning | grep "$NAME" \
    && echo "OK: '$NAME' is ready. Rebuild with scripts/bundle.sh."
