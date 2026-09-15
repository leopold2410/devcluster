# Update setup 01: kind upgrade, cloud-provider-kind, Istio per namespace, platform services, PKI, CLI tools

| | |
| --- | --- |
| Date | 2026-09-15 |
| Revision | 8: one Argo CD instance for the whole cluster (upstream `install.yaml` v3.5.3) instead of the Argo CD Operator. Earlier revisions: 7 repository layout and platform services as one Kustomize tree; 6 lazydocker; 5 k9s port-forwards; 4 k9s; 3 cert-manager, trust-manager, local CA; 2 ESO and Argo CD Operator |
| Status | **Applied and verified on 2026-09-15** on branch `update-setup-01`. All step 10 checks passed (HTTP/HTTPS on all paths, STRICT mTLS, ESO, Argo CD with guestbook, k9s port-forward). Fixed while applying: the Traefik repo was moved instead of deleted (step 1); the ZFS kubelet setting (step 2c); the Gateway API `safe-upgrades` policy (step 3); `USER` for k9s (step 8). Still open, because it needs root: the host trust store and `/etc/hosts` (step 4, README *Browser access*) |
| Scope | `/home/leo/dev/kind` |

## Goals

1. **Upgrade kind** from v0.20.0 (Kubernetes 1.27) to a current, pinned release.
2. **Use cloud-provider-kind as the vanilla Kubernetes ingress provider.** It
   provides `LoadBalancer` IPs and the default IngressClass `cloud-provider-kind`,
   and replaces MetalLB and Traefik.
3. **Add Istio with IngressClass `istio` in parallel**, as a second way to reach
   the same services.
4. **Turn on Istio per namespace with a label** (`istio-injection=enabled`).
5. **Platform services, upgraded to their latest versions:**
   - **External Secrets Operator (ESO):** 0.7.2 → **2.10.0**, cluster-wide mode;
   - **Argo CD:** v2.5.8 → **v3.5.3**, one instance that manages all namespaces
     (upstream `install.yaml`, no operator).
6. **Production-like service certificates:**
   - a **local OpenSSL root CA** with two intermediates: one for **cert-manager**
     (Ingress and service certificates) and one for the **Istio mesh CA**;
   - **trust-manager** distributes the root CA certificate to every namespace;
   - the host trusts the root CA, so HTTPS to `*.kind.local` validates.
7. **k9s in a container** (`cli/`, Docker Compose). It always uses the kind
   cluster's own kubeconfig, independent of `~/.kube/config` and the current
   kubectl context.
8. **lazydocker in a container** (`cli/`, same Compose project) for the Docker
   side of the setup: the kind node containers, cloud-provider-kind and its load
   balancer containers, and Compose projects.
9. **A repository layout by purpose:** `cluster/`, `cli/`, `platformservices/`
   (one Kustomize tree for all platform services) and `applications/` (one folder
   per test application).

## Repository layout (target)

```
/home/leo/dev/kind
├── README.md
├── update-setup-01.md
├── versions.env                  # cluster and CLI tool versions (platform services: in their kustomization.yaml)
├── deploy.sh                     # platformservices/deploy.sh, then applications/deploy.sh
├── .gitignore
│
├── cluster/                      # kind cluster, cloud-provider-kind, local PKI
│   ├── kind                      # kind v0.33.0 binary (git-ignored)
│   ├── cluster-config.yaml
│   ├── cluster.sh                # up | down | cpk
│   └── pki/
│       ├── create-ca.sh
│       └── out/                  # root CA + intermediates (git-ignored)
│
├── cli/                          # CLI / UI management tools, Compose project "kind-cli"
│   ├── compose.yaml              # services k9s, lazydocker
│   ├── k9s.Dockerfile
│   ├── lazydocker.Dockerfile
│   ├── k9s.sh
│   ├── lazydocker.sh
│   ├── .env -> ../versions.env
│   ├── k9s/                      # k9s config (committed)
│   ├── lazydocker/               # lazydocker config (committed)
│   └── kubeconfig                # generated (git-ignored)
│
├── platformservices/             # one Kustomize tree; Helm charts via helmCharts
│   ├── kustomization.yaml        # renders all platform services at once
│   ├── deploy.sh                 # applies the parts in dependency order
│   ├── cert-manager/             # chart + namespace;       config/: ClusterIssuer kind-ca
│   ├── trust-manager/            # chart;                   config/: Bundle kind-root-ca
│   ├── istio/                    # base + istiod + namespace; gateway/: ingress gateway; config/: IngressClass, certificate
│   ├── external-secrets/         # chart + namespace;       examples/
│   ├── argocd/                   # upstream install.yaml v3.5.3, namespace, Ingress; examples/
│   └── keda/                     # unchanged 2.11.0 manifest, not deployed (out of scope)
│
└── applications/                 # test applications, one folder each
    ├── deploy.sh                 # deploys the default applications (testapp)
    ├── testapp/                  # base + overlays/{plain,mesh}
    ├── secret-test/              # own git repository (git-ignored here)
    └── testhelm/                 # sample Helm chart
```

Where the current files go:

| Current | New |
| --- | --- |
| `kind`, `cluster-config.yaml`, `cluster.sh` | `cluster/` |
| — (new) | `cluster/pki/` |
| — (new) | `cli/` |
| `deployments/basicservices/istio/` | `platformservices/istio/` (Helm script replaced by Kustomize) |
| `deployments/basicservices/argocd/` | `platformservices/argocd/` (v2.5.8 manifest replaced by the upstream v3.5.3 install through Kustomize) |
| `deployments/external-secrets-operator/` | `platformservices/external-secrets/` (Kustomize generator replaced) |
| — (new) | `platformservices/cert-manager/`, `platformservices/trust-manager/` |
| `deployments/keda/` | `platformservices/keda/` |
| `deployments/testapp/` | `applications/testapp/` |
| `deployments/secret-test/` | `applications/secret-test/` |
| `deployments/basicservices/testhelm/` | `applications/testhelm/` |
| `deployments/basicservices/metallb/`, `…/traefik/`, `…/deploy.sh` | deleted |
| `deployments/README.md` | merged into `README.md` |
| `logs.txt` | deleted |

## Target architecture (runtime)

```
Host (Linux)
│
├── cluster/pki/out/ (git-ignored)   kind-dev Root CA ── root key can be moved offline
│                                       ├── kind-dev Issuing CA    → cert-manager ClusterIssuer "kind-ca"
│                                       └── kind-dev Istio Mesh CA → Istio plug-in CA (secret "cacerts")
│   Host trust store: kind-dev Root CA (name-constrained to kind.local / svc / cluster.local / localhost)
│
├── cli/  Compose project "kind-cli": k9s v0.51.0 + kubectl v1.36.4, joined to the "kind" network
│         kubeconfig from "kind get kubeconfig --internal" → https://dev-control-plane:6443
│         k9s port-forwards published on 127.0.0.1:18000-18009
│         lazydocker v0.25.2 on the Docker socket (no network), project directory mounted read-only
│
├── container "cloud-provider-kind"  (docker.sock mounted, host network)
│     ├── LoadBalancer Services  → one Envoy container "kindccm-…" per Service, IP from the kind network
│     └── Ingress class "cloud-provider-kind" (default)
│           → Gateway API Gateway + HTTPRoutes, HTTP :80 + HTTPS :443 (one Gateway, and one IP, per namespace)
│
└── kind cluster "dev" (Kubernetes 1.36)
      │  Platform services (istio-injection=disabled), from platformservices/
      ├── cert-manager            cert-manager (ClusterIssuer kind-ca), trust-manager (Bundle kind-root-ca)
      ├── istio-system            istiod (plug-in CA), istio-ingressgateway (LoadBalancer), wildcard cert *.kind.local
      ├── external-secrets        ESO controller, webhook, cert-controller (cluster-wide)
      ├── argocd                  Argo CD v3.5.3: one instance for all namespaces, UI via https://argocd.kind.local
      │
      │  Applications, from applications/ (each namespace gets ConfigMap kind-root-ca from trust-manager)
      ├── testapp        istio-injection=disabled   plain Kubernetes
      └── testapp-mesh   istio-injection=enabled    Istio sidecars, mTLS with certificates chaining to the local root
```

Every app can be reached in three ways:

| Path | Entry point | Resources | TLS |
| --- | --- | --- | --- |
| **Vanilla L7** | cloud-provider-kind Envoy (IP per namespace) | `Ingress` with `ingressClassName: cloud-provider-kind` | cert-manager annotation on the Ingress → Secret in the app namespace |
| **Istio L7** | `istio-ingressgateway` (one shared IP) | `Ingress` with `ingressClassName: istio` | Wildcard `*.kind.local` Certificate in `istio-system` |
| **L4** | cloud-provider-kind LB container (IP per Service) | `Service` with `type: LoadBalancer` | Whatever the app terminates itself |

## Decisions and versions

All versions were checked on 2026-09-15. Cluster and CLI tool versions go in a
new `versions.env`. Platform service versions are pinned in their
`kustomization.yaml` (`helmCharts[].version`, or the release tag in a URL), so
each version lives in exactly one place.

| Component | Current | New | Reason |
| --- | --- | --- | --- |
| kind | v0.20.0 | **v0.33.0** | Latest release (2026-08-26) |
| Node image | Kubernetes 1.27 (kind default) | **`kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed`** | From the kind v0.33.0 release notes. Istio 1.31 supports Kubernetes 1.32–1.36, so the newer v1.37.0 image is deliberately **not** used |
| kubectl | — (not installed) | **v1.36.4** | Matches the node image; used on the host and in the `cli/` image (includes Kustomize v5.8.1) |
| Helm | — (not installed) | **v3.22.0** | Only used to render charts for Kustomize (`kubectl kustomize --enable-helm`). v4.3.0 rendered the same tree successfully too |
| cloud-provider-kind | — | **v0.11.1** | Latest release (2026-06-26). Runs as a container: `registry.k8s.io/cloud-provider-kind/cloud-controller-manager` |
| Gateway API CRDs | v1alpha2 (from Traefik) | **v1.6.2** (standard channel) | Istio 1.31 docs install v1.6.0; v1.6.2 is its latest patch |
| Istio | unpinned | **1.31.0**, sidecar mode | Current release; supported until about February 2027. Charts from **`https://blob.istio.io/istio-release/charts`**: the old repo `istio-release.storage.googleapis.com/charts` stops at `1.31.0-rc.0` (checked) |
| cert-manager | — | **v1.21.2** | Latest release (2026-09-11). Chart `jetstack/cert-manager` |
| trust-manager | — | **v0.25.0** | Latest release (2026-09-11). Chart `jetstack/trust-manager` |
| External Secrets Operator | chart 0.7.2 (Feb 2023, vendored) | **chart 2.10.0 / app v2.10.0** | Latest release (2026-08-28) |
| Argo CD | v2.5.8 | **v3.5.3** | Latest release (2026-09-14). Argo CD tests 3.5 with Kubernetes 1.33–1.36. Upstream `install.yaml` through Kustomize, no operator |
| k9s | — | **v0.51.0** | Latest release (2026-06-06). Built into a local image, because Docker Hub's `derailed/k9s` only goes up to v0.50.18 and bundles kubectl v1.32.2 |
| lazydocker | — | **v0.25.2** | Latest release (2026-04-19). Built into a local image, because Docker Hub's `lazyteam/lazydocker` was last updated in 2022. The image contains Alpine's `docker-cli` 29.5.2 and `docker-cli-compose` 2.40.3 |
| OpenSSL (host) | 3.0.13 | — | Used by `cluster/pki/create-ca.sh` |
| Docker Compose (host) | v5.3.0 | — | Used by `cli/` |

