#!/usr/bin/env bash
# Harbor via Docker Compose (update-setup-02).
# Usage: registry/setup-host.sh          (as your user, no sudo; also the way to start Harbor
#                                         again after a reboot)
#        HARBOR_ADMIN_PASSWORD=... registry/setup-host.sh
# Harbor's own install.sh is not used: it requires the docker-compose v1 binary.
#
# Privileges: the script runs as the local user and never calls sudo; it needs the docker group
# and nothing else. Root exists only inside containers: ./prepare starts a privileged container
# that renders the configs and secrets as root (mode 0640, owner root or uid 10000). Afterwards
# the env files that Compose itself reads get the invoking user's group and group read - again
# from a container, because only root may change the group of root's files. So "docker compose"
# and day-to-day operation (up/stop/logs) work as the local user. File owners stay untouched,
# because Harbor's processes read the same files as uid 10000.
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
: "${HARBOR_WITH_TRIVY:=true}"
ROOT_CA="$(cd "$SCRIPT_DIR/../pki/out" && pwd)/root-ca.crt"
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

# Render Harbor's own template; only these fields differ from its defaults.
# storage_service.ca_bundle (update-setup-08): prepare empties
# common/config/shared/trust-certificates on every run and refills it only from harbor.yml.
# Every Harbor container mounts that directory as /harbor_cust_cert, and core needs the kind
# root CA there to reach Keycloak - so the CA goes in as the "storage" CA bundle, which prepare
# copies back in as storage_ca_bundle.crt each time. The storage itself stays filesystem.
sed -E \
    -e "s|^# storage_service:$|storage_service:\n  ca_bundle: $ROOT_CA\n  filesystem:\n    maxthreads: 100\n# (Harbor's commented example follows)\n# storage_service:|" \
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
# Trivy is a prepare flag, not a harbor.yml setting (update-setup-08)
prepare_args=()
[[ $HARBOR_WITH_TRIVY == true ]] && prepare_args+=(--with-trivy)
# Re-run prepare only when the configuration or its flags actually changed (not just a timestamp)
config_hash=$( { cat harbor.yml; echo "prepare ${prepare_args[*]}"; } | sha256sum | cut -d' ' -f1)
if [[ ! -f docker-compose.yml || ! -f .harbor.yml.sha256 || $(cat .harbor.yml.sha256) != "$config_hash" ]]; then
    echo "running ./prepare ${prepare_args[*]} (privileged container, writes the configs as root)"
    ./prepare "${prepare_args[@]}"   # renders docker-compose.yml, the nginx config and the secrets
    echo "$config_hash" > .harbor.yml.sha256
    grant_read=true
else
    # Can this user read the env files Compose needs? If not (a prepare run outside this
    # script resets them to root:root 0640), fix that.
    grant_read=false
    for f in common/config/*/env; do [[ -r $f ]] || grant_read=true; done
fi

if [[ $grant_read == true ]]; then
    # Compose (running as this user) has to read the env files; the containers read them as
    # their own uid. So keep the owner and only add group read for this user's group.
    # The prepare image is already there and brings a shell; no --privileged needed for this.
    echo "granting group read on the env files for $(id -un)"
    docker run --rm -v "$PWD/common/config:/config" --entrypoint sh \
        "goharbor/prepare:${HARBOR_VERSION}" -c "chgrp $(id -g) /config/*/env && chmod g+r /config/*/env"
fi

# Also brings Harbor back after a reboot: Docker's "restart: always" fails there, because every
# container logs to harbor-log (syslog on 127.0.0.1:1514) and is started before it listens.
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
