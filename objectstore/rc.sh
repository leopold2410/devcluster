#!/usr/bin/env bash
# RustFS's client "rc", run in a container (update-setup-09).
# Usage: objectstore/rc.sh <rc arguments>     e.g.  objectstore/rc.sh bucket list kind
#
# Nothing is installed on the host. The container runs as this user; its HOME is
# objectstore/out/rc, so the alias "kind" (set by setup-host.sh) is kept between calls.
# Mounted: /work (objectstore/out/work, for policy files) and, when Keycloak is set up,
# /identity (identity/out, read-only, for the OIDC client secret).
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../versions.env"
OUT="$SCRIPT_DIR/out"
IDENTITY="$SCRIPT_DIR/../identity/out"
KIND_GATEWAY=$(sed -n 's/^KIND_GATEWAY=//p' "$SCRIPT_DIR/.env" 2>/dev/null)
[[ -n $KIND_GATEWAY ]] || { echo "missing objectstore/.env - run objectstore/setup-host.sh first" >&2; exit 1; }
mkdir -p "$OUT/rc" "$OUT/work"

identity=(); [[ -d $IDENTITY ]] && identity=(-v "$IDENTITY:/identity:ro")
tty=(); [[ -t 0 && -t 1 ]] && tty=(-t)
exec docker run --rm -i "${tty[@]}" \
    --user "$(id -u):$(id -g)" \
    --add-host "${RUSTFS_HOSTNAME:-s3.kind.local}:$KIND_GATEWAY" \
    -e HOME=/cfg -e SSL_CERT_FILE=/ca.crt \
    -v "$OUT/rc:/cfg" -v "$OUT/work:/work" -v "$OUT/tls/ca.crt:/ca.crt:ro" \
    "${identity[@]}" \
    "rustfs/rc:${RUSTFS_RC_VERSION}" "$@"
