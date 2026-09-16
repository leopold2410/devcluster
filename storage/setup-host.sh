#!/usr/bin/env bash
# Host setup for TopoLVM (update-setup-02): LVM volume group on a loop-backed file + lvmd.
# Usage: sudo storage/setup-host.sh
# Re-runnable: existing file, loop device, volume group and binary are kept.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../versions.env"
: "${BACKING_FILE:=/var/lib/topolvm/backing.img}"
: "${BACKING_SIZE:=60G}"
: "${VG:=topolvm-vg}"
[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0" >&2; exit 1; }

# 1. LVM tools
command -v vgcreate >/dev/null || { apt-get update && apt-get install -y lvm2; }

# 2. Sparse backing file
mkdir -p "$(dirname "$BACKING_FILE")"
[[ -f $BACKING_FILE ]] || truncate -s "$BACKING_SIZE" "$BACKING_FILE"

# 3. Loop device
loop=$(losetup -j "$BACKING_FILE" | cut -d: -f1)
[[ -n $loop ]] || loop=$(losetup --find --show "$BACKING_FILE")
echo "loop device: $loop"

# 4. Physical volume + volume group
pvs --noheadings -o pv_name 2>/dev/null | grep -qw "$loop" || pvcreate -y "$loop"
vgs --noheadings -o vg_name 2>/dev/null | grep -qw "$VG"   || vgcreate "$VG" "$loop"
vgs "$VG"

# 5. lvmd binary (release asset contains only the binary; no checksum is published)
install -d /opt/sbin /etc/topolvm /run/topolvm
if [[ ! -x /opt/sbin/lvmd ]]; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    curl -fsSL "https://github.com/topolvm/topolvm/releases/download/${TOPOLVM_VERSION}/lvmd-${TOPOLVM_VERSION#v}.tar.gz" \
        -o "$tmp/lvmd.tar.gz"
    tar -xzf "$tmp/lvmd.tar.gz" -C "$tmp" lvmd
    install -m 0755 "$tmp/lvmd" /opt/sbin/lvmd
fi

# 6. Config and systemd units
install -m 0644 "$SCRIPT_DIR/lvmd.yaml" /etc/topolvm/lvmd.yaml
install -m 0644 "$SCRIPT_DIR/systemd/topolvm-loop.service" /etc/systemd/system/topolvm-loop.service
install -m 0644 "$SCRIPT_DIR/systemd/lvmd.service" /etc/systemd/system/lvmd.service
systemctl daemon-reload
systemctl enable --now topolvm-loop.service lvmd.service
systemctl --no-pager --lines=5 status lvmd.service || true
ls -l /run/topolvm/lvmd.sock
echo
echo "Done. The kind cluster needs /dev and /run/topolvm as extraMounts (cluster/cluster-config.yaml)."
