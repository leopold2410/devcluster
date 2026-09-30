#!/usr/bin/env bash
# backup-demo (update-setup-09): a PostgreSQL database with its own backups, deployed by Argo CD.
# Needs RustFS (objectstore/), Vault (vault/setup-host.sh), K8up and the ClusterSecretStore from
# platformservices/deploy.sh - and the pushed repository, because Argo CD deploys from GitHub.
#
# Backup and restore on request: applications/backup-demo/sync.sh backup | restore
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT="$SCRIPT_DIR/../.."

# What the platform provides: bucket, key and repository password, in Vault
"$ROOT/objectstore/setup-host.sh" backup-demo | grep '^namespace backup-demo'

# What the application brings: the database password, once. A rebuilt cluster gets the same
# one, so clients keep working after a restore.
vault() {
    docker compose -f "$ROOT/vault/compose.yaml" exec -T \
        -e VAULT_TOKEN="$(cat "$ROOT/vault/out/root-token")" vault vault "$@"
}
if ! vault kv get secret/backup-demo/db >/dev/null 2>&1; then
    python3 -c 'import json, secrets; print(json.dumps({"password": secrets.token_urlsafe(24)}))' |
        vault kv put secret/backup-demo/db - >/dev/null
    echo "database password written to Vault: secret/backup-demo/db"
fi

kubectl apply -f "$SCRIPT_DIR/argocd/"
echo -n "waiting for Argo CD to deploy backup-demo"
for i in $(seq 1 90); do
    status=$(kubectl -n argocd get application backup-demo \
        -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)
    [[ $status == Synced/Healthy ]] && { echo " ok"; break; }
    echo -n .; sleep 10
    [[ $i == 90 ]] && { echo; echo "backup-demo is $status; see: kubectl -n argocd describe application backup-demo" >&2; exit 1; }
done
kubectl -n backup-demo rollout status statefulset/postgres --timeout=600s
kubectl -n backup-demo get externalsecret,schedule
