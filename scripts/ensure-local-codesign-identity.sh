#!/usr/bin/env bash
set -euo pipefail

IDENTITY="${1:-ScreenCommentator Local Code Signing}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
P12_PASSWORD="screencommentator-local"

if security find-identity -v -p codesigning | grep -F "\"${IDENTITY}\"" >/dev/null; then
  echo "Using existing code signing identity: ${IDENTITY}"
  exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

cat > "${TMP_DIR}/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = v3_req
prompt = no

[ dn ]
CN = ${IDENTITY}

[ v3_req ]
basicConstraints = critical, CA:TRUE
keyUsage = critical, digitalSignature, keyCertSign
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

openssl req \
  -new \
  -newkey rsa:2048 \
  -nodes \
  -x509 \
  -days 3650 \
  -sha256 \
  -keyout "${TMP_DIR}/identity.key" \
  -out "${TMP_DIR}/identity.crt" \
  -config "${TMP_DIR}/openssl.cnf"

openssl pkcs12 \
  -export \
  -legacy \
  -inkey "${TMP_DIR}/identity.key" \
  -in "${TMP_DIR}/identity.crt" \
  -name "${IDENTITY}" \
  -out "${TMP_DIR}/identity.p12" \
  -passout "pass:${P12_PASSWORD}"

security import "${TMP_DIR}/identity.p12" \
  -k "${KEYCHAIN}" \
  -P "${P12_PASSWORD}" \
  -A \
  -T /usr/bin/codesign \
  -T /usr/bin/security

security add-trusted-cert \
  -d \
  -r trustRoot \
  -p codeSign \
  -k "${KEYCHAIN}" \
  "${TMP_DIR}/identity.crt" || true

if ! security find-identity -v -p codesigning | grep -F "\"${IDENTITY}\"" >/dev/null; then
  echo "Code signing identity was created but is not available for codesigning: ${IDENTITY}" >&2
  exit 1
fi

echo "Created code signing identity: ${IDENTITY}"
