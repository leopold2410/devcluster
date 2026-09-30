#!/usr/bin/env bash
# Server certificate for s3.kind.local from the local CA (update-setup-09).
# Same shape as vault/create-cert.sh. RustFS only reads a certificate pair named
# rustfs_cert.pem / rustfs_key.pem from its TLS directory; with other names it refuses to start.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PKI="$SCRIPT_DIR/../pki/out"
OUT="$SCRIPT_DIR/out/tls"
: "${RUSTFS_HOSTNAME:=s3.kind.local}"
[[ -f "$PKI/issuing-ca.key" ]] || { echo "missing $PKI/issuing-ca.key - run pki/create-ca.sh first" >&2; exit 1; }

mkdir -p "$OUT"
umask 077

# The root CA, for RustFS's own requests to Keycloak (SSL_CERT_FILE in compose.yaml)
install -m 644 "$PKI/root-ca.crt" "$OUT/ca.crt"

# Keep an existing certificate if it still matches and is valid for more than 30 days
if [[ -f "$OUT/rustfs_cert.pem" && -f "$OUT/rustfs_key.pem" ]] \
   && openssl x509 -in "$OUT/server.crt" -noout -checkend $((30 * 86400)) >/dev/null 2>&1 \
   && openssl x509 -in "$OUT/server.crt" -noout -ext subjectAltName | grep -q "DNS:$RUSTFS_HOSTNAME"; then
    echo "certificate for $RUSTFS_HOSTNAME already present and valid: $OUT/rustfs_cert.pem"
    exit 0
fi

openssl req -new -newkey rsa:2048 -nodes -sha256 \
    -keyout "$OUT/rustfs_key.pem" -out "$OUT/tls.csr" \
    -subj "/O=kind-dev/CN=$RUSTFS_HOSTNAME"
openssl x509 -req -in "$OUT/tls.csr" -CA "$PKI/issuing-ca.crt" -CAkey "$PKI/issuing-ca.key" \
    -CAcreateserial -days 825 -sha256 -out "$OUT/server.crt" -extfile <(printf '%s\n' \
        "basicConstraints=critical,CA:FALSE" \
        "keyUsage=critical,digitalSignature,keyEncipherment" \
        "extendedKeyUsage=serverAuth" \
        "subjectAltName=DNS:$RUSTFS_HOSTNAME,DNS:localhost")
cat "$OUT/server.crt" "$PKI/issuing-ca.crt" > "$OUT/rustfs_cert.pem"
# The container runs as this user (compose.yaml), so the key can stay private to it.
chmod 644 "$OUT/rustfs_cert.pem" "$OUT/server.crt"; chmod 600 "$OUT/rustfs_key.pem"
rm -f "$OUT/tls.csr"

openssl verify -CAfile "$PKI/root-ca.crt" -untrusted "$PKI/issuing-ca.crt" "$OUT/server.crt"
openssl x509 -in "$OUT/server.crt" -noout -subject -enddate -ext subjectAltName
