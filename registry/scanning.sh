#!/usr/bin/env bash
# Harbor scans every image it stores (update-setup-08): Trivy as the default scanner, scan on
# arrival for "library" and every proxy project in registry/mirrors.tsv, and a daily scan of
# everything against the current vulnerability database. Idempotent - re-run after adding a mirror.
# Needs Harbor started with Trivy (HARBOR_WITH_TRIVY=true in versions.env, registry/setup-host.sh).
# Usage: registry/scanning.sh
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../versions.env"
PKI="$SCRIPT_DIR/../pki/out"
: "${HARBOR_HOSTNAME:=harbor.kind.local}"
: "${HARBOR_HTTPS_PORT:=3443}"
: "${HARBOR_WITH_TRIVY:=true}"
API="https://$HARBOR_HOSTNAME:$HARBOR_HTTPS_PORT/api/v2.0"
MIRRORS="$SCRIPT_DIR/mirrors.tsv"
COMPOSE="$SCRIPT_DIR/out/harbor/docker-compose.yml"
PW=$(awk '/^harbor_admin_password:/{print $2}' "$SCRIPT_DIR/out/harbor/harbor.yml")

if [[ $HARBOR_WITH_TRIVY != true ]]; then
    echo "HARBOR_WITH_TRIVY=$HARBOR_WITH_TRIVY: Harbor runs without a scanner, nothing to configure."
    exit 0
fi

curl_harbor() {  # the CA and the host resolution in one place
    curl -fsS -u "admin:$PW" --cacert "$PKI/root-ca.crt" \
        --resolve "$HARBOR_HOSTNAME:$HARBOR_HTTPS_PORT:127.0.0.1" "$@"
}
json() { python3 -c "import sys,json; d=json.load(sys.stdin); print($1)"; }

# 1. The scanner. Core registers Trivy by itself when it starts with WITH_TRIVY; the adapter
# answers its metadata call once it is up.
echo -n "waiting for the Trivy scanner"
id=""
for i in $(seq 1 40); do
    id=$(curl_harbor "$API/scanners" 2>/dev/null | json 'next((s["uuid"] for s in d if s["name"] == "Trivy"), "")' 2>/dev/null || true)
    [[ -n $id ]] && curl_harbor -o /dev/null "$API/scanners/$id/metadata" 2>/dev/null && { echo " ok"; break; }
    echo -n .; sleep 3
    if [[ $i == 40 ]]; then
        echo
        echo "No working Trivy scanner in Harbor. Was prepare run with --with-trivy (registry/setup-host.sh)?" >&2
        echo "Check: docker compose -f $COMPOSE ps trivy-adapter" >&2
        exit 1
    fi
done
if [[ $(curl_harbor "$API/scanners/$id" | json 'd.get("is_default", False)') != True ]]; then
    curl_harbor -X PATCH -H 'Content-Type: application/json' -d '{"is_default": true}' "$API/scanners/$id" >/dev/null
fi

# 2. Scan everything daily at 02:00 UTC - after the retention run (00:00) and the weekly garbage
# collection (Sunday 01:00), so nothing about to be deleted gets scanned. Set only when no
# schedule exists, so one chosen in the UI stays. Without a schedule Harbor answers with an
# empty body or [].
if [[ $(curl_harbor "$API/system/scanAll/schedule") != *'"cron"'* ]]; then
    curl_harbor -X POST -H 'Content-Type: application/json' \
        -d '{"schedule": {"type": "Custom", "cron": "0 0 2 * * *"}}' \
        "$API/system/scanAll/schedule" >/dev/null
fi

# 3. Scan on arrival for our own images and every proxy cache. The update merges metadata keys,
# so "public" and the retention rule stay as they are.
projects=(library)
while read -r upstream adapter url project fallback <&3; do
    [[ -z ${upstream:-} || $upstream == \#* ]] && continue
    projects+=("$project")
done 3< "$MIRRORS"
for p in "${projects[@]}"; do
    curl_harbor -o /dev/null "$API/projects/$p" 2>/dev/null || { echo "  project $p missing - run registry/proxy-cache.sh"; continue; }
    curl_harbor -X PUT -H 'Content-Type: application/json' -d '{"metadata": {"auto_scan": "true"}}' \
        "$API/projects/$p" >/dev/null
done

# 4. Report
echo
curl_harbor "$API/scanners/$id/metadata" | json '"scanner:        %s %s (%s)" % (d["scanner"]["name"], d["scanner"]["version"], d["scanner"]["vendor"])'
echo "scan all:       $(curl_harbor "$API/system/scanAll/schedule" | json 'd["schedule"]["cron"]') (sec min hour dom mon dow, UTC)"
for p in "${projects[@]}"; do
    curl_harbor "$API/projects/$p" 2>/dev/null | json '"  %-14s auto_scan=%s" % (d["name"], d["metadata"].get("auto_scan", "false"))' || true
done
curl_harbor "$API/security/summary" | json '"findings:       %s total - critical %s, high %s, medium %s, low %s; %s of %s artifacts scanned" % (d.get("total_vuls"), d.get("critical_cnt"), d.get("high_cnt"), d.get("medium_cnt"), d.get("low_cnt"), d.get("scanned_cnt"), d.get("total_artifact"))'
