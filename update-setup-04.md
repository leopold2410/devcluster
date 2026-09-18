# Update setup 04: OIDC authentication for the API server, with a full RBAC model

| | |
| --- | --- |
| Date | 2026-09-16 |
| Status | **Postponed on 2026-09-18, not applied.** The plan stands; see *Before resuming* for what to re-check and what update-setup-03 taught |
| Scope | `/home/leo/dev/kind`, builds on [`update-setup-03.md`](update-setup-03.md) (Keycloak, realm `localdev`) |

## Before resuming

- **Prerequisites are met.** update-setup-03 is applied: Keycloak runs, the realm
  `localdev` exists, and `tests/run.sh` proves the OIDC logins end to end.
- **Re-check the versions** — Kubernetes (v1.36.4 at writing) and kubelogin
  (v1.36.4) will have moved — and the two *Open points* this plan could not
  verify: the `AuthenticationConfiguration` API version and whether
  `certificateAuthority` takes inline PEM.
- **Lessons from applying update-setup-03 that apply here too:**
  - `openid` is not a Keycloak client scope; listing it in `defaultClientScopes`
    crashes keycloak-config-cli. Step 1 below is already corrected.
  - Declaring `defaultClientScopes` drops Keycloak's optional scopes. If
    kubelogin requests `offline_access` for refresh tokens, the client needs
    `optionalClientScopes: [offline_access]`, or the callback fails with
    `invalid_scope` — after a successful login, which `curl` cannot see.
  - `keycloak.kind.local` resolves to the kind bridge gateway (`172.21.0.1`),
    not to Keycloak's container IP: the nodes cannot route to
    `172.25.0.3` (tested). The API server is `hostNetwork`, so it uses the
    node's `/etc/hosts`, which step 4 writes.
  - Add a suite to `tests/` for the API-server login, so it is verified the same
    way the Argo CD and Harbor logins are.

## Goals

1. **Log in to the API server as a person**, through Keycloak, instead of sharing
   the cluster-admin client certificate that kind generates.
2. **A complete RBAC model driven by group claims:** ClusterRoleBindings for the
   cluster-wide roles, RoleBindings where access should stop at a namespace, and
   nothing bound to `system:authenticated`.
3. **kubectl and k9s both work**, including k9s in its container without a
   browser.
4. **The certificate kubeconfig stays as break-glass.** OIDC is *added*; X.509
   authentication is never switched off.

## What was verified on the running cluster

Before writing this, on `dev-control-plane` (Kubernetes v1.36.4):

- **`--authentication-config` exists** and is *mutually exclusive with the
  `--oidc-*` flags*. The legacy flags are all still there
  (`--oidc-issuer-url`, `--oidc-ca-file`, `--oidc-username-claim`,
  `--oidc-username-prefix`, `--oidc-groups-claim`, `--oidc-groups-prefix`,
  `--oidc-required-claim`), so either path works — but not both.
- **The feature gate is gone as a toggle.** Only the derived gates
  `StructuredAuthenticationConfigurationEgressSelector` and
  `…JWKSMetrics` still appear, so the base feature is GA on 1.36 and needs no
  `--feature-gates` entry.
- **kubeadm here is `kubeadm.k8s.io/v1beta4`,** where `extraArgs` is a **list of
  `{name, value}`**, not a map. The existing config already shows that shape
  (`- name: runtime-config` / `value: ""`).
- **The API server static pod mounts** `/etc/ssl/certs`, `/etc/ca-certificates`,
  `/etc/kubernetes/pki`, `/usr/local/share/ca-certificates` and
  `/usr/share/ca-certificates` — but **not** `/etc/kubernetes` itself. A new
  directory therefore needs an `extraVolumes` entry.
- **The pod is `hostNetwork: true`,** so it resolves names through the node's
  `/etc/hosts`, which already carries `172.21.0.1 harbor.kind.local` from
  `registry/kind-trust.sh`. The same mechanism serves `keycloak.kind.local`.
- **`kubectl auth whoami` works** and prints username plus groups — the
  verification command for this whole plan. Today it answers
  `kubernetes-admin` / `[kubeadm:cluster-admins system:authenticated]`.
- **Built-in ClusterRoles** `cluster-admin`, `admin`, `edit`, `view` are present
  and are what the bindings below use.

## Versions

| Component | Version | Notes |
| --- | --- | --- |
| kubelogin (`kubectl oidc-login`) | **v1.36.4** (2026-09-08) | Asset `kubelogin_linux_amd64.zip` with a published `.sha256` |
| Keycloak | 26.7.3 (from update-setup-03) | Realm `localdev` |

