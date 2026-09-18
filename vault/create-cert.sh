#!/usr/bin/env bash
# Server certificate for vault.kind.local from the local CA (update-setup-06).
# Same shape as identity/create-cert.sh. Also names localhost, for the CLI inside the container.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PKI="$SCRIPT_DIR/../pki/out"
OUT="$SCRIPT_DIR/out/tls"
: "${VAULT_HOSTNAME:=vault.kind.local}"
[[ -f "$PKI/issuing-ca.key" ]] || { echo "missing $PKI/issuing-ca.key - run pki/create-ca.sh first" >&2; exit 1; }

mkdir -p "$OUT"
umask 077

# The root CA, for VAULT_CACERT inside the container
install -m 644 "$PKI/root-ca.crt" "$OUT/ca.crt"

# Keep an existing certificate if it still matches and is valid for more than 30 days
if [[ -f "$OUT/tls.crt" && -f "$OUT/tls.key" ]] \
   && openssl x509 -in "$OUT/server.crt" -noout -checkend $((30 * 86400)) >/dev/null 2>&1 \
   && openssl x509 -in "$OUT/server.crt" -noout -ext subjectAltName | grep -q "DNS:$VAULT_HOSTNAME"; then
    echo "certificate for $VAULT_HOSTNAME already present and valid: $OUT/tls.crt"
    exit 0
fi

openssl req -new -newkey rsa:2048 -nodes -sha256 \
    -keyout "$OUT/tls.key" -out "$OUT/tls.csr" \
    -subj "/O=kind-dev/CN=$VAULT_HOSTNAME"
openssl x509 -req -in "$OUT/tls.csr" -CA "$PKI/issuing-ca.crt" -CAkey "$PKI/issuing-ca.key" \
    -CAcreateserial -days 825 -sha256 -out "$OUT/server.crt" -extfile <(printf '%s\n' \
        "basicConstraints=critical,CA:FALSE" \
        "keyUsage=critical,digitalSignature,keyEncipherment" \
        "extendedKeyUsage=serverAuth" \
        "subjectAltName=DNS:$VAULT_HOSTNAME,DNS:localhost")
cat "$OUT/server.crt" "$PKI/issuing-ca.crt" > "$OUT/tls.crt"
# The container runs as this user (compose.yaml), so the key can stay private to it.
chmod 644 "$OUT/tls.crt" "$OUT/server.crt"; chmod 600 "$OUT/tls.key"
rm -f "$OUT/tls.csr"

openssl verify -CAfile "$PKI/root-ca.crt" -untrusted "$PKI/issuing-ca.crt" "$OUT/server.crt"
openssl x509 -in "$OUT/server.crt" -noout -subject -enddate -ext subjectAltName
