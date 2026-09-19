#!/usr/bin/env bash
# Harbor as a pull-through cache for every registry the cluster pulls from (update-setup-07).
# For each line of registry/mirrors.tsv: a registry endpoint and a public proxy-cache project,
# created through Harbor's API. Idempotent - re-run after changing mirrors.tsv or the Docker Hub
# credentials. The nodes' side is registry/kind-trust.sh.
#
# Optional: registry/out/dockerhub-credentials ("user:access-token", mode 600) lifts Docker Hub's
# anonymous rate limit. It never enters git (registry/out/ is ignored).
# Usage: registry/proxy-cache.sh
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../versions.env"
PKI="$SCRIPT_DIR/../pki/out"
: "${HARBOR_HOSTNAME:=harbor.kind.local}"
: "${HARBOR_HTTPS_PORT:=3443}"
HARBOR_URL="https://$HARBOR_HOSTNAME:$HARBOR_HTTPS_PORT"
API="$HARBOR_URL/api/v2.0"
MIRRORS="$SCRIPT_DIR/mirrors.tsv"
CREDS="$SCRIPT_DIR/out/dockerhub-credentials"
COMPOSE="$SCRIPT_DIR/out/harbor/docker-compose.yml"
PW=$(awk '/^harbor_admin_password:/{print $2}' "$SCRIPT_DIR/out/harbor/harbor.yml")

curl_harbor() {  # the CA and the host resolution in one place
    curl -fsS -u "admin:$PW" --cacert "$PKI/root-ca.crt" \
        --resolve "$HARBOR_HOSTNAME:$HARBOR_HTTPS_PORT:127.0.0.1" "$@"
}
json() { python3 -c "import sys,json; d=json.load(sys.stdin); print($1)"; }

# nginx answers 502 until core is serving; 401 means core is up and the password is wrong.
echo -n "waiting for Harbor"
for i in $(seq 1 40); do
    code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$PW" --cacert "$PKI/root-ca.crt" \
        --resolve "$HARBOR_HOSTNAME:$HARBOR_HTTPS_PORT:127.0.0.1" "$API/ping" || true)
    [[ $code == 200 ]] && { echo " ok"; break; }
    [[ $code == 401 ]] && { echo; echo "Harbor rejected the admin credentials." >&2; exit 1; }
    echo -n .; sleep 3
    [[ $i == 40 ]] && { echo; echo "Harbor is not answering (last HTTP $code); check: docker compose -f $COMPOSE ps" >&2; exit 1; }
done

# The endpoint's JSON; Docker Hub gets the credentials when they exist.
endpoint_body() {  # $1 name  $2 adapter  $3 url
    NAME="$1" TYPE="$2" URL="$3" CREDS_FILE="$CREDS" python3 -c '
import json, os
body = {"name": os.environ["NAME"], "type": os.environ["TYPE"], "url": os.environ["URL"], "insecure": False}
path = os.environ["CREDS_FILE"]
if os.environ["TYPE"] == "docker-hub" and os.path.isfile(path):
    user, token = open(path).read().strip().split(":", 1)
    body["credential"] = {"type": "basic", "access_key": user, "access_secret": token}
print(json.dumps(body))'
}
endpoint_id() {  # $1 name -> id, or empty
    curl_harbor "$API/registries?q=name%3D$1" | json '(d[0]["id"] if d else "")'
}

printf '\n%-16s %-9s %-14s %s\n' "upstream" "endpoint" "project" "proxy of endpoint"
while read -r upstream adapter url project fallback <&3; do
    [[ -z ${upstream:-} || $upstream == \#* ]] && continue

    # 1. Registry endpoint, named after the project
    id=$(endpoint_id "$project")
    if [[ -z $id ]]; then
        curl_harbor -X POST -H 'Content-Type: application/json' \
            -d "$(endpoint_body "$project" "$adapter" "$url")" "$API/registries" >/dev/null
        id=$(endpoint_id "$project")
    elif [[ $adapter == docker-hub && -f $CREDS ]]; then
        # Keeps the Docker Hub credentials current when the file changes.
        curl_harbor -X PUT -H 'Content-Type: application/json' \
            -d "$(endpoint_body "$project" "$adapter" "$url")" "$API/registries/$id" >/dev/null
    fi
    curl_harbor -X POST -H 'Content-Type: application/json' -d "{\"id\": $id}" \
        "$API/registries/ping" >/dev/null

    # 2. Public proxy-cache project on that endpoint
    if ! curl_harbor -o /dev/null "$API/projects/$project" 2>/dev/null; then
        curl_harbor -X POST -H 'Content-Type: application/json' \
            -d "{\"project_name\": \"$project\", \"registry_id\": $id, \"public\": true, \"metadata\": {\"public\": \"true\"}}" \
            "$API/projects" >/dev/null
    fi

    # 3. Report
    status=$(curl_harbor "$API/registries/$id" | json 'd.get("status","?")')
    proxy_of=$(curl_harbor "$API/projects/$project" | json 'd.get("registry_id")')
    printf '%-16s %-9s %-14s %s\n' "$upstream" "$status" "$project" "$proxy_of (endpoint id $id)"
done 3< "$MIRRORS"

# Harbor gives every proxy project a retention rule (keep what was pulled in the last 7 days,
# daily at 00:00 UTC), but that only removes artifacts - their layers stay on disk until garbage
# collection runs, and Harbor schedules none. Weekly, after the retention run; set only when no
# schedule exists, so one chosen in the UI stays. Untagged artifacts are kept (delete_untagged
# would also hit images pushed to "library" by digest).
# Without a schedule, Harbor answers with an empty body.
if [[ $(curl_harbor "$API/system/gc/schedule") != *'"cron"'* ]]; then
    curl_harbor -X POST -H 'Content-Type: application/json' \
        -d '{"schedule": {"type": "Custom", "cron": "0 0 1 * * 0"}, "parameters": {"delete_untagged": false, "workers": 1}}' \
        "$API/system/gc/schedule" >/dev/null
fi
echo "garbage collection: $(curl_harbor "$API/system/gc/schedule" | json 'd["schedule"]["cron"]') (sec min hour dom mon dow, UTC)"

echo
echo "Next: registry/kind-trust.sh   (points the nodes' containerd at these mirrors)"