New entry in `versions.env`:

```bash
# update-setup-04: OIDC login to the API server
KUBELOGIN_VERSION=v1.36.4
```

## Decisions

- **Structured `AuthenticationConfiguration`, not the legacy flags.** They are
  mutually exclusive, and the file is the form that survives: CEL claim
  mappings, validation rules and several issuers at once.
- **Everything is prefixed `oidc:`.** Usernames and groups both. Without a
  prefix a Keycloak group named `system:masters` would be a cluster takeover;
  with it, collisions are impossible by construction. The prefix is part of
  every RBAC subject name.
- **`preferred_username` as the username claim,** because `sub` is an opaque
  UUID and unreadable in audit logs and `kubectl auth whoami`.
- **A dedicated public client `kubernetes` with PKCE,** not a confidential one:
  a CLI on a developer machine cannot keep a secret, and PKCE is what public
  clients use instead.
- **Groups carry all authorization.** No user is ever named in a binding, so
  access is granted and revoked in Keycloak, not with kubectl.
- **Break-glass stays.** `--client-ca-file` is untouched and
  `~/.kube/config` keeps its `kubernetes-admin` context. Every step below is
  reversible from that context.
- **RBAC lives in `platformservices/rbac/`,** as a Kustomize part like the other
  platform services, applied by `platformservices/deploy.sh`.

## The RBAC model

| Keycloak group | RBAC subject | Bound to | Kind | Scope |
| --- | --- | --- | --- | --- |
| `platform-admins` | `oidc:platform-admins` | `cluster-admin` | ClusterRoleBinding | cluster |
| `platform-users` | `oidc:platform-users` | `view` + `cluster-reader-extras` | ClusterRoleBinding | cluster |
| `app-testapp-admins` | `oidc:app-testapp-admins` | `edit` | RoleBinding | namespace `testapp` |
| — | `system:authenticated` | nothing | — | — |

Two things this encodes:

- **A person with no group gets nothing.** Authentication succeeds, every
  request is denied, which is the correct default and worth testing explicitly.
- **`view` is namespace-shaped.** The built-in `view` role covers namespaced
  resources but not nodes, PersistentVolumes, StorageClasses or CRDs — exactly
  what you want to look at in a dev cluster. Rather than granting `cluster-admin`
  for that, a small aggregated ClusterRole adds cluster-scoped reads to `view`.

## Step 1: The `kubernetes` client in the realm

Add to `identity/realm/localdev.yaml` (from update-setup-03):

```yaml
  - clientId: kubernetes
    name: Kubernetes API
    enabled: true
    publicClient: true            # no secret: PKCE instead
    standardFlowEnabled: true
    attributes:
      pkce.code.challenge.method: S256
      oauth2.device.authorization.grant.enabled: "true"   # for the k9s container
    redirectUris:
      - http://localhost:8000     # kubelogin's local listener
      - http://localhost:18000
      - urn:ietf:wg:oauth:2.0:oob # authcode-keyboard
    # Client scopes only - "openid" is the request scope, not one of these, and listing
    # it crashes keycloak-config-cli (found while applying update-setup-03).
    defaultClientScopes: [basic, profile, email, roles, groups]
```

And the groups the model above expects:

```yaml
groups:
  - name: platform-admins
  - name: platform-users
  - name: app-testapp-admins
```

The `groups` client scope with the group membership mapper already exists in the
realm file; `full.path: "false"` is what makes the claim read `platform-admins`
rather than `/platform-admins`.

## Step 2: The authentication configuration

New folder `cluster/oidc/`, generated by a script so the CA is never copied by
hand:

```
cluster/
├── oidc-setup.sh              # renders oidc/authentication-config.yaml from pki/ + versions.env
└── oidc/                      # git-ignored: contains the rendered config
    └── authentication-config.yaml
```

`cluster/oidc/authentication-config.yaml`:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AuthenticationConfiguration
jwt:
- issuer:
    url: https://keycloak.kind.local:8443/realms/localdev
    audiences:
    - kubernetes
    certificateAuthority: |
      -----BEGIN CERTIFICATE-----
      ... contents of pki/out/root-ca.crt ...
      -----END CERTIFICATE-----
  claimMappings:
    username:
      claim: preferred_username
      prefix: "oidc:"
    groups:
      claim: groups
      prefix: "oidc:"
  claimValidationRules:
  - claim: email_verified
    requiredValue: "true"
