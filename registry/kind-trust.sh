#!/usr/bin/env bash
# Teach the kind nodes about harbor.kind.local (update-setup-02).
# Run after every cluster/cluster.sh up: /etc/hosts entry, containerd registry config and CA
# live inside the node containers.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../versions.env"
KIND="$SCRIPT_DIR/../cluster/kind"
CA="$SCRIPT_DIR/../pki/out/root-ca.crt"
: "${HARBOR_HOSTNAME:=harbor.kind.local}"
: "${HARBOR_HTTPS_PORT:=3443}"
# Harbor listens on a non-default port, so the port is part of the registry name:
# images are "harbor.kind.local:3443/library/...", and containerd looks the config
# up under that same name.
REGISTRY_HOST="$HARBOR_HOSTNAME:$HARBOR_HTTPS_PORT"
[[ -f "$CA" ]] || { echo "missing $CA - run pki/create-ca.sh first" >&2; exit 1; }

# The host's address on the kind network
HOST_IP=$(docker network inspect kind -f '{{range .IPAM.Config}}{{if .Gateway}}{{.Gateway}} {{end}}{{end}}' | tr ' ' '\n' | grep -v ':' | head -1)
[[ -n $HOST_IP ]] || { echo "could not determine the gateway of the kind network" >&2; exit 1; }
echo "$REGISTRY_HOST -> $HOST_IP"

for node in $("$KIND" get nodes --name "$CLUSTER_NAME"); do
    docker exec "$node" sh -c "grep -q ' $HARBOR_HOSTNAME\$' /etc/hosts || echo '$HOST_IP $HARBOR_HOSTNAME' >> /etc/hosts"
    docker exec "$node" mkdir -p "/etc/containerd/certs.d/$REGISTRY_HOST"
    docker cp "$CA" "$node:/etc/containerd/certs.d/$REGISTRY_HOST/ca.crt"
    docker exec "$node" sh -c "cat > '/etc/containerd/certs.d/$REGISTRY_HOST/hosts.toml' <<EOF
server = \"https://$REGISTRY_HOST\"

[host.\"https://$REGISTRY_HOST\"]
  capabilities = [\"pull\", \"resolve\"]
  ca = \"/etc/containerd/certs.d/$REGISTRY_HOST/ca.crt\"
EOF"
    # Leftover from the days when Harbor was on 443: containerd would otherwise keep
    # honouring the portless registry name.
    docker exec "$node" rm -rf "/etc/containerd/certs.d/$HARBOR_HOSTNAME"
    echo "  $node configured"
done
