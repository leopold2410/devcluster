#!/usr/bin/env bash
# Teach the cluster the names of the host-side services (update-setup-03, -06).
# Keycloak and Vault run in Docker Compose on the host; pods reach them at the kind bridge
# gateway, so CoreDNS gets a hosts block mapping their names there. Each service is listed
# once it is set up (its out/ directory exists).
# Run after every cluster/cluster.sh up - the Corefile is part of the cluster.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT="$SCRIPT_DIR/.."
source "$ROOT/versions.env"

HOST_IP=$(docker network inspect kind -f '{{range .IPAM.Config}}{{if .Gateway}}{{.Gateway}} {{end}}{{end}}' |
    tr ' ' '\n' | grep -v ':' | head -1)
[[ -n $HOST_IP ]] || { echo "could not determine the gateway of the kind network" >&2; exit 1; }

names=()
[[ -d "$ROOT/identity/out" ]] && names+=("${KEYCLOAK_HOSTNAME:-keycloak.kind.local}")
[[ -d "$ROOT/vault/out" ]]    && names+=("${VAULT_HOSTNAME:-vault.kind.local}")
if [[ ${#names[@]} == 0 ]]; then
    echo "no host-side services set up - nothing to add"
    exit 0
fi

current=$(kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}')

# Replace the managed hosts block (or the unmarked one an earlier version of this script
# wrote), or insert it before the kubernetes plugin, so cluster names keep priority and
# everything else still falls through to the upstream forwarder.
updated=$(HOST_IP="$HOST_IP" NAMES="${names[*]}" COREFILE="$current" python3 -c '
import os, re, sys
corefile = os.environ["COREFILE"]
lines = "".join("        %s %s\n" % (os.environ["HOST_IP"], n) for n in os.environ["NAMES"].split())
block = ("    # host-side services, managed by cluster/host-services-dns.sh\n"
         "    hosts {\n" + lines + "        fallthrough\n    }\n")
pattern = re.compile(r"(    # host-side services[^\n]*\n)?    hosts \{\n.*?\n    \}\n", re.S)
if pattern.search(corefile):
    corefile = pattern.sub(lambda m: block, corefile, count=1)
else:
    i = corefile.index("    kubernetes ")
    corefile = corefile[:i] + block + corefile[i:]
sys.stdout.write(corefile)
')

if [[ $updated == "$current" ]]; then
    echo "CoreDNS already resolves: ${names[*]} -> $HOST_IP"
    exit 0
fi

kubectl -n kube-system create configmap coredns --from-literal=Corefile="$updated" \
    --dry-run=client -o yaml | kubectl apply -f -
kubectl -n kube-system rollout restart deployment/coredns
kubectl -n kube-system rollout status deployment/coredns --timeout=120s
echo "CoreDNS resolves: ${names[*]} -> $HOST_IP"
