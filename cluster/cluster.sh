#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR="$SCRIPT_DIR/.."
source "$ROOT_DIR/versions.env"
KIND="$SCRIPT_DIR/kind"
CPK_CONTAINER=cloud-provider-kind

up() {
    "$KIND" create cluster --config "$SCRIPT_DIR/cluster-config.yaml" \
        --name "$CLUSTER_NAME" --image "$KIND_NODE_IMAGE"
    kubectl config use-context "kind-$CLUSTER_NAME"
    kubectl wait --for=condition=Ready nodes --all --timeout=180s

    # Gateway API CRDs must exist before cloud-provider-kind starts:
    # it only creates missing CRDs and never updates them.
    kubectl apply --server-side -f \
        "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

    cpk_start

    # Kubeconfig for the k9s container (cli/): API server via the "kind" network
    (umask 077 && "$KIND" get kubeconfig --internal --name "$CLUSTER_NAME" > "$ROOT_DIR/cli/kubeconfig")
}

cpk_start() {
    docker rm -f "$CPK_CONTAINER" >/dev/null 2>&1 || true
    docker run -d --name "$CPK_CONTAINER" --restart unless-stopped --network host \
        -v /var/run/docker.sock:/var/run/docker.sock \
        "registry.k8s.io/cloud-provider-kind/cloud-controller-manager:${CPK_VERSION}"
}

down() {
    docker rm -f "$CPK_CONTAINER" >/dev/null 2>&1 || true
    "$KIND" delete cluster --name "$CLUSTER_NAME"
    # Load balancer / gateway containers created by cloud-provider-kind
    docker ps -aq --filter "name=kindccm" | xargs -r docker rm -f
    rm -f "$ROOT_DIR/cli/kubeconfig"
}

case "${1:-up}" in
    up)   up ;;
    down) down ;;
    cpk)  cpk_start ;;
    *)    echo "usage: $0 [up|down|cpk]" >&2; exit 1 ;;
esac