Design decisions:

**Repository layout and Kustomize**
- **Four top-level folders, each with one purpose:**
  - `cluster/` creates and removes the cluster (kind, cloud-provider-kind,
    Gateway API CRDs) and holds the local PKI, which outlives any cluster;
  - `cli/` holds the management tools, which run next to the cluster;
  - `platformservices/` holds everything installed into the cluster once, for
    all applications;
  - `applications/` holds test workloads, one folder per application, each with
    its own `deploy.sh`.
- **Can all platform services be one Kustomize setup? Yes for rendering, but not
  for a single apply.**
  - Every platform service is a Kustomize directory. Helm charts come in through
    `helmCharts`, which `kubectl kustomize --enable-helm` renders with
    `helm template`. Plain manifests sit next to them.
  - `platformservices/kustomization.yaml` includes all parts, so
    `kubectl kustomize --enable-helm platformservices` renders the whole
    platform. In the test that was 217 resources, including 50 CRDs, with no
    conflicts between the parts. Use it for review and `kubectl diff`, and later
    as the source for an Argo CD app-of-apps.
  - It can't be applied in one go, because CRDs and webhooks must be ready before
    the resources that use them. `platformservices/deploy.sh` applies the parts
    in dependency order and waits in between:
    1. cert-manager;
    2. trust-manager, whose webhook certificate comes from cert-manager;
    3. the ClusterIssuer and the root CA Bundle;
    4. Istio base and istiod, which reads `cacerts` at startup;
    5. the Istio gateway, whose pods use `image: auto` and get their proxy
       from istiod's injection webhook (checked in the rendered chart);
    6. the Istio IngressClass and certificate;
    7. ESO;
    8. Argo CD.
  - For the same reason, controllers and their custom resources live in separate
    directories (`<service>/` and `<service>/config/`).
- **The secrets from the local PKI are deliberately not part of Kustomize.** They
  would show up in every render, and they must never reach git.
  `platformservices/deploy.sh` creates them from `cluster/pki/out/`.
- **Trade-offs compared with `helm upgrade --install`** (the previous revisions):
  - there's no Helm release history and no `helm rollback`;
  - there's no `--wait`; `deploy.sh` waits instead;
  - resources removed from the tree aren't deleted automatically, because
    `kubectl apply` doesn't prune;
  - in exchange, you get one declarative format, one render of the whole
    platform, and a tree Argo CD can use directly later;
  - none of the six charts uses Helm hooks or `lookup` (checked). Those are the
    main features `helm template` can't handle.
- **Found while testing: Istio charts now come from `blob.istio.io`.** The old
  repo has no `1.31.0` charts, so earlier revisions'
  `helm repo add istio https://istio-release.storage.googleapis.com/charts`
  would have failed.

**Networking**
- **Install the Gateway API CRDs before starting cloud-provider-kind.**
  cloud-provider-kind only *creates* CRDs that are missing and never updates
  existing ones. Installing first guarantees that Istio and cloud-provider-kind
  share the version above.
- **Keep cloud-provider-kind's Gateway API controller enabled**
  (`--gateway-channel standard`, the default). Its Ingress support is built on
  top of it, so disabling it would also disable the vanilla Ingress.
- **cloud-provider-kind is the default IngressClass** (`--enable-default-ingress=true`,
  the default). Istio's `ingressControllerMode` defaults to `STRICT`, so Istio
  only handles Ingresses with `ingressClassName: istio`, and the two don't
  overlap. Every Ingress should still set its class explicitly.
- **Name the Istio gateway release `istio-ingressgateway`** (currently
  `istio-ingress`). The Istio `gateway` chart derives the Service name
  (`istio-ingressgateway`) and pod label (`istio: ingressgateway`) from the
  release name (confirmed in the render). Those match Istio's default
  `meshConfig.ingressService`, so Kubernetes Ingress works without extra mesh
  settings.
- **Use sidecar mode with `istio-injection=enabled` per namespace.** It matches
  today's Helm install and gives full L7 policy enforcement at every pod without
  waypoints. Platform namespaces are explicitly labelled `istio-injection=disabled`.
  Ambient mode (`istio.io/dataplane-mode=ambient`) is a possible later update.
- **Remove MetalLB and Traefik.** Nothing in the repo uses Traefik-specific
  features. The only Traefik-only resource, `09-ingress-metrics.yaml`, exposes
  Traefik's own metrics.
- **Shrink the cluster to 1 control plane + 2 workers.** The `tier: ingress`
  labels and `extraPortMappings` were only needed for Traefik's NodePorts.

**Certificates (PKI)**
- **Two-tier PKI, as in production.**
  - The **root CA** is created with OpenSSL on the host, and its key never
    enters the cluster.
  - The script only needs the root key to issue a missing intermediate, so the
    key can be kept offline.
  - The two **intermediates** have `pathlen:0`, so they can't create further CAs.
    Their keys live in cluster Secrets, as with any in-cluster CA.
  - Two intermediates, not one, so the mesh and the Ingress/service certificates
    can be rotated or revoked independently.
- **The root CA is name-constrained** (critical) to `kind.local`, `svc`,
  `cluster.local` and `localhost`, which makes it safe to add to the host trust
  store. Even a leaked intermediate key can't produce a certificate that the host
  accepts for real domains. This was tested:
  - `testapp.kind.local`, `*.kind.local`, `nginx.testapp.svc`,
    `nginx.testapp.svc.cluster.local` and `localhost` verify;
  - `example.com` and `google.com` are rejected.
- **Algorithms and lifetimes:** RSA 4096 for the CAs; 10 years for the root,
  3 years for the intermediates. Leaf certificates from cert-manager last 90 days
  and are renewed 15 days before expiry.
- **cert-manager `ClusterIssuer` `kind-ca`** of type `CA`.
  - Its Secret `kind-issuing-ca` is in the `cert-manager` namespace (the cluster
    resource namespace).
  - `tls.crt` holds the full chain, *intermediate → root*, so issued Secrets get
    the correct `ca.crt` (as the cert-manager CA issuer docs require).
- **trust-manager `Bundle` `kind-root-ca`** writes the root certificate into a
  ConfigMap `kind-root-ca` (key `ca.crt`) in every namespace. Apps mount it to
  trust internal TLS. The public root certificate is its source.
- **Istio mesh CA:** Istio's *plug-in CA* feature.
  - The Secret `cacerts` (`ca-cert.pem`, `ca-key.pem`, `root-cert.pem`,
    `cert-chain.pem`) is created from the mesh intermediate **before** istiod is
    installed. The rendered istiod Deployment mounts it.
  - Workload mTLS certificates, and the `istio-ca-root-cert` ConfigMap, then
    chain to the same local root.
  - The alternative, istio-csr v0.17.0 (cert-manager as the mesh CA), is a
    possible follow-up.
- **Ingress TLS:**
  - *Vanilla:* annotate the Ingress with `cert-manager.io/cluster-issuer: kind-ca`.
    cert-manager creates the Certificate and Secret in the app namespace, and
    cloud-provider-kind adds the Secret to the namespace's Gateway as an HTTPS
    listener.
  - *Istio:* one wildcard Certificate `*.kind.local` in `istio-system`, because
    Istio reads Ingress TLS Secrets from the gateway's namespace, not the app's.
    Istio Ingresses therefore carry **no** cert-manager annotation.
  - TLS is terminated at the edge. Apps and Argo CD keep serving plain HTTP
    behind it (`server.insecure: true`).

**External Secrets Operator**
- **Install the chart through Kustomize** (`helmCharts`, version pinned). This
  replaces the unpinned `HelmChartInflationGenerator` and the vendored 0.7.2
  chart in `base/charts/`.
- **Switch from namespace-scoped to cluster-wide mode** (the chart defaults).
  Today it's restricted to its own namespace (`scopedNamespace`/`scopedRBAC`)
  with `ClusterSecretStore`, `ClusterExternalSecret` and `PushSecret` disabled,
  which is useless as a platform service.
- **ESO 2.x serves only the `external-secrets.io/v1` API**
  (`v1beta1` is off unless you set `crds.unsafeServeV1Beta1`). The repo has no
  ESO resources, so nothing needs migrating.

**Argo CD**
- **One Argo CD instance for the whole cluster, without an operator.** The
  upstream `install.yaml` at tag `v3.5.3` is a Kustomize remote resource. That's
  the Kustomize install from Argo CD's docs, pinned to a tag instead of `stable`.
  - It's the cluster-wide variant: the application controller's ClusterRole
    allows every verb on every resource. So the instance deploys into any
    namespace and can create namespaces. (`namespace-install.yaml` would limit
    it to its own namespace.)
  - It's also the newest Argo CD. Argo CD tests 3.5 with Kubernetes 1.36; the
    operator's pinned v3.3.10 was only tested up to 1.35.
  - Without the operator there's no `ArgoCD` custom resource, no conversion
    webhook to disable and no cluster-scope environment variable. Argo CD's
    settings are its own ConfigMaps (`argocd-cm`, `argocd-rbac-cm`,
    `argocd-cmd-params-cm`), patched in the same Kustomization.
- **`server.insecure: "true"` in `argocd-cmd-params-cm`** (a Kustomize patch,
  checked in the render) and our own Ingress (class `cloud-provider-kind`,
  `pathType: Prefix`, TLS via cert-manager). TLS is terminated at the Ingress.
- **`Application`s live in the `argocd` namespace** (the default). Argo CD deploys
  from there into any namespace. Letting teams create `Application`s in their own
  namespaces ("apps in any namespace") is possible but not enabled (step 5f).

**CLI (k9s, lazydocker)**
- **Build a small local image for k9s instead of using `derailed/k9s`.**
  - Docker Hub has no image for the latest k9s (v0.51.0).
  - The official image ships kubectl v1.32.2, four minor versions behind the
    cluster, outside kubectl's supported ±1 version skew.
  - The local image is `alpine:3.23.3` + k9s + kubectl, with both binaries
    checked against their published SHA-256 checksums during the build.
  - It's tagged `kind-cli/k9s:<k9s>-kubectl-<kubectl>`, so changing a version in
    `versions.env` makes Compose build a new image on the next start (tested).
- **Always the kind cluster's kubeconfig, never `~/.kube/config`.**
  - `cli/k9s.sh` regenerates `cli/kubeconfig` with
    `kind get kubeconfig --internal` on every start, because a recreated cluster
    has new certificates.
  - The container joins the `kind` Docker network and reaches the API server as
    `dev-control-plane:6443`, independent of the random host port and the host's
    current context.
  - `cluster/cluster.sh up` writes the file too, so plain
    `docker compose run --rm k9s` works as well.
  - If the file is missing, Compose fails with a clear error instead of creating
    an empty directory (`create_host_path: false`, tested).
- **The k9s container runs as the host user** (UID/GID), so files k9s writes
  into `cli/k9s/` belong to you. Data and state go into the named volume
  `kind-cli_k9s-local`.
- **Compose reads the versions through `cli/.env`**, a symlink to
  `../versions.env`, so there's still only one place for tool versions.
- **k9s port-forwards are reachable from the host, and only from the host.**
  - `K9S_DEFAULT_PF_ADDRESS=0.0.0.0` makes k9s listen on all interfaces
    *inside* the container. With the default `localhost`, a forward would be
    unreachable from outside the container.
  - Compose publishes the range `127.0.0.1:18000-18009`, so forwards are reachable
    at `localhost:<port>` on the host but not from the LAN.
  - `cli/k9s.sh` starts the container with `--service-ports`; plain
    `docker compose run` publishes nothing.
  - Tested:
    - a listener on `0.0.0.0:18000` inside the container is reachable at
      `127.0.0.1:18000`;
    - a listener on `127.0.0.1` inside the container is not;
    - the host's LAN address is not;
    - without `--service-ports`, nothing is published.
