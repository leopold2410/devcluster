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

echo "== playwright"
docker run --rm --init --network kind \
    --add-host "argocd.kind.local:$ARGOCD_IP" \
    --add-host "$KEYCLOAK_HOSTNAME:$HOST_IP" \
    --add-host "$HARBOR_HOSTNAME:$HOST_IP" \
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
