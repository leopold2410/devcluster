#!/usr/bin/env bash
# Harbor logs in through Keycloak (update-setup-03).
# Harbor's OIDC settings are runtime configuration, not part of harbor.yml, so they are
# set through its API. Run after identity/setup-host.sh.
# Usage: registry/oidc-setup.sh
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../versions.env"
PKI="$SCRIPT_DIR/../pki/out"
IDENTITY="$SCRIPT_DIR/../identity/out"
: "${HARBOR_HOSTNAME:=harbor.kind.local}"
: "${HARBOR_HTTPS_PORT:=3443}"
: "${KEYCLOAK_HOSTNAME:=keycloak.kind.local}"
: "${KEYCLOAK_HTTPS_PORT:=8443}"
: "${KEYCLOAK_REALM:=localdev}"
HARBOR_URL="https://$HARBOR_HOSTNAME:$HARBOR_HTTPS_PORT"
ISSUER="https://$KEYCLOAK_HOSTNAME:$KEYCLOAK_HTTPS_PORT/realms/$KEYCLOAK_REALM"
COMPOSE="$SCRIPT_DIR/out/harbor/docker-compose.yml"
TRUST="$SCRIPT_DIR/out/harbor/common/config/shared/trust-certificates"

[[ -f "$IDENTITY/harbor-client-secret" ]] || { echo "missing $IDENTITY/harbor-client-secret - run identity/setup-host.sh first" >&2; exit 1; }
PW=$(awk '/^harbor_admin_password:/{print $2}' "$SCRIPT_DIR/out/harbor/harbor.yml")

curl_harbor() {  # the CA and the host resolution in one place
    curl -fsS -u "admin:$PW" --cacert "$PKI/root-ca.crt" \
        --resolve "$HARBOR_HOSTNAME:$HARBOR_HTTPS_PORT:127.0.0.1" "$@"
}

# 1. Harbor verifies the issuer's certificate, which comes from the local CA, so the CA has
# to be in Harbor's custom certificate directory (mounted into the containers as
# /harbor_cust_cert). ./prepare created that directory as root, so this one copy needs sudo.
if [[ ! -f "$TRUST/kind-dev-root-ca.crt" ]]; then
    cat >&2 <<EOF
Harbor does not trust the local root CA yet. That is one root-owned copy:

  sudo cp $PKI/root-ca.crt $TRUST/kind-dev-root-ca.crt
  docker compose -f $COMPOSE restart core jobservice proxy

Then run this script again.
EOF
    exit 1
fi

# 2. After a restart, nginx answers 502 until core is serving again. Wait for it,
# otherwise the first API call gets HTML instead of JSON.
echo -n "waiting for Harbor"
for i in $(seq 1 40); do
    code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$PW" --cacert "$PKI/root-ca.crt" \
        --resolve "$HARBOR_HOSTNAME:$HARBOR_HTTPS_PORT:127.0.0.1" \
        "$HARBOR_URL/api/v2.0/ping" || true)
    [[ $code == 200 ]] && { echo " ok"; break; }
    # 401 means core is serving and only the credentials are wrong - waiting will not help.
    if [[ $code == 401 ]]; then
        echo
        echo "Harbor rejected the admin credentials from $SCRIPT_DIR/out/harbor/harbor.yml." >&2
        exit 1
    fi
    echo -n .
    sleep 3
    if [[ $i == 40 ]]; then
        echo
        echo "Harbor is not answering on $HARBOR_URL (last HTTP $code)." >&2
        echo "Check: docker compose -f $COMPOSE ps" >&2
        exit 1
    fi
done

# 3. auth_mode can only be changed while no normal user exists besides admin.
users=$(curl_harbor "$HARBOR_URL/api/v2.0/users" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))')
mode=$(curl_harbor "$HARBOR_URL/api/v2.0/configurations" | python3 -c 'import sys,json; print(json.load(sys.stdin)["auth_mode"]["value"])')
if [[ $mode != oidc_auth && $users -gt 0 ]]; then
    echo "Harbor has $users local users; auth_mode can only be switched while there are none." >&2
    exit 1
fi

# 3. The settings. oidc_auto_onboard creates the Harbor user on first login, and members of
# oidc_admin_group become Harbor administrators.
payload=$(ISSUER="$ISSUER" SECRET="$(cat "$IDENTITY/harbor-client-secret")" python3 -c '
import json, os
print(json.dumps({
    "auth_mode": "oidc_auth",
    "oidc_name": "Keycloak",
    "oidc_endpoint": os.environ["ISSUER"],
    "oidc_client_id": "harbor",
    "oidc_client_secret": os.environ["SECRET"],
    "oidc_scope": "openid,profile,email,groups,offline_access",
    "oidc_groups_claim": "groups",
    "oidc_admin_group": "platform-admins",
    "oidc_user_claim": "preferred_username",
    "oidc_auto_onboard": True,
    "oidc_verify_cert": True,
}))')

curl_harbor -X PUT -H 'Content-Type: application/json' -d "$payload" \
    "$HARBOR_URL/api/v2.0/configurations"

echo "OIDC settings applied:"
curl_harbor "$HARBOR_URL/api/v2.0/configurations" | python3 -c '
import sys, json
d = json.load(sys.stdin)
keys = ("auth_mode", "oidc_name", "oidc_endpoint", "oidc_client_id", "oidc_groups_claim",
        "oidc_admin_group", "oidc_auto_onboard", "oidc_user_claim", "oidc_verify_cert")
for k in keys:
    print("  %s: %s" % (k, d[k]["value"]))'

echo
echo "Log in at $HARBOR_URL - the button reads \"LOGIN VIA Keycloak\"."
echo "The local admin stays reachable at $HARBOR_URL/account/sign-in?always_sso_login=false"