- **lazydocker also gets a local image** (`cli/lazydocker.Dockerfile`), because
  `lazyteam/lazydocker` hasn't been updated since 2022.
  - It contains `alpine:3.23.3`, lazydocker v0.25.2 (checked against its
    SHA-256 checksum) and Alpine's `docker-cli` and `docker-cli-compose`, which
    lazydocker calls for Compose actions.
  - Both images live in one Compose project, `kind-cli`, as the services `k9s`
    and `lazydocker`, built from `k9s.Dockerfile` and `lazydocker.Dockerfile`.
- **lazydocker talks only to the Docker socket, as the host user.**
  - It mounts `/var/run/docker.sock` and runs as your UID/GID, plus the socket's
    group via `group_add`. That's GID 984 on this host, and `lazydocker.sh`
    detects it.
  - Its config ends up in `cli/lazydocker/` (`CONFIG_DIR`), owned by you.
  - `network_mode: none`: it doesn't need a network, and it works without a
    running cluster (tested).
- **Compose projects are visible from inside the container.**
  - `cli/lazydocker.sh [dir]` uses the project directory (default: the current
    directory) as the working directory, and mounts its git repository
    read-only at the same path.
  - lazydocker then shows that project's Compose services, and `docker compose`
    sees the same paths as on the host.
  - Relative symlinks inside the repository resolve too. Tested:
    `cli/.env → ../versions.env` broke when only `cli/` was mounted, and works
    with the repository mounted.

---

## Step 0: Baseline, branch and prerequisites

The folder is not under version control, and the steps below move and delete
files. Commit a baseline first and do the update on a branch:

```bash
cd /home/leo/dev/kind
cat > .gitignore <<'EOF'
/kind
# Own git repositories, not tracked here
/deployments/secret-test/
/deployments/basicservices/traefik/
EOF
git init -b main
git add -A
git commit -m "Baseline before update-setup-01"
git switch -c update-setup-01
```

`deployments/secret-test/` is its own git repository; changes there are
committed separately (step 7). The `.gitignore` is replaced by the final version
in step 1.

Tools needed on the host (on this machine, `kubectl` and `helm` are currently
**not installed**):

| Tool | Install |
| --- | --- |
| docker | already installed |
| docker compose | already installed (v5.3.0); used by `cli/` |
| openssl | already installed (3.0.13) |
| git | needed by `cli/lazydocker.sh` to find the repository root |
| kubectl v1.36.4 | see below |
| helm v3.22.0 | see below. Only renders charts for `kubectl kustomize --enable-helm` and must be on `PATH` |
| certutil (optional) | `sudo apt install libnss3-tools`, to add the root CA to Chrome/Chromium |

Both downloads are checked against their published SHA-256 checksums. The same
downloads and checks were used in the render test.

```bash
mkdir -p ~/.local/bin && cd /tmp
# kubectl
curl -fsSLO https://dl.k8s.io/release/v1.36.4/bin/linux/amd64/kubectl
echo "$(curl -fsSL https://dl.k8s.io/release/v1.36.4/bin/linux/amd64/kubectl.sha256)  kubectl" | sha256sum -c -
install -m 0755 kubectl ~/.local/bin/ && rm kubectl
# helm
curl -fsSLO https://get.helm.sh/helm-v3.22.0-linux-amd64.tar.gz
curl -fsSL https://get.helm.sh/helm-v3.22.0-linux-amd64.tar.gz.sha256sum | sha256sum -c -
tar -xzf helm-v3.22.0-linux-amd64.tar.gz && install -m 0755 linux-amd64/helm ~/.local/bin/
rm -rf linux-amd64 helm-v3.22.0-linux-amd64.tar.gz
```

No kind cluster is running at the moment (the `kind` Docker network doesn't
exist), so no live cluster needs migrating. The cluster is rebuilt from scratch.

## Step 1: Restructure the repository

Move what is kept, delete what is replaced, and write the final `.gitignore`.
The following steps then rewrite and add files in the new places.

```bash
cd /home/leo/dev/kind
mkdir -p cluster platformservices/external-secrets applications

# cluster/
mv kind cluster/kind                                  # untracked binary; replaced in step 2
git mv cluster-config.yaml cluster.sh cluster/

# platformservices/
git mv deployments/basicservices/istio  platformservices/istio
git mv deployments/basicservices/argocd platformservices/argocd
git mv deployments/keda                 platformservices/keda
git mv deployments/external-secrets-operator/prerequisites/01-namespace.yaml \
       platformservices/external-secrets/namespace.yaml

# applications/
git mv deployments/testapp                applications/testapp
git mv deployments/basicservices/testhelm applications/testhelm
mv deployments/secret-test applications/secret-test   # own git repository, not tracked here

# Traefik is its own git repository with unpushed changes: keep it, outside the project
mv deployments/basicservices/traefik ~/dev/traefik

# replaced or no longer needed (-f: istio/deploy.sh is a staged rename after the git mv above)
git rm -r -q -f deployments/basicservices/metallb deployments/basicservices/deploy.sh \
    deployments/external-secrets-operator deployments/README.md \
    platformservices/istio/deploy.sh logs.txt
find deployments -depth -type d -empty -delete
```

What gets removed:
- the MetalLB wrapper chart and the kustomize/native-manifest variant, with
  their hard-coded `172.22.255.x` pools;
- Traefik from the setup, including its `v1alpha2` Gateway API CRDs (the cause
  of the conflict with Istio), its default IngressClass and the metrics
  `IngressRoute`. Its folder is a separate git repository with unpushed changes,
  so it moves to `~/dev/traefik` instead of being deleted;
- the old ESO generator with its vendored 0.7.2 chart;
- the Istio Helm script, which is replaced by Kustomize in step 5;
- `deployments/README.md`, whose content moves into `README.md` in step 9;
- the empty `logs.txt`.

New `.gitignore`:

```
/cluster/kind
/cluster/pki/out/
/cli/kubeconfig
/applications/secret-test/
# Helm charts downloaded by "kubectl kustomize --enable-helm"
charts/
```

`cluster/pki/out/` holds private keys and `cli/kubeconfig` holds cluster-admin
credentials; neither may ever be committed.

```bash
git add -A && git commit -m "Restructure repository (update-setup-01, step 1)"
```

## Step 2: Upgrade kind and the cluster config

**2a. Replace the binary:**

```bash
curl -Lo cluster/kind https://kind.sigs.k8s.io/dl/v0.33.0/kind-linux-amd64
chmod +x cluster/kind
cluster/kind version        # expect: kind v0.33.0
```

**2b. New file `versions.env`** (top level):

```bash
# Pinned versions for the cluster and the CLI tools (update-setup-01)
# Also read by Docker Compose in cli/ (cli/.env is a symlink to this file).
# Platform service versions are pinned in platformservices/**/kustomization.yaml
# (helmCharts[].version, or the release tag in a URL).
CLUSTER_NAME=dev
KIND_VERSION=v0.33.0
KIND_NODE_IMAGE=kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed
# kubectl on the host and in cli/ matches the node image version
KUBECTL_VERSION=v1.36.4
CPK_VERSION=v0.11.1
GATEWAY_API_VERSION=v1.6.2
K9S_VERSION=v0.51.0
LAZYDOCKER_VERSION=v0.25.2
```

List all platform service versions:

```bash
grep -rnE '^\s+version:|/v[0-9.]+/manifests/' platformservices --include=kustomization.yaml
```

**2c. Rewrite `cluster/cluster-config.yaml`:**

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: dev
# Disable disk-pressure eviction (useful on a nearly full laptop disk)
kubeadmConfigPatches:
- |
  apiVersion: kubelet.config.k8s.io/v1beta1
  kind: KubeletConfiguration
  evictionHard:
    nodefs.available: "0%"
  # Docker storage on this host is ZFS. The kubelet (cAdvisor) can't read rootfs stats for a
  # ZFS dataset inside a kind node and exits with "failed to get rootfs info" (kind#4229).
  # Without local storage capacity isolation the kubelet skips that check;
  # ephemeral-storage requests/limits are then not enforced.
  localStorageCapacityIsolation: false
nodes:
- role: control-plane
- role: worker
- role: worker
```

Compared with the current file:
- the example header comment is removed;
- the `my-hostname` certSAN patch is removed. It targeted kubeadm `v1beta3`,
  which newer node images no longer use, so it would have been silently ignored;
- the `tier=ingress` labels, the `extraPortMappings` (32080→5080, 32443→5443)
  and the commented-out workers are removed;
- 3 + 1 workers become 2;
- the node image is **not** set here. `cluster.sh` passes it with `--image`, so
  it's only pinned in `versions.env`;
- `localStorageCapacityIsolation: false` is added. This was found while applying
  the plan: Docker's storage on this host is ZFS, and the kubelet exited with
  `failed to get rootfs info: cannot find filesystem info for device "rpool/…"`,
  so the control plane never started.
  - The cause is cAdvisor v0.56.2, vendored by Kubernetes 1.36. For a ZFS
    rootfs it calls the `zfs` command, which isn't in the node image, and has no
    fallback (kind#4229). The fix is on cAdvisor master but not released.
  - Kubernetes 1.36 only runs the fatal rootfs check when local storage capacity
    isolation is on, so turning it off avoids the crash.
  - Mounting `/dev/zfs` into the nodes would not help: the missing `zfs` command
    is the problem.

## Step 3: cloud-provider-kind and Gateway API CRDs (`cluster/cluster.sh`)

**Rewrite `cluster/cluster.sh`** so it creates the cluster, installs the CRDs,
starts cloud-provider-kind, writes the kubeconfig for `cli/`, and tears
everything down again:

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR="$SCRIPT_DIR/.."
source "$ROOT_DIR/versions.env"
KIND="$SCRIPT_DIR/kind"
CPK_CONTAINER=cloud-provider-kind

up() {
    "$KIND" create cluster --config "$SCRIPT_DIR/cluster-config.yaml" \
        --name "$CLUSTER_NAME" --image "$KIND_NODE_IMAGE"
    kubectl config use-context "kind-$CLUSTER_NAME"
    kubectl wait --for=condition=Ready nodes --all --timeout=180s

    # Gateway API CRDs must exist before cloud-provider-kind starts:
    # it only creates missing CRDs and never updates them.
    kubectl apply --server-side -f \
        "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
    # The bundle's "safe-upgrades" admission policy rejects cloud-provider-kind's attempt to create
    # its embedded (older) CRDs, and cloud-provider-kind then fails to start. Without the policy it
    # gets "already exists" and keeps the version installed above.
    kubectl delete validatingadmissionpolicybinding,validatingadmissionpolicy \
        safe-upgrades.gateway.networking.k8s.io --ignore-not-found

    cpk_start

    # Kubeconfig for the k9s container (cli/): API server via the "kind" network
    (umask 077 && "$KIND" get kubeconfig --internal --name "$CLUSTER_NAME" > "$ROOT_DIR/cli/kubeconfig")
}

cpk_start() {
    docker rm -f "$CPK_CONTAINER" >/dev/null 2>&1 || true
    docker run -d --name "$CPK_CONTAINER" --restart unless-stopped --network host \
        -v /var/run/docker.sock:/var/run/docker.sock \
        "registry.k8s.io/cloud-provider-kind/cloud-controller-manager:${CPK_VERSION}"
}

down() {
    docker rm -f "$CPK_CONTAINER" >/dev/null 2>&1 || true
    "$KIND" delete cluster --name "$CLUSTER_NAME"
    # Load balancer / gateway containers created by cloud-provider-kind
    docker ps -aq --filter "name=kindccm" | xargs -r docker rm -f
    rm -f "$ROOT_DIR/cli/kubeconfig"
}

case "${1:-up}" in
    up)   up ;;
    down) down ;;
    cpk)  cpk_start ;;
    *)    echo "usage: $0 [up|down|cpk]" >&2; exit 1 ;;
esac
```

