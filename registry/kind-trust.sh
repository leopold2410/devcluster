#!/usr/bin/env bash
# Teach the kind nodes about harbor.kind.local (update-setup-02) and use Harbor as a mirror for
# the upstream registries in registry/mirrors.tsv (update-setup-07).
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

# Mirrors (update-setup-07): only upstreams whose proxy project exists in Harbor get one, so a
# Harbor without them sends no pull on a detour. The projects are public, so this asks
# anonymously; Harbor answers 401 rather than 404 for a project it does not have.
MIRRORS="$SCRIPT_DIR/mirrors.tsv"
active=() stale=()
if [[ -f $MIRRORS ]]; then
    while read -r upstream adapter url project fallback <&3; do
        [[ -z ${upstream:-} || $upstream == \#* ]] && continue
        if curl -fsS -o /dev/null --cacert "$CA" --resolve "$REGISTRY_HOST:127.0.0.1" \
               "https://$REGISTRY_HOST/api/v2.0/projects/$project" 2>/dev/null; then
            active+=("$upstream $project $fallback")
        else
            stale+=("$upstream")
        fi
    done 3< "$MIRRORS"
fi

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

    # Harbor as a mirror: image names stay unchanged, override_path keeps the proxy project in
    # the path, and "server" - the original registry - is the fallback when Harbor fails.
    # containerd reads certs.d on every pull, so no restart is needed.
    for m in "${active[@]}"; do
        read -r upstream project fallback <<<"$m"
        docker exec "$node" mkdir -p "/etc/containerd/certs.d/$upstream"
        docker exec "$node" sh -c "cat > '/etc/containerd/certs.d/$upstream/hosts.toml' <<EOF
# Harbor proxy cache \"$project\" (update-setup-07); server is the fallback.
server = \"$fallback\"

[host.\"https://$REGISTRY_HOST/v2/$project\"]
  capabilities = [\"pull\", \"resolve\"]
  ca = \"/etc/containerd/certs.d/$REGISTRY_HOST/ca.crt\"
  override_path = true
EOF"
    done
    for upstream in "${stale[@]}"; do
        docker exec "$node" rm -rf "/etc/containerd/certs.d/$upstream"
    done
    echo "  $node configured, mirrors: ${#active[@]}"
done
