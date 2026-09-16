#!/usr/bin/env bash
# Add the kind cluster's Ingress host names (*.kind.local) to /etc/hosts.
# The entries live in a marked block that is rewritten on every run, so changed
# LoadBalancer IPs (e.g. after recreating the cluster) are picked up. Uses sudo only
# when the file actually changes. Entries outside the block are never touched.
#
# Usage: ./hosts.sh [--istio] [--dry-run] [--remove]
#   --istio    hosts with a vanilla and an Istio Ingress get the Istio gateway IP
#              (default: the cloud-provider-kind IP)
#   --dry-run  only show what would change
#   --remove   remove the block again
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/versions.env"
HOSTS_FILE=${HOSTS_FILE:-/etc/hosts}
BEGIN_MARK="# BEGIN kind-$CLUSTER_NAME ingress hosts (managed by hosts.sh)"
END_MARK="# END kind-$CLUSTER_NAME ingress hosts"

prefer=cloud-provider-kind dry_run=false remove=false
for arg in "$@"; do
    case $arg in
        --istio)   prefer=istio ;;
        --dry-run) dry_run=true ;;
        --remove)  remove=true ;;
        *) echo "usage: $0 [--istio] [--dry-run] [--remove]" >&2; exit 1 ;;
    esac
done

# The hosts file without our block
outside=$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" '$0 == b {skip = 1; next} $0 == e {skip = 0; next} !skip' "$HOSTS_FILE")

block=""
if ! $remove; then
    # "ip host" for every *.kind.local Ingress host; the preferred class wins if a host has several Ingresses
    entries=$(kubectl --context "kind-$CLUSTER_NAME" get ingress -A -o jsonpath='{range .items[*]}{.spec.ingressClassName}{"\t"}{.status.loadBalancer.ingress[0].ip}{"\t"}{range .spec.rules[*]}{.host}{" "}{end}{"\n"}{end}' |
        awk -F'\t' -v prefer="$prefer" '
            {
                n = split($3, hosts, " ")
                for (i = 1; i <= n; i++) {
                    h = hosts[i]
                    if (h !~ /\.kind\.local$/) continue
                    if ($2 == "") { pending[h] = 1; continue }
                    if (!(h in ip) || $1 == prefer) ip[h] = $2
                }
            }
            END {
                for (h in pending) if (!(h in ip)) print "note: " h " has no LoadBalancer IP yet" > "/dev/stderr"
                for (h in ip) print ip[h], h
            }' | sort -k2)

    while read -r ip host; do
        [[ -n $host ]] || continue
        # Already defined outside the block (e.g. by hand)? Leave it alone.
        existing=$(awk -v h="$host" '!/^[[:space:]]*#/ { for (i = 2; i <= NF; i++) if ($i == h) { print $1; exit } }' <<<"$outside")
        if [[ -n $existing ]]; then
            [[ $existing == "$ip" ]] || echo "warning: $host is already in $HOSTS_FILE with $existing, the cluster has $ip - fix that line by hand" >&2
            continue
        fi
        block+="$ip $host"$'\n'
    done <<<"$entries"
fi

if [[ -z $block ]] && ! grep -qxF "$BEGIN_MARK" "$HOSTS_FILE"; then
    echo "nothing to add to $HOSTS_FILE"
    exit 0
fi

new=$outside
[[ -z $block ]] || new+=$'\n\n'"$BEGIN_MARK"$'\n'"$block$END_MARK"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
printf '%s\n' "$new" > "$tmp"

if cmp -s "$tmp" "$HOSTS_FILE"; then
    echo "$HOSTS_FILE is up to date"
    exit 0
fi
diff -u "$HOSTS_FILE" "$tmp" || true    # diff exits 1 when the files differ
$dry_run && exit 0

# tee keeps owner and permissions of the existing file
if [[ -w $HOSTS_FILE ]]; then
    cat "$tmp" > "$HOSTS_FILE"
else
    sudo tee "$HOSTS_FILE" < "$tmp" > /dev/null
fi
echo "updated $HOSTS_FILE"