Notes:
- cloud-provider-kind runs with its defaults: Gateway API channel `standard`,
  default IngressClass on. No port mapping is needed on Linux, because the kind
  Docker network is directly reachable from the host.
- `down` removes every container named `kindccm*`, including those of other kind
  clusters if you run several.
- Mounting `docker.sock` gives the container root-equivalent access to the host.
  That's acceptable for a local dev machine.
- **The `safe-upgrades` admission policy is removed** right after the CRDs are
  installed. This was found while applying the plan.
  - The Gateway API v1.6.2 bundle includes a `ValidatingAdmissionPolicy` that
    rejects installing older CRD versions.
  - cloud-provider-kind v0.11.1 tries to *create* its embedded v1.5.0 CRDs at
    startup. The policy denied that before the normal "already exists" answer
    could come back, and cloud-provider-kind stopped with
    `Failed to start cloud controller`.
  - Without the policy, it logs `already exists, skipping creation` and our
    v1.6.2 CRDs stay (verified).

Check:

```bash
cluster/cluster.sh up
docker logs cloud-provider-kind | tail
kubectl get ingressclass          # cloud-provider-kind (default)
kubectl get gatewayclass          # cloud-provider-kind
kubectl get crd | grep gateway.networking.k8s.io
```

## Step 4: Local PKI with OpenSSL (`cluster/pki/`)

This runs once, independently of the cluster lifecycle.
`cluster/cluster.sh down` does **not** touch `cluster/pki/out/`, so a recreated
cluster reuses the same root CA, and the host trust stays valid.

```
cluster/pki/
├── create-ca.sh              # committed
└── out/                      # git-ignored, created by the script
    ├── root-ca.crt           # kind-dev Root CA (10 years, name-constrained); public
    ├── root-ca.key           # root key: move offline after the first run
    ├── issuing-ca.crt/.key   # kind-dev Issuing CA (3 years, pathlen:0) → cert-manager
    ├── issuing-ca-chain.crt  # issuing-ca + root (tls.crt of the ClusterIssuer Secret)
    ├── istio-ca.crt/.key     # kind-dev Istio Mesh CA (3 years, pathlen:0) → Istio cacerts
    └── istio-ca-chain.crt    # istio-ca + root (cert-chain.pem)
```

**New file `cluster/pki/create-ca.sh`.** This exact script was tested on this
host (OpenSSL 3.0.13):
- the chain verifies;
- re-running it doesn't change existing keys or certificates;
- with `root-ca.key` moved away, a re-run keeps the existing root;
- if an intermediate is missing and the root key isn't there, it stops with a
  clear error;
- the name constraints reject `example.com`.

```bash
#!/usr/bin/env bash
# Local root CA + two intermediate CAs for the kind dev cluster (update-setup-01).
# Output in pki/out/ (git-ignored). Existing certificates/keys are never overwritten.
# root-ca.key is only needed to issue missing intermediates and may be kept offline.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
umask 077
mkdir -p out
cd out

# The root may only certify names below these domains, even if a key leaks
NAME_CONSTRAINTS="critical,permitted;DNS:kind.local,permitted;DNS:svc,permitted;DNS:cluster.local,permitted;DNS:localhost"

if [[ ! -f root-ca.crt ]]; then
    openssl req -x509 -new -newkey rsa:4096 -nodes -sha256 -days 3650 \
        -keyout root-ca.key -out root-ca.crt \
        -subj "/O=kind-dev/CN=kind-dev Root CA" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -addext "subjectKeyIdentifier=hash" \
        -addext "nameConstraints=${NAME_CONSTRAINTS}"
fi

# $1 = file prefix, $2 = common name
issue_intermediate() {
    local name=$1 cn=$2
    [[ -f $name.crt ]] && return 0
    [[ -f root-ca.key ]] || { echo "root-ca.key is required to issue $name - restore it from offline storage" >&2; exit 1; }
    openssl req -new -newkey rsa:4096 -nodes -sha256 \
        -keyout "$name.key" -out "$name.csr" -subj "/O=kind-dev/CN=$cn"
    openssl x509 -req -in "$name.csr" -CA root-ca.crt -CAkey root-ca.key -CAcreateserial \
        -days 1095 -sha256 -out "$name.crt" -extfile <(printf '%s\n' \
            "basicConstraints=critical,CA:TRUE,pathlen:0" \
            "keyUsage=critical,keyCertSign,cRLSign" \
            "subjectKeyIdentifier=hash" \
            "authorityKeyIdentifier=keyid:always")
    rm "$name.csr"
    cat "$name.crt" root-ca.crt > "$name-chain.crt"
}

issue_intermediate issuing-ca "kind-dev Issuing CA"      # -> cert-manager ClusterIssuer "kind-ca"
issue_intermediate istio-ca   "kind-dev Istio Mesh CA"   # -> Istio plug-in CA (secret cacerts)

chmod 644 ./*.crt
openssl verify -CAfile root-ca.crt issuing-ca.crt istio-ca.crt
```

Run it and inspect the result:

```bash
cluster/pki/create-ca.sh          # expect: issuing-ca.crt: OK / istio-ca.crt: OK
openssl x509 -in cluster/pki/out/root-ca.crt -noout -subject -enddate -ext nameConstraints
```

**Keep the root key offline.** This is recommended once both intermediates
exist; the script works without the key until an intermediate has to be
re-issued:

```bash
# Option A: move it to offline storage (encrypted USB stick, password manager, ...)
mv cluster/pki/out/root-ca.key /path/to/offline/storage/
# Option B: keep an encrypted copy only
openssl pkey -in cluster/pki/out/root-ca.key -aes256 -out cluster/pki/out/root-ca.key.enc \
    && shred -u cluster/pki/out/root-ca.key
```

**Trust the root CA on the host.** This is safe because of the name constraints,
which OpenSSL, Go and current browsers enforce.

```bash
# System store (curl, wget, Go/Python tools, ...) - Debian/Ubuntu
sudo cp cluster/pki/out/root-ca.crt /usr/local/share/ca-certificates/kind-dev-root-ca.crt
sudo update-ca-certificates
# Chrome / Chromium (NSS database)
certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n "kind-dev Root CA" -i cluster/pki/out/root-ca.crt
# Firefox: Settings → Privacy & Security → Certificates → View Certificates → Authorities → Import
```

To remove it later: delete the file, then run `sudo update-ca-certificates --fresh`
and `certutil -d sql:$HOME/.pki/nssdb -D -n "kind-dev Root CA"`.

## Step 5: Platform services as one Kustomize tree (`platformservices/`)

```
platformservices/
├── kustomization.yaml            # all parts below: one render of the whole platform
├── deploy.sh                     # PKI secrets, then the parts in dependency order
├── cert-manager/
│   ├── kustomization.yaml        # helmCharts: cert-manager v1.21.2 (+ CRDs)
│   ├── namespace.yaml
│   └── config/                   # ClusterIssuer kind-ca
├── trust-manager/
│   ├── kustomization.yaml        # helmCharts: trust-manager v0.25.0 (namespace cert-manager)
│   └── config/                   # Bundle kind-root-ca
├── istio/
│   ├── kustomization.yaml        # helmCharts: base + istiod 1.31.0
│   ├── namespace.yaml
│   ├── gateway/                  # helmCharts: gateway 1.31.0 (release istio-ingressgateway)
│   └── config/                   # IngressClass istio, Certificate *.kind.local
├── external-secrets/
│   ├── kustomization.yaml        # helmCharts: external-secrets 2.10.0
│   ├── namespace.yaml            # moved in step 1, + label
│   └── examples/fake-store.yaml
├── argocd/
│   ├── kustomization.yaml        # upstream install.yaml v3.5.3, namespace argocd, server.insecure patch
│   ├── namespace.yaml            # moved in step 5f, + label
│   ├── ingress.yaml              # moved in step 5f, class + host + TLS changed
│   └── examples/guestbook.yaml
└── keda/                         # moved in step 1, unchanged, not deployed
```

Every `kustomization.yaml` below was part of the render test. Each part
rendered on its own, and the whole tree rendered at once, with Helm v3.22.0
(and v4.3.0):

| Part | Resources | of which CRDs |
| --- | --- | --- |
| `cert-manager` | 51 | 6 |
| `trust-manager` | 15 | 1 |
| `cert-manager/config` | 1 | — |
| `trust-manager/config` | 1 | — |
| `istio` | 35 | 15 |
| `istio/gateway` | 6 | — |
| `istio/config` | 2 | — |
| `external-secrets` | 45 | 25 |
| `argocd` | 61 | 3 |
| **`platformservices` (all)** | **217** | **50** |

### 5a. Aggregate: `platformservices/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
# All platform services in one render (update-setup-01):
#   kubectl kustomize --enable-helm platformservices
# Useful for review, diffs and as a future Argo CD source. It is NOT applied in one go:
# CRDs and webhooks must be ready before the resources that use them, so
# platformservices/deploy.sh applies the parts below one by one, in this order, with waits.
resources:
- cert-manager
- trust-manager
- cert-manager/config
- trust-manager/config
- istio
- istio/gateway
- istio/config
- external-secrets
- argocd
```

### 5b. cert-manager

`cert-manager/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
# cert-manager controller, webhook, cainjector and CRDs
resources:
- namespace.yaml
helmCharts:
- name: cert-manager
  repo: https://charts.jetstack.io
  version: v1.21.2
  releaseName: cert-manager
  namespace: cert-manager
  valuesInline:
    crds:
      enabled: true
```

`cert-manager/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager
  labels:
    istio-injection: disabled
```

`cert-manager/config/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
# Needs the cert-manager CRDs and webhook (apply after cert-manager/)
resources:
- cluster-issuer.yaml
```

`cert-manager/config/cluster-issuer.yaml`:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: kind-ca
spec:
  ca:
    # In the cluster resource namespace (cert-manager), created by platformservices/deploy.sh.
    # tls.crt = issuing CA + root, so issued Secrets get the root as ca.crt
    secretName: kind-issuing-ca
```

### 5c. trust-manager

`trust-manager/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
# trust-manager (in the cert-manager namespace = trust namespace).
# Its webhook certificate comes from cert-manager: apply after cert-manager/ is ready.
helmCharts:
- name: trust-manager
  repo: https://charts.jetstack.io
  version: v0.25.0
  releaseName: trust-manager
  namespace: cert-manager
```

`trust-manager/config/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
# Needs the trust-manager CRD (apply after trust-manager/)
resources:
- root-ca-bundle.yaml
```

`trust-manager/config/root-ca-bundle.yaml`:

```yaml
apiVersion: trust.cert-manager.io/v1alpha1
kind: Bundle
metadata:
  name: kind-root-ca            # name of the target ConfigMap in every namespace
spec:
  sources:
  - configMap:
      name: kind-root-ca-source # in the trust namespace (cert-manager); created by platformservices/deploy.sh
      key: ca.crt
  target:
    configMap:
      key: ca.crt
    # no namespaceSelector -> all namespaces
```

