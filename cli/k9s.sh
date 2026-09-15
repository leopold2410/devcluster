#!/usr/bin/env bash
# Start k9s in a container against the kind cluster (update-setup-01).
# Usage: cli/k9s.sh [k9s flags], e.g. cli/k9s.sh -n testapp
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../versions.env"

# Regenerate on every start: a recreated cluster has new certificates.
# --internal: API server https://<cluster>-control-plane:6443, reachable on the "kind" network.
kubeconfig=$("$SCRIPT_DIR/../cluster/kind" get kubeconfig --internal --name "$CLUSTER_NAME")
(umask 077 && printf '%s\n' "$kubeconfig" > "$SCRIPT_DIR/kubeconfig")

HOST_UID=$(id -u)
HOST_GID=$(id -g)
export HOST_UID HOST_GID
# --service-ports: publish the port-forward range (127.0.0.1:18000-18009) to the host
exec docker compose -f "$SCRIPT_DIR/compose.yaml" run --rm --service-ports k9s "$@"
