# kind + MetalLB local cluster

A local multi-node Kubernetes cluster built with [kind](https://kind.sigs.k8s.io/)
(Kubernetes IN Docker), with [MetalLB](https://metallb.io/) handing out real
`LoadBalancer` IPs from the kind Docker network. Platform services and demo apps
live in [`deployments/`](deployments/README.md).

> ⚠️ **Status:** this setup is from mid-2023 (kind v0.20.0, MetalLB 0.13.10,
> Kubernetes 1.27) and is partly experimental. It still describes a working
> pattern, but read [Suggested improvements](#suggested-improvements) before
> relying on it. A planned overhaul (kind upgrade, cloud-provider-kind, Istio
> per namespace, ESO, Argo CD Operator, cert-manager with a local CA) is
> described in [`update-setup-01.md`](update-setup-01.md).

## Contents

| File | Purpose |
| --- | --- |
| `kind` | Checked-in kind binary (**v0.20.0**, default node image Kubernetes v1.27.x) |
| `cluster-config.yaml` | kind cluster definition: 1 control plane + 4 workers, host port mappings |
| `cluster.sh` | Creates the cluster `dev` from `cluster-config.yaml` |
| `deploy.sh` | Deploys `deployments/basicservices` (MetalLB + Istio) and `deployments/testapp` |
| `logs.txt` | Empty; unused |
| `deployments/` | Manifests, Helm charts and scripts; see [`deployments/README.md`](deployments/README.md) |

## Architecture

```
Host (Linux)
│
│  localhost:5080 ──► control-plane:32080  (NodePort → Traefik "web", if deployed)
│  localhost:5443 ──► control-plane:32443  (NodePort → Traefik "websecure")
│
│  172.22.255.1-200 ──► MetalLB L2 (ARP) on the "kind" Docker bridge
│                        → any Service of type LoadBalancer (Istio gateway, testapp nginx)
│
└── Docker network "kind" (e.g. 172.22.0.0/16)
    ├── dev-control-plane   label tier=ingress, tainted NoSchedule
    ├── dev-worker
    ├── dev-worker2
    ├── dev-worker3
    └── dev-worker4         label tier=ingress (Traefik nodeSelector)
```

You can reach the cluster from the host in two ways:

1. **NodePorts via `extraPortMappings`.** Ports 32080/32443 on the control-plane
   container are published to `localhost:5080`/`localhost:5443`. The Traefik
   chart (`deployments/basicservices/traefik/base/values.yaml`) uses exactly these
   NodePorts, so this path only matters when Traefik is deployed.
2. **MetalLB LoadBalancer IPs.** MetalLB runs in Layer 2 mode and answers ARP for
   addresses in the kind Docker subnet. On a **Linux** host the Docker bridge is
   directly routable, so `curl http://<EXTERNAL-IP>` just works. On Docker
   Desktop (macOS/Windows) the bridge is inside a VM and these IPs are **not**
   reachable from the host.

## Cluster configuration (`cluster-config.yaml`)

The file started as kind's "all config fields" example (its header still says
*"this is not a particularly useful config file"*) and was then adapted:

| Setting | Value | Notes |
| --- | --- | --- |
| Nodes | 1 control-plane, 3 plain workers, 1 `tier: ingress` worker | Two more ingress workers are commented out |
| Control-plane node label | `tier=ingress` (via `kubeletExtraArgs.node-labels`) | The node is tainted, so pods without a toleration still won't run there |
| `extraPortMappings` | `32080→5080`, `32443→5443` (TCP, control plane only) | Match Traefik's NodePorts |
| `evictionHard.nodefs.available` | `0%` | Disables disk-pressure eviction; useful on a nearly full laptop disk |
| `apiServer.certSANs` | adds `my-hostname` | Placeholder from the example; has no effect unless you use that name |
| kubeadm patch API | `kubeadm.k8s.io/v1beta3` | Correct for the node image that kind v0.20 uses |

## MetalLB setup

MetalLB is installed by `deployments/basicservices/metallb/deploy.sh` as a small
local **wrapper Helm chart** called `loadbalancer`:

```
deployments/basicservices/metallb/
├── deploy.sh                    # the active install path
├── loadbalancer/                # wrapper chart (release name "loadbalancer")
│   ├── Chart.yaml               # depends on metallb 0.13.10 (vendored in charts/)
│   ├── values.yaml              # addresspool: [172.22.255.1-172.22.255.200]
│   └── templates/
│       ├── ipadresspool.yaml    # IPAddressPool "example"  (post-install hook)
│       └── l2advertisement.yaml # L2Advertisement "empty"  (post-install hook)
│
├── kustomization.yaml           # alternative path, NOT used by deploy.sh:
├── 00-metallb-native.yaml       #   upstream metallb-native manifest v0.13.10
├── 01-metallb-config.yaml       #   IPAddressPool 172.22.255.1-250 + L2Advertisement
├── environment-properties.env   #   METALLB_IP_RANGE, injected via kustomize replacements
└── values.yaml                  # legacy configInline format (pre-0.13); ignored
```

What `deploy.sh` does:

1. Reads the kind network subnet:
   `docker network inspect kind -f '{{(index .IPAM.Config 0).Subnet}}'`
2. Rewrites it with `sed` into `x.y.255.1-x.y.255.250`, which assumes a `/16`
   subnet ending in `.0.0`.
3. Runs `helm upgrade --install loadbalancer loadbalancer -n metallb-system --create-namespace --wait`.

The computed `METALLB_IP_RANGE` is **never used**. It isn't passed to Helm, and the
line that would write it to `environment-properties.env` is commented out. The
pool that actually gets applied is the hard-coded `172.22.255.1-172.22.255.200`
from `loadbalancer/values.yaml`. If your kind network isn't `172.22.0.0/16`,
Services get IPs that nobody can reach.

The pool and advertisement are Helm `post-install` hooks. They must be created
after MetalLB's CRDs and webhook are ready, and the hooks guarantee that.

## Usage

Prerequisites: `docker`, `kubectl`, `helm` (v3). The Istio Helm repo must be
registered once:

```bash
helm repo add istio https://istio-release.storage.googleapis.com/charts && helm repo update
```

Bring everything up:

```bash
cd /home/leo/dev/kind
./cluster.sh     # kind create cluster --config cluster-config.yaml --name dev
kubectl config use-context kind-dev
kubectl wait --for=condition=Ready nodes --all --timeout=180s

# Check that the MetalLB pool matches your kind subnet (see note above)
docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}'

./deploy.sh      # MetalLB + Istio, then testapp
```

Verify MetalLB:

```bash
kubectl -n metallb-system get pods
kubectl -n metallb-system get ipaddresspools,l2advertisements
kubectl -n testapp get svc nginx               # EXTERNAL-IP from the pool
curl http://$(kubectl -n testapp get svc nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
```

Tear down:

```bash
./kind delete cluster --name dev
```

`cluster.sh` and `deploy.sh` use relative paths (`./kind`, `cluster-config.yaml`),
so run them from this directory.

## Trusting external CAs with trust-manager

> **Planned:** this applies once [`update-setup-01.md`](update-setup-01.md) is
> implemented (cert-manager v1.21.2 + trust-manager v0.25.0). It is not part of
> the current setup.

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

In update-setup-01, the Bundle `kind-root-ca` distributes the local
*kind-dev Root CA* as ConfigMap `kind-root-ca` (key `ca.crt`) to every
namespace.

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
trust-manager also needs Secret targets enabled in its chart:

```bash
--set secretTargets.enabled=true --set 'secretTargets.authorizedSecrets={partner-api-tls-cacert}'
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

## Suggested improvements

Ordered roughly by impact.

### 1. Make the IP pool follow the real Docker subnet

This is the biggest correctness issue. Today the range is computed and then thrown
away. Pass it to the chart, and pick the IPv4 subnet explicitly, since the kind
network is dual-stack and `index .IPAM.Config 0` can return the IPv6 subnet:

```bash
KIND_NET_CIDR=$(docker network inspect kind \
  -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' | grep -v ':' | head -1)
# e.g. 172.22.0.0/16 -> 172.22.255.200-172.22.255.250
PREFIX=$(echo "$KIND_NET_CIDR" | cut -d. -f1-2)
METALLB_IP_RANGE="${PREFIX}.255.200-${PREFIX}.255.250"

helm upgrade --install loadbalancer loadbalancer -n metallb-system --create-namespace --wait \
  --set "addresspool={${METALLB_IP_RANGE}}"
```

Use the top of the subnet and keep the range small. Docker hands out container IPs
from the bottom, so this avoids clashes with node IPs.

### 2. Pick one MetalLB install path and delete the other

There are three overlapping configs: the wrapper chart, the kustomize
native-manifest path, and a legacy `values.yaml` in the `configInline` format that
MetalLB ≥ 0.13 ignores. Their ranges also disagree (`.1-.200` vs `.1-.250`).
Keep one:

- **Helm (recommended):** keep `loadbalancer/`, delete `00-metallb-native.yaml`,
  `01-metallb-config.yaml`, `kustomization.yaml`, `environment-properties.env`
  and the old `values.yaml`.
- **Plain manifests:** keep the kustomize path, remove the chart, and have
  `deploy.sh` generate `environment-properties.env` before running
  `kubectl apply -k`.

### 3. Fix the Helm hooks so upgrades apply pool changes

`IPAddressPool` and `L2Advertisement` only run on `post-install`. After the
first install, changing `addresspool` and running `helm upgrade` does nothing,
and `helm uninstall` leaves them behind. Use
`"helm.sh/hook": post-install,post-upgrade`. Even simpler, install the upstream
`metallb/metallb` chart with `--wait` and then `kubectl apply` the two small CRs,
which is the approach the MetalLB docs recommend. Also remove the leftover
*"Public IPs are expensive, so we leased just 4 of them"* comment and fix the
filename typo `ipadresspool.yaml`.

### 4. Consider `cloud-provider-kind` instead of MetalLB

The kind project now ships
[`cloud-provider-kind`](https://github.com/kubernetes-sigs/cloud-provider-kind),
which implements `type: LoadBalancer` for kind clusters with no in-cluster
components and no IP-pool bookkeeping, and also works on macOS and Windows.
MetalLB is still worth keeping if the goal is to practise a production-like
MetalLB config.

### 5. Upgrade kind, the node image and MetalLB, and pin them

- kind v0.20.0 and Kubernetes 1.27 are long out of support. Install a current
  kind (package manager, `go install sigs.k8s.io/kind@<version>`, or the release
  binary) instead of keeping a 6 MB binary next to the config.
- Pin the node image in `cluster-config.yaml` so the cluster is reproducible:
  ```yaml
  nodes:
  - role: control-plane
    image: kindest/node:<version>@sha256:<digest>   # from the kind release notes
  ```
- Newer node images (Kubernetes ≥ 1.31) use kubeadm `v1beta4`. The
  `kubeadmConfigPatchesJSON6902` entry that targets `v1beta3` will then **silently
  stop applying**. Update the version, or drop the patch since `my-hostname` is
  only a placeholder.
- MetalLB 0.13.10 is several minor versions behind. Check the release notes when
  bumping, and regenerate `Chart.lock` / `charts/` with `helm dependency update`.

### 6. Clean up `cluster-config.yaml`

- Remove the example header and leftovers: the `my-hostname` certSAN and the
  commented ingress workers.
- Add a `name: dev` field so the name lives in the config and not only in
  `cluster.sh`.
- Decide on an ingress strategy. The control plane is labelled `tier=ingress`
  but is tainted, and the only port mappings are on the control plane. It works
  because NodePorts listen on every node, but it's confusing. Either put the
  `extraPortMappings` on the `tier: ingress` worker, or skip NodePorts and expose
  Traefik/Istio through a MetalLB `LoadBalancer` IP.
- Five nodes is a lot for a laptop. One control plane plus 1–2 workers is enough
  for most testing; add nodes only when you're testing scheduling or HA.
- Pick a fixed `networking.podSubnet`/`serviceSubnet` if you plan to run several
  clusters side by side.

### 7. Make the scripts robust

- Start every script with `set -euo pipefail` so a failed step stops the run.
- Resolve paths via `SCRIPT_DIR` in `cluster.sh` too, so it works from any
  directory (`deploy.sh` already does this).
- Check prerequisites up front (`command -v docker kubectl helm`) and make sure
  the context is `kind-dev` before applying anything.
- After creating the cluster, `kubectl wait --for=condition=Ready nodes --all`.
- Register the Istio Helm repo inside `istio/deploy.sh`
  (`helm repo add istio … 2>/dev/null || true`).
- Add a teardown script, or combine everything into a small `Makefile` with
  `up`, `deploy`, `test` and `down` targets.
- Delete `logs.txt`, which is empty and unused.

### 8. Quality-of-life additions

- **Local image registry:** add a `registry:2` container plus the
  `containerdConfigPatches` from the
  [kind local-registry guide](https://kind.sigs.k8s.io/docs/user/local-registry/)
  so you can `docker push localhost:5001/app` instead of
  `kind load docker-image` for every build.
- **Put the folder under git.** Only `deployments/secret-test` is a repository
  today. Version control makes experiments like switching Istio and Traefik
  reversible. Add `kind` (the binary) and `charts/*.tgz` to `.gitignore`, or
  consciously vendor them.
- **Smoke test script:** deploy `testapp`, wait for an external IP, `curl` it,
  and exit non-zero on failure. That gives a one-command check that
  kind + MetalLB still work after an upgrade.