### 5d. Istio

`istio/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
# Istio CRDs (base) and control plane (istiod). The plug-in CA secret "cacerts" must exist
# before istiod starts (created by platformservices/deploy.sh).
resources:
- namespace.yaml
helmCharts:
- name: base
  repo: https://blob.istio.io/istio-release/charts
  version: 1.31.0
  releaseName: istio-base
  namespace: istio-system
  includeCRDs: true
  valuesInline:
    defaultRevision: default
- name: istiod
  repo: https://blob.istio.io/istio-release/charts
  version: 1.31.0
  releaseName: istiod
  namespace: istio-system
```

`istio/namespace.yaml` (left unlabelled: the Istio charts manage their own pods):

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: istio-system
```

`istio/gateway/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
# Ingress gateway. Its pods get their proxy through istiod's injection webhook,
# so apply only after istio/ (istiod) is ready.
# Release name "istio-ingressgateway" -> Service istio-ingressgateway, label istio=ingressgateway,
# which Istio uses for Kubernetes Ingress by default (meshConfig.ingressService).
helmCharts:
- name: gateway
  repo: https://blob.istio.io/istio-release/charts
  version: 1.31.0
  releaseName: istio-ingressgateway
  namespace: istio-system
```

`istio/config/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
# IngressClass "istio" and the wildcard gateway certificate (needs cert-manager/config)
resources:
- ingressclass.yaml
- gateway-certificate.yaml
```

`istio/config/ingressclass.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: istio
spec:
  controller: istio.io/ingress-controller
```

`istio/config/gateway-certificate.yaml`. It's a wildcard certificate for all
Istio Ingresses; Istio reads Ingress TLS Secrets from its gateway namespace.

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: kind-local-wildcard
  namespace: istio-system
spec:
  secretName: kind-local-wildcard-tls
  dnsNames:
  - "*.kind.local"
  issuerRef:
    kind: ClusterIssuer
    name: kind-ca
  duration: 2160h       # 90 days
  renewBefore: 360h     # 15 days
```

### 5e. External Secrets Operator

`external-secrets/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
# External Secrets Operator, cluster-wide mode (chart defaults); only external-secrets.io/v1 is served
resources:
- namespace.yaml
helmCharts:
- name: external-secrets
  repo: https://charts.external-secrets.io
  version: 2.10.0
  releaseName: external-secrets
  namespace: external-secrets
  valuesInline:
    installCRDs: true
    crds:
      unsafeServeV1Beta1: false
```

`external-secrets/namespace.yaml`. It was moved in step 1; this adds the label:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: external-secrets
  labels:
    istio-injection: disabled
```

`external-secrets/examples/fake-store.yaml` uses ESO's built-in `fake`
provider, so no real secret backend is needed. It's not part of the aggregate:

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: fake
spec:
  provider:
    fake:
      data:
      - key: /demo/greeting
        value: hello-from-eso
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: demo
  namespace: testapp
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: fake
  target:
    name: demo-secret
  data:
  - secretKey: greeting
    remoteRef:
      key: /demo/greeting
```

### 5f. Argo CD: one instance for the whole cluster

Restructure the moved `platformservices/argocd/`. The 11,000-line v2.5.8
manifest and the Traefik `HTTPRoute` go away, and Kustomize pulls in the upstream
v3.5.3 install instead:

```bash
cd /home/leo/dev/kind/platformservices/argocd
mkdir -p examples
git mv base/00-namespace.yaml namespace.yaml
git mv base/02-ingress.yaml   ingress.yaml
git rm -r -q base               # 01-install.yaml (v2.5.8), 03-httproute.yaml, kustomization.yaml
```

The render test for this folder gave 61 resources: 3 CRDs, 6 Deployments and the
application-controller StatefulSet, all in `argocd`. The `server.insecure` patch
shows up in `argocd-cmd-params-cm`, and the three ClusterRoleBindings bind to
ServiceAccounts in `argocd`. Upstream's NetworkPolicy for `argocd-server` allows
all incoming traffic, so the cloud-provider-kind Ingress can reach it.

`argocd/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
# One Argo CD instance for the whole cluster: upstream install.yaml (cluster-wide permissions,
# deploys into any namespace), pinned to a release tag.
namespace: argocd
resources:
- namespace.yaml
- https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.3/manifests/install.yaml
- ingress.yaml
patches:
# Plain HTTP behind the Ingress; TLS is terminated at the Ingress (cert-manager, kind-ca)
- patch: |-
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: argocd-cmd-params-cm
    data:
      server.insecure: "true"
```

`argocd/namespace.yaml`. It was moved from `base/00-namespace.yaml`; this adds
the label:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: argocd
  labels:
    istio-injection: disabled
```

`argocd/ingress.yaml`. It was moved from `base/02-ingress.yaml`, with these
changes:
- class `traefik` → `cloud-provider-kind`;
- host `argocd.localhost` → `argocd.kind.local`;
- TLS added via cert-manager.

The backend stays Service `argocd-server`, port `http` (80 → 8080), from the
upstream install.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-web
  annotations:
    cert-manager.io/cluster-issuer: kind-ca   # -> Certificate + Secret argocd-web-tls
spec:
  ingressClassName: cloud-provider-kind
  tls:
  - hosts:
    - argocd.kind.local
    secretName: argocd-web-tls
  rules:
  - host: argocd.kind.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              name: http
```

`argocd/examples/guestbook.yaml`. This checks the cluster-scoped instance: it
creates a new namespace with the Istio label convention.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: guestbook
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps.git
    targetRevision: HEAD
    path: guestbook
  destination:
    server: https://kubernetes.default.svc
    namespace: guestbook
  syncPolicy:
    automated: {}
    syncOptions:
    - CreateNamespace=true
    managedNamespaceMetadata:
      labels:
        istio-injection: disabled
```

(`argoproj.io/v1alpha1` is still the current API version of Argo CD's `Application`.)

Admin login: user `admin`. Argo CD generates the password on first start and
stores it in the Secret `argocd-initial-admin-secret`. Change it after the first
login, then delete that Secret:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

**Applications in other namespaces (optional, not enabled).** By default,
`Application` resources live in `argocd`, and Argo CD deploys from there into any
namespace. To let teams keep their `Application`s in their own namespaces, add
`application.namespaces` (e.g. `team-*`) to the `argocd-cmd-params-cm` patch and
allow those namespaces in an `AppProject` (`spec.sourceNamespaces`).

### 5g. `platformservices/deploy.sh`

```bash
#!/usr/bin/env bash
# Platform services in dependency order (update-setup-01).
# Everything is Kustomize; Helm charts are rendered via helmCharts
# ("kubectl kustomize --enable-helm", needs helm on PATH).
# One render of the whole platform: kubectl kustomize --enable-helm platformservices
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PKI="$SCRIPT_DIR/../cluster/pki/out"
[[ -f "$PKI/issuing-ca.key" ]] || { echo "missing $PKI/issuing-ca.key - run cluster/pki/create-ca.sh first" >&2; exit 1; }

apply() {       # $1 = kustomization directory below platformservices/
    echo "--- platformservices/$1"
    kubectl kustomize --enable-helm "$SCRIPT_DIR/$1" | kubectl apply --server-side --force-conflicts -f -
}
available() {   # $1 = namespace: wait until all its Deployments are available
    kubectl -n "$1" wait deployment --all --for=condition=Available --timeout=300s
}
from_files() {  # "kubectl create secret/configmap ..." -> apply (never in git, never in the render)
    "$@" --dry-run=client -o yaml | kubectl apply -f -
}

# 0. Namespaces and material from the local PKI
kubectl apply -f "$SCRIPT_DIR/cert-manager/namespace.yaml" -f "$SCRIPT_DIR/istio/namespace.yaml"
from_files kubectl -n cert-manager create secret tls kind-issuing-ca \
    --cert="$PKI/issuing-ca-chain.crt" --key="$PKI/issuing-ca.key"
from_files kubectl -n cert-manager create configmap kind-root-ca-source \
    --from-file=ca.crt="$PKI/root-ca.crt"
from_files kubectl -n istio-system create secret generic cacerts \
    --from-file=ca-cert.pem="$PKI/istio-ca.crt" \
    --from-file=ca-key.pem="$PKI/istio-ca.key" \
    --from-file=root-cert.pem="$PKI/root-ca.crt" \
    --from-file=cert-chain.pem="$PKI/istio-ca-chain.crt"

# 1. cert-manager, then trust-manager (its webhook certificate comes from cert-manager)
apply cert-manager;         available cert-manager
apply trust-manager;        available cert-manager
apply cert-manager/config;  kubectl wait clusterissuer/kind-ca --for=condition=Ready --timeout=60s
apply trust-manager/config

# 2. Istio: CRDs + istiod (reads cacerts at startup), then the gateway (needs istiod's injection webhook)
apply istio;                available istio-system
apply istio/gateway;        available istio-system
apply istio/config

# 3. External Secrets Operator
apply external-secrets;     available external-secrets

# 4. Argo CD: one instance for the whole cluster
apply argocd;               available argocd
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
```

After changing the plug-in CA Secret `cacerts`, restart istiod with
`kubectl -n istio-system rollout restart deployment/istiod`.

## Step 6: Namespace labels for Istio

Convention: every namespace states explicitly whether it's in the mesh.

| Label | Meaning | Namespaces |
| --- | --- | --- |
| `istio-injection: enabled` | Istio sidecars are injected into new pods: mTLS, AuthorizationPolicy, VirtualService / DestinationRule take effect | `testapp-mesh`, and any app namespace that should be meshed |
| `istio-injection: disabled` | Plain Kubernetes; no sidecars | `cert-manager`, `external-secrets`, `argocd`, `testapp` |

`istio-system` is left unlabelled: the Istio charts manage their own pods.

Switching a namespace at runtime (sidecars are only injected when pods are created):

```bash
kubectl label ns <ns> istio-injection=enabled --overwrite
kubectl -n <ns> rollout restart deployment
kubectl -n <ns> get pods          # READY 2/2 = app + istio-proxy
```

Istio *routing* with IngressClass `istio` works for both kinds of namespace.
Only the *mesh* features at the pod (mTLS, pod-level policies) need the label.
Apps that Argo CD deploys can set the label through
`spec.syncPolicy.managedNamespaceMetadata` (see the guestbook example in step 5f).

## Step 7: Applications (`applications/`)

Each test application lives in its own folder with its own `deploy.sh`.
`applications/deploy.sh` deploys the default ones:

```bash
#!/usr/bin/env bash
# Default test applications (update-setup-01). Others are deployed from their own folder.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
"$SCRIPT_DIR/testapp/deploy.sh"
```

### 7a. `applications/testapp`: a plain and a meshed variant (HTTP + HTTPS)

The same nginx app is deployed twice so that both namespace types can be compared:

```
applications/testapp/
├── base/
│   ├── kustomization.yaml
│   ├── 01-deployment.yaml        # moved, unchanged
│   ├── 02-service.yaml           # moved, unchanged (type LoadBalancer = L4 path)
│   ├── 03-ingress-vanilla.yaml   # new, TLS via cert-manager annotation
│   └── 04-ingress-istio.yaml     # new, TLS via the istio-system wildcard Secret
├── overlays/
│   ├── plain/   → namespace testapp       (istio-injection=disabled), host testapp.kind.local
│   └── mesh/    → namespace testapp-mesh  (istio-injection=enabled),  host testapp-mesh.kind.local
└── deploy.sh
```

```bash
cd /home/leo/dev/kind/applications/testapp
mkdir -p base overlays/plain overlays/mesh
git mv 01-deployment.yaml 02-service.yaml base/
git rm -q 00-namespace.yaml kustomization.yaml     # replaced by the overlays
```

`base/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- 01-deployment.yaml
- 02-service.yaml
- 03-ingress-vanilla.yaml
- 04-ingress-istio.yaml
```

`base/03-ingress-vanilla.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nginx-vanilla
  annotations:
    cert-manager.io/cluster-issuer: kind-ca   # -> Certificate + Secret nginx-vanilla-tls in this namespace
