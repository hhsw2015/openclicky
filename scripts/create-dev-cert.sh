#!/usr/bin/env bash
# create-dev-cert.sh — one-time creation of a persistent self-signed
# cert used by scripts/sign-and-install.sh to keep TCC (Accessibility,
# Screen Recording, Microphone) permissions across OpenClicky rebuilds.
#
# Run this ONCE per developer machine. Idempotent — no-op if the cert
# already exists in the login keychain.
#
# usage: bash scripts/create-dev-cert.sh
set -euo pipefail

CERT_NAME="OpenClicky Dev Sign"
DAYS=3650
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

if security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
    echo "cert '$CERT_NAME' already present. no-op."
    exit 0
fi

echo "[1/4] generating self-signed cert (valid $DAYS days)"

# X.509 extensions needed for macOS code signing.
cat > "$TMPDIR/ext.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = $CERT_NAME

[v3_req]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -keyout "$TMPDIR/key.pem" \
    -out "$TMPDIR/cert.pem" -days $DAYS -nodes \
    -config "$TMPDIR/ext.cnf" 2>/dev/null

echo "[2/4] converting to p12"
P12_PASS="openclicky-dev-cert"
openssl pkcs12 -export -inkey "$TMPDIR/key.pem" -in "$TMPDIR/cert.pem" \
    -out "$TMPDIR/cert.p12" -name "$CERT_NAME" -passout pass:$P12_PASS \
    -legacy 2>/dev/null || \
openssl pkcs12 -export -inkey "$TMPDIR/key.pem" -in "$TMPDIR/cert.pem" \
    -out "$TMPDIR/cert.p12" -name "$CERT_NAME" -passout pass:$P12_PASS

echo "[3/4] importing into login keychain (you may be prompted for password)"
security import "$TMPDIR/cert.p12" -k ~/Library/Keychains/login.keychain-db \
    -P "$P12_PASS" -T /usr/bin/codesign

echo "[4/4] verifying"
security find-certificate -c "$CERT_NAME" >/dev/null

echo "done. cert '$CERT_NAME' is in your login keychain, valid $DAYS days."
echo "next: bash scripts/sign-and-install.sh"
