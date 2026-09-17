#!/usr/bin/env bash
# Teach the cluster about keycloak.kind.local (update-setup-03).
# Argo CD resolves the OIDC issuer through CoreDNS, and the name lives on the host,
# so CoreDNS gets a hosts block pointing at the kind bridge gateway.
# Run after every cluster/cluster.sh up, like registry/kind-trust.sh.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../versions.env"
: "${KEYCLOAK_HOSTNAME:=keycloak.kind.local}"

HOST_IP=$(docker network inspect kind -f '{{range .IPAM.Config}}{{if .Gateway}}{{.Gateway}} {{end}}{{end}}' | tr ' ' '\n' | grep -v ':' | head -1)
[[ -n $HOST_IP ]] || { echo "could not determine the gateway of the kind network" >&2; exit 1; }

current=$(kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}')
if grep -q "$KEYCLOAK_HOSTNAME" <<<"$current"; then
    echo "CoreDNS already resolves $KEYCLOAK_HOSTNAME"
    exit 0
fi

# Insert a hosts block before the kubernetes plugin, so cluster names keep priority
# and everything else still falls through to the upstream forwarder.
updated=$(HOST_IP="$HOST_IP" NAME="$KEYCLOAK_HOSTNAME" COREFILE="$current" python3 -c '
import os, sys
corefile = os.environ["COREFILE"]
block = "    hosts {\n        %s %s\n        fallthrough\n    }\n" % (os.environ["HOST_IP"], os.environ["NAME"])
marker = "    kubernetes "
i = corefile.index(marker)
sys.stdout.write(corefile[:i] + block + corefile[i:])
')

kubectl -n kube-system create configmap coredns --from-literal=Corefile="$updated" \
    --dry-run=client -o yaml | kubectl apply -f -
kubectl -n kube-system rollout restart deployment/coredns
kubectl -n kube-system rollout status deployment/coredns --timeout=120s
echo "$KEYCLOAK_HOSTNAME -> $HOST_IP (CoreDNS)"
