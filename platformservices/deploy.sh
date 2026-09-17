#!/usr/bin/env bash
# Platform services in dependency order (update-setup-01).
# Everything is Kustomize; Helm charts are rendered via helmCharts
# ("kubectl kustomize --enable-helm", needs helm on PATH).
# One render of the whole platform: kubectl kustomize --enable-helm platformservices
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PKI="$SCRIPT_DIR/../pki/out"
[[ -f "$PKI/issuing-ca.key" ]] || { echo "missing $PKI/issuing-ca.key - run pki/create-ca.sh first" >&2; exit 1; }

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

# 2. TopoLVM (lvmd runs on the host, see storage/); its webhook certificate comes from cert-manager
[[ -S /run/topolvm/lvmd.sock ]] || { echo "missing /run/topolvm/lvmd.sock - run 'sudo storage/setup-host.sh' first" >&2; exit 1; }
apply topolvm;              available topolvm-system
# TopoLVM becomes the default StorageClass; kind's local-path stays available
kubectl annotate storageclass standard storageclass.kubernetes.io/is-default-class=false --overwrite

# 3. Istio: CRDs + istiod (reads cacerts at startup), then the gateway (needs istiod's injection webhook)
apply istio;                available istio-system
apply istio/gateway;        available istio-system
apply istio/config

# 3. External Secrets Operator
apply external-secrets;     available external-secrets

# 4. Argo CD: one instance for the whole cluster
apply argocd;               available argocd
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

# 5. Keycloak as Argo CD's identity provider (update-setup-03), when identity/ is set up.
# Not part of the Kustomize render: the client secret lives in identity/out/ and the root CA
# in pki/out/, neither of which is in git.
IDENTITY="$SCRIPT_DIR/../identity/out"
if [[ -f "$IDENTITY/argocd-client-secret" ]]; then
    echo "--- argocd: Keycloak OIDC"
    source "$SCRIPT_DIR/../versions.env"
    kubectl -n argocd patch secret argocd-secret --type merge \
        -p "{\"stringData\":{\"oidc.keycloak.clientSecret\":\"$(cat "$IDENTITY/argocd-client-secret")\"}}" >/dev/null
    # rootCA lets Argo CD verify the issuer against the local root, instead of skipping verification
    patch=$(CA="$(cat "$PKI/root-ca.crt")" \
            ISSUER="https://${KEYCLOAK_HOSTNAME}:${KEYCLOAK_HTTPS_PORT}/realms/${KEYCLOAK_REALM}" \
            python3 -c '
import json, os
ca = "\n".join("  " + line for line in os.environ["CA"].splitlines())
issuer = os.environ["ISSUER"]
oidc = (
    "name: Keycloak\n"
    "issuer: " + issuer + "\n"
    "clientID: argocd\n"
    "clientSecret: $oidc.keycloak.clientSecret\n"
    "cliClientID: argocd\n"
    "requestedScopes: [\"openid\", \"profile\", \"email\", \"groups\"]\n"
    "rootCA: |\n" + ca + "\n"
)
print(json.dumps({"data": {"url": "https://argocd.kind.local", "oidc.config": oidc}}))')
    kubectl -n argocd patch configmap argocd-cm --type merge -p "$patch" >/dev/null
    kubectl -n argocd rollout restart deployment/argocd-server
    kubectl -n argocd rollout status deployment/argocd-server --timeout=180s
else
    echo "--- argocd: identity/out/argocd-client-secret missing, skipping the Keycloak wiring"
fi
