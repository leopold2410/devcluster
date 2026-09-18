#!/usr/bin/env bash
# HashiCorp Vault via Docker Compose (update-setup-06).
# Usage: vault/setup-host.sh      - safe to re-run; also the way to unseal after a restart
#
# 1. certificate, .env, containers
# 2. once: "vault operator init" with one key share - unseal key and root token to out/
# 3. every run: unseal if sealed
# 4. the cluster's CA for Kubernetes auth (a new cluster has a new CA)
# 5. Terraform (vault/config), when present
#
# No root needed. The unseal key sits next to the data in out/ - a dev-only shortcut.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../versions.env"
OUT="$SCRIPT_DIR/out"
: "${VAULT_HOSTNAME:=vault.kind.local}"
: "${VAULT_PORT:=8200}"

KIND_GATEWAY=$(docker network inspect kind -f '{{range .IPAM.Config}}{{if .Gateway}}{{.Gateway}} {{end}}{{end}}' 2>/dev/null |
    tr ' ' '\n' | grep -v ':' | head -1 || true)
[[ -n $KIND_GATEWAY ]] || { echo "no kind network - Vault joins it to reach the API server; create the cluster first" >&2; exit 1; }

mkdir -p "$OUT/file" "$OUT/tls"
chmod 700 "$OUT"
"$SCRIPT_DIR/create-cert.sh"

umask 077
cat > "$SCRIPT_DIR/.env" <<EOF
VAULT_VERSION=$VAULT_VERSION
VAULT_PORT=$VAULT_PORT
KIND_GATEWAY=$KIND_GATEWAY
HOST_UID=$(id -u)
HOST_GID=$(id -g)
EOF

cd "$SCRIPT_DIR"
docker compose up -d

v() { docker compose exec -T vault vault "$@"; }

# "vault status" exits 0 when unsealed, 2 when sealed, 1 on error (not up yet).
echo -n "waiting for Vault"
for i in $(seq 1 30); do
    rc=0; v status >/dev/null 2>&1 || rc=$?
    [[ $rc == 0 || $rc == 2 ]] && { echo " ok"; break; }
    echo -n .; sleep 2
    [[ $i == 30 ]] && { echo; echo "Vault did not answer; see: docker compose -f $SCRIPT_DIR/compose.yaml logs vault" >&2; exit 1; }
done

initialized=$(v status -format=json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["initialized"])' || true)
if [[ $initialized != True ]]; then
    echo "initializing Vault (one key share - dev only)"
    v operator init -key-shares=1 -key-threshold=1 -format=json > "$OUT/init.json"
    python3 - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
d = json.load(open(os.path.join(out, "init.json")))
for name, value in (("unseal-key", d["unseal_keys_b64"][0]), ("root-token", d["root_token"])):
    path = os.path.join(out, name)
    with open(path, "w") as f:
        f.write(value)
    os.chmod(path, 0o600)
PY
fi

sealed=$(v status -format=json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["sealed"])' || true)
if [[ $sealed == True ]]; then
    v operator unseal "$(cat "$OUT/unseal-key")" >/dev/null
    echo "unsealed"
fi

# The cluster's CA, for Vault's Kubernetes auth. A new cluster brings a new CA.
if kubectl -n default get configmap kube-root-ca.crt >/dev/null 2>&1; then
    kubectl -n default get configmap kube-root-ca.crt -o jsonpath='{.data.ca\.crt}' > "$OUT/k8s-ca.crt"
fi

if [[ -f "$SCRIPT_DIR/config/main.tf" ]]; then
    "$SCRIPT_DIR/tf.sh" init -input=false >/dev/null
    "$SCRIPT_DIR/tf.sh" apply -auto-approve -input=false
fi

echo
echo "Vault:      https://$VAULT_HOSTNAME:$VAULT_PORT   (./hosts.sh adds the name)"
echo "Root token: $OUT/root-token"
echo "Stop:       docker compose -f $SCRIPT_DIR/compose.yaml stop   (re-run this script to unseal)"
