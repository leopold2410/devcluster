#!/usr/bin/env bash
# Server certificate for harbor.kind.local from the local CA (update-setup-02).
# Usage: registry/create-cert.sh
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PKI="$SCRIPT_DIR/../pki/out"
OUT="$SCRIPT_DIR/out"
: "${HARBOR_HOSTNAME:=harbor.kind.local}"
[[ -f "$PKI/issuing-ca.key" ]] || { echo "missing $PKI/issuing-ca.key - run pki/create-ca.sh first" >&2; exit 1; }

mkdir -p "$OUT"
umask 077

# Keep an existing certificate if it still matches and is valid for more than 30 days
if [[ -f "$OUT/harbor.crt" && -f "$OUT/harbor.key" ]] \
   && openssl x509 -in "$OUT/harbor.crt" -noout -checkend $((30 * 86400)) >/dev/null 2>&1 \
   && openssl x509 -in "$OUT/harbor.crt" -noout -ext subjectAltName | grep -q "DNS:$HARBOR_HOSTNAME"; then
    echo "certificate for $HARBOR_HOSTNAME already present and valid: $OUT/harbor.crt"
    exit 0
fi
openssl req -new -newkey rsa:2048 -nodes -sha256 \
    -keyout "$OUT/harbor.key" -out "$OUT/harbor.csr" \
    -subj "/O=kind-dev/CN=$HARBOR_HOSTNAME"
openssl x509 -req -in "$OUT/harbor.csr" -CA "$PKI/issuing-ca.crt" -CAkey "$PKI/issuing-ca.key" \
    -CAcreateserial -days 825 -sha256 -out "$OUT/harbor.crt" -extfile <(printf '%s\n' \
        "basicConstraints=critical,CA:FALSE" \
        "keyUsage=critical,digitalSignature,keyEncipherment" \
        "extendedKeyUsage=serverAuth" \
        "subjectAltName=DNS:$HARBOR_HOSTNAME")
# Harbor's nginx needs the chain: server certificate + issuing CA
cat "$OUT/harbor.crt" "$PKI/issuing-ca.crt" > "$OUT/harbor-chain.crt"
chmod 644 "$OUT/harbor-chain.crt" "$OUT/harbor.crt"
rm -f "$OUT/harbor.csr"

openssl verify -CAfile "$PKI/root-ca.crt" -untrusted "$PKI/issuing-ca.crt" "$OUT/harbor.crt"
openssl x509 -in "$OUT/harbor.crt" -noout -subject -enddate -ext subjectAltName
