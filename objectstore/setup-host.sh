#!/usr/bin/env bash
# RustFS via Docker Compose: the object store for backups (update-setup-09, ADR-0030).
# Usage: objectstore/setup-host.sh [namespace ...]    - safe to re-run; also the way to start
#                                                       RustFS again
#
# 1. certificate, admin key, .env, container
# 2. the alias "kind" for objectstore/rc.sh
# 3. per namespace (the arguments, plus every namespace of an earlier run): a bucket, a user
#    that may use this bucket only, a restic repository password - and all three in Vault at
#    secret/backup/<namespace>, where the namespace's ExternalSecret reads them
# 4. the Keycloak login for the console, when identity/ is set up
#
# No root needed. The admin key and the bucket keys sit next to the data in out/ - a dev-only
# shortcut, like Vault's unseal key.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT="$SCRIPT_DIR/.."
source "$ROOT/versions.env"
OUT="$SCRIPT_DIR/out"
PKI="$ROOT/pki/out"
: "${RUSTFS_HOSTNAME:=s3.kind.local}"
: "${RUSTFS_PORT:=9000}"
: "${RUSTFS_CONSOLE_PORT:=9001}"
: "${KEYCLOAK_HOSTNAME:=keycloak.kind.local}"
: "${KEYCLOAK_HTTPS_PORT:=8443}"
: "${KEYCLOAK_REALM:=localdev}"
URL="https://$RUSTFS_HOSTNAME:$RUSTFS_PORT"
CONSOLE_URL="https://$RUSTFS_HOSTNAME:$RUSTFS_CONSOLE_PORT/rustfs/console/"

for ns in "$@"; do
    [[ $ns =~ ^[a-z0-9]([-a-z0-9]{1,61}[a-z0-9])$ ]] || { echo "not a usable namespace/bucket name: $ns" >&2; exit 1; }
done

KIND_GATEWAY=$(docker network inspect kind -f '{{range .IPAM.Config}}{{if .Gateway}}{{.Gateway}} {{end}}{{end}}' 2>/dev/null |
    tr ' ' '\n' | grep -v ':' | head -1 || true)
[[ -n $KIND_GATEWAY ]] || { echo "no kind network - RustFS publishes on its gateway for the pods; create the cluster first" >&2; exit 1; }

mkdir -p "$OUT"/{data,logs,tls,admin,keys,rc,work}
chmod 700 "$OUT"
"$SCRIPT_DIR/create-cert.sh"

# Secrets: generated once, kept afterwards. Never in git.
gen() { [[ -s $1 ]] || openssl rand -hex 20 | tr -d '\n' > "$1"; chmod 600 "$1"; }
[[ -s "$OUT/admin/access-key" ]] || { printf 'objectstore-admin' > "$OUT/admin/access-key"; chmod 600 "$OUT/admin/access-key"; }
gen "$OUT/admin/secret-key"

umask 077
cat > "$SCRIPT_DIR/.env" <<EOF
RUSTFS_VERSION=$RUSTFS_VERSION
RUSTFS_HOSTNAME=$RUSTFS_HOSTNAME
RUSTFS_PORT=$RUSTFS_PORT
RUSTFS_CONSOLE_PORT=$RUSTFS_CONSOLE_PORT
KEYCLOAK_HOSTNAME=$KEYCLOAK_HOSTNAME
KEYCLOAK_HTTPS_PORT=$KEYCLOAK_HTTPS_PORT
KIND_GATEWAY=$KIND_GATEWAY
HOST_UID=$(id -u)
HOST_GID=$(id -g)
EOF

cd "$SCRIPT_DIR"
docker compose up -d

echo -n "waiting for RustFS"
for i in $(seq 1 30); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$PKI/root-ca.crt" \
        --resolve "$RUSTFS_HOSTNAME:$RUSTFS_PORT:127.0.0.1" "$URL/health" || true)
    [[ $code == 200 ]] && { echo " ok"; break; }
    echo -n .; sleep 2
    [[ $i == 30 ]] && { echo; echo "RustFS did not answer; see: docker compose -f $SCRIPT_DIR/compose.yaml logs rustfs" >&2; exit 1; }
done

rc() { "$SCRIPT_DIR/rc.sh" "$@" </dev/null; }
rc alias set kind "$URL" "$(cat "$OUT/admin/access-key")" "$(cat "$OUT/admin/secret-key")" >/dev/null

# --- Namespaces: bucket, user, policy, repository password, Vault secret -------------------
touch "$OUT/namespaces"
for ns in "$@"; do grep -qxF "$ns" "$OUT/namespaces" || echo "$ns" >> "$OUT/namespaces"; done

vault_ready=false
if [[ -s "$ROOT/vault/out/root-token" ]] \
   && docker compose -f "$ROOT/vault/compose.yaml" exec -T vault vault status >/dev/null 2>&1; then
    vault_ready=true
fi

while read -r ns; do
    [[ -n $ns ]] || continue
    rc bucket list "kind/$ns" >/dev/null 2>&1 || rc bucket create "kind/$ns" >/dev/null

    # The key may read and write its own bucket and nothing else.
    cat > "$OUT/work/policy-$ns.json" <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["s3:ListBucket","s3:GetBucketLocation"],"Resource":["arn:aws:s3:::$ns"]},
 {"Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:DeleteObject"],"Resource":["arn:aws:s3:::$ns/*"]}]}
