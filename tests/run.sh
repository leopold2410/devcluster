#!/usr/bin/env bash
# Browser smoke test for the Keycloak logins in Argo CD and Harbor (update-setup-03).
# Usage: tests/run.sh [playwright args, e.g. --headed or -g "Harbor"]
#
# Runs Playwright in a container on the kind network, with the three host names resolved
# to where they actually live:
#   argocd.kind.local   -> the LoadBalancer IP of the Ingress (cloud-provider-kind)
#   keycloak.kind.local -> the kind bridge gateway, i.e. the host, where Compose publishes
#   harbor.kind.local   -> the same gateway
# No sudo, nothing installed on the host.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../versions.env"
PKI="$SCRIPT_DIR/../pki/out"
IDENTITY="$SCRIPT_DIR/../identity/out"
: "${KEYCLOAK_HOSTNAME:=keycloak.kind.local}"
: "${KEYCLOAK_HTTPS_PORT:=8443}"
: "${KEYCLOAK_REALM:=localdev}"
: "${HARBOR_HOSTNAME:=harbor.kind.local}"
: "${HARBOR_HTTPS_PORT:=3443}"
: "${PLAYWRIGHT_VERSION:?set in ../versions.env}"

[[ -f "$IDENTITY/dev-password" ]] || { echo "missing $IDENTITY/dev-password - run identity/setup-host.sh first" >&2; exit 1; }

ARGOCD_IP=$(kubectl -n argocd get ingress argocd-web -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
[[ -n $ARGOCD_IP ]] || { echo "the argocd-web Ingress has no LoadBalancer IP - is cloud-provider-kind running?" >&2; exit 1; }
HOST_IP=$(docker network inspect kind -f '{{range .IPAM.Config}}{{if .Gateway}}{{.Gateway}} {{end}}{{end}}' |
    tr ' ' '\n' | grep -v ':' | head -1)
[[ -n $HOST_IP ]] || { echo "could not determine the gateway of the kind network" >&2; exit 1; }
# Grafana is optional: its suite runs when monitoring is deployed (update-setup-05).
GRAFANA_IP=$(kubectl -n monitoring get ingress grafana -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
grafana_args=()
if [[ -n $GRAFANA_IP ]]; then
    grafana_args=(--add-host "grafana.kind.local:$GRAFANA_IP" -e GRAFANA_URL=https://grafana.kind.local)
fi
# Vault is optional too: its suite runs once it is set up (update-setup-06).
VAULT_URL=""
vault_args=()
if [[ -s "$SCRIPT_DIR/../vault/out/root-token" ]]; then
    VAULT_URL="https://${VAULT_HOSTNAME:-vault.kind.local}:${VAULT_PORT:-8200}"
    vault_args=(--add-host "${VAULT_HOSTNAME:-vault.kind.local}:$HOST_IP" -e VAULT_URL="$VAULT_URL")
fi

ARGOCD_URL="https://argocd.kind.local"
HARBOR_URL="https://$HARBOR_HOSTNAME:$HARBOR_HTTPS_PORT"
KEYCLOAK_URL="https://$KEYCLOAK_HOSTNAME:$KEYCLOAK_HTTPS_PORT"

# The browser profile in the container does not trust the local CA, so the tests run with
# ignoreHTTPSErrors. Verify the certificates here instead, with the real root CA.
echo "== certificate check (real CA, before the browser ignores them)"
for spec in "argocd.kind.local:443:$ARGOCD_IP|$ARGOCD_URL/" \
            "$KEYCLOAK_HOSTNAME:$KEYCLOAK_HTTPS_PORT:127.0.0.1|$KEYCLOAK_URL/realms/$KEYCLOAK_REALM" \
            "$HARBOR_HOSTNAME:$HARBOR_HTTPS_PORT:127.0.0.1|$HARBOR_URL/api/v2.0/ping"; do
    resolve=${spec%%|*}; url=${spec##*|}
    printf '   %-60s ' "$url"
    curl -fsS -o /dev/null --cacert "$PKI/root-ca.crt" --resolve "$resolve" "$url" && echo OK
done
if [[ -n $GRAFANA_IP ]]; then
    printf '   %-60s ' "https://grafana.kind.local/api/health"
    curl -fsS -o /dev/null --cacert "$PKI/root-ca.crt" --resolve "grafana.kind.local:443:$GRAFANA_IP" \
        https://grafana.kind.local/api/health && echo OK
fi
if [[ -n $VAULT_URL ]]; then
    # sys/health answers 503 while Vault is sealed, so a sealed Vault fails here, not in the browser
    printf '   %-60s ' "$VAULT_URL/v1/sys/health"
    curl -fsS -o /dev/null --cacert "$PKI/root-ca.crt" \
        --resolve "${VAULT_HOSTNAME:-vault.kind.local}:${VAULT_PORT:-8200}:127.0.0.1" \
        "$VAULT_URL/v1/sys/health" && echo OK
fi

echo "== playwright"
docker run --rm --init --network kind \
    --add-host "argocd.kind.local:$ARGOCD_IP" \
    --add-host "$KEYCLOAK_HOSTNAME:$HOST_IP" \
    --add-host "$HARBOR_HOSTNAME:$HOST_IP" \
    "${grafana_args[@]}" \
    "${vault_args[@]}" \
    -e ARGOCD_URL="$ARGOCD_URL" \
    -e HARBOR_URL="$HARBOR_URL" \
    -e KEYCLOAK_REALM="$KEYCLOAK_REALM" \
    -e OIDC_USER="${OIDC_USER:-dev}" \
    -e OIDC_PASSWORD="$(cat "$IDENTITY/dev-password")" \
    -e OIDC_ADMIN_GROUP="${OIDC_ADMIN_GROUP:-platform-admins}" \
    -e CI=1 \
    -v "$SCRIPT_DIR:/work" -w /work \
    --user "$(id -u):$(id -g)" \
    "mcr.microsoft.com/playwright:v${PLAYWRIGHT_VERSION}-noble" \
    sh -c 'node -e "require.resolve(\"@playwright/test\")" 2>/dev/null || npm install --no-save --no-audit --no-fund --silent "@playwright/test@'"$PLAYWRIGHT_VERSION"'"; npx playwright test "$@"' -- "$@"
