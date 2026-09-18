# Architecture

Local Kubernetes development platform on [kind](https://kind.sigs.k8s.io/):
one host, one cluster, everything reproducible from this repository.

- **Purpose:** trying out platform components (ingress, service mesh, GitOps,
  secrets, certificates, storage, registry) close to how they behave in
  production, on a laptop.
- **How it came to be:** [`update-setup-01.md`](update-setup-01.md) (applied
  2026-09-15) and [`update-setup-02.md`](update-setup-02.md) (applied
  2026-09-16). This file describes the result and records the decisions.
- **Operating instructions:** [`README.md`](README.md).

## Quality goals

| Goal | Why |
| --- | --- |
| Reproducible | The whole platform comes back from `cluster/cluster.sh up` plus `./deploy.sh`; versions are pinned |
| Disposable cluster, durable data | Certificates, LVM volumes and registry images survive `cluster.sh down` |
| Production-like | Real ingress paths, mTLS, GitOps, CSI storage and a registry with TLS, rather than shortcuts |
| Modest resources | Runs next to a desktop on a 16 GB laptop |
| Portable | Nothing depends on this machine beyond Docker, LVM and systemd; a move to WSL2 stays possible |

## Constraints

- **Host:** Ubuntu 24.04, Docker on **ZFS**, 16 GB RAM, Wi-Fi with DHCP.
- **kind nodes are containers:** their `/dev` is a tmpfs copy, kubelet and
  containerd run inside them, and host services are reachable over the `kind`
  Docker network (`172.21.0.0/16`).
- **No public DNS or CA:** names end in `.kind.local`, certificates come from a
  local CA.

## C4 container diagram

```mermaid
C4Container
    title Container diagram: kind development platform

    Person(dev, "Developer", "Deploys and tries out workloads")

    System_Boundary(host, "Host (Ubuntu, Docker, systemd)") {
        Container(cli, "CLI tools", "k9s, lazydocker (Compose project kind-cli)", "Cluster and Docker operation; own images, pinned versions")
        Container(cpk, "cloud-provider-kind", "Container, Docker socket", "Gives LoadBalancer Services an IP and serves the default IngressClass")
        Container(envoys, "kindccm-* proxies", "Envoy containers", "One per LoadBalancer Service and per namespace with Ingresses")
        Container(lvmd, "lvmd", "systemd unit, gRPC over a Unix socket", "Creates and resizes LVM volumes for TopoLVM")
        ContainerDb(vg, "Volume group topolvm-vg", "LVM on a loop-backed file", "Backing store of all node volumes")
        Container(harbor, "Harbor", "Docker Compose: nginx, core, registry, jobservice, portal, db, redis", "Container registry with TLS from the local CA")
        Container(keycloak, "Keycloak", "Docker Compose: keycloak + PostgreSQL, port 8443", "Central identity provider standing in for a company IdP; realm localdev as code")
        ContainerDb(pki, "Local PKI", "OpenSSL files in pki/out", "Root CA plus intermediates for cert-manager, the Istio mesh and the host-side services")
    }

    System_Boundary(cluster, "kind cluster dev (Kubernetes 1.36)") {
        Container_Boundary(platform, "Platform services (platformservices/)") {
            Container(istio, "Istio", "istiod + ingress gateway", "Second ingress path and the service mesh; mTLS from the local root")
            Container(certmgr, "cert-manager", "ClusterIssuer kind-ca", "Issues certificates for Ingresses and services")
            Container(trustmgr, "trust-manager", "Bundle kind-root-ca", "Distributes the root certificate into every namespace")
            Container(eso, "External Secrets Operator", "Cluster-wide", "Syncs external secret stores into Kubernetes Secrets")
            Container(argocd, "Argo CD", "Upstream install, cluster-wide", "GitOps for all namespaces")
            Container(topolvm, "TopoLVM", "CSI controller + node DaemonSet", "StorageClass topolvm; talks to lvmd on the host")
            Container(otelcol, "OpenTelemetry Collector", "DaemonSet behind Service otel-collector (node-local)", "Collects logs, metrics and traces on every node")
            ContainerDb(prometheus, "Prometheus", "One process, OTLP and remote-write receivers", "Metrics, 15 days; exemplars for recent data")
            ContainerDb(loki, "Loki", "Monolithic, filesystem on TopoLVM", "Logs, 7 days")
            ContainerDb(tempo, "Tempo", "Monolithic, local storage on TopoLVM", "Traces, 72 hours; generates span metrics and the service graph")
            Container(grafana, "Grafana", "Ingress grafana.kind.local", "Explores all three signals, linked; login through Keycloak")
        }
        Container_Boundary(appspace, "Applications (applications/)") {
            Container(apps, "Test workloads", "testapp, testapp-mesh", "The same app with and without a sidecar, each with two Ingresses")
            Container(guestbook, "guestbook", "Deployed by Argo CD", "Proves the cluster-wide GitOps permissions")
        }
    }

    Rel(dev, cli, "Operates", "terminal")
    Rel(dev, harbor, "Pushes images, uses the UI", "HTTPS")
    Rel(dev, envoys, "Reaches applications", "HTTP/HTTPS")
    Rel(dev, argocd, "Declares applications, uses the UI", "Git and HTTPS via Ingress")

    Rel(cli, apps, "Manages workloads", "Kubernetes API over the kind network")
    Rel(cpk, envoys, "Creates and configures", "Docker API")
    Rel(envoys, apps, "Forwards traffic", "TCP")
    Rel(envoys, istio, "Forwards traffic for the istio class", "TCP")

    Rel(topolvm, lvmd, "Creates volumes", "gRPC over the mounted socket")
    Rel(lvmd, vg, "Manages logical volumes", "LVM")
    Rel(apps, vg, "Mounts volumes", "XFS on /dev/mapper")

    Rel(certmgr, pki, "Signs with the issuing CA", "Secret from pki")
    Rel(istio, pki, "Mesh certificates from the mesh CA", "Secret cacerts")
    Rel(trustmgr, apps, "Provides the root certificate", "ConfigMap per namespace")
    Rel(argocd, guestbook, "Deploys into any namespace", "Kubernetes API")
    Rel(apps, harbor, "Pulls images", "HTTPS via containerd, certs.d")

    Rel(dev, keycloak, "Logs in once for the platform", "HTTPS, browser")
    Rel(argocd, keycloak, "OIDC discovery and token validation", "HTTPS via CoreDNS to the kind gateway")
    Rel(harbor, keycloak, "Authenticates users, groups decide admin rights", "OIDC")
    Rel(keycloak, pki, "Server certificate from the issuing CA", "files in identity/out/tls")

    Rel(apps, otelcol, "Sends telemetry", "OTLP to otel-collector.monitoring.svc")
    Rel(istio, otelcol, "Sends spans", "OTLP")
    Rel(otelcol, prometheus, "Metrics", "OTLP")
    Rel(otelcol, loki, "Logs, events", "OTLP")
    Rel(otelcol, tempo, "Traces", "OTLP")
    Rel(tempo, prometheus, "Span metrics, service graph", "remote write with exemplars")
    Rel(grafana, prometheus, "Queries", "PromQL")
    Rel(grafana, loki, "Queries", "LogQL")
    Rel(grafana, tempo, "Queries", "TraceQL")
    Rel(grafana, keycloak, "Login", "OIDC")
    Rel(dev, grafana, "Explores telemetry", "HTTPS via Ingress")
```

## Storage

Volumes are LVM logical volumes on the host. `lvmd` runs there as a systemd
unit; the kind nodes reach its socket and the LVM devices through `extraMounts`.

```mermaid
flowchart TD
    pvc["PersistentVolumeClaim<br/>StorageClass topolvm (default)"] --> ctrl["topolvm-controller<br/>(in the cluster)"]
    ctrl --> node["topolvm-node<br/>(DaemonSet on every node)"]
    node -->|"gRPC via /run/topolvm/lvmd.sock<br/>(extraMount from the host)"| lvmd["lvmd<br/>systemd unit on the host"]
    lvmd --> vg["Volume group topolvm-vg"]
    vg --> loop["/dev/loop19"]
    loop --> img["/var/lib/topolvm/backing.img<br/>60 GB sparse file"]
    vg -.->|"Device appears via the /dev extraMount"| pod["Pod mounts the volume<br/>XFS, expandable online"]

    subgraph boot["At boot"]
        loopsvc["topolvm-loop.service<br/>re-creates the loop device, activates the VG"] --> lvmdsvc["lvmd.service"]
    end
```

- **Node-local:** `WaitForFirstConsumer`, so the pod is scheduled first and the
  volume is created on its node.
- **Fallback:** kind's `standard` (local-path) stays available.
- **Snapshots** would need a thin pool; the device class for that is prepared in
  `storage/lvmd.yaml` but commented out.

## Registry

Harbor runs on the host, so images outlive the cluster.

```mermaid
flowchart LR
    subgraph hostside["Host"]
        compose["Docker Compose project harbor<br/>9 containers, ports 3030/3443"]
        cert["Server certificate harbor.kind.local<br/>issued by the local issuing CA"]
        prep["./prepare (root, one-time)<br/>renders configs and secrets"]
    end
    subgraph clusterside["kind cluster"]
        containerd["containerd on every node<br/>/etc/containerd/certs.d/harbor.kind.local:3443"]
        pod["Pod pulls<br/>harbor.kind.local:3443/library/..."]
    end

    prep --> compose
    cert --> compose
    containerd -->|"HTTPS to 172.21.0.1<br/>CA: kind-dev root"| compose
    pod --> containerd
    dev["Developer / CI"] -->|"push, UI"| compose
```

- **Trust:** the certificate comes from the same local CA as everything else, so
  the nodes and the host verify it without exceptions.
- **Name resolution:** `registry/kind-trust.sh` writes the `/etc/hosts` entry,
  the CA and `hosts.toml` into the nodes after every cluster creation.
- **Ports:** Harbor listens on 3030/3443 so that 80 and 443 stay free on the host
  for the cluster ingress. `external_url` makes Harbor put that port into the
  URLs it generates, and the port becomes part of the registry name in every
  image tag.
- **Privileges:** only `prepare` needs root; running Harbor does not.

## Observability

One collector per node, three stores, one place to look (update-setup-05,
ADR-0019 to ADR-0022).

```mermaid
flowchart LR
    subgraph node["every node, control plane included"]
        app["Services and sidecars"]
        logs["/var/log/pods"]
        kubelet["kubelet /metrics/cadvisor"]
        annotated["pods with prometheus.io/scrape"]
        otel["OpenTelemetry Collector<br/>(DaemonSet pod)"]
    end
    svc["Service otel-collector<br/>internalTrafficPolicy: Local"]
    subgraph mon["namespace monitoring"]
        prom["Prometheus"]
        loki["Loki"]
        tempo["Tempo"]
        grafana["Grafana"]
    end

    app -->|"OTLP"| svc
    svc -->|"same node only"| otel
    logs --> otel
    kubelet --> otel
    annotated --> otel
    otel -->|"OTLP metrics"| prom
    otel -->|"OTLP logs, events"| loki
    otel -->|"OTLP traces"| tempo
    tempo -->|"span metrics, service graph,<br/>remote write with exemplars"| prom
    grafana --> prom & loki & tempo
```

- **One endpoint for every service and for the mesh:**
  `otel-collector.monitoring.svc:4317` (gRPC) and `:4318` (HTTP). The Service's
  `internalTrafficPolicy: Local` delivers each request to the collector on the
  sender's own node; there are no host ports.
- **What each collector gathers on its node:** pod logs (with read positions
  kept on the node), host metrics (in a pipeline of their own that stamps the
  node name), container metrics from the kubelet's `/metrics/cadvisor`, pods
  annotated `prometheus.io/scrape` (Istio, cert-manager), and OTLP. The one
  holding the Lease also collects cluster metrics and Kubernetes events.
- **Metric names are mixed, labels are not.** Cluster and host metrics use
  OpenTelemetry names (`k8s_*`, `system_*`); container metrics use cAdvisor's
  (`container_*`); scraped applications keep their own (`istio_*`). All carry
  `k8s_namespace_name` and `k8s_pod_name`, so queries join across them.
- **The links between signals:**

| From | To | Through |
| --- | --- | --- |
| a metric sample | its trace | exemplars; Tempo's label is `traceID` |
| a trace | its logs | the trace id, stored with each OTLP log line |
| a trace | its metrics | Grafana's trace-to-metrics queries on Prometheus |
| a log line | its trace | the trace id in the line |
| the mesh | a service graph | Tempo's `service-graphs` processor |

- **Retention:** Prometheus 15 days (15 Gi), Loki 7 days (10 Gi), Tempo 72 hours
  (10 Gi), all on TopoLVM volumes.
- **What a collector restart can lose:** no pod logs, which resume at their
  read position; no queued data, since the send queues are on the node's disk;
  a short gap in pulled metrics; and only what services push during the seconds
  the collector is down. Verified: a 74-second Loki outage with a collector
  restart in the middle lost none of 120 log lines.
- **Limits of this host:** the kubelet's `/stats/summary` fails on ZFS, so
  container metrics come from cAdvisor instead; kind's kubelet certificates name
  no IP and are not verified; and host metrics describe the **host machine**,
  because kind's nodes share its kernel.

## Identities and roles

Two parallel paths lead into every service: identities from Keycloak, and local
break-glass accounts that Keycloak knows nothing about.

```mermaid
flowchart LR
    subgraph kc["Keycloak realm localdev"]
        dev["User dev"]
        ga["Group platform-admins"]
        gu["Group platform-users"]
        dev --> ga
    end
    subgraph svc["Services"]
        argo["Argo CD<br/>argocd-rbac-cm"]
        harbor["Harbor<br/>oidc_admin_group"]
        grafana["Grafana<br/>role_attribute_path"]
    end
    subgraph local["Local accounts (break-glass)"]
        la["argocd admin"]
        lh["harbor admin"]
        lg["grafana admin"]
        lk["keycloak admin (master realm)"]
    end

    ga -->|"groups claim -> role:admin"| argo
    ga -->|"groups claim -> admin_role_in_auth"| harbor
    ga -->|"groups claim -> GrafanaAdmin"| grafana
    gu -->|"everyone else: role:readonly"| argo
    gu -->|"groups claim -> Editor"| grafana
    la -.->|"form login, bypasses the IdP"| argo
    lh -.->|"always_sso_login=false"| harbor
    lg -.->|"login form"| grafana
    lk -.->|"administers the realm"| kc
```

### Where the credentials live

Every password is generated, never committed: `identity/out/` and
`registry/out/` are git-ignored, and `identity/.env` is mode 600.

| Identity | Scope | Password / secret |
| --- | --- | --- |
| `dev` | Realm user, member of `platform-admins`; the account for daily use | `identity/out/dev-password` |
| `admin` (Keycloak) | `master` realm, administers `localdev` | `identity/out/admin-password` |
| `admin` (Argo CD) | Local account, form login only | Secret `argocd-secret` in namespace `argocd`; the first password is in Secret `argocd-initial-admin-secret` |
| `admin` (Harbor) | Local account, `/account/sign-in?always_sso_login=false` | `harbor_admin_password` in `registry/out/harbor/harbor.yml` |
| `admin` (Grafana) | Local account, the login form under the Keycloak button | `identity/out/grafana-admin-password`, copied into Secret `grafana-admin` in namespace `monitoring` |
| Client `argocd` | Confidential OIDC client | `identity/out/argocd-client-secret`, copied into `argocd-secret` as `oidc.keycloak.clientSecret` |
| Client `harbor` | Confidential OIDC client | `identity/out/harbor-client-secret`, stored in Harbor's configuration |
| Client `grafana` | Confidential OIDC client, PKCE | `identity/out/grafana-client-secret`, copied into Secret `grafana-oidc` in namespace `monitoring` |
| PostgreSQL | Keycloak's database | `identity/out/db-password` |

### How group membership becomes rights

| Group | Argo CD | Harbor | Grafana |
| --- | --- | --- | --- |
| `platform-admins` | `policy.csv: g, platform-admins, role:admin` | `oidc_admin_group`, reported as `admin_role_in_auth: true` | `GrafanaAdmin`: server admin and organisation Admin |
| `platform-users` | covered by `policy.default: role:readonly` | ordinary user, projects assigned per project | `Editor` |
| no group | `role:readonly` | ordinary user | `Viewer` |

Four details that cost time to learn, so they are recorded here:

- **Argo CD identifies users by the `email` claim,** so the session username is
  `dev@kind.local`, while Harbor onboards `preferred_username`, i.e. `dev`.
- **Harbor leaves `sysadmin_flag` false for OIDC admins.** That column is for
  locally promoted admins; rights from `oidc_admin_group` are evaluated per
  session and reported as `admin_role_in_auth`.
- **Harbor's OIDC users need the CLI secret** from their profile for
  `docker login`, not their Keycloak password.
- **Grafana grants server admin only for `GrafanaAdmin`.** With
  `allow_assign_grafana_admin`, `role_attribute_path` must return
  `'GrafanaAdmin'`; returning `'Admin'` stops at the organisation. The Grafana
  browser test asserts `isGrafanaAdmin` for exactly this reason.

### Why the local accounts stay

They are the only way back in when the identity path breaks, and during this
setup it broke four times: a rejected `return_url`, a `Secure` state cookie that
a plain-http page never stores, a realm import that failed on an unknown client
scope, and a callback rejected with `invalid_scope`. Each one would have locked
every service out. Disabling Argo CD's local admin (`admin.enabled: "false"`) is
a hardening step for when the OIDC path has proven itself; Harbor's fallback is
worth keeping regardless, because a lockout there also stops image pulls.

---

# Architecture decisions

Format after Michael Nygard: context, decision, consequences. Status values are
*Accepted*, *Superseded* or *Proposed*.

## ADR-0001: kind as the local Kubernetes platform, versions pinned

**Date:** 2026-09-15 · **Status:** Accepted

**Context.** The setup should be recreatable at will and behave like a real
multi-node cluster. The predecessor (2023) used an unpinned kind v0.20 with
Kubernetes 1.27, which had drifted out of support.

**Decision.** kind v0.33 with a node image pinned by digest (Kubernetes 1.36.4),
one control plane and two workers. All cluster and CLI versions live in
`versions.env`; platform service versions are pinned in their
`kustomization.yaml`.

**Consequences.** Rebuilds are reproducible, and upgrades are single, visible
changes. The node image is tied to Istio's supported Kubernetes range, so
component upgrades have to be coordinated. Three nodes cost roughly 2.8 GB RAM.

## ADR-0002: cloud-provider-kind instead of MetalLB

**Date:** 2026-09-15 · **Status:** Accepted

**Context.** The old setup ran MetalLB with a hard-coded address pool that had to
match the Docker network, defined in three overlapping places. `LoadBalancer`
Services and a default Ingress were needed.

**Decision.** cloud-provider-kind runs as a container on the host. It assigns
LoadBalancer IPs from the kind network and provides the default IngressClass
`cloud-provider-kind`.

**Consequences.** No address pools to maintain, and Ingress with TLS works out of
the box. Each namespace with Ingresses gets its own IP. The client source IP is
lost, because Envoy proxies without PROXY protocol. The container needs the
Docker socket, which is root-equivalent access to the host.

## ADR-0003: Istio as a second ingress path; Traefik removed

**Date:** 2026-09-15 · **Status:** Accepted

**Context.** Traefik and Istio both wanted to be the ingress, and Traefik shipped
old `v1alpha2` Gateway API CRDs that conflicted with Istio. Comparing "plain
Kubernetes" against "service mesh" routing was a goal, though.

**Decision.** Traefik goes; Istio provides a second path through IngressClass
`istio`, next to `cloud-provider-kind`. Applications carry one Ingress per path,
so the same workload is reachable both ways.

**Consequences.** Both paths can be compared directly, with one CRD set in the
cluster. Istio TLS secrets have to live in `istio-system`, which is why there's a
wildcard certificate. Traefik-specific features are gone (nothing used them). The
Traefik folder was a separate git repository with unpushed work, so it was moved
to `~/dev/traefik` rather than deleted.

## ADR-0004: Istio per namespace, sidecar mode

**Date:** 2026-09-15 · **Status:** Accepted

**Context.** Mesh and non-mesh behaviour should be observable side by side, and
platform components shouldn't be dragged into the mesh unintentionally.

**Decision.** Sidecar injection is opt-in per namespace via
`istio-injection=enabled`. Platform namespaces are explicitly `disabled`. The
test application is deployed twice: `testapp` and `testapp-mesh`.

**Consequences.** Policies such as STRICT mTLS can be tried on one namespace
while another stays untouched (verified: the vanilla path then fails, the Istio
path keeps working). Pods need a restart when a namespace changes. Ambient mode
remains a later option.

## ADR-0005: Platform services as one Kustomize tree

**Date:** 2026-09-15 · **Status:** Accepted

**Context.** The old setup mixed Helm releases, a kustomize Helm generator and
plain manifests. A single, reviewable description of the platform was wanted,
ideally one Argo CD could consume later.

**Decision.** Every platform service is a Kustomize directory; Helm charts come
in through `helmCharts`. `platformservices/kustomization.yaml` renders everything
at once (246 resources). Applying happens in dependency order through
`platformservices/deploy.sh`, with controllers and their custom resources in
separate directories.

**Consequences.** One format, one render, `kubectl diff` on the whole platform,
and a tree Argo CD can adopt. Lost: Helm release history and `helm rollback`.
`kubectl apply` doesn't prune, so removals need manual cleanup. Rendering needs
`helm` on `PATH` and network access.

## ADR-0006: Repository layout by lifecycle

**Date:** 2026-09-15 · **Status:** Accepted

**Context.** Everything used to live under `deployments/`, mixing cluster setup,
platform services and test applications.

**Decision.** Top-level folders by purpose and lifecycle: `cluster/` (cluster and
PKI), `cli/` (tools), `platformservices/`, `applications/`, and later `storage/`
and `registry/` for the host-side parts.

**Consequences.** It's obvious where something belongs and what runs on the host
versus in the cluster. Host-side folders contain scripts that need root once,
which is documented in each of them.

## ADR-0007: Local two-tier PKI with name constraints

**Date:** 2026-09-15 · **Status:** Accepted

**Context.** Certificates were needed for Ingress TLS and the service mesh,
without warnings in the browser, and without a public CA. Adding a self-signed
root to the host's trust store is a risk if its key leaks.

**Decision.** An OpenSSL root CA on the host (10 years), **name-constrained** to
`kind.local`, `svc`, `cluster.local` and `localhost`, plus two intermediates:
one for cert-manager (`ClusterIssuer kind-ca`) and one for the Istio mesh CA
(`cacerts`). trust-manager distributes the root certificate to all namespaces.
The root key is only needed to issue intermediates and can be kept offline.

**Consequences.** Every certificate, including mesh certificates, chains to one
root; the host can trust it safely (verified: certificates for `example.com` are
rejected). The intermediate keys live in cluster Secrets. There's no CRL or
OCSP: revocation means re-issuing an intermediate. Renewal of leaf certificates
is automatic, the intermediates expire after three years.

## ADR-0008: Argo CD through the Argo CD Operator

**Date:** 2026-09-15 · **Status:** Superseded by ADR-0009

**Context.** Argo CD 2.5.8 was installed as an 11,000-line manifest. An operator
promised lifecycle management through a custom resource.

**Decision.** Install the Argo CD Operator v0.18.0 without OLM and manage an
`ArgoCD` resource.

**Consequences.** It would have added a CRD, a conversion webhook needing
cert-manager wiring, and a cluster-scope environment variable. It also pinned
Argo CD to v3.3.10, which upstream tests only up to Kubernetes 1.35 — while this
cluster runs 1.36.

## ADR-0009: One Argo CD instance from the upstream manifests

**Date:** 2026-09-15 · **Status:** Accepted (supersedes ADR-0008)

**Context.** See ADR-0008. What was actually needed: one instance that can deploy
into every namespace.

**Decision.** The upstream `install.yaml` at tag v3.5.3, pulled in by Kustomize,
in its cluster-wide variant. `server.insecure` is set through a patch on
`argocd-cmd-params-cm`; TLS is terminated at our own Ingress.

**Consequences.** Fewer moving parts, the current Argo CD version (tested with
Kubernetes 1.36), and its settings are normal Kustomize patches. Argo CD has
cluster-wide permissions, which is what makes one instance for all namespaces
possible; `AppProject`s limit what gets deployed where. Upgrades mean changing a
tag, without a Helm release to roll back.

## ADR-0010: CLI tools as containers with their own images

**Date:** 2026-09-15 · **Status:** Accepted

**Context.** k9s and lazydocker shouldn't have to be installed on the host, must
match the cluster version, and should always use the cluster's kubeconfig
regardless of the current context.

**Decision.** A Compose project `kind-cli` with locally built images (k9s v0.51.0
plus matching kubectl; lazydocker v0.25.2), binaries verified by checksum. k9s
uses `kind get kubeconfig --internal` over the kind network; its port-forwards
listen on `0.0.0.0` in the container and are published on `127.0.0.1:18000-18009`.

**Consequences.** Independent of the host's tooling and kubectl skew, and the
current context can't send commands to the wrong cluster. Upstream images are
unusable (outdated, old kubectl), so the images are ours to rebuild. lazydocker
needs the Docker socket, and port-forwards only work within the published range.

## ADR-0011: Disable local storage capacity isolation (ZFS)

**Date:** 2026-09-15 · **Status:** Accepted

**Context.** The cluster wouldn't start: the kubelet exited with
`failed to get rootfs info` because Docker's storage here is ZFS and the vendored
cAdvisor (v0.56.2) shells out to a `zfs` binary that doesn't exist in the node
image. The fix is upstream but unreleased (kind#4229).

**Decision.** `localStorageCapacityIsolation: false` in the kubelet
configuration. Mounting `/dev/zfs` was rejected: the missing binary is the
problem, not the device.

**Consequences.** The cluster starts. Pods' `ephemeral-storage` requests and
limits are not enforced, and nodes don't report ephemeral-storage capacity. On a
non-ZFS host, or once a release ships the fix, the setting can go. A ZFS-enabled
node image would work here but wouldn't be portable to WSL2.

## ADR-0012: Remove the Gateway API "safe-upgrades" policy

**Date:** 2026-09-15 · **Status:** Accepted

**Context.** The Gateway API v1.6.2 bundle installs a `ValidatingAdmissionPolicy`
that rejects older CRD versions. cloud-provider-kind creates its embedded v1.5.0
CRDs at startup, was denied before the usual "already exists" answer, and stopped
with `Failed to start cloud controller`.

**Decision.** `cluster/cluster.sh` deletes the policy and its binding right after
installing the CRDs.

**Consequences.** cloud-provider-kind starts and keeps our newer CRDs (verified).
Accidental downgrades of the Gateway API CRDs are no longer prevented; only
`cluster.sh` installs them.

## ADR-0013: TopoLVM with lvmd on the host for node volumes

**Date:** 2026-09-16 · **Status:** Accepted

**Context.** Kafka/Strimzi and databases want block-backed local storage;
Strimzi explicitly advises against file storage such as NFS. kind's local-path
offers no expansion, no snapshots and no capacity handling. Alternatives were
weighed: NFS (file storage), JuiceFS (FUSE, no block), Ceph/Rook (gigabytes of
RAM, monitor IPs pinned), OpenEBS ZFS (needs a `zfs` binary in the nodes and
isn't portable), csi-driver-host-path (a demo driver).

**Decision.** TopoLVM (chart 17.2.0) with `lvmd` as a systemd unit on the host,
against a volume group on a loop-backed 60 GB file. The nodes get `/dev` and the
`lvmd` socket through `extraMounts`. `topolvm` becomes the default StorageClass;
`standard` stays as a fallback.

**Consequences.** Real LVM volumes with online expansion (verified 1 → 3 GiB
including the filesystem), no extra data plane, and low memory use. Volumes are
node-local and have no snapshots without a thin pool. Logical volumes outlive the
cluster and need cleaning up. The host mount of `/dev` widens what the (already
privileged) nodes can see. A loop file on ZFS means copy-on-write twice.

## ADR-0014: Harbor on the host as the registry

**Date:** 2026-09-16 · **Status:** Accepted

**Context.** A registry was needed that survives cluster rebuilds and speaks TLS
the cluster trusts. Alternatives: a plain registry (zot, distribution) without a
UI, or Harbor in the cluster via Helm, whose data would then die with the cluster.

**Decision.** Harbor v2.15.2 in Docker Compose on the host, with a server
certificate from the local issuing CA. The nodes learn the host entry, the CA and
a containerd `hosts.toml` through `registry/kind-trust.sh`. Harbor's `install.sh`
is not used: it requires the obsolete `docker-compose` v1 binary.

**Consequences.** Images and Harbor's features (UI, RBAC, scanning) survive
cluster rebuilds; the cluster pulls over TLS without exceptions (verified, 199 ms
with a cleared node cache). Harbor needs about 4 GB RAM when running and can be
stopped when not needed. `kind-trust.sh` has to run after every cluster creation.

## ADR-0015: Root only for Harbor's `prepare`, not for running it

**Date:** 2026-09-16 · **Status:** Accepted

**Context.** Harbor's installer runs everything as root. `prepare` is a
`--privileged` container with the host filesystem mounted at `/hostfs`, and it
writes configs and secrets as root with mode 0640, which initially forced
`docker compose` to run as root as well. Running the installation entirely
without root is an open upstream issue (goharbor/harbor#17494).

**Decision.** `prepare` stays a deliberate, rare root step, guarded by a checksum
of `harbor.yml` so it only re-runs on real changes. Afterwards the four env files
that Compose reads get group read for the invoking user; owners stay untouched,
because Harbor's processes read them as uid 10000. Everyday operation runs
unprivileged.

**Consequences.** The privileged surface shrinks to a single, visible step
(verified: the script completes with `sudo` disabled, and Harbor restarts as a
normal user). `prepare` resets the permissions, so the script re-applies them.
The `--privileged` container with `/hostfs` remains a trust decision; swapping
Harbor for zot would remove it entirely, at the cost of UI, RBAC and scanning.

## ADR-0016: Storage tiers for applications

**Date:** 2026-09-16 · **Status:** Accepted

**Context.** Different workloads want different storage: databases and Kafka want
local block-backed volumes, other workloads want shared volumes or none at all.

**Decision.** Two tiers: `topolvm` (default) for local volumes, `standard`
(local-path) as a fallback for throwaway data. Shared volumes across nodes (RWX)
are deliberately not provided; if needed, JuiceFS or Ceph would be the next step
(see ADR-0013).

**Consequences.** Simple and cheap, matching Strimzi's recommendation. No RWX and
no data outliving a cluster rebuild at the Kubernetes level: logical volumes stay
on the host, but their PVs don't.

## ADR-0017: Keycloak outside the cluster as the central identity provider

**Date:** 2026-09-17 · **Status:** Accepted

**Context.** Every platform service brought its own login: Argo CD's local admin,
Harbor's admin. That gives no per-person identity, does not scale past one
person, and does not resemble production. An identity provider *inside* the dev
cluster would disappear with every rebuild, while everything else depends on it —
a company IdP behaves the other way round: it is there, and systems register with
it.

**Decision.** Keycloak 26.7.3 with PostgreSQL in Docker Compose on the host, on
port 8443, because 80/443 stay reserved for the cluster ingress and Harbor holds
3030/3443. One realm, `localdev`, applied from `identity/realm/localdev.yaml` by
keycloak-config-cli, which updates an existing realm instead of only creating
one — so the realm is code rather than state on the host. Argo CD and Harbor are
the first clients, authorization comes from the `groups` claim
(`platform-admins`), and the server certificate is issued by the local issuing
CA, so clients verify it against the same root as everything else. Local admin
accounts stay as break-glass.

**Consequences.** One login for the platform, identity survives cluster rebuilds,
and each further service is one client plus its own OIDC settings. Argo CD
verifies the issuer through `rootCA` instead of skipping verification, and pods
resolve the issuer through a CoreDNS hosts entry that `cluster/host-services-dns.sh`
re-applies after every cluster creation. Against that: logging in now depends on
Keycloak running, the port appears in the issuer URL and in every redirect URI,
Harbor's trust step needs one root-owned copy of the root CA, and the in-cluster
operator path is not practised. Secrets (client secrets, admin and user
passwords) live in `identity/out/`, outside git.

ADR-0018 is reserved by the postponed update-setup-04 (OIDC for the API server).

## ADR-0019: Collection with the OpenTelemetry Collector

**Date:** 2026-09-18 · **Status:** Accepted

**Context.** Metrics, logs and traces have to be collected from the nodes, the
workloads and the mesh. Grafana's `k8s-monitoring` chart and the upstream
collector both do it. Alloy is Grafana's distribution of the same OpenTelemetry
components with its own configuration language, and `k8s-monitoring` 4.x still
needs collectors defined and every feature assigned by hand.

**Decision.** The upstream collector, Kubernetes distribution
(`otel/opentelemetry-collector-k8s` 0.160.0) from chart 0.173.1, sending OTLP to
every backend. The chart's presets are used where they fit this cluster; three
did not, and their receivers are configured by hand: annotation discovery
follows OpenTelemetry's own annotations rather than `prometheus.io/*`; kubelet
metrics fail on this host (below); and host metrics from the three nodes collided
into one series until they got a pipeline that stamps the node name.

**Consequences.** Vendor-neutral configuration in plain YAML, checked with
`otelcol-k8s validate` before it is applied. Chart and image are upgraded
together, because the presets rely on component-name aliases that 0.160 still
accepts. The configuration is longer than a preset-only one, and each hand-made
receiver is commented with the reason it exists.

## ADR-0020: The collector as a DaemonSet behind one node-local Service

**Date:** 2026-09-18 · **Status:** Accepted

**Context.** Pod logs exist only as files on each node, and the collector has no
receiver that reads them through the Kubernetes API. Services should have one
endpoint. A single Service name is not a single processing point, and nothing
planned needs one: cluster-wide receivers can use leader election, and Tempo
computes span metrics from every span itself. Considered: a gateway Deployment
only (loses pod logs), agent plus gateway (a second component with no work yet),
and `hostPort` (a second way in, reachable from outside the pod network).

**Decision.** A DaemonSet on every node, the control plane included (its API
server, etcd and scheduler logs are the most useful). Service `otel-collector`
with `internalTrafficPolicy: Local` is the only endpoint, for services and Istio
alike; no host ports. Cluster metrics and events run on one pod at a time,
through Leases. Send queues are on the node's disk. A gateway is added when tail
sampling, central filtering or an export outside the cluster requires it.

**Consequences.** One address, no cross-node hop, the sending pod identified by
its connection. A restart loses only what services push during the seconds it is
down: logs resume from their read position and queued data survives — verified
with a 74-second backend outage and a collector restart, 120 of 120 log lines
delivered. The exporters' retry gives up after its default five minutes, which
bounds how long a backend may stay down without loss. The queues last as long as
the node.

## ADR-0021: Prometheus as the metrics store, fed over OTLP

**Date:** 2026-09-18 · **Status:** Accepted

**Context.** Mimir was the first choice. Its chart (`mimir-distributed` 6.2.0)
enables Kafka, MinIO and a dozen components and has no monolithic mode, and
Mimir's strengths — scale-out, object-storage retention, multi-tenancy — do not
apply to one node. `kube-prometheus-stack` would duplicate the collection layer
and bring its own Grafana.

**Decision.** Prometheus 3.14 for storage and queries only: an OTLP receiver for
the collector, a remote-write receiver for Tempo's span metrics, exemplar
storage, the Kubernetes resource attributes promoted to labels, and every scrape
job but its own disabled.

**Consequences.** One process from a maintained chart; Grafana is unaffected if
Mimir is ever added behind remote write. Without promotion no metric could be
filtered by namespace — it is verified in place. Exemplars live in memory, so
metric → trace links exist for recent data only, and their label is `traceID`,
which Grafana's data source names explicitly. Retention is bound by a 15 GiB
volume.

## ADR-0022: Monolithic Loki and Tempo on local volumes

**Date:** 2026-09-18 · **Status:** Accepted

**Context.** Scalable modes and object storage serve throughput and availability
this cluster does not need. The charts moved: `grafana`, `tempo` and
`tempo-distributed` are deprecated in `grafana/helm-charts`, and Loki's chart
there is for Grafana Enterprise Logs only.

**Decision.** Loki in `Monolithic` mode and Tempo 3 monolithic, filesystem
storage on TopoLVM, 7 days and 72 hours of retention, charts from
`grafana-community`. Tempo's metrics generator gets its processors through the
tenant overrides — the chart's default enables none.

**Consequences.** A small footprint and no object store to run; no high
availability; the data lives and dies with the cluster. The charts come from a
community repository, whose releases need watching. Tempo's chart keeps an
unused Jaeger receiver: its Service template requires the block, and kustomize
drops the `null` that would remove it.
