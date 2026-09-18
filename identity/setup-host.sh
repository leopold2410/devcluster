#!/usr/bin/env bash
# Keycloak + PostgreSQL via Docker Compose, realm applied declaratively (update-setup-03).
# Usage: identity/setup-host.sh
#
# Privileges: none. Everything here runs as your user; only the /etc/hosts entry for
# keycloak.kind.local needs root, and that is left to you (./hosts.sh or a manual line).
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../versions.env"
OUT="$SCRIPT_DIR/out"
PKI="$SCRIPT_DIR/../pki/out"
: "${KEYCLOAK_HOSTNAME:=keycloak.kind.local}"
: "${KEYCLOAK_HTTPS_PORT:=8443}"
: "${KEYCLOAK_REALM:=localdev}"
URL="https://$KEYCLOAK_HOSTNAME:$KEYCLOAK_HTTPS_PORT"

mkdir -p "$OUT/data/postgres" "$OUT/tls"

# Secrets: generated once, kept afterwards. Never in git.
gen() { [[ -s "$OUT/$1" ]] || openssl rand -base64 24 | tr -d '\n' > "$OUT/$1"; chmod 600 "$OUT/$1"; }
gen db-password
gen admin-password
gen argocd-client-secret
gen harbor-client-secret
gen grafana-client-secret
gen grafana-admin-password     # Grafana's local admin, the break-glass account (update-setup-05)
gen vault-client-secret        # update-setup-06
gen dev-password

"$SCRIPT_DIR/create-cert.sh"

# .env for Compose: the pinned versions plus the two secrets the containers need.
# Written with 600 because it contains passwords; git-ignored.
{
    grep -E '^(KEYCLOAK_VERSION|KEYCLOAK_HOSTNAME|KEYCLOAK_HTTPS_PORT|KEYCLOAK_REALM|KEYCLOAK_CONFIG_CLI_VERSION)=' "$SCRIPT_DIR/../versions.env"
    echo "POSTGRES_PASSWORD=$(cat "$OUT/db-password")"
    echo "KEYCLOAK_ADMIN_PASSWORD=$(cat "$OUT/admin-password")"
} > "$SCRIPT_DIR/.env"
chmod 600 "$SCRIPT_DIR/.env"

cd "$SCRIPT_DIR"
docker compose up -d

# Wait for Keycloak to answer over TLS. The first start builds the server, which takes a while.
echo -n "waiting for Keycloak"
for i in $(seq 1 60); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$PKI/root-ca.crt" \
        --resolve "$KEYCLOAK_HOSTNAME:$KEYCLOAK_HTTPS_PORT:127.0.0.1" \
        "$URL/realms/master" || true)
    [[ $code == 200 ]] && { echo " ok"; break; }
    echo -n .; sleep 3
    [[ $i == 60 ]] && { echo; echo "Keycloak did not become ready; see: docker compose -f $SCRIPT_DIR/compose.yaml logs keycloak" >&2; exit 1; }
done

# Realm as code. keycloak-config-cli applies the file to an existing realm as well,
# so this is idempotent - unlike Keycloak's own --import-realm, which only ever creates.
# SSL verification is off for this call alone: it goes to the container's own name
# inside the Compose network, which the certificate (keycloak.kind.local) does not cover.
docker run --rm --network identity_default \
    -e KEYCLOAK_URL="https://keycloak:$KEYCLOAK_HTTPS_PORT" \
    -e KEYCLOAK_USER=admin \
    -e KEYCLOAK_PASSWORD="$(cat "$OUT/admin-password")" \
    -e KEYCLOAK_AVAILABILITYCHECK_ENABLED=true \
    -e KEYCLOAK_SSLVERIFY=false \
    -e IMPORT_FILES_LOCATIONS='/config/*.yaml' \
    -e IMPORT_VARSUBSTITUTION_ENABLED=true \
    -e ARGOCD_CLIENT_SECRET="$(cat "$OUT/argocd-client-secret")" \
    -e HARBOR_CLIENT_SECRET="$(cat "$OUT/harbor-client-secret")" \
    -e GRAFANA_CLIENT_SECRET="$(cat "$OUT/grafana-client-secret")" \
    -e VAULT_CLIENT_SECRET="$(cat "$OUT/vault-client-secret")" \
    -e DEV_USER_PASSWORD="$(cat "$OUT/dev-password")" \
    -v "$SCRIPT_DIR/realm:/config:ro" \
    "adorsys/keycloak-config-cli:${KEYCLOAK_CONFIG_CLI_VERSION}"

echo
echo "Keycloak:  $URL   (add '127.0.0.1 $KEYCLOAK_HOSTNAME' to /etc/hosts)"
echo "Admin:     admin / $(cat "$OUT/admin-password")"
echo "Realm:     $KEYCLOAK_REALM   user: dev / $(cat "$OUT/dev-password")"
echo
echo "Next: cluster/host-services-dns.sh   (after every cluster/cluster.sh up, so pods resolve $KEYCLOAK_HOSTNAME)"
echo "Stop:  docker compose -f $SCRIPT_DIR/compose.yaml stop"