spec:
  ingressClassName: cloud-provider-kind
  tls:
  - hosts:
    - placeholder.kind.local                  # set per overlay
    secretName: nginx-vanilla-tls
  rules:
  - host: placeholder.kind.local              # set per overlay
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: nginx
            port:
              name: http
```

`base/04-ingress-istio.yaml`. There's **no** cert-manager annotation, because
Istio reads the TLS Secret from `istio-system`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nginx-istio
spec:
  ingressClassName: istio
  tls:
  - hosts:
    - placeholder.kind.local                  # set per overlay
    secretName: kind-local-wildcard-tls       # Secret in istio-system (step 5d)
  rules:
  - host: placeholder.kind.local              # set per overlay
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: nginx
            port:
              name: http
```

`overlays/mesh/kustomization.yaml` (`plain` is the same with `testapp` and
`testapp.kind.local`):

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: testapp-mesh
resources:
- namespace.yaml
- ../../base
patches:
- target:
    kind: Ingress
  patch: |-
    - op: replace
      path: /spec/rules/0/host
      value: testapp-mesh.kind.local
    - op: replace
      path: /spec/tls/0/hosts/0
      value: testapp-mesh.kind.local
```

`overlays/mesh/namespace.yaml` (`plain` uses `name: testapp` and `istio-injection: disabled`):

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: testapp-mesh
  labels:
    istio-injection: enabled
```

`deploy.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
kubectl apply -k "$SCRIPT_DIR/overlays/plain"
kubectl apply -k "$SCRIPT_DIR/overlays/mesh"
```

The hostnames differ per namespace because both namespaces share the single
Istio gateway IP. On the vanilla path, each namespace gets its own IP anyway.

### 7b. `applications/secret-test` and `applications/testhelm`

| File | Change |
| --- | --- |
| `applications/secret-test/overlays/local/04-ingress.yaml` | `ingressClassName: traefik` → `cloud-provider-kind`; host `secret-test-web.minikube` → `secret-test-web.kind.local`; add annotation `cert-manager.io/cluster-issuer: kind-ca` and a `tls` block (`secretName: secret-test-web-tls`). **Left uncommitted in the `secret-test` repo for review**: it builds on an earlier uncommitted change there (annotation → `ingressClassName`) |
| `applications/testhelm/values.yaml` | `ingress.className: "traefik"` → `"cloud-provider-kind"`; `ingress.annotations: {cert-manager.io/cluster-issuer: kind-ca}` |

Both are deployed manually from their folders, e.g.
`kubectl apply -k applications/secret-test/overlays/local`.

## Step 8: CLI containers: k9s and lazydocker (`cli/`)

k9s runs in a container that always connects to the kind cluster, whatever
`~/.kube/config` or the current kubectl context says. The setup below was tested
in a scratch directory on this host:
- the image builds, both SHA-256 checks pass, and k9s v0.51.0 / kubectl v1.36.4
  run as UID 1000;
- Compose resolves the versions through the `.env` symlink;
- `docker compose run` builds a missing image automatically;
- a missing `kubeconfig` gives a clear error;
- without a running cluster, Compose stops with
  `network kind declared as external, but could not be found`;
- with `--service-ports`, a listener on `0.0.0.0:18000` inside the container is
  reachable at `127.0.0.1:18000` on the host, but not via the host's LAN address.
  A listener on `127.0.0.1` inside the container is not reachable at all, which
  is why `K9S_DEFAULT_PF_ADDRESS` is set.

Not yet tested: an actual k9s port-forward to a pod, because that needs the
cluster. Step 10 covers it. Since the test, the only change is the path to the
kind binary in `k9s.sh` (`../cluster/kind`). The lazydocker tests are listed in
its own section below.

```
cli/
├── compose.yaml              # project "kind-cli": services "k9s" (kind network) and "lazydocker" (Docker socket)
├── k9s.Dockerfile            # alpine 3.23.3 + k9s + kubectl, SHA-256 verified
├── lazydocker.Dockerfile     # alpine 3.23.3 + lazydocker (SHA-256 verified) + docker-cli + docker-cli-compose
├── k9s.sh                    # regenerates cli/kubeconfig, then "docker compose run --rm --service-ports k9s"
├── lazydocker.sh             # mounts the project's git repo read-only, then "docker compose run --rm lazydocker"
├── .env -> ../versions.env   # symlink: K9S_VERSION / KUBECTL_VERSION / LAZYDOCKER_VERSION for Compose
├── k9s/                      # K9S_CONFIG_DIR (config.yaml, aliases, hotkeys, ...); committed
│   └── .gitkeep
├── lazydocker/               # CONFIG_DIR (config.yml); committed
│   └── .gitkeep
└── kubeconfig                # generated, git-ignored (cluster-admin credentials, mode 600)
```

```bash
cd /home/leo/dev/kind
mkdir -p cli/k9s cli/lazydocker && touch cli/k9s/.gitkeep cli/lazydocker/.gitkeep
ln -s ../versions.env cli/.env
chmod +x cli/k9s.sh cli/lazydocker.sh     # after creating the files below
```

**`cli/k9s.Dockerfile`:**

```dockerfile
# k9s + kubectl matching the cluster version, pinned via ../versions.env (update-setup-01).
# Built locally: the official derailed/k9s image lags behind releases and ships an old kubectl.
FROM alpine:3.23.3
ARG K9S_VERSION
ARG KUBECTL_VERSION
ARG TARGETARCH
RUN set -eux; \
    apk add --no-cache ca-certificates curl vim; \
    cd /tmp; \
    curl -fsSLO "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_${TARGETARCH}.tar.gz"; \
    curl -fsSL "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/checksums.sha256" \
        | grep " k9s_Linux_${TARGETARCH}.tar.gz\$" | sha256sum -c -; \
    tar -xzf "k9s_Linux_${TARGETARCH}.tar.gz" -C /usr/local/bin k9s; \
    rm "k9s_Linux_${TARGETARCH}.tar.gz"; \
    curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl"; \
    echo "$(curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl.sha256")  /usr/local/bin/kubectl" \
        | sha256sum -c -; \
    chmod +x /usr/local/bin/kubectl; \
    # Home for any UID (the container runs as the host user); .local is backed by a named volume
    mkdir -p /home/k9s/.local; \
    chmod -R 1777 /home/k9s
ENV HOME=/home/k9s \
    EDITOR=vim
ENTRYPOINT ["k9s"]
```

**`cli/compose.yaml`:**

```yaml
# CLI tools for the kind cluster (update-setup-01). Start them with ./k9s.sh and ./lazydocker.sh
# Variables come from .env -> ../versions.env
name: kind-cli

services:
  k9s:
    build:
      context: .
      dockerfile: k9s.Dockerfile
      args:
        K9S_VERSION: ${K9S_VERSION:?set in ../versions.env}
        KUBECTL_VERSION: ${KUBECTL_VERSION:?set in ../versions.env}
    image: kind-cli/k9s:${K9S_VERSION}-kubectl-${KUBECTL_VERSION}
    user: "${HOST_UID:-1000}:${HOST_GID:-1000}"
    stdin_open: true
    tty: true
    networks: [kind]
    environment:
      KUBECONFIG: /kube/config
      K9S_CONFIG_DIR: /k9s
      # k9s needs $USER for its log location (the host UID has no passwd entry in the image)
      USER: k9s
      # Port-forwards listen on all interfaces inside the container (default: localhost)
      K9S_DEFAULT_PF_ADDRESS: 0.0.0.0
      TERM: ${TERM:-xterm-256color}
    # k9s port-forwards (shift-f): use a "Local Port" from this range.
    # Published on 127.0.0.1 only - not reachable from the LAN.
    # Only active with "docker compose run --service-ports" (k9s.sh does that).
    ports:
      - "127.0.0.1:${K9S_PF_PORTS:-18000-18009}:${K9S_PF_PORTS:-18000-18009}"
    volumes:
      # Generated by k9s.sh / cluster.sh ("kind get kubeconfig --internal"); fail if missing
      - type: bind
        source: ./kubeconfig
        target: /kube/config
        read_only: true
        bind:
          create_host_path: false
      # k9s config (config.yaml, aliases, hotkeys, ...) - committed
      - ./k9s:/k9s
      # k9s data/state (logs, screen dumps, per-cluster settings)
      - k9s-local:/home/k9s/.local

  lazydocker:
    build:
      context: .
      dockerfile: lazydocker.Dockerfile
      args:
        LAZYDOCKER_VERSION: ${LAZYDOCKER_VERSION:?set in ../versions.env}
    image: kind-cli/lazydocker:${LAZYDOCKER_VERSION}
    user: "${HOST_UID:-1000}:${HOST_GID:-1000}"
    group_add:
      - "${DOCKER_GID:-984}"        # group owning /var/run/docker.sock (lazydocker.sh sets it)
    stdin_open: true
    tty: true
    network_mode: none              # only talks to the Docker socket
    environment:
      CONFIG_DIR: /config
      TERM: ${TERM:-xterm-256color}
    volumes:
      # Full control over the host's Docker daemon (root-equivalent)
      - /var/run/docker.sock:/var/run/docker.sock
      # lazydocker config (config.yml) - committed
      - ./lazydocker:/config

networks:
  kind:
    external: true      # created by kind; the API server is https://dev-control-plane:6443

volumes:
  k9s-local:
```

**`cli/k9s.sh`:**

```bash
#!/usr/bin/env bash
# Start k9s in a container against the kind cluster (update-setup-01).
# Usage: cli/k9s.sh [k9s flags], e.g. cli/k9s.sh -n testapp
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../versions.env"

# Regenerate on every start: a recreated cluster has new certificates.
# --internal: API server https://<cluster>-control-plane:6443, reachable on the "kind" network.
kubeconfig=$("$SCRIPT_DIR/../cluster/kind" get kubeconfig --internal --name "$CLUSTER_NAME")
(umask 077 && printf '%s\n' "$kubeconfig" > "$SCRIPT_DIR/kubeconfig")

HOST_UID=$(id -u)
HOST_GID=$(id -g)
export HOST_UID HOST_GID
# --service-ports: publish the port-forward range (127.0.0.1:18000-18009) to the host
exec docker compose -f "$SCRIPT_DIR/compose.yaml" run --rm --service-ports k9s "$@"
```

Usage:

```bash
cli/k9s.sh                          # start k9s
cli/k9s.sh -n testapp-mesh          # k9s flags are passed through
cli/k9s.sh --readonly               # look, don't touch
cli/k9s.sh info                     # show where k9s keeps its config, data and logs
K9S_PF_PORTS=19000-19009 cli/k9s.sh  # use a different port-forward range

docker compose -f cli/compose.yaml run --rm --service-ports k9s   # without the wrapper (kubeconfig from cluster/cluster.sh up)
docker compose -f cli/compose.yaml run --rm k9s     # a second k9s instance, without published ports
docker compose -f cli/compose.yaml build --pull     # rebuild, e.g. for Alpine security updates
docker volume rm kind-cli_k9s-local                 # reset k9s data/state
```

Inside k9s, shell (`s`), logs (`l`) and edit (`e`, using `vim`) work through the
API server.