```

Two details to confirm on first run (see *Open points*): the exact API version
(`apiserver.config.k8s.io/v1`, with `v1beta1` as the fallback) and that
`certificateAuthority` takes **inline PEM** rather than a path. If it is inline,
this single file is all the API server needs — no second CA file, no extra mount
beyond the directory itself.

## Step 3: Wire it into the cluster config

`cluster/cluster-config.yaml`, control-plane node — the mount and the patch:

```yaml
nodes:
- role: control-plane
  extraMounts:
  - hostPath: /dev
    containerPath: /dev
  - hostPath: /run/topolvm
    containerPath: /run/topolvm
  - hostPath: /home/leo/dev/kind/cluster/oidc     # absolute path required by kind
    containerPath: /etc/kubernetes/oidc
    readOnly: true
```

```yaml
kubeadmConfigPatches:
- |
  apiVersion: kubeadm.k8s.io/v1beta4
  kind: ClusterConfiguration
  apiServer:
    extraArgs:
    - name: authentication-config
      value: /etc/kubernetes/oidc/authentication-config.yaml
    extraVolumes:
    - name: oidc
      hostPath: /etc/kubernetes/oidc
      mountPath: /etc/kubernetes/oidc
      readOnly: true
      pathType: Directory
```

Note the list form of `extraArgs` — v1beta4. The `extraVolumes` entry is
required because `/etc/kubernetes` is not among the paths the static pod already
mounts, only `/etc/kubernetes/pki` is.

**Faster path for the first experiment:** instead of recreating the cluster,
copy the file into the running node and edit the static pod manifest:

```bash
docker cp cluster/oidc/authentication-config.yaml dev-control-plane:/etc/kubernetes/oidc/
docker exec -it dev-control-plane vi /etc/kubernetes/manifests/kube-apiserver.yaml
# add the flag, the volumeMount and the volume; the kubelet restarts the pod within seconds
docker exec dev-control-plane crictl ps --name kube-apiserver
```

`cluster/cluster.sh down` discards that, so the kind config above is the durable
form.

## Step 4: Name resolution for the API server

The API server must resolve `keycloak.kind.local`. `cluster/oidc-setup.sh` adds
the entry to every node, in the style of `registry/kind-trust.sh`:

```bash
HOST_IP=$(docker network inspect kind -f '{{range .IPAM.Config}}{{if .Gateway}}{{.Gateway}} {{end}}{{end}}' | tr ' ' '\n' | grep -v ':' | head -1)
for node in $("$KIND" get nodes --name "$CLUSTER_NAME"); do
    docker exec "$node" sh -c "grep -q ' keycloak.kind.local\$' /etc/hosts || echo '$HOST_IP keycloak.kind.local' >> /etc/hosts"
done
```

This has to run **after every `cluster/cluster.sh up`**, like `kind-trust.sh`.
The ordering also inverts: **Keycloak must be running before the cluster is
created**, because the API server verifies tokens against the issuer's JWKS.

## Step 5: RBAC as a platform service

New part `platformservices/rbac/`, added to the aggregate
`platformservices/kustomization.yaml` and applied by `deploy.sh` (it has no
dependencies, so it can go first).

`platformservices/rbac/cluster-bindings.yaml`:

```yaml
# Cluster administrators: everything, including RBAC itself.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: oidc-platform-admins
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: oidc:platform-admins     # the prefix comes from claimMappings.groups.prefix
---
# Everyone else with a group: read-only across the cluster.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: oidc-platform-users-view
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: oidc:platform-users
```

`platformservices/rbac/cluster-reader-extras.yaml` — the cluster-scoped reads
that `view` lacks, added by aggregation so the binding above needs no change:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cluster-reader-extras
  labels:
    rbac.authorization.k8s.io/aggregate-to-view: "true"
rules:
- apiGroups: [""]
  resources: [nodes, persistentvolumes, namespaces]
  verbs: [get, list, watch]
- apiGroups: [storage.k8s.io]
  resources: [storageclasses, volumeattachments, csidrivers, csinodes]
  verbs: [get, list, watch]
- apiGroups: [apiextensions.k8s.io]
  resources: [customresourcedefinitions]
  verbs: [get, list, watch]
- apiGroups: [topolvm.io]
  resources: [logicalvolumes]
  verbs: [get, list, watch]
```

