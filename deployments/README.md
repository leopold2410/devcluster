# kind development cluster — deployments

A collection of Kubernetes manifests, Helm charts and shell scripts used to bring
up a local development cluster on [kind](https://kind.sigs.k8s.io/) (Kubernetes IN
Docker). It installs the core "platform" services (load balancer, service mesh /
ingress, GitOps, secrets) plus a couple of demo/test workloads.

> ⚠️ **Status:** this is an older, somewhat experimental setup. Several pieces are
> commented out, some overlap (Istio *and* Traefik, two MetalLB definitions), and
> pinned versions (Traefik v3.0, ESO, KEDA 2.11.0, MetalLB 0.13.10) are dated.
> Treat it as a starting point, not a turnkey environment. See
> [Caveats & cleanup](#caveats--cleanup).

## Prerequisites

You need these tools on your `PATH`:

| Tool | Used for |
| --- | --- |
| `docker` | Runs the kind nodes; MetalLB reads its Docker network |
| `kind` | Creates the local cluster |
| `kubectl` (v1.25+) | Applies manifests; `kubectl kustomize --enable-helm` inflates Helm charts |
| `helm` (v3) | Installs Istio, MetalLB (wrapper chart) and ESO |

Charts are pulled from upstream repos at deploy time, so an internet connection is
required on first run.

## Big picture

```
kind cluster (Docker)
└── MetalLB            LoadBalancer IPs, handed out from the kind Docker subnet
    ├── Istio          base + istiod + ingress gateway   (default path)
    └── Traefik        ingress + Gateway API             (alternative, commented out)
        └── ArgoCD     GitOps UI, exposed via Traefik    (commented out)

Add-ons / workloads
├── external-secrets-operator   syncs external secret stores into k8s Secrets
├── keda                        event-driven autoscaling (raw 2.11.0 manifest)
├── testapp                     nginx demo behind a LoadBalancer Service
└── secret-test                 demo app with base + local/dev kustomize overlays
```

Everything is organized as **kustomize bases** (often wrapping a Helm chart via
`HelmChartInflationGenerator`) plus small `deploy.sh` wrappers.

## Repository layout

| Path | What it is |
| --- | --- |
| `basicservices/deploy.sh` | Top-level orchestrator for the platform services |
| `basicservices/metallb/` | MetalLB via a local `loadbalancer` wrapper chart; IP pool derived from the kind Docker network |
| `basicservices/istio/` | Istio `base`, `istiod` and ingress `gateway` Helm releases |
| `basicservices/traefik/` | Traefik ingress: `prerequisites/` (CRDs, RBAC, namespace) + `base/` (Helm chart + Services/Ingress/Gateway) |
| `basicservices/argocd/` | ArgoCD install + Ingress/HTTPRoute (`argocd.localhost`) |
| `basicservices/testhelm/` | A scaffolded sample Helm chart (not wired into any deploy script) |
| `external-secrets-operator/` | ESO via Helm (`prerequisites/` namespace + `base/` chart) |
| `keda/keda-2.11.0.yaml` | Full KEDA 2.11.0 manifest, applied directly |
| `testapp/` | nginx Deployment + `LoadBalancer` Service (MetalLB smoke test) |
| `secret-test/` | Demo web app; `base/` + `overlays/{local,dev}` (own git repo) |

## Step 0 — Create the kind cluster

The cluster config lives one level up, in `../cluster-config.yaml` (1 control
plane + 4 workers, NodePort mappings for Traefik). Create the cluster from there:

```bash
cd .. && ./cluster.sh     # kind create cluster --config cluster-config.yaml --name dev
```

See [`../README.md`](../README.md) for the cluster and MetalLB setup, and for
suggested improvements. A plain `kind create cluster --name dev` also works, but
you lose the host port mappings and the `tier: ingress` node labels that Traefik
relies on.

Confirm your context points at it:

```bash
kubectl config use-context kind-dev
kubectl get nodes
```

MetalLB later inspects the `kind` Docker network to pick an IP range, so the
cluster must exist (and its Docker network must be present) before you deploy it.

## Step 1 — Platform services (`basicservices`)

The orchestrator runs from `basicservices/`:

```bash
cd basicservices
./deploy.sh
```

As checked in, `deploy.sh` runs **MetalLB** and **Istio** only — Traefik and
ArgoCD are commented out:

```bash
deploy_metallb
deploy_istio
#deploy_traefik
#deploy_argocd
```

### MetalLB (`basicservices/metallb`)

`metallb/deploy.sh`:

1. Reads the kind Docker network CIDR:
   `docker network inspect kind -f '{{(index .IPAM.Config 0).Subnet}}'`
2. Derives an address range from it (e.g. `172.22.255.1-172.22.255.250`).
3. `helm upgrade --install` of the local `loadbalancer` chart, which depends on
   upstream MetalLB `0.13.10`, into `metallb-system`.

> **Note:** the derived `METALLB_IP_RANGE` is computed but the line that writes it
> to `environment-properties.env` is commented out, and the actual pool
> (`IPAddressPool`) is hard-coded in `01-metallb-config.yaml` /
> `loadbalancer/values.yaml`. If your kind network is **not** `172.22.0.0/16`,
> update the IP range so LoadBalancer Services get reachable IPs.

### Istio (`basicservices/istio`)

`istio/deploy.sh` runs three Helm releases into `istio-system`:

```bash
helm upgrade istio-base    istio/base    --install --set defaultRevision=default --wait
helm upgrade istiod        istio/istiod  --install --wait
helm upgrade istio-ingress istio/gateway --install --wait
```

The script assumes the `istio` Helm repo is already registered. Add it once:

```bash
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update
```

### Traefik (`basicservices/traefik`) — optional

Enabled by uncommenting `deploy_traefik` in `deploy.sh`, or run directly:

```bash
cd basicservices/traefik
./deploy.sh install     # install prerequisites, then Traefik
./deploy.sh get_port    # print the 'web' nodePort of the traefik Service
```

Two phases (see `traefik/README.md`):

1. **Prerequisites** (`kubectl apply -k prerequisites`): Gateway API CRDs,
   `traefik` namespace, ServiceAccount, ClusterRole/RoleBinding, Traefik CRDs.
2. **Traefik** (`kubectl kustomize base --enable-helm | kubectl apply -f -`):
   the Traefik Helm chart (v3.0) plus web UI Service/Ingress and metrics Ingress.
   A shared Gateway API `Gateway` (`10-gateway.yaml`) and HTTPRoute exist but are
   commented out in `base/kustomization.yaml`.

### ArgoCD (`basicservices/argocd`) — optional

Enabled by uncommenting `deploy_argocd`, or:

```bash
kubectl apply -k basicservices/argocd/base
```

Installs ArgoCD into the `argocd` namespace with an Ingress at
`argocd.localhost` (routed through Traefik, so deploy Traefik first). An
alternative Gateway API `HTTPRoute` (`03-httproute.yaml`) is available but
commented out.

## Step 2 — Add-ons

### External Secrets Operator (`external-secrets-operator`)

```bash
cd external-secrets-operator
./deploy.sh install
```

Applies the `prerequisites` (the `external-secrets` namespace) and then inflates
the ESO Helm chart from `https://charts.external-secrets.io` into that namespace.

### KEDA (`keda`)

Plain manifest, no script:

```bash
kubectl apply -f keda/keda-2.11.0.yaml
```

## Step 3 — Test workloads

### testapp (`testapp`)

nginx (3 replicas) fronted by a `LoadBalancer` Service — the quickest way to
confirm MetalLB is handing out reachable IPs:

```bash
cd testapp
./deploy.sh                       # kubectl apply -k .
kubectl -n testapp get svc nginx  # EXTERNAL-IP should be from the MetalLB pool
```

### secret-test (`secret-test`)

Demo web app using kustomize base + overlays:

```bash
kubectl apply -k secret-test/overlays/local   # base + Ingress
```

- `overlays/local` — adds an Ingress (`ingressClassName: traefik`; host
  `secret-test-web.minikube`, a leftover you'll likely want to change).
- `overlays/dev` — adds an OpenShift `Route` instead (`04-oc-route.yaml`).

`secret-test/` is its own git repository (has a nested `.git`).

## Quick start (default path)

```bash
# 0. Cluster (from /home/leo/dev/kind)
cd .. && ./cluster.sh && cd deployments

# 1. Helm repo for Istio (one-time)
helm repo add istio https://istio-release.storage.googleapis.com/charts && helm repo update

# 2. Platform: MetalLB + Istio
cd basicservices && ./deploy.sh && cd ..

# 3. Smoke test the load balancer
cd testapp && ./deploy.sh && cd ..
kubectl -n testapp get svc nginx -w
```

## Caveats & cleanup

- **`deploy.sh` only installs MetalLB + Istio** by default; Traefik and ArgoCD are
  commented out. Istio and Traefik both provide ingress — pick one.
- **MetalLB is defined twice**: the active `loadbalancer` wrapper chart and a
  separate `00-metallb-native.yaml` + `01-metallb-config.yaml` kustomize path
  (referenced in `metallb/kustomization.yaml`, not used by `deploy.sh`).
- **IP ranges are hard-coded** to `172.22.255.x`. Verify against your actual kind
  Docker subnet (`docker network inspect kind`) and adjust if different.
- **Pinned versions are old** (Traefik v3.0, KEDA 2.11.0, MetalLB 0.13.10) — bump
  before relying on them.
- Leftover/host references (`secret-test-web.minikube`) suggest this migrated from
  a Minikube setup.

### Tear down

```bash
kind delete cluster --name dev
```
