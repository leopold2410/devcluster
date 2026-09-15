# kind development cluster

A local multi-node Kubernetes cluster on [kind](https://kind.sigs.k8s.io/)
(Kubernetes IN Docker) with:
- [cloud-provider-kind](https://github.com/kubernetes-sigs/cloud-provider-kind),
  which provides `LoadBalancer` IPs and the default ("vanilla") Ingress;
- Istio as a second ingress path, turned on per namespace;
- cert-manager with a local CA, plus trust-manager;
- the External Secrets Operator (ESO) and Argo CD;
- containerized k9s and lazydocker.

Set up with [`update-setup-01.md`](update-setup-01.md), applied and verified on
2026-09-15. It replaced the 2023 kind + MetalLB + Traefik setup (kept on git
history: commit `ada2a79`).

## Quick start

```bash
cluster/pki/create-ca.sh      # once: local root CA + intermediates (cluster/pki/out/, git-ignored)
cluster/cluster.sh up         # kind cluster, Gateway API CRDs, cloud-provider-kind
./deploy.sh                   # platform services, then test applications
cluster/cluster.sh down       # delete the cluster (the PKI stays)
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
├── cluster/              # kind binary (git-ignored), cluster-config.yaml, cluster.sh (up | down | cpk)
│   └── pki/              # create-ca.sh; out/ holds the CA keys (git-ignored)
├── platformservices/     # one Kustomize tree; Helm charts via helmCharts
│   ├── kustomization.yaml    # renders everything: kubectl kustomize --enable-helm platformservices
│   ├── deploy.sh             # applies the parts in dependency order
│   ├── cert-manager/  trust-manager/  istio/  external-secrets/  argocd/
│   └── keda/                 # old 2.11.0 manifest, not deployed
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
sudo cp cluster/pki/out/root-ca.crt /usr/local/share/ca-certificates/kind-dev-root-ca.crt
sudo update-ca-certificates
certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n "kind-dev Root CA" -i cluster/pki/out/root-ca.crt  # Chrome/Chromium (libnss3-tools)
# Firefox: Settings → Privacy & Security → Certificates → View Certificates → Authorities → Import

# 2. Host names -> Ingress IPs (check the current IPs with "kubectl get ingress -A")
echo "$(kubectl -n argocd get ingress argocd-web -o jsonpath='{.status.loadBalancer.ingress[0].ip}') argocd.kind.local" | sudo tee -a /etc/hosts
```

Then open **https://argocd.kind.local**. The user is `admin`; the initial
password is in a Secret:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

Change it after the first login, then delete that Secret. Without root, use a
port-forward instead: `kubectl -n argocd port-forward svc/argocd-server 8080:80`
→ http://localhost:8080.

For the test apps, add `testapp.kind.local` and `testapp-mesh.kind.local` the same
way. Note that the vanilla and Istio paths have different IPs, so a hosts entry
picks one of them.

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

- **Local PKI (`cluster/pki/create-ca.sh`):**
  - `kind-dev Root CA`: 10 years, name-constrained to `kind.local`, `svc`,
    `cluster.local` and `localhost`;
  - two intermediates (3 years): `kind-dev Issuing CA` for cert-manager and
    `kind-dev Istio Mesh CA` for Istio;
  - the root key is only needed to issue intermediates, so move
    `cluster/pki/out/root-ca.key` offline.
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
- the intermediate CA keys live in cluster Secrets; there's no CRL/OCSP.

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