EOF
    rc admin policy create kind "backup-$ns" "/work/policy-$ns.json" >/dev/null

    gen "$OUT/keys/$ns.secret"
    # Never regenerated: a restic repository can only be opened with the password it was
    # created with.
    gen "$OUT/keys/$ns.repo"
    rc admin user info kind "$ns" >/dev/null 2>&1 \
        || rc admin user add kind "$ns" "$(cat "$OUT/keys/$ns.secret")" >/dev/null
    rc admin policy attach kind "backup-$ns" --user "$ns" >/dev/null 2>&1 || true

    if $vault_ready; then
        python3 -c 'import json, sys; print(json.dumps({"access-key": sys.argv[1], "secret-key": open(sys.argv[2]).read(), "repo-password": open(sys.argv[3]).read()}))' \
            "$ns" "$OUT/keys/$ns.secret" "$OUT/keys/$ns.repo" |
            docker compose -f "$ROOT/vault/compose.yaml" exec -T -e VAULT_TOKEN="$(cat "$ROOT/vault/out/root-token")" \
                vault vault kv put "secret/backup/$ns" - >/dev/null
        echo "namespace $ns: bucket, key and repository password ready; Vault: secret/backup/$ns"
    else
        echo "namespace $ns: bucket, key and repository password ready; NOT in Vault (not set up or sealed) - re-run after vault/setup-host.sh"
    fi
done < "$OUT/namespaces"

# --- People: the console login through Keycloak ---------------------------------------------
# RustFS takes the names of a user's policies from the token claim "policy". Keycloak fills it
# from the client roles of "rustfs", which the groups platform-admins and platform-users hand
# out (identity/realm/localdev.yaml). The policies need those names and have to be stored ones:
# a claim naming a built-in policy (consoleAdmin, readonly) is rejected with "OIDC policy
# mapping did not resolve to current policies". Someone in neither group cannot log in.
# The local admin key stays for the scripts.
wait_ready() {
    for i in $(seq 1 30); do
        code=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$PKI/root-ca.crt" \
            --resolve "$RUSTFS_HOSTNAME:$RUSTFS_PORT:127.0.0.1" "$URL/health" || true)
        [[ $code == 200 ]] && return 0
        sleep 2
    done
    echo "RustFS did not come back; see: docker compose -f $SCRIPT_DIR/compose.yaml logs rustfs" >&2; exit 1
}
IDENTITY="$ROOT/identity/out"
if [[ -s "$IDENTITY/rustfs-client-secret" ]]; then
    cat > "$OUT/work/policy-platform-admins.json" <<'JSON'
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["admin:*"]},
 {"Effect":"Allow","Action":["kms:*"]},
 {"Effect":"Allow","Action":["s3:*"],"Resource":["arn:aws:s3:::*"]},
 {"Effect":"Allow","Action":["sts:AssumeRole"]}]}
JSON
    cat > "$OUT/work/policy-platform-users.json" <<'JSON'
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["s3:ListAllMyBuckets","s3:ListBucket","s3:GetBucketLocation","s3:GetObject"],"Resource":["arn:aws:s3:::*"]},
 {"Effect":"Allow","Action":["sts:AssumeRole"]}]}
JSON
    rc admin policy create kind platform-admins /work/policy-platform-admins.json >/dev/null
    rc admin policy create kind platform-users /work/policy-platform-users.json >/dev/null

    # The secret is only sent when it is new: replacing it counts as a change and would
    # restart RustFS on every run.
    secret_hash=$(sha256sum < "$IDENTITY/rustfs-client-secret" | cut -d' ' -f1)
    secret_args=()
    if [[ $(cat "$OUT/oidc-secret.sha256" 2>/dev/null) != "$secret_hash" ]]; then
        secret_args=(--client-secret-file /identity/rustfs-client-secret --replace-client-secret)
    fi
    idp=$(rc admin idp openid set kind keycloak \
        --config-url "https://$KEYCLOAK_HOSTNAME:$KEYCLOAK_HTTPS_PORT/realms/$KEYCLOAK_REALM" \
        --client-id rustfs "${secret_args[@]}" \
        --display-name Keycloak \
        --scope openid --scope profile --scope email --scope groups \
        --claim-name policy --groups-claim groups)
    echo "$secret_hash" > "$OUT/oidc-secret.sha256"
    # A new or changed provider only becomes active with a restart.
    active=$(curl -s --cacert "$PKI/root-ca.crt" --resolve "$RUSTFS_HOSTNAME:$RUSTFS_PORT:127.0.0.1" \
        "$URL/rustfs/admin/v3/oidc/providers" || true)
    if grep -q 'Restart required: true' <<<"$idp" || ! grep -q '"keycloak"' <<<"$active"; then
        docker compose restart rustfs >/dev/null 2>&1
        wait_ready
    fi
    echo "console login: Keycloak, realm $KEYCLOAK_REALM (platform-admins: everything, platform-users: read only)"
else
    echo "console login: local admin only ($IDENTITY/rustfs-client-secret missing - run identity/setup-host.sh)"
fi

echo
echo "RustFS:   $URL   (./hosts.sh adds the name)"
echo "Console:  $CONSOLE_URL"
echo "Admin:    $(cat "$OUT/admin/access-key") / $OUT/admin/secret-key"
echo "Client:   objectstore/rc.sh bucket list kind"
echo
echo "Next: ./hosts.sh and cluster/host-services-dns.sh (after every cluster/cluster.sh up)"
