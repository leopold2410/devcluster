# kind development cluster

A local multi-node Kubernetes cluster on [kind](https://kind.sigs.k8s.io/)
(Kubernetes IN Docker) with:
- [cloud-provider-kind](https://github.com/kubernetes-sigs/cloud-provider-kind),
  which provides `LoadBalancer` IPs and the default ("vanilla") Ingress;
- Istio as a second ingress path, turned on per namespace;
- cert-manager with a local CA, plus trust-manager;
- the External Secrets Operator (ESO) and Argo CD;
- containerized k9s and lazydocker;
- TopoLVM for node-local block storage, backed by LVM on the host;
- Harbor as a local registry, in Docker Compose next to the cluster.

Set up with [`update-setup-01.md`](update-setup-01.md), applied and verified on
2026-09-15, and [`update-setup-02.md`](update-setup-02.md) (storage and
registry), applied and verified on 2026-09-16. It replaced the 2023 kind + MetalLB + Traefik setup (kept on git
history: commit `ada2a79`).

## Quick start

```bash
pki/create-ca.sh      # once: local root CA + intermediates (pki/out/, git-ignored)
sudo storage/setup-host.sh    # once: LVM volume group on a loop file + lvmd as a systemd unit
cluster/cluster.sh up         # kind cluster, Gateway API CRDs, cloud-provider-kind
./deploy.sh                   # platform services, then test applications
cluster/cluster.sh down       # delete the cluster (the PKI and the LVM volume group stay)

registry/setup-host.sh        # optional: Harbor (sudo only for its ./prepare step)
registry/kind-trust.sh        # after every "cluster.sh up" if Harbor is used

identity/setup-host.sh        # optional: Keycloak (no root; one /etc/hosts line is yours)
cluster/host-services-dns.sh  # after every "cluster.sh up": pods resolve Keycloak and Vault

vault/setup-host.sh           # optional: Vault (no root; unseals after every restart)
```

You need on `PATH`:
- `docker` with the Compose plugin;
- `kubectl` v1.36.4;
- `helm` v3.22.0, which renders charts for Kustomize;
- `openssl`;
- `git`.

Step 0 of the plan has checksum-verified install commands for kubectl and helm.

## Layout

```
.
├── versions.env          # cluster and CLI tool versions (platform services: in their kustomization.yaml)
├── deploy.sh             # platformservices/deploy.sh, then applications/deploy.sh
├── hosts.sh              # *.kind.local Ingress hosts -> /etc/hosts (managed block)
├── cluster/              # kind binary (git-ignored), cluster-config.yaml, cluster.sh (up | down | cpk)
├── pki/                  # create-ca.sh; out/ holds the CA keys (git-ignored). Used by the cluster
│                         # and by the host-side services (Harbor, later Keycloak)
├── platformservices/     # one Kustomize tree; Helm charts via helmCharts
│   ├── kustomization.yaml    # renders everything: kubectl kustomize --enable-helm platformservices
│   ├── deploy.sh             # applies the parts in dependency order
│   ├── cert-manager/  trust-manager/  istio/  external-secrets/  argocd/
│   ├── monitoring/           # OpenTelemetry Collector, Prometheus, Loki, Tempo, Grafana
│   └── keda/                 # old 2.11.0 manifest, not deployed
├── storage/              # host side of TopoLVM: loop device, volume group, lvmd systemd units
├── registry/             # Harbor via Docker Compose; out/ is generated (git-ignored)
├── identity/             # Keycloak via Docker Compose; the realm is code in realm/localdev.yaml
├── applications/         # one folder per test application, each with its own deploy.sh
│   ├── deploy.sh             # deploys the default ones (testapp)
│   ├── testapp/  testhelm/
│   └── secret-test/          # own git repository (git-ignored here)
└── cli/                  # Compose project "kind-cli": k9s.sh, lazydocker.sh
```

## What runs where

```
Host (Linux, Docker on ZFS)
├── cloud-provider-kind container   LoadBalancer IPs + Ingress class "cloud-provider-kind" (default)
├── kindccm-* containers            one Envoy per LoadBalancer Service / per namespace with Ingresses
└── kind cluster "dev" (Kubernetes 1.36.4; 1 control plane + 2 workers)
    ├── cert-manager            cert-manager v1.21.2 (ClusterIssuer kind-ca), trust-manager v0.25.0
    ├── istio-system            Istio 1.31.0: istiod (plug-in CA), istio-ingressgateway (LoadBalancer)
    ├── external-secrets        ESO 2.10.0, cluster-wide
    ├── argocd                  Argo CD v3.5.3, one instance for all namespaces
    ├── testapp                 nginx, no mesh       (istio-injection=disabled)
    └── testapp-mesh            nginx with sidecars  (istio-injection=enabled)
```

Every app can be reached three ways:

| Path | Entry point | How |
| --- | --- | --- |
| Vanilla L7 | cloud-provider-kind Envoy, one IP per namespace | `Ingress` with `ingressClassName: cloud-provider-kind`; TLS via annotation `cert-manager.io/cluster-issuer: kind-ca` |
| Istio L7 | `istio-ingressgateway`, one shared IP | `Ingress` with `ingressClassName: istio`; TLS via the wildcard Secret `kind-local-wildcard-tls` in `istio-system` |
| L4 | cloud-provider-kind, one IP per Service | `Service` with `type: LoadBalancer` |

The LoadBalancer and Ingress IPs come from the `kind` Docker network (here
`172.21.0.0/16`) and are reachable from this host only. They can change when the
cluster is recreated:

```bash
kubectl get ingress -A; kubectl -n istio-system get svc istio-ingressgateway
```

## Browser access

Ingresses route by hostname, so a bare IP gives `404`. For `*.kind.local`
without certificate warnings, do these once (both need root):

```bash
# 1. Trust the local root CA (name-constrained to kind.local, svc, cluster.local, localhost)
#    The system store below covers curl, git and friends. Chrome and Firefox do NOT read
#    it - they keep their own NSS database - so skipping the certutil part leaves every
#    page failing with ERR_CERT_AUTHORITY_INVALID even though curl is happy.
sudo cp pki/out/root-ca.crt /usr/local/share/ca-certificates/kind-dev-root-ca.crt
sudo update-ca-certificates

sudo apt-get install -y libnss3-tools                    # provides certutil
mkdir -p "$HOME/.pki/nssdb"
certutil -d sql:"$HOME/.pki/nssdb" -N --empty-password 2>/dev/null || true   # only if there is no database yet
certutil -d sql:"$HOME/.pki/nssdb" -A -t "C,," -n "kind-dev Root CA" -i pki/out/root-ca.crt
certutil -d sql:"$HOME/.pki/nssdb" -L | grep kind-dev    # verify, then restart the browser
# Firefox: Settings → Privacy & Security → Certificates → View Certificates → Authorities → Import

# 2. Host names -> Ingress IPs: all *.kind.local Ingress hosts into a managed block in /etc/hosts
#    (sudo only if something changes; re-run after recreating the cluster)
./hosts.sh               # --istio: prefer the Istio gateway IP, --dry-run, --remove
```

Then open **https://argocd.kind.local**. The user is `admin`; the initial
password is in a Secret:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

Change it after the first login, then delete that Secret. Without root, use a
port-forward instead: `kubectl -n argocd port-forward svc/argocd-server 8080:80`
→ http://localhost:8080.

`hosts.sh` also adds `testapp.kind.local` and `testapp-mesh.kind.local`. Each of
them has a vanilla and an Istio Ingress with different IPs. The script uses the
vanilla (cloud-provider-kind) IP unless you pass `--istio`.

## Cluster (`cluster/`)

- `cluster/cluster.sh up`:
  1. creates the cluster from `cluster-config.yaml`, with the node image pinned
     in `versions.env`;
  2. installs the Gateway API CRDs v1.6.2;
  3. starts cloud-provider-kind v0.11.1 as a container;
  4. writes `cli/kubeconfig`.
- `cluster/cluster.sh down` removes the cluster, cloud-provider-kind, its
  `kindccm-*` containers and `cli/kubeconfig`. `cluster/cluster.sh cpk` restarts
  cloud-provider-kind only.
- Two host-specific workarounds, both found during setup:
  - **ZFS:** Docker's storage here is ZFS, and the kubelet can't read ZFS rootfs
    stats inside a kind node (kind#4229). `cluster-config.yaml` therefore sets
    `localStorageCapacityIsolation: false`. Ephemeral-storage limits aren't
    enforced.
  - **Gateway API policy:** the Gateway API bundle's `safe-upgrades` admission
    policy blocks cloud-provider-kind's startup, so `cluster.sh` removes it
    after installing the CRDs.

## Platform services (`platformservices/`)

All platform services form one Kustomize tree. Helm charts come in through
`helmCharts` and are rendered with `helm template`. Versions are pinned in each
`kustomization.yaml`:

```bash
kubectl kustomize --enable-helm platformservices | grep -c '^kind:'     # render everything (217 resources)
grep -rnE '^\s+version:|/v[0-9.]+/manifests/' platformservices --include=kustomization.yaml   # pinned versions
```

The tree isn't applied in one go, because CRDs and webhooks have to be ready
before the resources that use them. `platformservices/deploy.sh` does it in this
order, waiting in between:
1. creates the Secrets from the local PKI (never in git, never in a render);
2. cert-manager → trust-manager;
3. ClusterIssuer and Bundle;
4. Istio base + istiod → gateway → IngressClass and certificate;
5. ESO;
6. Argo CD.

Controllers and their custom resources live in separate folders
(`<service>/` and `<service>/config/`).

- **Istio:** charts from `https://blob.istio.io/istio-release/charts` (the old
  repo has no 1.31 charts).
- **ESO:** only `external-secrets.io/v1`. Try it with
  `kubectl apply -f platformservices/external-secrets/examples/fake-store.yaml`.
- **Argo CD:** the upstream `install.yaml` with cluster-wide permissions, so one
  instance deploys into any namespace. Settings go into Kustomize patches on its
  ConfigMaps (e.g. `server.insecure`). Example app:
  `kubectl apply -f platformservices/argocd/examples/guestbook.yaml`.

## Istio per namespace

Every namespace states whether it's in the mesh:

```bash
kubectl label ns <ns> istio-injection=enabled --overwrite && kubectl -n <ns> rollout restart deployment
```

Platform namespaces are `istio-injection=disabled`. Routing through Ingress class
`istio` works for both kinds of namespace. With
`PeerAuthentication` `STRICT` in a meshed namespace, only the Istio path
still works: the vanilla path gets `503` and L4 a reset connection (verified).

## Certificates

- **Local PKI (`pki/create-ca.sh`):**
  - `kind-dev Root CA`: 10 years, name-constrained to `kind.local`, `svc`,
    `cluster.local` and `localhost`;
  - two intermediates (3 years): `kind-dev Issuing CA` for cert-manager and
    `kind-dev Istio Mesh CA` for Istio;
  - the root key is only needed to issue intermediates, so move
    `pki/out/root-ca.key` offline.
- **cert-manager:** ClusterIssuer `kind-ca`. Annotate an Ingress with
  `cert-manager.io/cluster-issuer: kind-ca` and give it a `tls` block.
- **trust-manager:** the Bundle `kind-root-ca` puts the root certificate into
  a ConfigMap `kind-root-ca` (key `ca.crt`) in every namespace.
- **Istio:** a plug-in CA (Secret `cacerts`), so mesh certificates chain to the
  same root.

## Trusting external CAs with trust-manager

### cert-manager vs. trust-manager

trust-manager is a separate project from the cert-manager maintainers, with its
own Helm chart (`jetstack/trust-manager`) and a pre-1.0 API
(`trust.cert-manager.io/v1alpha1`). By default its chart asks cert-manager for
the certificate of its own webhook, so cert-manager has to be installed first.

| | cert-manager | trust-manager |
|---|---|---|
| Handles | Service certificates **and their private keys** | Only **public CA certificates**; it refuses private keys |
| Output | One Secret per Certificate, in that certificate's namespace | The same ConfigMap/Secret in every selected namespace |
| Updating | **Renews** certificates before they expire | **Re-syncs** the bundle when its source changes, and adds it to new namespaces |
| Question it answers | "Who am I?" (server identity) | "Whom do I trust?" (client side) |

### Distributing an external CA

Use a separate Bundle when services must trust an external CA, for example a
partner's CA that signs client certificates for mutual TLS. Bundle sources
(ConfigMap, Secret, inline PEM or the public default CAs) must be in the trust
namespace, `cert-manager`:

```bash
kubectl -n cert-manager create configmap partner-client-ca-source --from-file=ca.crt=partner-ca.pem
```

If the partner CA lives in a secret store, ESO can sync it into a Secret in
`cert-manager` instead. Use that Secret as the source, and a rotated partner CA
then reaches every service automatically.

How the CA gets to the service depends on **where the client's TLS connection
ends**.

**A. The service checks client certificates itself** (e.g. nginx
`ssl_client_certificate`, a Java truststore). Distribute a ConfigMap, only to the
namespaces that opt in:

```yaml
apiVersion: trust.cert-manager.io/v1alpha1
kind: Bundle
metadata:
  name: partner-client-ca               # name of the target ConfigMap
spec:
  sources:
  - configMap:
      name: partner-client-ca-source
      key: ca.crt
  target:
    configMap:
      key: ca.crt
    namespaceSelector:
      matchLabels:
        trust.kind.local/partner-client-ca: "true"
```

The app mounts the ConfigMap `partner-client-ca` as a file. For Java,
`target.additionalFormats` can also produce `jks` or `pkcs12` truststores.

**B. The Istio ingress gateway checks client certificates.** Kubernetes
`Ingress` has no client-certificate option, so use an Istio `Gateway` (or
Gateway API) with `tls.mode: MUTUAL`. Istio looks for the client CA in a
separate Secret `<credentialName>-cacert` (key `cacert`) in `istio-system`, and
trust-manager can write it:

```yaml
apiVersion: trust.cert-manager.io/v1alpha1
kind: Bundle
metadata:
  name: partner-api-tls-cacert          # = <credentialName>-cacert
spec:
  sources:
  - configMap: { name: partner-client-ca-source, key: ca.crt }
  target:
    secret:
      key: cacert
    namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: istio-system
---
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: partner-api
  namespace: istio-system
spec:
  selector:
    istio: ingressgateway
  servers:
  - port: { number: 443, name: https, protocol: HTTPS }
    hosts: [partner-api.kind.local]
    tls:
      mode: MUTUAL
      credentialName: partner-api-tls   # server certificate (cert-manager Certificate in istio-system)
```

Add a VirtualService that binds the `partner-api` Gateway to the backend.
trust-manager also needs Secret targets enabled in its chart. Add these values
to the `helmCharts` entry in `platformservices/trust-manager/kustomization.yaml`:

```yaml
  valuesInline:
    secretTargets:
      enabled: true
      authorizedSecrets: [partner-api-tls-cacert]
```

With this setting, trust-manager gets read access to all Secrets in the cluster,
as the chart itself warns.

> ⚠️ **Always create the `-cacert` Secret.** Istio uses `<credentialName>-cacert`
> first. If it's missing, Istio falls back to `ca.crt` inside the server
> certificate Secret (source: `GetCaCert` in Istio's `pilot/pkg/credentials/kube/secrets.go`).
> cert-manager always sets that key to the kind-dev Root CA, so **every
> certificate issued by `kind-ca` would be accepted as a client**.

**C. Vanilla Ingress (cloud-provider-kind): not supported.** The Ingress API has
no field for checking client certificates. Terminate mutual TLS at the Istio
gateway (B) or in the service (A).

### Rules

- **One Bundle per trust purpose.** Keep `kind-root-ca` (trust for your own
  services) separate from client-authentication bundles such as
  `partner-client-ca`, so services don't trust more issuers than intended.
- **Never add `useDefaultCAs` to a client-authentication bundle.** Anyone with
  a public certificate, such as one from Let's Encrypt, could then authenticate.
- **Limit client-CA bundles with `namespaceSelector`,** so they only reach the
  services that accept those clients.
- **Running apps may need a restart after a bundle changes.** Kubernetes updates
  mounted ConfigMap files (unless they're mounted with `subPath`), but many apps
  only read CA files at startup.
- **To replace a CA without downtime:** put the old and new CA in the source,
  wait until the bundle has been distributed, switch issuance, then remove the
  old CA.

## Applications (`applications/`)

- **`testapp`:** nginx deployed twice, as `testapp` (no mesh) and `testapp-mesh`
  (sidecars). Each copy has a vanilla and an Istio Ingress (HTTP and HTTPS) and
  a `LoadBalancer` Service. `applications/deploy.sh` deploys it.
- **`secret-test`:** its own git repository. Its local overlay now uses class
  `cloud-provider-kind`, host `secret-test-web.kind.local` and TLS. The change
  is uncommitted in that repository for review. Deploy it with
  `kubectl apply -k applications/secret-test/overlays/local`.
- **`testhelm`:** a sample Helm chart, with Ingress class `cloud-provider-kind`.

## CLI tools (`cli/`)

- **k9s:** `cli/k9s.sh [k9s flags]` runs k9s v0.51.0 with kubectl v1.36.4 in a
  container.
  - It always uses the kind cluster's kubeconfig
    (`kind get kubeconfig --internal`, regenerated on each start), whatever
    `~/.kube/config` says.
  - **Port-forwards** (`shift-f`) must use a *Local Port* in 18000–18009; open
    them at `http://localhost:<port>`. They're published on `127.0.0.1` only.
- **lazydocker:** `cli/lazydocker.sh [project-dir]` runs lazydocker v0.25.2 on
  the Docker socket.
  - It shows the kind nodes, cloud-provider-kind and its `kindccm-*` containers.
  - It mounts the project's git repository read-only, so Compose projects are
    visible too.
- **Rebuilding:** both images are built locally with checksum-verified binaries.
  Rebuild with `docker compose -f cli/compose.yaml build --pull`.

## Storage (`storage/`, TopoLVM)

Volumes are LVM logical volumes on the host, which suits Kafka/Strimzi and
databases. `lvmd` runs on the host as a systemd unit; the kind nodes reach its
socket and the LVM devices through `extraMounts` in `cluster/cluster-config.yaml`.

```bash
sudo storage/setup-host.sh          # once: lvm2, 60 GB loop file, volume group topolvm-vg, lvmd
systemctl is-active lvmd.service    # active
sudo vgs topolvm-vg                 # the volume group
sudo lvs topolvm-vg                 # one logical volume per PVC
sudo storage/teardown-host.sh       # removes it again (asks before deleting data)
```

| StorageClass | Use |
| --- | --- |
| `topolvm` (default) | LVM volumes on the node: databases, Kafka, anything that wants a local disk. Expansion works online |
| `standard` | kind's local-path, kept as a fallback |

Good to know:
- **Volumes are node-local:** the class uses `WaitForFirstConsumer`, so the pod is
  scheduled first and the volume is created on that node.
- **Snapshots need a thin pool.** With plain (thick) LVs, TopoLVM can't snapshot.
  `storage/lvmd.yaml` has a commented-out thin-pool device class for that.
- **Logical volumes outlive the cluster.** Deleting the cluster leaves the LVs
  behind, because the PVs go with it. Check with `sudo lvs topolvm-vg` and remove
  with `sudo lvremove`.
- **The backing file lives at `/var/lib/topolvm/backing.img`;** size it with
  `sudo BACKING_SIZE=100G storage/setup-host.sh` before the first run.

## Registry (`registry/`, Harbor)

Harbor runs in Docker Compose on the host, so images survive
`cluster/cluster.sh down`. Its TLS certificate comes from the local CA, so
anything that trusts the root CA trusts Harbor.

```bash
registry/setup-host.sh              # certificate, installer, config, start (sudo only for ./prepare)
registry/kind-trust.sh              # after every cluster.sh up: hosts entry, CA and containerd config in the nodes
docker compose -f registry/out/harbor/docker-compose.yml ps     # runs as your user
docker compose -f registry/out/harbor/docker-compose.yml stop   # when you need the memory
```

The admin password is in `registry/out/harbor/harbor.yml`
(`harbor_admin_password`); the user is `admin`. Open
https://harbor.kind.local:3443 — `./hosts.sh` adds the name to its managed block
once `registry/out/` exists, pointing at the kind bridge gateway, so the browser,
the pods and the other containers all reach the same endpoint.

**Harbor is on 3030/3443, not 80/443:** those host ports stay reserved for the
cluster ingress. The HTTPS port is therefore part of the registry name, so images
are tagged `harbor.kind.local:3443/library/...` and the nodes keep their
containerd config under `/etc/containerd/certs.d/harbor.kind.local:3443/`. Both
ports are set in `versions.env` (`HARBOR_HTTP_PORT`, `HARBOR_HTTPS_PORT`);
changing them there and re-running `registry/setup-host.sh` re-renders Harbor's
config, which also re-runs `prepare`.

Privileges, worth knowing:
- **Only `prepare` needs root.** It runs a `--privileged` container with your
  whole filesystem mounted at `/hostfs` and writes the configs and secrets as
  root. It runs once, and again only when `harbor.yml` changes.
- **Everything else runs as your user:** `up`, `stop`, `restart`, `ps`, `logs`.
  After a `prepare`, the script re-adds group read on the four env files that
  Compose itself reads; the file owners stay untouched, because Harbor's
  processes read them as uid 10000.
- **At runtime Harbor is unprivileged:** no container is privileged, and eight of
  nine run as non-root users. Running the installation entirely without root is
  an open upstream issue (goharbor/harbor#17494).

To push from your own Docker (optional, needs root once):

```bash
sudo mkdir -p "/etc/docker/certs.d/harbor.kind.local:3443"
sudo cp pki/out/root-ca.crt "/etc/docker/certs.d/harbor.kind.local:3443/ca.crt"
./hosts.sh          # supplies harbor.kind.local; do not add it by hand as well
docker login harbor.kind.local:3443
```

## Identity (`identity/`, Keycloak)

Keycloak stands in for a company-wide identity provider: it runs on the host, so
it exists before the cluster and survives `cluster/cluster.sh down`. Argo CD and
Harbor are its clients, so one login covers the platform.

```bash
identity/setup-host.sh              # certificate, secrets, containers, realm (no root)
cluster/host-services-dns.sh             # after every cluster.sh up: CoreDNS entry for the pods
docker compose -f identity/compose.yaml ps
docker compose -f identity/compose.yaml stop     # when you need the memory
```

The browser has to resolve the name too, which `./hosts.sh` takes care of: it
adds `keycloak.kind.local` to its managed block once `identity/out/` exists,
alongside the Ingress hosts. The entry points at the **kind bridge gateway**
(`172.21.0.1`), not at `127.0.0.1`: Docker's embedded DNS forwards to the host
resolver, so `/etc/hosts` is what Harbor's containers see as well, and their own
loopback is not the host's. Keycloak publishes on both addresses, so the gateway
address works for the browser, for Harbor and for the pods alike.

- **URL** https://keycloak.kind.local:8443, realm **`localdev`**, admin `admin`.
  The passwords are generated into `identity/out/` (`admin-password`,
  `dev-password`); the realm ships one user, `dev`, in `platform-admins`.
- **The realm is code.** `identity/realm/localdev.yaml` is applied by
  keycloak-config-cli, which *updates* an existing realm, so re-running
  `setup-host.sh` is safe and the file stays the source of truth. Client secrets
  are substituted from `identity/out/` with `$(env:NAME)` and never enter git.
- **Certificate from the local CA,** like Harbor's, so anything that trusts the
  root CA trusts Keycloak. Argo CD verifies it through `rootCA` in `oidc.config`
  rather than skipping verification.
- **Pods reach it** through a CoreDNS `hosts` entry pointing at the kind bridge
  gateway; `cluster/host-services-dns.sh` writes it after every cluster creation.
- **The cluster names it too.** `platformservices/identity/` holds a namespace
  and an ExternalName Service, so the external provider appears in the cluster's
  own naming:
  `keycloak.identity.svc.cluster.local` → `keycloak.kind.local` → `172.21.0.1`.
  Use it to find and reach Keycloak — but **not as the OIDC URL**: a client must
  call the issuer's own hostname, because the token's `iss` has to match what was
  requested and the certificate only carries `DNS:keycloak.kind.local`.
- **Why the gateway address and not Keycloak's container IP.** Keycloak sits on
  its own Docker network (`identity_default`, 172.25.0.0/16). Docker isolates
  bridges, so neither the pods nor Harbor's containers can route there — only the
  host can. `172.21.0.1` is the host's address on the kind bridge, and Keycloak
  publishes its port on it, so browser, Harbor and pods all reach the same
  endpoint. It also has to be a host address because Docker's embedded DNS
  forwards to the host resolver, which means `/etc/hosts` is what containers see.
- **Port 8443** because 80/443 stay reserved for the cluster ingress and Harbor
  holds 3030/3443. The port is part of the issuer URL and of every redirect URI.

**Argo CD** is wired up by `platformservices/deploy.sh` whenever
`identity/out/` exists: it patches the client secret into `argocd-secret` and
`oidc.config` into `argocd-cm`. Permissions come from the group claim —
`platform-admins` get `role:admin`, everyone else `role:readonly`. The local
`admin` account stays as break-glass.

**Start the login on `https://argocd.kind.local`.** cloud-provider-kind's Ingress
serves the UI on plain http too and does *not* redirect to https, but the OIDC
login only completes from the https origin. Starting on http gives one of two
errors:

```
Invalid redirect URL: the protocol and host (including port) must match ...
  -> Argo CD checks the login request's return_url against url in argocd-cm

http: named cookie not present
  -> Argo CD sets argocd.oauthstate with the Secure flag, so a plain-http page
     never stores it and the callback on https finds no state cookie
```

Adding the http origin to `additionalUrls` silences the first error but not the
second, so it is deliberately not configured: the flow would break after the
password has been typed instead of before. The OIDC `redirect_uri` is always
`https://argocd.kind.local/auth/callback`, which is what the realm registers.

**Harbor** is switched over by `registry/oidc-setup.sh`. It needs the root CA in
Harbor's custom certificate directory first, which `./prepare` created as root:

```bash
sudo cp pki/out/root-ca.crt \
  registry/out/harbor/common/config/shared/trust-certificates/kind-dev-root-ca.crt
# proxy as well: nginx resolves its upstreams once at startup, so restarting only core
# and jobservice leaves it pointing at their previous container addresses (API calls
# then land on the wrong service and fail with "should start with 'Harbor-Secret'")
docker compose -f registry/out/harbor/docker-compose.yml restart core jobservice proxy
registry/oidc-setup.sh
```

Members of `platform-admins` become Harbor administrators, users are onboarded
on first login, and the local admin stays reachable at
`/account/sign-in?always_sso_login=false`. Note that OIDC users need the **CLI
secret** from their Harbor profile for `docker login`, not their Keycloak
password.

**Adding a service** is one client in `identity/realm/localdev.yaml` plus that
service's own OIDC settings — the realm holds platform, application and workload
identities alike.

## Monitoring (`platformservices/monitoring/`)

Metrics, logs and traces, deployed by `./deploy.sh` with the other platform
services. The design and its reasons are in `architecture.md` (*Observability*,
ADR-0019 to ADR-0022).

- **Open https://grafana.kind.local** and choose *Sign in with Keycloak* (`dev`
  lands as server admin). `./hosts.sh` adds the name, since it is an Ingress
  host. The local `admin` stays as break-glass; its password is in
  `identity/out/grafana-admin-password`.
- **Dashboards:** *Platform / Cluster overview*, built for the metrics this
  cluster actually has, and Istio's Mesh, Service and Workload dashboards, pinned
  by revision.
- **Sending telemetry from a service:** one endpoint for everything, answered by
  the collector on the pod's own node:

  ```yaml
  env:
    - name: OTEL_EXPORTER_OTLP_ENDPOINT
      value: http://otel-collector.monitoring.svc:4318
    - name: OTEL_EXPORTER_OTLP_PROTOCOL
      value: http/protobuf
  ```

  Pod logs need nothing at all: the collector reads them from each node. Pods
  annotated `prometheus.io/scrape`, `prometheus.io/port` (and optionally
  `prometheus.io/path`) are scraped as well.
- **Mesh traces come for free:** Istio sends every sidecar's spans (100 %
  sampling), and Tempo turns them into span metrics and a service graph. Send a
  few requests to `testapp-mesh.kind.local` and open the service graph in
  Grafana's *Explore → Tempo*.
- **Memory:** roughly 1.2–2 GiB for the whole stack. If the host gets tight,
  stop Harbor first.

Worth knowing on this host: container metrics come from the kubelet's cAdvisor
endpoint, because its summary API fails on ZFS; and host metrics show the host
machine for every node, because kind's nodes share its kernel.

## Browser smoke tests (`tests/`)

The OIDC logins are the part `curl` cannot check: the login button, Keycloak's
form, the callback and the session that comes back are all browser work. Three
real failures during setup lived exactly there, so they have a test.

```bash
tests/run.sh                           # both suites
tests/run.sh specs/harbor.spec.ts      # one service
tests/run.sh specs/argocd.spec.ts
tests/run.sh --headed                  # watch it (needs an X server reachable from the container)
```

One suite per service — `specs/argocd.spec.ts`, `specs/harbor.spec.ts` and
`specs/grafana.spec.ts`, with the shared Keycloak form handling in
`specs/support.ts`. The Grafana suite runs only when monitoring is deployed
(`run.sh` looks for its Ingress), and also asserts that all three data sources
pass Grafana's own health check.

Playwright runs in a container on the `kind` network, with the host names
resolved to where the services actually are: `argocd.kind.local` to the
Ingress's LoadBalancer IP, `keycloak.kind.local` and `harbor.kind.local` to the
kind bridge gateway. Nothing is installed on the host and no sudo is involved.

- **A real browser:** the Chromium build shipped in the Playwright image, driven
  with Chrome's device profile. `PLAYWRIGHT_CHANNEL=chrome` switches to branded
  Google Chrome once the image has fetched it.
- **Certificates are checked before the browser starts.** The throwaway browser
  profile does not trust the local CA, so the tests run with
  `ignoreHTTPSErrors`; `run.sh` verifies all three endpoints with `curl` and the
  real root CA first, so a broken certificate still fails the run.
- **What is asserted:** that Argo CD's session reports `dev` with the
  `platform-admins` group (which is what grants `role:admin`), and that Harbor
  onboards the same user and marks it a Harbor administrator.
- **Credentials** come from `identity/out/dev-password`; nothing is hardcoded.

## Known limitations

[`update-setup-01.md`](update-setup-01.md) has the complete list. The main
points:
- the client source IP is lost on the L4 and Istio paths (cloud-provider-kind
  proxies without PROXY protocol);
- `kubectl apply` doesn't prune: resources removed from `platformservices/`
  stay until deleted by hand, or until Argo CD manages the platform;
- ephemeral storage isn't enforced (the ZFS workaround) and there's no Gateway
  API downgrade protection;
- this host's inotify limits are low (`max_user_instances=128`); kind recommends
  512;
- the intermediate CA keys live in cluster Secrets; there's no CRL/OCSP;
- TopoLVM volumes are node-local, have no snapshots without a thin pool, and
  their logical volumes stay on the host when the cluster is deleted;
- the loop file sits on ZFS here, so it's copy-on-write on copy-on-write: fine
  for dev, but not a performance reference;
- Harbor's `prepare` is a privileged step (see above), and `registry/kind-trust.sh`
  has to run after every cluster creation.

## Status of the 2023 suggestions

| # | Suggestion | Status |
| --- | --- | --- |
| 1–3 | Make the MetalLB pool follow the Docker subnet; one MetalLB path; fix its Helm hooks | Obsolete: MetalLB replaced by cloud-provider-kind |
| 4 | Consider cloud-provider-kind | Done |
| 5 | Upgrade and pin kind, the node image and MetalLB | Done: kind v0.33.0, Kubernetes 1.36.4, every version pinned |
| 6 | Clean up `cluster-config.yaml` | Done: 1 CP + 2 workers, no leftovers |
| 7 | Robust scripts | Done: `set -euo pipefail`, `SCRIPT_DIR`, waits, `up`/`down` |
| 8 | Quality of life | Done: git. Partly: the smoke tests are in step 10 of the plan, but not scripted yet. Open: local image registry |

Possible next steps:
- an Argo CD app-of-apps for `platformservices/` (adds pruning and drift
  detection);
- istio-csr;
- cert-manager for the ESO webhook;
- Istio ambient mode;
- `HTTPRoute`s instead of two Ingresses;
- a real ESO backend such as Vault;
- a scripted smoke test;
- upgrading KEDA.
