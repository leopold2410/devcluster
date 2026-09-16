# Update setup 02: TopoLVM node volumes and Harbor as local registry

| | |
| --- | --- |
| Date | 2026-09-16 |
| Status | **Applied and verified on 2026-09-16.** TopoLVM: PVC bound, XFS, data read back, logical volume visible on the host, online expansion 1 → 3 GiB including the filesystem in the pod. Harbor: nine containers healthy, TLS from the local CA, image pushed, pulled from the cluster in 199 ms with a cleared node cache. See *Implementation notes* for the deviations |
| Scope | `/home/leo/dev/kind`, builds on [`update-setup-01.md`](update-setup-01.md) (applied 2026-09-15) |

## Goals

1. **Node-local block storage with [TopoLVM](https://github.com/topolvm/topolvm).**
   Volumes are LVM logical volumes on the host, which is what Kafka/Strimzi and
   databases want. `lvmd` runs on the host as a systemd unit; the kind nodes
   reach its socket and the LVM devices through **`extraMounts` in the kind
   config**.
2. **A loop-backed volume group,** so no real disk or partition is needed.
3. **A new folder `storage/`** for the host-side setup: LVM, loop device,
   systemd units, `lvmd` config.
4. **TopoLVM in `platformservices/`,** as a Kustomize part like the other
   platform services.
5. **Harbor as the local registry,** in a Docker Compose setup next to the
   cluster, with a TLS certificate from the local CA, in a new folder
   `registry/`.

## Layout additions

```
.
├── storage/                      # host-side storage setup (needs root once)
│   ├── setup-host.sh             # lvm2, backing file, loop device, volume group, lvmd + units
│   ├── teardown-host.sh          # removes them again
│   ├── lvmd.yaml                 # device-class config -> /etc/topolvm/lvmd.yaml
│   └── systemd/
│       ├── topolvm-loop.service  # re-creates the loop device and activates the VG at boot
│       └── lvmd.service          # runs /opt/sbin/lvmd
├── registry/                     # Harbor via Docker Compose (needs root once)
│   ├── setup-host.sh             # certificate, installer, prepare, docker compose up -d
│   ├── create-cert.sh            # server certificate for harbor.kind.local from the local CA
│   ├── harbor.yml.tmpl           # Harbor configuration template
│   ├── kind-trust.sh             # /etc/hosts + containerd certs.d + CA in the kind nodes
│   └── out/                      # installer, generated compose file, certificates, data (git-ignored)
└── platformservices/
    └── topolvm/                  # Helm chart via helmCharts + namespace + StorageClass
```

## Versions

Checked on 2026-09-16.

| Component | Version | Notes |
| --- | --- | --- |
| TopoLVM chart | **17.2.0** | app version 0.41.1 |
| `lvmd` (host) | **v0.41.1** | Prebuilt: release asset `lvmd-0.41.1.tar.gz` (12 MB, contains only the `lvmd` binary); no checksum file is published |
| Harbor | **v2.15.2** | Online installer `harbor-online-installer-v2.15.2.tgz` (12 KB; extracts to `harbor/` with `prepare`, `install.sh`, `harbor.yml.tmpl`; the images are pulled on first start) |

New entries in `versions.env`:

```bash
TOPOLVM_VERSION=v0.41.1          # lvmd on the host; the chart version is pinned in platformservices/topolvm
HARBOR_VERSION=v2.15.2
```

## Decisions

**Storage**
- **`lvmd` runs on the host, not in the cluster.** It manages the host's volume
  group, and TopoLVM's chart supports this with `lvmd.managed: false`. The node
  DaemonSet then talks to `/run/topolvm/lvmd.sock`.
- **The kind nodes get what they need through `extraMounts`,** as in TopoLVM's
  own kind example:
  - `/dev` → `/dev`, because a kind node's `/dev` is a **tmpfs copy** (verified),
    so logical volumes created afterwards would otherwise be invisible;
  - `/run/topolvm` → `/run/topolvm`, for the `lvmd` socket.
- **A loop-backed volume group** (`topolvm-vg`) on a sparse file under
  `/var/lib/topolvm/`. No partition needed, and the size can be changed later.
  A systemd unit re-creates the loop device at boot, before `lvmd` starts.
- **Volumes are node-local.** The StorageClass uses `WaitForFirstConsumer`, so
  the scheduler places the pod first and TopoLVM creates the LV on that node.
  In this cluster all nodes share the same host volume group, but Kubernetes
  still pins each pod to its node.
- **TopoLVM becomes the default StorageClass,** and kind's `standard`
  (local-path) stays as a fallback.
- **Snapshots need a thin pool.** With plain (thick) LVs, TopoLVM can't
  snapshot. The `lvmd` config below has a commented-out thin-pool device class
  for that.

**Registry**
- **Harbor runs in Docker Compose on the host,** the same lifecycle as
  cloud-provider-kind: it outlives the cluster, so images survive
  `cluster/cluster.sh down`.
- **TLS from the local CA:** a server certificate for `harbor.kind.local`,
  issued by `kind-dev Issuing CA` from `cluster/pki/`. The root CA is
  name-constrained to `kind.local`, so this works. Anything that already trusts
  the root CA (this host, after step 4 of update-setup-01) trusts Harbor.
- **The cluster reaches Harbor over the kind network.** The nodes get an
  `/etc/hosts` entry for `harbor.kind.local` and a containerd `hosts.toml` with
  the CA. The node's containerd (2.3.4) uses the **v2 config format**, so the
  patch key is the one from kind's local-registry guide:
  `[plugins."io.containerd.grpc.v1.cri".registry] config_path = "/etc/containerd/certs.d"`
  (verified: the nodes currently have neither `config_path` nor `certs.d`).
- **`install.sh` is skipped.** It hardcodes the old `docker-compose` v1 binary,
  which isn't installed here (Compose v5.3.0 plugin). The steps run `./prepare`
  and then `docker compose up -d` directly. Harbor's own docs require
  "Docker compose > 2.3" anyway.
- **Root only for `prepare`, not for running Harbor.** `prepare` is a
  `--privileged` container with the host filesystem mounted at `/hostfs`, and it
  writes the configs and secrets as root with mode 0640. Afterwards the four env
  files that Compose itself reads get group read for the invoking user, with the
  owners untouched (Harbor's processes read them as uid 10000). Then `up`,
  `stop`, `restart`, `ps` and `logs` all run unprivileged. At runtime no Harbor
  container is privileged and eight of nine run as non-root users; installing
  entirely without root is an open upstream issue (goharbor/harbor#17494).
- **Harbor is heavy:** minimum 2 CPU / 4 GB RAM / 40 GB disk. This host has
  about 3.5 GB free with the cluster running, so plan to start it only when
  needed (`docker compose stop`/`start`), and leave Trivy off (the default).

---

## Step 1: `storage/` — LVM, loop device and lvmd on the host

**`storage/lvmd.yaml`:**

```yaml
socket-name: /run/topolvm/lvmd.sock
device-classes:
  - name: local
    volume-group: topolvm-vg
    default: true
    spare-gb: 5
# For snapshot/clone tests, LVM needs a thin pool. Create it once on the host:
#   sudo lvcreate --type thin-pool -L 20G -n thinpool topolvm-vg
# and add:
#  - name: local-thin
#    volume-group: topolvm-vg
#    type: thin
#    thin-pool:
#      name: thinpool
#      overprovision-ratio: 5.0
```

**`storage/systemd/topolvm-loop.service`:**

```ini
[Unit]
Description=Loop device and volume group for TopoLVM
DefaultDependencies=no
After=local-fs.target
Before=lvmd.service

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=BACKING_FILE=/var/lib/topolvm/backing.img
Environment=VG=topolvm-vg
ExecStart=/bin/sh -c 'losetup -j "$BACKING_FILE" | grep -q . || losetup --find "$BACKING_FILE"; vgchange -ay "$VG"'
ExecStop=/bin/sh -c 'vgchange -an "$VG" || true; loop=$(losetup -j "$BACKING_FILE" | cut -d: -f1); [ -n "$loop" ] && losetup -d "$loop" || true'

[Install]
WantedBy=multi-user.target
```

**`storage/systemd/lvmd.service`** (from TopoLVM's `deploy/systemd/lvmd.service`,
with the config flag and a dependency on the loop unit):

```ini
[Unit]
Description=lvmd for TopoLVM
Wants=lvm2-monitor.service topolvm-loop.service
After=lvm2-monitor.service topolvm-loop.service

[Service]
Type=simple
Restart=on-failure
RestartForceExitStatus=SIGPIPE
ExecStartPre=/bin/mkdir -p /run/topolvm
ExecStart=/opt/sbin/lvmd --config=/etc/topolvm/lvmd.yaml

[Install]
WantedBy=multi-user.target
```

**`storage/setup-host.sh`** (run once with `sudo`, re-runnable):

```bash
#!/usr/bin/env bash
# Host setup for TopoLVM (update-setup-02): LVM volume group on a loop-backed file + lvmd.
# Usage: sudo storage/setup-host.sh
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

# 5. lvmd binary (prebuilt release asset; no published checksum)
install -d /opt/sbin /etc/topolvm /run/topolvm
if [[ ! -x /opt/sbin/lvmd ]]; then
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    curl -fsSL "https://github.com/topolvm/topolvm/releases/download/${TOPOLVM_VERSION}/lvmd-${TOPOLVM_VERSION#v}.tar.gz" \
        -o "$tmp/lvmd.tar.gz"
    tar -xzf "$tmp/lvmd.tar.gz" -C "$tmp" lvmd   # the archive contains only the binary
    install -m 0755 "$tmp/lvmd" /opt/sbin/lvmd
fi
/opt/sbin/lvmd --version || true

# 6. Config and systemd units
install -m 0644 "$SCRIPT_DIR/lvmd.yaml" /etc/topolvm/lvmd.yaml
install -m 0644 "$SCRIPT_DIR/systemd/topolvm-loop.service" /etc/systemd/system/topolvm-loop.service
install -m 0644 "$SCRIPT_DIR/systemd/lvmd.service" /etc/systemd/system/lvmd.service
systemctl daemon-reload
systemctl enable --now topolvm-loop.service lvmd.service
systemctl --no-pager --lines=5 status lvmd.service
ls -l /run/topolvm/lvmd.sock
```

**`storage/teardown-host.sh`:** stop and disable both units, `vgremove topolvm-vg`,
`losetup -d`, then remove `/var/lib/topolvm/backing.img`, `/etc/topolvm`,
`/opt/sbin/lvmd` and the unit files. It asks before deleting the backing file,
since that destroys all volume data.

Check:

```bash
sudo storage/setup-host.sh
sudo vgs topolvm-vg
systemctl is-active lvmd.service topolvm-loop.service
```

## Step 2: kind config — the nodes get the volumes via `extraMounts`

Extend `cluster/cluster-config.yaml`. Every node gets both mounts, plus the
containerd patch for Harbor (step 5):

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: dev
# Registry (Harbor): let containerd read per-registry config from /etc/containerd/certs.d
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry]
    config_path = "/etc/containerd/certs.d"
kubeadmConfigPatches:
- |
  apiVersion: kubelet.config.k8s.io/v1beta1
  kind: KubeletConfiguration
  evictionHard:
    nodefs.available: "0%"
  # ZFS workaround, see update-setup-01 step 2c
  localStorageCapacityIsolation: false
nodes:
- role: control-plane
  extraMounts:
  # TopoLVM: the node's /dev is a tmpfs copy, so LVM devices need the host's /dev
  - hostPath: /dev
    containerPath: /dev
  # TopoLVM: lvmd socket from the host (storage/)
  - hostPath: /run/topolvm
    containerPath: /run/topolvm
- role: worker
  extraMounts:
  - hostPath: /dev
    containerPath: /dev
  - hostPath: /run/topolvm
    containerPath: /run/topolvm
- role: worker
  extraMounts:
  - hostPath: /dev
    containerPath: /dev
  - hostPath: /run/topolvm
    containerPath: /run/topolvm
```

`/run/topolvm` has to exist on the host before the cluster is created, otherwise
Docker creates it as a directory owned by root. `storage/setup-host.sh` creates
it, so run that first. The cluster has to be recreated for the mounts to take
effect:

```bash
cluster/cluster.sh down && cluster/cluster.sh up
```

## Step 3: `platformservices/topolvm/`

`platformservices/topolvm/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: topolvm-system
  labels:
    istio-injection: disabled
    # TopoLVM's node pods are privileged; explicit in case Pod Security is enforced later
    pod-security.kubernetes.io/enforce: privileged
```

`platformservices/topolvm/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
# TopoLVM with lvmd on the host (systemd unit, see storage/). The node DaemonSet talks to
# /run/topolvm/lvmd.sock, which the nodes get through extraMounts in cluster/cluster-config.yaml.
# The chart's webhook certificate comes from cert-manager, so apply this after cert-manager.
resources:
- namespace.yaml
helmCharts:
- name: topolvm
  repo: https://topolvm.github.io/topolvm
  version: 17.2.0
  releaseName: topolvm
  namespace: topolvm-system
  valuesInline:
    lvmd:
      managed: false                      # lvmd runs on the host, not as a DaemonSet
      socketName: /run/topolvm/lvmd.sock
    node:
      lvmdEmbedded: false
      lvmdSocket: /run/topolvm/lvmd.sock
    storageClasses:
    - name: topolvm
      storageClass:
        fsType: xfs
        isDefaultClass: true              # default class; kind's "standard" stays as fallback
        volumeBindingMode: WaitForFirstConsumer
        allowVolumeExpansion: true
```

Add it to the aggregate `platformservices/kustomization.yaml` (after
`trust-manager/config`) and to `platformservices/deploy.sh`, right after the
cert-manager block:

```bash
# 2. TopoLVM (lvmd runs on the host); the chart's webhook certificate comes from cert-manager
[[ -S /run/topolvm/lvmd.sock ]] || { echo "missing /run/topolvm/lvmd.sock - run storage/setup-host.sh first" >&2; exit 1; }
apply topolvm;              available topolvm-system
# TopoLVM becomes the default StorageClass; kind's local-path stays available
kubectl annotate storageclass standard storageclass.kubernetes.io/is-default-class=false --overwrite
```

## Step 4: `registry/` — certificate and Harbor

**`registry/create-cert.sh`:** issues a server certificate for
`harbor.kind.local` from `cluster/pki/out/issuing-ca.*`, writing
`registry/out/harbor.key` and `registry/out/harbor-chain.crt` (server
certificate plus issuing CA, which Harbor's nginx needs):

```bash
#!/usr/bin/env bash
# Server certificate for harbor.kind.local from the local CA (update-setup-02)
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PKI="$SCRIPT_DIR/../cluster/pki/out"
OUT="$SCRIPT_DIR/out"
[[ -f "$PKI/issuing-ca.key" ]] || { echo "missing $PKI/issuing-ca.key - run cluster/pki/create-ca.sh first" >&2; exit 1; }
mkdir -p "$OUT"; umask 077
openssl req -new -newkey rsa:2048 -nodes -sha256 \
    -keyout "$OUT/harbor.key" -out "$OUT/harbor.csr" -subj "/O=kind-dev/CN=harbor.kind.local"
openssl x509 -req -in "$OUT/harbor.csr" -CA "$PKI/issuing-ca.crt" -CAkey "$PKI/issuing-ca.key" \
    -CAcreateserial -days 825 -sha256 -out "$OUT/harbor.crt" -extfile <(printf '%s\n' \
        "basicConstraints=critical,CA:FALSE" \
        "keyUsage=critical,digitalSignature,keyEncipherment" \
        "extendedKeyUsage=serverAuth" \
        "subjectAltName=DNS:harbor.kind.local")
cat "$OUT/harbor.crt" "$PKI/issuing-ca.crt" > "$OUT/harbor-chain.crt"
chmod 644 "$OUT/harbor-chain.crt"; rm -f "$OUT/harbor.csr"
openssl verify -CAfile "$PKI/root-ca.crt" -untrusted "$PKI/issuing-ca.crt" "$OUT/harbor.crt"
```

**`registry/harbor.yml.tmpl`** (the parts that differ from Harbor's template):

```yaml
hostname: harbor.kind.local
http:
  port: 80
https:
  port: 443
  certificate: @OUT@/harbor-chain.crt
  private_key: @OUT@/harbor.key
harbor_admin_password: @ADMIN_PASSWORD@
data_volume: @OUT@/data
# everything else stays at Harbor's defaults (database, jobservice, log, _version)
```

**`registry/setup-host.sh`:**

```bash
#!/usr/bin/env bash
# Harbor via Docker Compose (update-setup-02).
# Usage: registry/setup-host.sh   (./prepare needs sudo; it writes as root)
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../versions.env"
OUT="$SCRIPT_DIR/out"; mkdir -p "$OUT/data"
: "${HARBOR_ADMIN_PASSWORD:=$(openssl rand -base64 18)}"

"$SCRIPT_DIR/create-cert.sh"

# Installer (online: pulls the images on first start)
if [[ ! -d "$OUT/harbor" ]]; then
    curl -fsSL "https://github.com/goharbor/harbor/releases/download/${HARBOR_VERSION}/harbor-online-installer-${HARBOR_VERSION}.tgz" \
        -o "$OUT/harbor-installer.tgz"
    tar -xzf "$OUT/harbor-installer.tgz" -C "$OUT"
fi

sed -e "s|@OUT@|$OUT|g" -e "s|@ADMIN_PASSWORD@|$HARBOR_ADMIN_PASSWORD|g" \
    "$SCRIPT_DIR/harbor.yml.tmpl" > "$OUT/harbor/harbor.yml"

cd "$OUT/harbor"
sudo ./prepare                 # renders docker-compose.yml and the nginx config
docker compose up -d           # NOT ./install.sh: it requires the docker-compose v1 binary
docker compose ps --format '{{.Name}}\t{{.Status}}'
echo "Harbor: https://harbor.kind.local   user: admin   password: $HARBOR_ADMIN_PASSWORD"
```

Harbor sets `restart: always` on its containers, so it comes back after a
reboot. Stop it with `docker compose -f registry/out/harbor/docker-compose.yml stop`
when you need the memory.

Add to `.gitignore`:

```
/registry/out/
```

## Step 5: Connect the cluster to Harbor

**`registry/kind-trust.sh`** runs after every `cluster/cluster.sh up`:

```bash
#!/usr/bin/env bash
# Teach the kind nodes about harbor.kind.local (update-setup-02)
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../versions.env"
KIND="$SCRIPT_DIR/../cluster/kind"
CA="$SCRIPT_DIR/../cluster/pki/out/root-ca.crt"
# Address of the host on the kind network
HOST_IP=$(docker network inspect kind -f '{{range .IPAM.Config}}{{if not (eq .Gateway "")}}{{.Gateway}}{{end}}{{end}}')
echo "harbor.kind.local -> $HOST_IP"

for node in $("$KIND" get nodes --name "$CLUSTER_NAME"); do
    docker exec "$node" sh -c "grep -q harbor.kind.local /etc/hosts || echo '$HOST_IP harbor.kind.local' >> /etc/hosts"
    docker exec "$node" mkdir -p /etc/containerd/certs.d/harbor.kind.local
    docker cp "$CA" "$node:/etc/containerd/certs.d/harbor.kind.local/ca.crt"
    docker exec "$node" sh -c 'cat > /etc/containerd/certs.d/harbor.kind.local/hosts.toml <<EOF
server = "https://harbor.kind.local"

[host."https://harbor.kind.local"]
  capabilities = ["pull", "resolve"]
  ca = "/etc/containerd/certs.d/harbor.kind.local/ca.crt"
EOF'
done
```

The `config_path` patch from step 2 makes containerd read those files; no
restart is needed, since containerd re-reads `certs.d` per pull.

On the host, Docker also needs to trust Harbor for `docker login`/`docker push`.
That works once the root CA is in the system trust store (update-setup-01,
step 4). Otherwise: `sudo mkdir -p /etc/docker/certs.d/harbor.kind.local && sudo cp cluster/pki/out/root-ca.crt /etc/docker/certs.d/harbor.kind.local/ca.crt`.

Add `harbor.kind.local` to `/etc/hosts` on the host with `./hosts.sh`, extended
by a static entry, or manually:
`echo "$HOST_IP harbor.kind.local" | sudo tee -a /etc/hosts`.

## Step 6: Verification

**Storage:**

```bash
kubectl get storageclass                       # topolvm (default), standard
kubectl -n topolvm-system get pods             # controller + node DaemonSet Running
kubectl get csidrivers topolvm.io
# 1 GiB volume, written and read back
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: lvm-test, namespace: default }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
---
apiVersion: v1
kind: Pod
metadata: { name: lvm-test, namespace: default }
spec:
  containers:
  - { name: app, image: busybox, command: [sh, -c, "echo hello > /data/test && sleep 3600"],
      volumeMounts: [{ name: data, mountPath: /data }] }
  volumes: [{ name: data, persistentVolumeClaim: { claimName: lvm-test } }]
EOF
kubectl wait pod/lvm-test --for=condition=Ready --timeout=120s
kubectl exec lvm-test -- cat /data/test        # hello
sudo lvs topolvm-vg                            # the LV on the host
kubectl get logicalvolumes.topolvm.io
# Expansion
kubectl patch pvc lvm-test -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'
kubectl get pvc lvm-test -w                    # capacity 2Gi
```

**Registry:**

```bash
docker login harbor.kind.local                 # admin + generated password
docker pull busybox:1.36 && docker tag busybox:1.36 harbor.kind.local/library/busybox:1.36
docker push harbor.kind.local/library/busybox:1.36
kubectl run harbor-test --image=harbor.kind.local/library/busybox:1.36 --restart=Never -- sleep 60
kubectl get pod harbor-test -w                 # Running = the node pulled from Harbor
```

For private Harbor projects, a pull secret is needed; `library` is public by
default.

**Kafka smoke test (optional).** Install Strimzi and let a Kafka cluster use
`topolvm` volumes. That's the reason for block-like storage.

## Step 7: Docs

- `README.md`: a *Storage* section (TopoLVM, `storage/setup-host.sh`, the
  StorageClasses) and a *Registry* section (Harbor, login, push/pull, how to
  stop it). Extend the layout tree by `storage/` and `registry/`.
- Note in both sections that the host setup needs root once and that
  `registry/kind-trust.sh` runs after every `cluster/cluster.sh up`.

## Implementation notes

The scripts in `storage/` and `registry/` are authoritative; they differ from the
drafts above in these points, all found while applying:

- **`registry/setup-host.sh` runs as a normal user** and calls `sudo` only for
  `prepare`, then re-applies group read on `common/config/*/env`. The first
  version ran everything as root, which is unnecessary: only `prepare` needs it.
  Verified afterwards with `sudo` deliberately disabled: the script completes and
  Harbor starts.
- **`prepare` is guarded by a checksum** of `harbor.yml`, so it only re-runs when
  the configuration actually changed, not on every run.
- **`registry/create-cert.sh` is idempotent:** an existing certificate is kept
  while it matches the hostname and is valid for more than 30 days.
- **The port check ignores Harbor itself.** It aborted when Harbor was already
  listening on 80/443; now it only refuses when another service holds them.
- **`registry/harbor.yml.tmpl` isn't used.** The script renders Harbor's own
  `harbor.yml.tmpl` from the installer and replaces only hostname, certificate
  paths, admin password and data volume, so it doesn't drift with Harbor versions.
- **The kind nodes' `/dev` is a tmpfs copy** (confirmed), which is why the `/dev`
  extraMount is required and not optional.
- **Harbor's admin password is generated** and stored in
  `registry/out/harbor/harbor.yml`; re-runs reuse it.

## Known limitations

**Storage**
- **Logical volumes outlive the cluster.** Deleting the cluster leaves the LVs
  in the volume group, because the PVs and TopoLVM's `LogicalVolume` objects go
  with it. Clean up with `sudo lvs topolvm-vg` and `sudo lvremove`, or
  `teardown-host.sh`.
- **No snapshots with thick LVs.** Snapshots and clones need the thin-pool
  device class from step 1.
- **The loop file sits on ZFS here,** so it's copy-on-write on copy-on-write.
  Fine for dev, but not a performance reference.
- **All nodes share one host volume group.** Capacity numbers per node are
  therefore the same pool; TopoLVM's scheduling still treats them as per-node.
- **`/dev` is mounted from the host into the nodes.** That's what TopoLVM's own
  kind example does, but it gives the (already privileged) nodes access to all
  host devices.
- **WSL2:** loop devices and LVM work, but `lvmd` needs systemd enabled in the
  distro (`/etc/wsl.conf`). Untested.

**Registry**
- **Harbor needs 4 GB RAM** (minimum, per its docs) and pulls several GB of
  images on first start. On this host that competes with the cluster; stop it
  when unused.
- **`./prepare` needs sudo** and writes root-owned files under `registry/out/`.
  It also resets the permissions of `common/config/*/env`, so the group read bits
  are re-applied after every run (the script does this).
- **`install.sh` is unusable here** (it requires `docker-compose` v1); the steps
  use `./prepare` plus `docker compose up -d`.
- **`kind-trust.sh` has to run after every cluster creation,** because the
  `/etc/hosts` entries and `certs.d` files live inside the node containers.
- **The Harbor certificate is valid for 825 days** and is renewed by re-running
  `registry/create-cert.sh` followed by `docker compose restart`.

## Possible follow-ups

- Have `cluster/cluster.sh up` call `registry/kind-trust.sh` automatically;
- Harbor as a pull-through cache for docker.io/ghcr.io, which makes cluster
  rebuilds much faster;
- a thin pool as the default device class, so snapshots work everywhere;
- `storage/` volume group on a real partition or a second disk instead of a loop
  file;
- the snapshot controller plus a `VolumeSnapshotClass` for TopoLVM;
- Strimzi/Kafka and CloudNativePG as applications on `topolvm`.
