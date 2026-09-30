#!/usr/bin/env bash
# Backup or restore on request, through Argo CD (update-setup-09).
# Usage: applications/backup-demo/sync.sh backup | restore
#
# Does what the Sync button of the application "backup-demo-backup" or "backup-demo-restore"
# does in the Argo CD UI, or "argocd app sync": it starts a sync, whose hook creates the K8up
# Backup or runs the restore Job. Then it waits for the result.
set -euo pipefail
what=${1:-}
[[ $what == backup || $what == restore ]] || { echo "usage: $0 backup | restore" >&2; exit 1; }
app="backup-demo-$what"

kubectl -n argocd patch application "$app" --type merge \
    -p '{"operation":{"initiatedBy":{"username":"sync.sh"},"sync":{"syncStrategy":{"hook":{}}}}}' >/dev/null
echo -n "syncing $app"
for i in $(seq 1 90); do
    phase=$(kubectl -n argocd get application "$app" -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)
    [[ $phase == Succeeded ]] && { echo " ok"; break; }
    [[ $phase == Failed || $phase == Error ]] && {
        echo; kubectl -n argocd get application "$app" -o jsonpath='{.status.operationState.message}{"\n"}' >&2; exit 1; }
    echo -n .; sleep 5
    [[ $i == 90 ]] && { echo; echo "$app is still $phase" >&2; exit 1; }
done

if [[ $what == backup ]]; then
    # Argo CD is done once the Backup exists; K8up then runs it.
    kubectl -n backup-demo wait backup/on-request --for=condition=Completed --timeout=600s >/dev/null
    kubectl -n backup-demo get backup on-request
    kubectl -n backup-demo get snapshots \
        -o custom-columns='SNAPSHOT:.metadata.name,DATE:.spec.date,PATHS:.spec.paths' --sort-by=.spec.date
else
    kubectl -n backup-demo logs job/restore-db --all-containers | tail -3
fi
