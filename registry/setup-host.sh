#!/usr/bin/env bash
# Harbor via Docker Compose (update-setup-02).
# Usage: registry/setup-host.sh          (./prepare runs with sudo; it writes as root)
#        HARBOR_ADMIN_PASSWORD=... registry/setup-host.sh
# Harbor's own install.sh is not used: it requires the docker-compose v1 binary.
#
# Privileges: only ./prepare needs root (it runs a privileged container that renders the configs
# and secrets as root, mode 0640). Afterwards the four env files that Compose itself reads are
# made group-readable for the invoking user, so "docker compose" and day-to-day operation
# (up/stop/logs) run unprivileged. File owners stay untouched, because Harbor's processes
# read the same files as uid 10000.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../versions.env"
OUT="$SCRIPT_DIR/out"
: "${HARBOR_HOSTNAME:=harbor.kind.local}"
# 80 and 443 stay free on the host (reserved for the cluster ingress), so Harbor uses
# its own ports. The HTTPS port ends up in the registry name and in every image tag:
# harbor.kind.local:3443/library/... - external_url makes Harbor generate URLs with it.
: "${HARBOR_HTTP_PORT:=3030}"
: "${HARBOR_HTTPS_PORT:=3443}"
HARBOR_URL="https://$HARBOR_HOSTNAME:$HARBOR_HTTPS_PORT"
# Keep the password of an earlier run unless one is given explicitly
if [[ -z ${HARBOR_ADMIN_PASSWORD:-} && -f "$OUT/harbor/harbor.yml" ]]; then
    HARBOR_ADMIN_PASSWORD=$(awk '/^harbor_admin_password:/{print $2}' "$OUT/harbor/harbor.yml")
fi
: "${HARBOR_ADMIN_PASSWORD:=$(openssl rand -base64 18)}"

# Harbor's ports must be free - unless Harbor itself is already listening on them
harbor_running=$(docker ps --filter name=nginx --filter label=com.docker.compose.project=harbor -q 2>/dev/null)
if [[ -z $harbor_running ]]; then
    for p in "$HARBOR_HTTP_PORT" "$HARBOR_HTTPS_PORT"; do
        ss -ltn "sport = :$p" 2>/dev/null | grep -q LISTEN && { echo "port $p is already in use on this host" >&2; exit 1; }
    done
fi

mkdir -p "$OUT/data"
"$SCRIPT_DIR/create-cert.sh"

# Installer (online: the images are pulled on first start)
if [[ ! -d "$OUT/harbor" ]]; then
    curl -fsSL "https://github.com/goharbor/harbor/releases/download/${HARBOR_VERSION}/harbor-online-installer-${HARBOR_VERSION}.tgz" \
        -o "$OUT/harbor-installer.tgz"
    tar -xzf "$OUT/harbor-installer.tgz" -C "$OUT"
fi

# Render Harbor's own template; only these fields differ from its defaults
sed -E \
    -e "s|^hostname: .*|hostname: $HARBOR_HOSTNAME|" \
    -e "s|^  port: 80$|  port: $HARBOR_HTTP_PORT|" \
    -e "s|^  port: 443$|  port: $HARBOR_HTTPS_PORT|" \
    -e "s|^# external_url: .*|external_url: $HARBOR_URL|" \
    -e "s|^  certificate: .*|  certificate: $OUT/harbor-chain.crt|" \
    -e "s|^  private_key: .*|  private_key: $OUT/harbor.key|" \
    -e "s|^harbor_admin_password: .*|harbor_admin_password: $HARBOR_ADMIN_PASSWORD|" \
    -e "s|^data_volume: .*|data_volume: $OUT/data|" \
    "$OUT/harbor/harbor.yml.tmpl" > "$OUT/harbor/harbor.yml"

cd "$OUT/harbor"
# Re-run prepare only when the configuration actually changed (not just its timestamp)
config_hash=$(sha256sum harbor.yml | cut -d' ' -f1)
if [[ ! -f docker-compose.yml || ! -f .harbor.yml.sha256 || $(cat .harbor.yml.sha256) != "$config_hash" ]]; then
    echo "running ./prepare (needs root: privileged container, writes the configs as root)"
    sudo ./prepare              # renders docker-compose.yml, the nginx config and the secrets
    grant_read=true
else
    # Can this user read the env files Compose needs? If not, fix that once.
    grant_read=false
    for f in common/config/*/env; do [[ -r $f ]] || grant_read=true; done
fi

if [[ $grant_read == true ]]; then
    # Compose (running as this user) has to read the env files; the containers read them as
    # their own uid. So keep the owner and only add group read for this user's group.
    echo "granting group read on the env files for $(id -un) (needs root once)"
    sudo chgrp "$(id -g)" common/config/*/env
    sudo chmod g+r common/config/*/env
fi

docker compose up -d
docker compose ps --format '{{.Name}}\t{{.Status}}'

echo
echo "Harbor:   $HARBOR_URL"
echo "User:     admin"
echo "Password: $HARBOR_ADMIN_PASSWORD"
echo "Registry: $HARBOR_HOSTNAME:$HARBOR_HTTPS_PORT   (the port is part of every image tag)"
echo
echo "Next: registry/kind-trust.sh (after every cluster/cluster.sh up)"
echo "Stop:  docker compose -f $OUT/harbor/docker-compose.yml stop"