`platformservices/rbac/testapp-binding.yaml` — namespace-scoped write access, as
the pattern every application follows:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: oidc-app-testapp-admins
  namespace: testapp
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: edit                     # includes pods/exec, pods/portforward, pods/log
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: oidc:app-testapp-admins
```

Deliberately absent: any binding for `system:authenticated` or
`system:unauthenticated`, and any binding naming a user. `system:masters` cannot
be granted through RBAC at all — `cluster-admin` is its equivalent and is
revocable, which is the point.

## Step 6: kubectl on the host

Install kubelogin pinned and checksum-verified, in the style of the other tool
installs:

```bash
curl -fsSLO "https://github.com/int128/kubelogin/releases/download/${KUBELOGIN_VERSION}/kubelogin_linux_amd64.zip"
curl -fsSL  "https://github.com/int128/kubelogin/releases/download/${KUBELOGIN_VERSION}/kubelogin_linux_amd64.zip.sha256" | sha256sum -c -
unzip -o kubelogin_linux_amd64.zip kubectl-oidc_login -d ~/.local/bin/
```

A second context next to the certificate one, so break-glass stays one
`--context` away:

```bash
kubectl config set-credentials oidc \
  --exec-api-version=client.authentication.k8s.io/v1beta1 \
  --exec-command=kubectl \
  --exec-arg=oidc-login --exec-arg=get-token \
  --exec-arg=--oidc-issuer-url=https://keycloak.kind.local:8443/realms/localdev \
  --exec-arg=--oidc-client-id=kubernetes \
  --exec-arg=--oidc-extra-scope=groups \
  --exec-arg=--oidc-use-pkce \
  --exec-arg=--certificate-authority=/home/leo/dev/kind/pki/out/root-ca.crt
kubectl config set-context dev-oidc --cluster=kind-dev --user=oidc
```

`/etc/hosts` needs `keycloak.kind.local` on the host too — `./hosts.sh` or the
static entry from update-setup-03.

## Step 7: k9s in the container

Three changes in `cli/`:

1. **kubelogin in the image** (`cli/k9s.Dockerfile`), pinned by
   `KUBELOGIN_VERSION` and checksum-verified like kubectl, installed as
   `kubectl-oidc_login` on `PATH`.
2. **A second kubeconfig** `cli/kubeconfig-oidc`, written by `cluster.sh`: the
   internal server URL (`https://dev-control-plane:6443`) with the exec user
   from step 6, but **`--grant-type=authcode-keyboard`** — there is no browser in
   the container, so kubelogin prints a URL, you open it on the host and paste
   the code back. The device-code grant enabled in step 1 is the alternative.
3. **A persistent token cache:** a named volume on `~/.kube/cache/oidc-login`,
   otherwise every container start means a fresh login.

The container also needs the root CA for the `--certificate-authority` flag:
mount `pki/out/root-ca.crt` read-only.

## Step 8: Testing

**8.1 The token itself** — before involving the cluster:

```bash
kubectl oidc-login get-token \
  --oidc-issuer-url=https://keycloak.kind.local:8443/realms/localdev \
  --oidc-client-id=kubernetes --oidc-use-pkce --oidc-extra-scope=groups \
  --certificate-authority=pki/out/root-ca.crt \
  | python3 -c 'import sys,json,base64; t=json.load(sys.stdin)["status"]["token"]; p=t.split(".")[1]; print(json.dumps(json.loads(base64.urlsafe_b64decode(p+"=="*(-len(p)%4))), indent=2))'
```

Expected: `iss` exactly the issuer from the config, `aud` containing
`kubernetes`, `preferred_username`, and a `groups` array with unprefixed names.
A missing `groups` claim means the client scope from step 1 is not attached.

**8.2 Identity as the API server sees it:**

```bash
kubectl --context dev-oidc auth whoami
# Username  oidc:dev
# Groups    [oidc:platform-admins system:authenticated]
```

The `oidc:` prefixes here are the single most important thing to confirm: they
must match the RBAC subjects character for character.

**8.3 Authorization, positive:**

```bash
kubectl --context dev-oidc auth can-i --list | head
kubectl --context dev-oidc get nodes
kubectl --context dev-oidc -n argocd get secrets            # admins only
```

**8.4 Authorization, negative — without a second browser login.** Impersonation
from the admin context tests every group in the model:

