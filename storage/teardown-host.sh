#!/usr/bin/env bash
# Removes the TopoLVM host setup (update-setup-02).
# Usage: sudo storage/teardown-host.sh [--keep-data]
# Without --keep-data the backing file is deleted, which destroys ALL volume data.
set -euo pipefail
: "${BACKING_FILE:=/var/lib/topolvm/backing.img}"
: "${VG:=topolvm-vg}"
[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0" >&2; exit 1; }
keep_data=false
[[ ${1:-} == --keep-data ]] && keep_data=true

systemctl disable --now lvmd.service topolvm-loop.service 2>/dev/null || true
rm -f /etc/systemd/system/lvmd.service /etc/systemd/system/topolvm-loop.service
systemctl daemon-reload

if ! $keep_data; then
    echo "This deletes the volume group $VG and $BACKING_FILE including all volume data."
    read -r -p "Continue? [y/N] " answer
    [[ ${answer,,} == y ]] || { echo "aborted"; exit 1; }
    vgremove -f "$VG" 2>/dev/null || true
    loop=$(losetup -j "$BACKING_FILE" | cut -d: -f1 || true)
    [[ -n ${loop:-} ]] && losetup -d "$loop"
    rm -f "$BACKING_FILE"
else
    vgchange -an "$VG" 2>/dev/null || true
fi

rm -rf /etc/topolvm /opt/sbin/lvmd
rmdir /run/topolvm 2>/dev/null || true
echo "done"
