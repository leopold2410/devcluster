#!/usr/bin/env bash
# Terraform for Vault's configuration, run in a container (update-setup-06).
# Usage: vault/tf.sh <terraform arguments>     e.g.  vault/tf.sh plan
#
# Nothing is installed on the host. The container runs as this user, so the state file and the
# provider cache in vault/config stay owned by it. Secrets reach Terraform as TF_VAR_* from the
# files that hold them; the state file then contains them too, which is why it is git-ignored.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../versions.env"
OUT="$SCRIPT_DIR/out"
IDENTITY="$SCRIPT_DIR/../identity/out"
PKI="$SCRIPT_DIR/../pki/out"

for f in "$OUT/root-token" "$OUT/k8s-ca.crt" "$IDENTITY/vault-client-secret" "$PKI/root-ca.crt"; do
    [[ -s $f ]] || { echo "missing $f - run identity/setup-host.sh and vault/setup-host.sh first" >&2; exit 1; }
done
KIND_GATEWAY=$(sed -n 's/^KIND_GATEWAY=//p' "$SCRIPT_DIR/.env" 2>/dev/null)
[[ -n $KIND_GATEWAY ]] || { echo "missing vault/.env - run vault/setup-host.sh first" >&2; exit 1; }

tty=(); [[ -t 0 ]] && tty=(-t)
exec docker run --rm -i "${tty[@]}" \
    --user "$(id -u):$(id -g)" \
    --add-host "vault.kind.local:$KIND_GATEWAY" \
    -v "$SCRIPT_DIR/config:/workspace" -w /workspace \
    -v "$PKI/root-ca.crt:/ca/root-ca.crt:ro" \
    -e HOME=/tmp \
    -e TF_IN_AUTOMATION=1 \
    -e VAULT_TOKEN="$(cat "$OUT/root-token")" \
    -e VAULT_CACERT=/ca/root-ca.crt \
    -e TF_VAR_oidc_client_secret="$(cat "$IDENTITY/vault-client-secret")" \
    -e TF_VAR_root_ca_pem="$(cat "$PKI/root-ca.crt")" \
    -e TF_VAR_kubernetes_ca_pem="$(cat "$OUT/k8s-ca.crt")" \
    "hashicorp/terraform:${TERRAFORM_VERSION}" "$@"