```bash
# A read-only user
kubectl auth can-i get pods -A            --as=oidc:someone --as-group=oidc:platform-users   # yes
kubectl auth can-i get nodes              --as=oidc:someone --as-group=oidc:platform-users   # yes (aggregated role)
kubectl auth can-i delete namespace argocd --as=oidc:someone --as-group=oidc:platform-users  # no
kubectl auth can-i get secrets -n argocd  --as=oidc:someone --as-group=oidc:platform-users   # no

# An application owner
kubectl auth can-i create deployment -n testapp --as=oidc:someone --as-group=oidc:app-testapp-admins  # yes
kubectl auth can-i create deployment -n argocd  --as=oidc:someone --as-group=oidc:app-testapp-admins  # no

# Authenticated but in no group: nothing
kubectl auth can-i list pods -A --as=oidc:nobody    # no
```

This is the cheapest way to prove the whole matrix, and it runs from the
certificate context.

**8.5 Break-glass:** with Keycloak stopped
(`docker compose -f identity/compose.yaml stop`), the default context must still
work, and a *new* OIDC login must fail cleanly:

```bash
kubectl get nodes                          # works: client certificate
kubectl --context dev-oidc get nodes       # fails once the cached token expires
```

**8.6 The startup dependency** — the experiment worth doing deliberately:
stop Keycloak, then restart the API server (`docker restart dev-control-plane`)
and watch whether it becomes ready. Record the result in this document, because
it decides whether Keycloak is merely convenient or load-bearing for cluster
startup.

**8.7 Group changes propagate:** move the user out of `platform-admins` in
Keycloak, clear the cache (`rm -rf ~/.kube/cache/oidc-login`), log in again,
and confirm `auth whoami` and `can-i` follow. An existing token keeps its old
groups until it expires — that is OIDC working as designed, and worth seeing.

**8.8 k9s:** start with the OIDC kubeconfig, confirm the keyboard grant, then
port-forward a pod to prove it works with an exec-plugin identity.

**8.9 Audit trail:** `kubectl -n kube-system logs` on the API server shows
`oidc:dev` as the username in authorization denials — real names in the logs
being one of the reasons to do this at all.

## Step 9: Hardening and follow-ups

- **Shorten `cluster-admin`'s reach later:** a custom ClusterRole for daily work
  and `cluster-admin` only for a smaller group.
- **Session lifetimes** in the realm (access token 5 min, SSO idle 30 min by
  default) decide how often you re-authenticate; tune them in `localdev.yaml`.
- **Argo CD's own RBAC stays separate** (`argocd-rbac-cm`); the same Keycloak
  groups drive both, which is the point of one realm.
- **Enable the API server audit log** if you want the identities recorded
  persistently rather than only in denials.

## Step 10: Rollback

1. Remove the `authentication-config` arg and the `extraVolumes`/`extraMounts`
   entries, recreate the cluster (or revert the static pod manifest in the node).
2. `kubectl delete -k platformservices/rbac` — the bindings are inert once no
   OIDC user exists, but removing them keeps the cluster honest.
3. `kubectl config delete-context dev-oidc`.

Nothing here touches the certificate authentication path, so rollback cannot
lock you out.

## Planned ADR (for `architecture.md` once applied)

**ADR-0018: OIDC authentication for the API server, RBAC through group claims.**
Context: everyone who touches the cluster shares kind's `kubernetes-admin`
certificate, so there is no per-person identity, no least privilege and nothing
useful in the logs. Keycloak already exists as the central IdP (ADR-0017).
Decision: add a structured `AuthenticationConfiguration` naming the `localdev`
realm as a JWT issuer, prefix usernames and groups with `oidc:`, and grant all
authorization through group-bound ClusterRoleBindings and RoleBindings, with
kubelogin as the exec credential plugin for kubectl and k9s. The client
certificate stays as break-glass. Consequences: real identities in audit and
`auth whoami`, access granted and revoked in Keycloak rather than with kubectl,
and one login for Argo CD, Harbor and the API server; but the cluster gains a
startup dependency on Keycloak, the configuration requires recreating the
cluster, and tokens carry stale group membership until they expire.

## Open points

- **Unverified: the API version** of `AuthenticationConfiguration` on 1.36
  (`apiserver.config.k8s.io/v1` assumed, `v1beta1` the fallback) and whether
  `certificateAuthority` is inline PEM or a path. Both surface immediately: the
  API server refuses to start and names the problem in
  `docker logs dev-control-plane` / `crictl logs`.
- **Unverified: API server behaviour when the issuer is unreachable at startup**
  (see 8.6).
- **kind's `extraMounts` needs absolute host paths**, so `cluster-config.yaml`
  gains a machine-specific path unless `cluster.sh` renders it.
- **The k9s keyboard grant is untested** in this container setup.
- **`kubectl auth can-i --as`** requires impersonation rights, which the
  certificate context has; it is a test tool, not something to grant to OIDC
  users.