**Port-forwarding from k9s to the host:**
1. Select a pod or service and press `shift-f`.
2. In the dialog, keep **Address** at `0.0.0.0`, the default from
   `K9S_DEFAULT_PF_ADDRESS`.
3. Set **Local Port** to a port in **18000–18009**. The container port can be
   anything, e.g. `80`.
4. Open `http://localhost:18000` on the host.
5. List active forwards with `:pf`; stop one with `ctrl-d`.

```
Browser / curl on the host ──► 127.0.0.1:18000 (published by Docker)
    ──► k9s container 0.0.0.0:18000 ──► API server (port-forward) ──► pod :80
```

### lazydocker

lazydocker shows the Docker side of the setup:
- the kind node containers (`dev-control-plane`, `dev-worker*`);
- `cloud-provider-kind` and its `kindccm-*` load balancer/gateway containers;
- Compose projects such as `kind-cli`.

The `lazydocker` service is part of `cli/compose.yaml` above. It was tested in
the scratch directory:
- the image builds, the SHA-256 check passes, and `lazydocker --version`
  reports 0.25.2;
- as UID 1000 with the socket's group (984), the container reaches the host's
  Docker daemon (29.6.1) and `docker compose` (2.40.3);
- lazydocker starts under a terminal and writes `cli/lazydocker/config.yml`,
  owned by UID 1000;
- it works without the `kind` network, i.e. without a running cluster;
- with the git repository mounted, `docker compose` inside the container reads
  the `kind-cli` project, including `cli/.env → ../versions.env`. For a directory
  outside any git repository, the script falls back to mounting that directory.

**`cli/lazydocker.Dockerfile`:**

```dockerfile
# lazydocker + Docker CLI/Compose plugin, pinned via ../versions.env (update-setup-01).
# Built locally: the official lazyteam/lazydocker image hasn't been updated since 2022.
FROM alpine:3.23.3
ARG LAZYDOCKER_VERSION
ARG TARGETARCH
RUN set -eux; \
    apk add --no-cache ca-certificates curl docker-cli docker-cli-compose; \
    case "${TARGETARCH}" in \
        amd64) arch=x86_64 ;; \
        arm64) arch=arm64 ;; \
        *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    file="lazydocker_${LAZYDOCKER_VERSION#v}_Linux_${arch}.tar.gz"; \
    cd /tmp; \
    curl -fsSLO "https://github.com/jesseduffield/lazydocker/releases/download/${LAZYDOCKER_VERSION}/${file}"; \
    curl -fsSL "https://github.com/jesseduffield/lazydocker/releases/download/${LAZYDOCKER_VERSION}/checksums.txt" \
        | grep " ${file}\$" | sha256sum -c -; \
    tar -xzf "${file}" -C /usr/local/bin lazydocker; \
    rm "${file}"; \
    # Home for any UID (the container runs as the host user); holds ~/.docker
    mkdir -p /home/lazydocker; \
    chmod 1777 /home/lazydocker
ENV HOME=/home/lazydocker
ENTRYPOINT ["lazydocker"]
```

**`cli/lazydocker.sh`:**

```bash
#!/usr/bin/env bash
# Start lazydocker in a container (update-setup-01).
# Usage: cli/lazydocker.sh [project-dir]   (default: current directory)
# The project directory is the working directory: if it contains a Compose file,
# lazydocker shows that project's services. Its git repository (or the directory
# itself) is mounted read-only at the same path, so "docker compose" commands see
# the same paths as on the host and relative symlinks (cli/.env -> ../versions.env) resolve.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "${1:-$PWD}" && pwd)
MOUNT_DIR=$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$PROJECT_DIR")

HOST_UID=$(id -u)
HOST_GID=$(id -g)
DOCKER_GID=$(stat -c %g /var/run/docker.sock)
export HOST_UID HOST_GID DOCKER_GID
exec docker compose -f "$SCRIPT_DIR/compose.yaml" run --rm \
    -v "$MOUNT_DIR:$MOUNT_DIR:ro" -w "$PROJECT_DIR" lazydocker
```

Usage:

```bash
cli/lazydocker.sh                   # current directory; shows all containers if it has no Compose file
cli/lazydocker.sh ~/dev/kind/cli    # the kind-cli project (services k9s, lazydocker)
cli/lazydocker.sh ~/dev/other-app   # any other Compose project (its git repository is mounted read-only)
docker compose -f cli/compose.yaml build --pull lazydocker   # rebuild, e.g. for Alpine security updates
```

In lazydocker, `x` opens the actions for the selected item and `q` quits.

## Step 9: Top-level deploy script and docs

**Rewrite `deploy.sh`** (top level):

```bash
#!/usr/bin/env bash
# Everything inside the cluster (update-setup-01). Create the cluster first: cluster/cluster.sh up
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
"$SCRIPT_DIR/platformservices/deploy.sh"
"$SCRIPT_DIR/applications/deploy.sh"
```

**`README.md`:**
- describe the new layout (`cluster/`, `cli/`, `platformservices/`,
  `applications/`), and merge in the useful parts of the removed
  `deployments/README.md`;
- rewrite *Contents*, *Architecture* and *Usage* for cloud-provider-kind, Istio,
  the platform services and the PKI;
- replace the *MetalLB setup* section with *cloud-provider-kind*, *Istio ingress*,
  *Platform services (Kustomize)* and *Certificates*;
- document trusting the root CA on the host;
- keep the section *Trusting external CAs with trust-manager*. It was already
  added on 2026-09-15; remove its "Planned" note, and check its examples
  against the deployed trust-manager version;
- add a *CLI (k9s, lazydocker)* section: `cli/k9s.sh`, how the kubeconfig is
  generated, port-forwarding via `127.0.0.1:18000-18009`, and
  `cli/lazydocker.sh [project-dir]`;
- mark suggestions 1–5 as done and update 6–8;
- link this file.

## Step 10: Verify end to end

```bash
cd /home/leo/dev/kind
cluster/pki/create-ca.sh      # once
cluster/cluster.sh up
./deploy.sh
```

**Render check.** No cluster is needed for this:

```bash
kubectl kustomize --enable-helm platformservices | grep -c '^kind:'    # 217 in the render test
```

**Certificates:**

```bash
kubectl -n cert-manager get pods                  # cert-manager, -cainjector, -webhook, trust-manager: Running
kubectl get clusterissuer kind-ca                 # READY True
kubectl get certificate -A                        # istio-system/kind-local-wildcard, testapp*/nginx-vanilla-tls,
                                                  # argocd/argocd-web-tls: all READY True
# Root CA distributed by trust-manager
kubectl -n testapp get configmap kind-root-ca -o jsonpath='{.data.ca\.crt}' | openssl x509 -noout -subject
#   -> subject=O = kind-dev, CN = kind-dev Root CA
# Istio mesh chains to the same local root
kubectl -n testapp-mesh get configmap istio-ca-root-cert -o jsonpath='{.data.root-cert\.pem}' | openssl x509 -noout -subject
#   -> subject=O = kind-dev, CN = kind-dev Root CA
```

**Ingress paths, HTTP and HTTPS.** HTTPS is checked against the local root:

```bash
CA=cluster/pki/out/root-ca.crt
ISTIO_IP=$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
for ns in testapp testapp-mesh; do
  H=$ns.kind.local
  VANILLA_IP=$(kubectl -n $ns get ingress nginx-vanilla -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  L4_IP=$(kubectl -n $ns get svc nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  curl -s -o /dev/null -w "$ns vanilla http  %{http_code}\n" -H "Host: $H" "http://$VANILLA_IP/"
  curl -s -o /dev/null -w "$ns vanilla https %{http_code}\n" --cacert $CA --resolve "$H:443:$VANILLA_IP" "https://$H/"
  curl -s -o /dev/null -w "$ns istio   http  %{http_code}\n" -H "Host: $H" "http://$ISTIO_IP/"
  curl -s -o /dev/null -w "$ns istio   https %{http_code}\n" --cacert $CA --resolve "$H:443:$ISTIO_IP" "https://$H/"
  curl -s -o /dev/null -w "$ns l4      http  %{http_code}\n" "http://$L4_IP/"
done
kubectl -n testapp      get pods   # READY 1/1
kubectl -n testapp-mesh get pods   # READY 2/2 (sidecar)
```

Expected: `200` for all ten requests. The HTTPS requests pass without `-k`
because the certificates chain to the local root.

**Mesh policy check.** Make mTLS mandatory in the meshed namespace:

```bash
kubectl apply -f - <<'EOF'
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: testapp-mesh
spec:
  mtls:
    mode: STRICT
EOF
```

Expected afterwards for `testapp-mesh`:
- `istio`: still `200` (the gateway speaks mTLS to the sidecar);
- `vanilla` and `l4`: fail with a 5xx or a reset connection, because
  cloud-provider-kind's Envoy is outside the mesh and sends plaintext.

Delete the PeerAuthentication to return to `PERMISSIVE`.

**External Secrets Operator:**

```bash
kubectl -n external-secrets get pods               # external-secrets, -webhook, -cert-controller: Running
kubectl apply -f platformservices/external-secrets/examples/fake-store.yaml
kubectl get clustersecretstore fake                # READY True
kubectl -n testapp get externalsecret demo         # STATUS SecretSynced
kubectl -n testapp get secret demo-secret -o jsonpath='{.data.greeting}' | base64 -d; echo   # hello-from-eso
```

**Argo CD:**

```bash
kubectl -n argocd get pods                         # application-controller-0, applicationset-controller, dex-server,
                                                   # notifications-controller, redis, repo-server, server: Running
ARGO_IP=$(kubectl -n argocd get ingress argocd-web -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -s -o /dev/null -w "argocd %{http_code}\n" --cacert cluster/pki/out/root-ca.crt \
     --resolve "argocd.kind.local:443:$ARGO_IP" https://argocd.kind.local/   # 200
kubectl apply -f platformservices/argocd/examples/guestbook.yaml
kubectl -n argocd get application guestbook        # SYNC STATUS Synced, HEALTH Healthy
kubectl get ns guestbook --show-labels             # istio-injection=disabled
```

**k9s:**

```bash
cli/k9s.sh --readonly -n testapp-mesh     # pods visible, READY 2/2; quit with :q
kubectl config current-context            # host context is irrelevant: works even if it isn't kind-dev
ls -l cli/kubeconfig                      # -rw------- (git-ignored)

# Port-forward: cli/k9s.sh -n testapp -> select the nginx pod -> shift-f
#   Container Port 80, Local Port 18000, Address 0.0.0.0. Then, in a second terminal:
curl -s -o /dev/null -w "k9s port-forward %{http_code}\n" http://127.0.0.1:18000/   # 200
```

**lazydocker:**

```bash
cli/lazydocker.sh ~/dev/kind/cli    # Services: k9s, lazydocker. Containers: dev-control-plane, dev-worker,
                                    # dev-worker2, cloud-provider-kind, kindccm-*; quit with q
ls -ln cli/lazydocker/config.yml    # owned by your UID, not root
```

**In the browser**, once the root CA is trusted (step 4), add `/etc/hosts`
entries, for example `<ARGO_IP> argocd.kind.local`, and open
`https://argocd.kind.local`. It should load without a certificate warning.
Note that the vanilla and Istio paths have different IPs.

When everything passes, merge the branch:
`git switch main && git merge update-setup-01`.

## Rollback

The update happens on the branch `update-setup-01`, so rolling back means
switching back to `main`:

