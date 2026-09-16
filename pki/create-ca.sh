#!/usr/bin/env bash
# Local root CA + two intermediate CAs for the kind dev cluster (update-setup-01).
# Output in pki/out/ (git-ignored). Existing certificates/keys are never overwritten.
# root-ca.key is only needed to issue missing intermediates and may be kept offline.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
umask 077
mkdir -p out
cd out

# The root may only certify names below these domains, even if a key leaks
NAME_CONSTRAINTS="critical,permitted;DNS:kind.local,permitted;DNS:svc,permitted;DNS:cluster.local,permitted;DNS:localhost"

if [[ ! -f root-ca.crt ]]; then
    openssl req -x509 -new -newkey rsa:4096 -nodes -sha256 -days 3650 \
        -keyout root-ca.key -out root-ca.crt \
        -subj "/O=kind-dev/CN=kind-dev Root CA" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -addext "subjectKeyIdentifier=hash" \
        -addext "nameConstraints=${NAME_CONSTRAINTS}"
fi

# $1 = file prefix, $2 = common name
issue_intermediate() {
    local name=$1 cn=$2
    [[ -f $name.crt ]] && return 0
    [[ -f root-ca.key ]] || { echo "root-ca.key is required to issue $name - restore it from offline storage" >&2; exit 1; }
    openssl req -new -newkey rsa:4096 -nodes -sha256 \
        -keyout "$name.key" -out "$name.csr" -subj "/O=kind-dev/CN=$cn"
    openssl x509 -req -in "$name.csr" -CA root-ca.crt -CAkey root-ca.key -CAcreateserial \
        -days 1095 -sha256 -out "$name.crt" -extfile <(printf '%s\n' \
            "basicConstraints=critical,CA:TRUE,pathlen:0" \
            "keyUsage=critical,keyCertSign,cRLSign" \
            "subjectKeyIdentifier=hash" \
            "authorityKeyIdentifier=keyid:always")
    rm "$name.csr"
    cat "$name.crt" root-ca.crt > "$name-chain.crt"
}

issue_intermediate issuing-ca "kind-dev Issuing CA"      # -> cert-manager ClusterIssuer "kind-ca"
issue_intermediate istio-ca   "kind-dev Istio Mesh CA"   # -> Istio plug-in CA (secret cacerts)

chmod 644 ./*.crt
openssl verify -CAfile root-ca.crt issuing-ca.crt istio-ca.crt
