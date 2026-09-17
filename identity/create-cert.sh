#!/usr/bin/env bash
# Server certificate for keycloak.kind.local from the local CA (update-setup-03).
# Same shape as registry/create-cert.sh: issued by the issuing CA, chain written for the server.
# Usage: identity/create-cert.sh
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PKI="$SCRIPT_DIR/../pki/out"
OUT="$SCRIPT_DIR/out/tls"
: "${KEYCLOAK_HOSTNAME:=keycloak.kind.local}"
[[ -f "$PKI/issuing-ca.key" ]] || { echo "missing $PKI/issuing-ca.key - run pki/create-ca.sh first" >&2; exit 1; }

mkdir -p "$OUT"
umask 077

# Keep an existing certificate if it still matches and is valid for more than 30 days
if [[ -f "$OUT/tls.crt" && -f "$OUT/tls.key" ]] \
   && openssl x509 -in "$OUT/tls.crt" -noout -checkend $((30 * 86400)) >/dev/null 2>&1 \
   && openssl x509 -in "$OUT/tls.crt" -noout -ext subjectAltName | grep -q "DNS:$KEYCLOAK_HOSTNAME"; then
    echo "certificate for $KEYCLOAK_HOSTNAME already present and valid: $OUT/tls.crt"
    exit 0
fi

openssl req -new -newkey rsa:2048 -nodes -sha256 \
    -keyout "$OUT/tls.key" -out "$OUT/tls.csr" \
    -subj "/O=kind-dev/CN=$KEYCLOAK_HOSTNAME"
openssl x509 -req -in "$OUT/tls.csr" -CA "$PKI/issuing-ca.crt" -CAkey "$PKI/issuing-ca.key" \
    -CAcreateserial -days 825 -sha256 -out "$OUT/server.crt" -extfile <(printf '%s\n' \
        "basicConstraints=critical,CA:FALSE" \
        "keyUsage=critical,digitalSignature,keyEncipherment" \
        "extendedKeyUsage=serverAuth" \
        "subjectAltName=DNS:$KEYCLOAK_HOSTNAME")
# Keycloak serves what is in KC_HTTPS_CERTIFICATE_FILE, so it needs the chain:
# server certificate + issuing CA, with the root already in the clients' trust stores.
cat "$OUT/server.crt" "$PKI/issuing-ca.crt" > "$OUT/tls.crt"
# The container runs as uid 1000, same as this user; keep the key unreadable for others.
chmod 644 "$OUT/tls.crt"; chmod 640 "$OUT/tls.key"
rm -f "$OUT/tls.csr"

openssl verify -CAfile "$PKI/root-ca.crt" -untrusted "$PKI/issuing-ca.crt" "$OUT/server.crt"
openssl x509 -in "$OUT/server.crt" -noout -subject -enddate -ext subjectAltName