```bash
cluster/cluster.sh down
git switch main                                        # restores the baseline layout and files
mv applications/secret-test deployments/secret-test    # untracked, so git doesn't move it back
mv ~/dev/traefik deployments/basicservices/traefik     # moved out in step 1
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64 && chmod +x kind
# Optional: remove the root CA from the host trust stores (step 4); cluster/pki/out/ can be deleted
```

## Summary of changes

| Path | Action | Step |
| --- | --- | --- |
| git repository, branch `update-setup-01` | new (baseline commit on `main`) | 0 |
| `.gitignore` | new (`/cluster/kind`, `/cluster/pki/out/`, `/cli/kubeconfig`, `/applications/secret-test/`, `charts/`) | 1 |
| `deployments/` | dissolved into `cluster/`, `platformservices/`, `applications/`; MetalLB, Traefik, old ESO generator, `basicservices/deploy.sh`, `README.md` deleted | 1 |
| `logs.txt` | deleted | 1 |
| `cluster/kind` | moved and replaced: v0.20.0 → v0.33.0 | 1, 2 |
| `versions.env` | new (kind, node image, kubectl, cloud-provider-kind, Gateway API, k9s, lazydocker) | 2 |
| `cluster/cluster-config.yaml` | moved and rewritten (1 CP + 2 workers, no port mappings, labels or certSAN patch) | 1, 2 |
| `cluster/cluster.sh` | moved and rewritten (`up`/`down`/`cpk`; Gateway API CRDs; cloud-provider-kind container; writes/removes `cli/kubeconfig`) | 1, 3 |
| `cluster/pki/create-ca.sh` | new (root CA + issuing CA + Istio mesh CA, name-constrained, idempotent) | 4 |
| `cluster/pki/out/` | generated, git-ignored | 4 |
| Host trust stores | root CA added (system store, NSS, Firefox) | 4 |
| `platformservices/kustomization.yaml` | new (aggregate of all parts) | 5a |
| `platformservices/cert-manager/` | new: `kustomization.yaml` (chart v1.21.2), `namespace.yaml`, `config/` (ClusterIssuer) | 5b |
| `platformservices/trust-manager/` | new: `kustomization.yaml` (chart v0.25.0), `config/` (Bundle) | 5c |
| `platformservices/istio/` | moved; `deploy.sh` replaced by `kustomization.yaml` (base + istiod 1.31.0 from `blob.istio.io`), `namespace.yaml`, `gateway/`, `config/` (IngressClass, wildcard Certificate) | 1, 5d |
| `platformservices/external-secrets/` | new: `kustomization.yaml` (chart 2.10.0), `namespace.yaml` (moved + label), `examples/fake-store.yaml` | 1, 5e |
| `platformservices/argocd/` | moved; `base/` (v2.5.8, `03-httproute.yaml`) replaced by `kustomization.yaml` (upstream `install.yaml` v3.5.3 + `server.insecure` patch), `namespace.yaml` (moved + label), `ingress.yaml` (moved; class, host, TLS), `examples/guestbook.yaml` | 1, 5f |
| `platformservices/deploy.sh` | new (PKI secrets, then the parts in dependency order with waits) | 5g |
| `platformservices/keda/` | moved, unchanged (its old 2.11.0 version is out of scope; not deployed) | 1 |
| `applications/deploy.sh` | new | 7 |
| `applications/testapp/` | moved; restructured into `base/` + `overlays/{plain,mesh}`, two Ingresses per app with TLS | 1, 7a |
| `applications/secret-test/overlays/local/04-ingress.yaml` | moved with its repo; class → `cloud-provider-kind`, host → `secret-test-web.kind.local`, TLS (own repo) | 1, 7b |
| `applications/testhelm/values.yaml` | moved; `className` → `cloud-provider-kind`, cert-manager annotation | 1, 7b |
| `cli/` | new: `compose.yaml` (services `k9s` and `lazydocker`; port-forward range `127.0.0.1:18000-18009`), `k9s.Dockerfile`, `lazydocker.Dockerfile`, `k9s.sh` (`--service-ports`), `lazydocker.sh` (read-only repository mount), `.env` → `../versions.env` (symlink), `k9s/.gitkeep`, `lazydocker/.gitkeep`; `kubeconfig` generated | 8 |
| `deploy.sh` | rewritten (platformservices, then applications) | 9 |
| `README.md` | updated (already contains *Trusting external CAs with trust-manager*) | 9 |

## Known limitations and open points

**Cluster**
- **Ephemeral storage isn't enforced.** `localStorageCapacityIsolation: false`
  is needed because this host's Docker storage is ZFS (step 2c). Pods'
  `ephemeral-storage` requests and limits are ignored, and nodes don't report
  ephemeral-storage capacity. Remove the setting once a Kubernetes release
  vendors a cAdvisor with the ZFS fallback (track kind#4229), or on hosts whose
  Docker storage isn't ZFS.
- **No Gateway API downgrade protection.** The bundle's `safe-upgrades`
  admission policy is removed so cloud-provider-kind can start (step 3). Nothing
  stops an accidental downgrade of the Gateway API CRDs any more; only
  `cluster/cluster.sh` installs them.
- **Low inotify limits on this host** (`max_user_instances=128`,
  `max_user_watches=65536`). kind recommends 512 and 524288 against "too many
  open files" errors in pods. Raising them needs root, e.g. in
  `/etc/sysctl.d/99-kind.conf`.

**Platform services (Kustomize)**
- **`kubectl apply` doesn't prune.** Resources removed from the tree stay in the
  cluster until you delete them yourself, or until Argo CD manages the platform
  (a follow-up).
- **No Helm release management.** `helm list`/`helm rollback` don't know these
  installs. To roll back, check out the previous `kustomization.yaml` and run
  `platformservices/deploy.sh` again.
- **Chart upgrades can hit immutable Jobs.** cert-manager's
  `cert-manager-startupapicheck` is rendered as a normal Job. If a new chart
  version changes it, delete the Job before re-applying:
  `kubectl -n cert-manager delete job cert-manager-startupapicheck`.
- **Rendering needs `helm` on `PATH` and network access.** Charts are downloaded
  into `charts/` directories next to each `kustomization.yaml` (git-ignored). The
  first render takes a while.
- **The waits in `deploy.sh` are per namespace** (`deployment --all`). A broken
  unrelated Deployment in one of these namespaces blocks the run until the
  timeout.

**Networking**
- **Client source IP is lost** on the L4 path and on the Istio path, because
  cloud-provider-kind's Envoy proxies connections without PROXY protocol.
  Istio `AuthorizationPolicy` rules based on `remoteIpBlocks` can't be tested
  with real client IPs.
- **cloud-provider-kind v0.11.1 is built against Gateway API v1.5.1**, and we
  install v1.6.2 CRDs. The `v1` API is backward compatible, but if its gateway or
  Ingress translation misbehaves, fall back to the v1.5.x CRDs.
- **Vanilla Ingress gets one IP per namespace**, because cloud-provider-kind
  creates one Gateway (and one Envoy container) per namespace that has Ingresses.
  So the Argo CD UI gets its own IP.
- **Vanilla Ingress is HTTP/HTTPS only**, with basic features (no
  middlewares). For TCP/UDP, use `type: LoadBalancer` Services (not SCTP).
- **cloud-provider-kind's HTTPS listener is the least-proven piece of the plan.**
  It adds Ingress TLS Secrets to its per-namespace Gateway as an HTTPS listener.
  Step 10 checks this explicitly. If it fails, the Istio path still gives HTTPS.

**Certificates**
- **`root-ca.key` is on disk in `cluster/pki/out/` after the first run.** Move it
  offline or encrypt it (step 4); it's only needed to re-issue intermediates.
- **Intermediate CA keys live in cluster Secrets** (`cert-manager/kind-issuing-ca`,
  `istio-system/cacerts`). That's normal for an in-cluster CA; anyone with
  Secret read access in those namespaces can issue certificates within the name
  constraints.
- **There is no CRL or OCSP.** Revoke by re-issuing the affected intermediate:
  delete its files, run `create-ca.sh` with the root key available, re-run
  `platformservices/deploy.sh`, and restart istiod for the mesh CA.
- **The intermediates expire after 3 years and the root after 10.** cert-manager
  renews leaf certificates automatically, but not the intermediates.
- **ESO still uses its own self-signed webhook certificate** (its
  cert-controller). Moving it to cert-manager is a follow-up.
- **Firefox on Linux doesn't read the system trust store** by default; import
  the root CA manually (step 4).

**Argo CD**
- **The upstream `install.yaml` is fetched from GitHub at render time**
  (Kustomize remote resource; needs network access). To work offline, download
  it once next to the kustomization and reference the file instead of the URL.
- **Argo CD has cluster-wide permissions:** the application controller may do
  anything to any resource. That's what lets one instance manage all namespaces,
  and it's acceptable for a local platform cluster. Limit what gets deployed
  where with `AppProject`s.
- **Upgrades:** change the tag in the URL and re-run
  `platformservices/deploy.sh`, after reading Argo CD's upgrade notes. There's
  no Helm release, so rolling back means re-applying the previous tag.
- **Keep Argo CD settings in Kustomize patches** (`argocd-cm`, `argocd-rbac-cm`,
  `argocd-cmd-params-cm`), not in `kubectl edit`, so they're versioned and survive
  a cluster rebuild.

**External Secrets Operator**
- **ESO only serves `external-secrets.io/v1`.** Any older `v1beta1` manifests
  need migrating (the repo has none).
- **ESO is cluster-wide**, so every namespace can use `ClusterSecretStore`s.

**CLI (k9s, lazydocker)**
- **k9s port-forwards need a Local Port in 18000–18009.** Other local ports only
  work inside the container. Change the range with
  `K9S_PF_PORTS=19000-19009 cli/k9s.sh`.
- **Only one k9s instance can publish the range at a time.** A second
  `cli/k9s.sh` fails with `port is already allocated`. Start extra instances
  with `docker compose -f cli/compose.yaml run --rm k9s` (no host port-forwards).
- **Active port-forwards listen on `0.0.0.0` inside the container.** Other
  containers on the `kind` network (kind nodes, cloud-provider-kind's Envoys)
  can reach them while they run. That's acceptable locally: on the host they're
  published on `127.0.0.1` only.
- **lazydocker has full control over the host's Docker daemon** through the
  socket. That's root-equivalent, as with the cloud-provider-kind container.
  Only run images you trust from `cli/`.
- **lazydocker mounts the project's git repository read-only.** Compose actions
  that write into the project directory fail. lazydocker's own config lives in
  `cli/lazydocker/`.
- **The Compose plugin in the lazydocker image (2.40.3, Alpine package) is older
  than the host's (v5.3.0).** lazydocker's Compose actions use the older plugin.
  If a Compose file needs newer features, run that action on the host. Container
  actions (logs, stats, restart, exec) use the Docker API directly.
- **`cli/kubeconfig` holds cluster-admin credentials.** It's created with mode
  600, git-ignored, and removed by `cluster/cluster.sh down`.
- **The images aren't rebuilt automatically for Alpine security updates.** Run
  `docker compose -f cli/compose.yaml build --pull` from time to time.

**Possible follow-ups (update-setup-02)**
- Argo CD app-of-apps for `platformservices/` (the aggregate Kustomize tree is
  already the right shape; adds pruning and drift detection);
- istio-csr (cert-manager as the Istio mesh CA, instead of the static plug-in CA);
- cert-manager for the ESO webhook;
- cert-manager approver-policy;
- Istio ambient mode;
- Gateway API `HTTPRoute`s attached to both classes, instead of two Ingresses;
- a real ESO backend (for example Vault in dev mode);
- upgrading KEDA;
- a local image registry.
