#!/usr/bin/env bash
# Teach the kind nodes about harbor.kind.local (update-setup-02).
# Run after every cluster/cluster.sh up: /etc/hosts entry, containerd registry config and CA
# live inside the node containers.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../versions.env"
KIND="$SCRIPT_DIR/../cluster/kind"
CA="$SCRIPT_DIR/../cluster/pki/out/root-ca.crt"
: "${HARBOR_HOSTNAME:=harbor.kind.local}"
[[ -f "$CA" ]] || { echo "missing $CA - run cluster/pki/create-ca.sh first" >&2; exit 1; }

# The host's address on the kind network
HOST_IP=$(docker network inspect kind -f '{{range .IPAM.Config}}{{if .Gateway}}{{.Gateway}} {{end}}{{end}}' | tr ' ' '\n' | grep -v ':' | head -1)
[[ -n $HOST_IP ]] || { echo "could not determine the gateway of the kind network" >&2; exit 1; }
echo "$HARBOR_HOSTNAME -> $HOST_IP"

for node in $("$KIND" get nodes --name "$CLUSTER_NAME"); do
    docker exec "$node" sh -c "grep -q ' $HARBOR_HOSTNAME\$' /etc/hosts || echo '$HOST_IP $HARBOR_HOSTNAME' >> /etc/hosts"
    docker exec "$node" mkdir -p "/etc/containerd/certs.d/$HARBOR_HOSTNAME"
    docker cp "$CA" "$node:/etc/containerd/certs.d/$HARBOR_HOSTNAME/ca.crt"
    docker exec "$node" sh -c "cat > /etc/containerd/certs.d/$HARBOR_HOSTNAME/hosts.toml <<EOF
server = \"https://$HARBOR_HOSTNAME\"

[host.\"https://$HARBOR_HOSTNAME\"]
  capabilities = [\"pull\", \"resolve\"]
  ca = \"/etc/containerd/certs.d/$HARBOR_HOSTNAME/ca.crt\"
EOF"
    echo "  $node configured"
done
