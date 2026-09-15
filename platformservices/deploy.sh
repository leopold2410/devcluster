#!/usr/bin/env bash
# Platform services in dependency order (update-setup-01).
# Everything is Kustomize; Helm charts are rendered via helmCharts
# ("kubectl kustomize --enable-helm", needs helm on PATH).
# One render of the whole platform: kubectl kustomize --enable-helm platformservices
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PKI="$SCRIPT_DIR/../cluster/pki/out"
[[ -f "$PKI/issuing-ca.key" ]] || { echo "missing $PKI/issuing-ca.key - run cluster/pki/create-ca.sh first" >&2; exit 1; }

apply() {       # $1 = kustomization directory below platformservices/
    echo "--- platformservices/$1"
    kubectl kustomize --enable-helm "$SCRIPT_DIR/$1" | kubectl apply --server-side --force-conflicts -f -
}
available() {   # $1 = namespace: wait until all its Deployments are available
    kubectl -n "$1" wait deployment --all --for=condition=Available --timeout=300s
}
from_files() {  # "kubectl create secret/configmap ..." -> apply (never in git, never in the render)
    "$@" --dry-run=client -o yaml | kubectl apply -f -
}

# 0. Namespaces and material from the local PKI
kubectl apply -f "$SCRIPT_DIR/cert-manager/namespace.yaml" -f "$SCRIPT_DIR/istio/namespace.yaml"
from_files kubectl -n cert-manager create secret tls kind-issuing-ca \
    --cert="$PKI/issuing-ca-chain.crt" --key="$PKI/issuing-ca.key"
from_files kubectl -n cert-manager create configmap kind-root-ca-source \
    --from-file=ca.crt="$PKI/root-ca.crt"
from_files kubectl -n istio-system create secret generic cacerts \
    --from-file=ca-cert.pem="$PKI/istio-ca.crt" \
    --from-file=ca-key.pem="$PKI/istio-ca.key" \
    --from-file=root-cert.pem="$PKI/root-ca.crt" \
    --from-file=cert-chain.pem="$PKI/istio-ca-chain.crt"

# 1. cert-manager, then trust-manager (its webhook certificate comes from cert-manager)
apply cert-manager;         available cert-manager
apply trust-manager;        available cert-manager
apply cert-manager/config;  kubectl wait clusterissuer/kind-ca --for=condition=Ready --timeout=60s
apply trust-manager/config

# 2. Istio: CRDs + istiod (reads cacerts at startup), then the gateway (needs istiod's injection webhook)
apply istio;                available istio-system
apply istio/gateway;        available istio-system
apply istio/config

# 3. External Secrets Operator
apply external-secrets;     available external-secrets

# 4. Argo CD: one instance for the whole cluster
apply argocd;               available argocd
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
