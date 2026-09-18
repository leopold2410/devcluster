#!/usr/bin/env bash
# A secret from Vault, delivered by the External Secrets Operator (update-setup-06).
# Needs Vault (vault/setup-host.sh) and the ClusterSecretStore from platformservices/deploy.sh.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
kubectl apply -k "$SCRIPT_DIR"
kubectl -n vault-demo wait externalsecret/hello --for=condition=Ready --timeout=120s
echo -n "greeting from Vault: "
kubectl -n vault-demo get secret hello -o jsonpath='{.data.greeting}' | base64 -d; echo
