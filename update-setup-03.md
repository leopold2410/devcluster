# Update setup 03: Keycloak as the central identity provider (external), Argo CD and Harbor as clients

| | |
| --- | --- |
| Date | 2026-09-16 |
| Status | **Applied on 2026-09-17.** Keycloak 26.7.3 runs with PostgreSQL on the host, realm `localdev` is applied from code, and Argo CD logs in through it (verified: the server initialises the OIDC provider against the issuer, `/auth/login` redirects to the realm, and an example ID token carries `groups: [platform-admins]`). Harbor's switch is scripted in `registry/oidc-setup.sh` and waits for one root-owned copy of the root CA. See *Implementation notes* |
| Scope | `/home/leo/dev/kind`, builds on [`update-setup-01.md`](update-setup-01.md) and [`update-setup-02.md`](update-setup-02.md) |

## Goals

1. **Keycloak 26.7.3 outside the cluster**, in Docker Compose next to Harbor, as
   a stand-in for a company-wide identity provider: it exists before the cluster,
   survives `cluster/cluster.sh down`, and stays available when the cluster is
   gone.
2. **Argo CD logs in through Keycloak** (OIDC), with group-based permissions
   instead of the shared local admin account.
3. **Harbor logs in through Keycloak** as the second client, which is what makes
   the "central IdP" idea real rather than theoretical.
4. **A realm that further services join later** by adding one client each:
   applications behind Istio, the Kubernetes API, other UIs.

## Why external

An IdP that lives inside the dev cluster disappears with it, and every rebuild
would invalidate what other systems depend on. A company IdP behaves the other
way round: it is there, and everything else registers with it. Consequences of
that choice, both directions:

- **For:** identity survives cluster rebuilds; Harbor (also external) can use it
  without depending on the cluster; the cluster is a *consumer* of identity, as
  in production.
- **Against:** it doesn't practise the in-cluster operator path, and the realm is
  state on the host. The second point is answered by managing the realm
  declaratively (see step 4), so it can be rebuilt from this repository.

## Architecture

```
Host (Docker Compose)                                kind cluster
┌───────────────────────────────┐                    ┌──────────────────────────────┐
│ identity/  keycloak  :8443    │◄───OIDC discovery──│ argocd-server                │
│            postgres           │    + token         │  (CoreDNS: keycloak.kind.local│
│ registry/  harbor    :3443    │◄───OIDC login──────│   -> 172.21.0.1)             │
└───────────────────────────────┘                    └──────────────────────────────┘
         ▲                ▲
         │ browser login  │ browser login
        Developer        Developer
```

- **Ports:** 80 and 443 stay reserved on the host for the cluster ingress, and
  Harbor sits on 3030/3443, so Keycloak listens on **8443**. That port is part of
  the issuer URL and of every redirect URI.
- **Certificates:** a server certificate for `keycloak.kind.local` from the local
  issuing CA, exactly like Harbor's.
- **Name resolution:** `keycloak.kind.local` must resolve on the host (browser,
  `/etc/hosts`) and inside the cluster (Argo CD's discovery, via CoreDNS).

## Versions

Checked on 2026-09-16.

| Component | Version | Notes |
| --- | --- | --- |
| Keycloak | **26.7.3** | `quay.io/keycloak/keycloak:26.7.3` |
| PostgreSQL | **17-alpine** | Keycloak's database, in the same Compose project |
| keycloak-config-cli | **6.5.1-26** | Applies the realm declaratively and **idempotently**, unlike `--import-realm`, which never updates an existing realm |
| Harbor | v2.15.2 (already running) | OIDC client, configured through its API |
| Argo CD | v3.5.3 (already running) | OIDC client, configured through `argocd-cm` |

New entries in `versions.env`:

```bash
# update-setup-03
KEYCLOAK_VERSION=26.7.3
KEYCLOAK_CONFIG_CLI_VERSION=6.5.1-26
```

## Decisions

- **Compose, like Harbor,** in a new folder `identity/`. Same pattern: certificate
  from the local CA, data in a git-ignored `out/`, containers with
  `restart: unless-stopped`.
- **Production mode with a database.** `start --optimized` with PostgreSQL, not
  `start-dev`: hostname, proxy headers and TLS behave like a real deployment, and
  the data is durable.
- **Keycloak terminates TLS itself** (`KC_HTTPS_CERTIFICATE_FILE`), rather than
  putting a second reverse proxy in front. One less moving part, and the
  certificate is the same one clients verify.
- **Realm as code with keycloak-config-cli**, not `--import-realm`. The import
  only ever *creates* a realm; config-cli applies changes to an existing realm,
  so the realm file in git stays the source of truth.
- **One realm `localdev`, not `master`.** It holds every identity in this setup - platform services, applications and workload clients - because a second realm would be a second issuer with its own user store, which ends SSO at the boundary. `master` stays administrative.
- **Client secrets are generated once** into `identity/out/`, and injected into
  the realm file, Argo CD and Harbor from there. They never enter git.
- **Local admin accounts stay** in Argo CD and Harbor as break-glass access, and
  are only disabled at the end, reversibly.

## Step 1: `identity/` — Keycloak and PostgreSQL in Compose

```
identity/
├── compose.yaml            # keycloak + postgres, ports 127.0.0.1:8443
├── setup-host.sh           # certificate, secrets, start, realm apply
├── create-cert.sh          # server certificate for keycloak.kind.local from the local CA
├── realm/
│   └── localdev.yaml       # the realm as code (clients, groups, mappers, users)
└── out/                    # certificate, secrets, database volume (git-ignored)
```

`identity/compose.yaml`:

```yaml
name: identity

services:
  postgres:
    image: postgres:17-alpine
    restart: unless-stopped
    environment:
      POSTGRES_DB: keycloak
      POSTGRES_USER: keycloak
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
    secrets: [db_password]
    volumes:
      - ./out/data/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U keycloak -d keycloak"]
      interval: 10s
      timeout: 5s
      retries: 10

  keycloak:
    image: quay.io/keycloak/keycloak:${KEYCLOAK_VERSION:?set in ../versions.env}
    restart: unless-stopped
    depends_on:
      postgres: { condition: service_healthy }
    command: ["start", "--optimized"]
    environment:
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://postgres:5432/keycloak
      KC_DB_USERNAME: keycloak
      KC_DB_PASSWORD_FILE: /run/secrets/db_password
      KC_BOOTSTRAP_ADMIN_USERNAME: admin
      KC_BOOTSTRAP_ADMIN_PASSWORD_FILE: /run/secrets/admin_password
      KC_HOSTNAME: https://keycloak.kind.local:8443
      KC_HTTPS_CERTIFICATE_FILE: /opt/keycloak/conf/tls/tls.crt
      KC_HTTPS_CERTIFICATE_KEY_FILE: /opt/keycloak/conf/tls/tls.key
      KC_HTTPS_PORT: 8443
      KC_HEALTH_ENABLED: "true"
    secrets: [db_password, admin_password]
    volumes:
      - ./out/tls:/opt/keycloak/conf/tls:ro
    ports:
      - "127.0.0.1:8443:8443"      # host only; the cluster reaches it via the kind bridge
      - "172.21.0.1:8443:8443"

secrets:
  db_password:
    file: ./out/db-password
  admin_password:
    file: ./out/admin-password
```

Two published addresses on purpose: `127.0.0.1` for the browser, and the kind
bridge gateway `172.21.0.1` so pods can reach Keycloak. Check the gateway
address with
`docker network inspect kind -f '{{range .IPAM.Config}}{{.Gateway}} {{end}}'`
and make it a variable if it ever differs.

**`--optimized` requires a build step** (`kc.sh build`) in the image. Two
options, to decide during implementation:
1. drop `--optimized` and let Keycloak build on start (slower start, simplest), or
2. a two-line `identity/Dockerfile` (`FROM quay.io/keycloak/keycloak:26.7.3`,
   `RUN /opt/keycloak/bin/kc.sh build --db=postgres`) and build it in Compose.

Start with option 1, measure the start time, then decide.

## Step 2: Certificate and secrets

`identity/create-cert.sh` mirrors `registry/create-cert.sh`: a server certificate
for `keycloak.kind.local` from `pki/out/issuing-ca.*`, written to
`identity/out/tls/tls.crt` (with the issuing CA appended) and `tls.key`, and
skipped when a valid certificate is already there.

`identity/setup-host.sh` generates what doesn't exist yet:

```bash
mkdir -p out/data/postgres out/tls
[[ -f out/db-password ]]     || openssl rand -base64 24 > out/db-password
[[ -f out/admin-password ]]  || openssl rand -base64 24 > out/admin-password
[[ -f out/argocd-secret ]]   || openssl rand -base64 24 > out/argocd-secret
[[ -f out/harbor-secret ]]   || openssl rand -base64 24 > out/harbor-secret
chmod 600 out/db-password out/admin-password out/argocd-secret out/harbor-secret
./create-cert.sh
docker compose up -d
```

No root anywhere: Compose runs as your user, and the Keycloak image already runs
as a non-root user.

## Step 3: Names

**On the host** (browser and `curl`), one line in `/etc/hosts`:

```
127.0.0.1 keycloak.kind.local
```

**In the cluster**, CoreDNS has to resolve the name to the host. A `hosts` block
in the `coredns` ConfigMap in `kube-system`, inserted before the `kubernetes`
plugin (this cluster runs CoreDNS v1.14.2 with an otherwise untouched Corefile):

```
hosts {
    172.21.0.1 keycloak.kind.local
    fallthrough
}
```

`identity/cluster-dns.sh` applies this idempotently and restarts CoreDNS. It has
to run after every `cluster/cluster.sh up`, like `registry/kind-trust.sh`, so
`deploy.sh` calls it when `identity/out` exists.

## Step 4: The realm as code

`identity/realm/localdev.yaml` is applied by keycloak-config-cli, which supports
variable substitution, so secrets stay out of git:

```yaml
realm: localdev
displayName: kind-dev local development
enabled: true

groups:                    # the names say what the rights are for, not what the realm is
  - name: platform-admins  # admin on the platform services (Argo CD, Harbor)
  - name: platform-users
  # applications add their own as they arrive, e.g. app-<name>-admins

clientScopes:
  - name: groups
    protocol: openid-connect
    attributes:
      include.in.token.scope: "true"
    protocolMappers:
      - name: groups
        protocol: openid-connect
        protocolMapper: oidc-group-membership-mapper
        config:
          claim.name: groups
          full.path: "false"
          id.token.claim: "true"
          access.token.claim: "true"
          userinfo.token.claim: "true"

clients:
  - clientId: argocd
    name: Argo CD
    enabled: true
    publicClient: false
    standardFlowEnabled: true
    secret: $(env ARGOCD_CLIENT_SECRET)
    rootUrl: https://argocd.kind.local
    redirectUris:
      - https://argocd.kind.local/auth/callback
      - http://localhost:8085/auth/callback        # argocd CLI
    webOrigins: [https://argocd.kind.local]
    defaultClientScopes: [openid, profile, email, roles, web-origins, groups]

  - clientId: harbor
    name: Harbor
    enabled: true
    publicClient: false
    standardFlowEnabled: true
    secret: $(env HARBOR_CLIENT_SECRET)
    rootUrl: https://harbor.kind.local:3443
    redirectUris:
      - https://harbor.kind.local:3443/c/oidc/callback  # path confirmed in Harbor's source (common.OIDCCallbackPath)
    webOrigins: [https://harbor.kind.local:3443]
    defaultClientScopes: [openid, profile, email, roles, web-origins, groups]

users:
  - username: dev
    enabled: true
    email: dev@kind.local
    emailVerified: true
    firstName: Dev
    lastName: User
    groups: [platform-admins]
    credentials:
      - type: password
        value: $(env DEV_USER_PASSWORD)
        temporary: true
```

Applied from `identity/setup-host.sh`:

```bash
docker run --rm --network identity_default \
  -e KEYCLOAK_URL=https://keycloak:8443 \
  -e KEYCLOAK_USER=admin \
  -e KEYCLOAK_PASSWORD="$(cat out/admin-password)" \
  -e KEYCLOAK_AVAILABILITYCHECK_ENABLED=true \
  -e KEYCLOAK_SSLVERIFY=false \
  -e IMPORT_FILES_LOCATIONS=/config/*.yaml \
  -e ARGOCD_CLIENT_SECRET="$(cat out/argocd-secret)" \
  -e HARBOR_CLIENT_SECRET="$(cat out/harbor-secret)" \
  -e DEV_USER_PASSWORD="$(cat out/dev-password)" \
  -v "$PWD/realm:/config:ro" \
  adorsys/keycloak-config-cli:${KEYCLOAK_CONFIG_CLI_VERSION}
```

`KEYCLOAK_SSLVERIFY=false` is acceptable only because this call goes to the
container's own hostname inside the Compose network; verify the exact variable
names against the config-cli README during implementation.

## Step 5: Argo CD as an OIDC client

Two patches in `platformservices/argocd/kustomization.yaml`, in the style of the
existing `argocd-cmd-params-cm` patch:

```yaml
- patch: |-
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: argocd-cm
    data:
      url: https://argocd.kind.local
      oidc.config: |
        name: Keycloak
        issuer: https://keycloak.kind.local:8443/realms/localdev
        clientID: argocd
        clientSecret: $oidc.keycloak.clientSecret
        cliClientID: argocd
        requestedScopes: ["openid", "profile", "email", "groups"]
        rootCA: |
          <content of pki/out/root-ca.crt>
- patch: |-
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: argocd-rbac-cm
    data:
      policy.default: role:readonly
      policy.csv: |
        g, platform-admins, role:admin
```

- **`rootCA`** is a documented `oidc.config` field and makes Argo CD trust the
  local CA, instead of `oidc.tls.insecure.skip.verify`.
- **The client secret** goes into `argocd-secret`, from `deploy.sh`:

```bash
kubectl -n argocd patch secret argocd-secret \
  --patch="{\"stringData\": {\"oidc.keycloak.clientSecret\": \"$(cat identity/out/argocd-secret)\"}}"
```

- **The root certificate is public**, so it may live in the manifest; to avoid
  duplicating it, `deploy.sh` can inject it from `pki/out/root-ca.crt`.

## Step 6: Harbor as an OIDC client

Harbor's OIDC settings are configuration, not part of `harbor.yml`. All 15
`oidc_*` fields are editable through the API (verified against the running
instance), so `registry/oidc-setup.sh` can script it:

```bash
curl -u "admin:$HARBOR_ADMIN_PASSWORD" -X PUT \
  --cacert pki/out/root-ca.crt --resolve harbor.kind.local:3443:127.0.0.1 \
  https://harbor.kind.local:3443/api/v2.0/configurations \
  -H 'Content-Type: application/json' -d '{
    "auth_mode": "oidc_auth",
    "oidc_name": "Keycloak",
    "oidc_endpoint": "https://keycloak.kind.local:8443/realms/localdev",
    "oidc_client_id": "harbor",
    "oidc_client_secret": "<identity/out/harbor-secret>",
    "oidc_scope": "openid,profile,email,groups,offline_access",
    "oidc_groups_claim": "groups",
    "oidc_admin_group": "platform-admins",
    "oidc_user_claim": "preferred_username",
    "oidc_auto_onboard": true,
    "oidc_verify_cert": true
  }'
```

Two things have to be true for this to work:

- **`auth_mode` can only be changed while no normal users exist** besides
  `admin`. On a fresh Harbor that's the case; otherwise the switch is rejected.
- **Harbor must trust the local CA**, or `oidc_verify_cert` has to be turned off.
  Harbor mounts `common/config/shared/trust-certificates` into its containers at
  `/harbor_cust_cert` (confirmed in the generated compose file), so the root
  certificate goes there:

```bash
cp pki/out/root-ca.crt registry/out/harbor/common/config/shared/trust-certificates/
docker compose -f registry/out/harbor/docker-compose.yml restart core jobservice
```

Harbor keeps `admin` as a local account, so a failed OIDC setup doesn't lock you
out. Note that Harbor's CLI/registry login for OIDC users uses a **CLI secret**
from the user profile, not the Keycloak password.

## Step 7: Verification

```bash
# Keycloak reachable, issuer correct
curl -s --cacert pki/out/root-ca.crt https://keycloak.kind.local:8443/realms/localdev/.well-known/openid-configuration \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["issuer"]); print(d["authorization_endpoint"])'

# Reachable from inside the cluster (CoreDNS + certificate)
kubectl -n argocd exec deploy/argocd-server -- \
  curl -s https://keycloak.kind.local:8443/realms/localdev | head -c 120

# Argo CD: browser login via Keycloak, then
argocd login argocd.kind.local --sso --grpc-web
argocd account get-user-info          # shows groups: [platform-admins]

# Harbor: browser login via Keycloak; a user in platform-admins is an administrator
curl -s -u "admin:$PW" --cacert pki/out/root-ca.crt --resolve harbor.kind.local:3443:127.0.0.1 \
  https://harbor.kind.local:3443/api/v2.0/configurations | grep -o '"auth_mode":{[^}]*}'
```

Expected: the issuer is `https://keycloak.kind.local:8443/realms/localdev` in
both directions, the Argo CD user `dev` is admin through `platform-admins` while
users without the group are read-only, and Harbor accepts the same login.

## Step 8: Hardening and documentation

- **Change the Keycloak admin password** (`identity/out/admin-password`) and keep
  it in your password manager.
- **Disable Argo CD's local admin** (`admin.enabled: "false"` in `argocd-cm`)
  once login works; reversible.
- **README:** an *Identity* section — what the realm contains, how to log in, how
  to add a client.
- **architecture.md:** Keycloak as a container in the host boundary, relations
  "developer → Keycloak", "Argo CD → Keycloak", "Harbor → Keycloak", plus the ADR
  below.

## Planned ADR (for `architecture.md` once applied)

**ADR-0017: Keycloak outside the cluster as the central identity provider.**
Context: every platform service brought its own login (Argo CD admin, Harbor
admin), which doesn't scale and doesn't resemble production. An IdP inside the
dev cluster would disappear with the cluster, while everything else depends on
it. Decision: Keycloak in Docker Compose on the host, with a single realm
`localdev` as code - named after the environment, because it holds application
and workload identities as well as the platform ones. Argo CD and Harbor are the
first OIDC clients, and permissions come from the group `platform-admins`.
Consequences: one login for the platform, identity survives
cluster rebuilds, and new services are one client each; but Keycloak becomes a
critical dependency (hence local break-glass accounts), it occupies port 8443
because 80/443 are reserved for the cluster ingress and Harbor sits on 3030/3443,
and that port is part of the issuer URL. The in-cluster operator path is not
practised.

## Later integrations

| Service | How | Note |
| --- | --- | --- |
| **Applications behind Istio** | `RequestAuthentication` + `AuthorizationPolicy` with the realm's JWKS | Authentication at the gateway, application untouched |
| **Applications behind the vanilla Ingress** | oauth2-proxy in front of the app | cloud-provider-kind has no auth of its own |
| **Kubernetes API** | `oidc-issuer-url` and friends as `kubeadmConfigPatches` | Requires recreating the cluster; kubectl then logs in through Keycloak |
| **Other UIs** (Grafana, …) | Standard OIDC clients in the realm file | Same pattern as Argo CD |

## Implementation notes

The files in `identity/` are authoritative; they differ from the drafts above in
these points, all found while applying:

- **`$(env:NAME)`, not `$(env NAME)`.** keycloak-config-cli resolves variables
  through a lookup prefix, so the colon is required. The first run failed with
  `Cannot resolve variable 'env VAR'` — and the variable it could not resolve
  came from the *comment* in the realm file, which substitution reads as well.
  Substitution also needs `IMPORT_VARSUBSTITUTION_ENABLED=true`.
- **`start`, not `start --optimized`.** The stock image has no `kc.sh build`
  baked in, so the build happens at startup. Option 1 of step 1, as planned.
- **Secrets reach Compose through a generated `identity/.env`** (mode 600,
  git-ignored) rather than Docker secrets and `_FILE` variables, so
  `docker compose ps|logs|stop` work without the script and no `_FILE` support
  has to be assumed.
- **Keycloak is published on two addresses:** `127.0.0.1:8443` for the browser
  and `172.21.0.1:8443` for the pods, instead of one host-wide binding.
- **`KEYCLOAK_SSLVERIFY=false` for the config-cli call only.** It talks to the
  container's own name inside the Compose network, which the certificate
  (`keycloak.kind.local`) does not cover.
- **Argo CD's `oidc.config` is patched by `platformservices/deploy.sh`,** not
  rendered by Kustomize: it carries the root CA and the client secret, which live
  outside git. Kustomize keeps the static half (`argocd-rbac-cm`). The block is
  skipped when `identity/out/` is absent, so the cluster still deploys without
  Keycloak.
- **`identity/cluster-dns.sh` edits the CoreDNS Corefile** and inserts a `hosts`
  block before the `kubernetes` plugin, then restarts CoreDNS.
- **`./hosts.sh` adds the host entry**, instead of the manual line the plan asked
  for. It emits `keycloak.kind.local` into its managed block as soon as
  `identity/out/` exists, so the browser side needs no separate step. The block
  markers stayed as they were, so existing blocks are still recognised and
  replaced.
- **That entry points at the kind bridge gateway, not at `127.0.0.1`.** Docker's
  embedded DNS forwards to the host resolver, which reads `/etc/hosts`, so the
  line leaks into every container — and a container's loopback is not the host's.
  With `127.0.0.1` there, Harbor's core failed with
  `dial tcp 127.0.0.1:8443: connect: connection refused` while fetching the
  discovery document. Keycloak publishes on `127.0.0.1:8443` and on
  `172.21.0.1:8443`, so the gateway address serves the browser, Harbor and the
  pods alike. Argo CD never saw the problem because it resolves through CoreDNS.
- **Restart Harbor's `proxy` along with `core` and `jobservice`.** nginx resolves
  its upstreams once at startup, so restarting only the two left it pointing at
  their previous container addresses; every API call then landed on the wrong
  service and returned
  `401 'Authorization' should start with 'Harbor-Secret'`. Note the service is
  `proxy` while the container is named `nginx`.
- **`registry/oidc-setup.sh` waits for Harbor** after such a restart: nginx
  answers 502 until core is serving, which otherwise breaks the first API call.
- **Harbor's trust step needs sudo.** `./prepare` creates
  `common/config/shared/trust-certificates/` as root, so copying the root CA in
  is the one privileged action; `registry/oidc-setup.sh` refuses with the exact
  two commands rather than doing it silently.
- **Getting an admin token with curl needs `--data-urlencode`.** The generated
  passwords contain `+`, which is a space in form encoding — the cause of a
  confusing `invalid_grant` while verifying.
- **The realm is `localdev`,** renamed before implementation because it holds
  application and workload identities too, not only the platform ones.

Verification evidence (2026-09-17):

```
argocd-server: Initializing OIDC provider (issuer: https://keycloak.kind.local:8443/realms/localdev)
GET /auth/login -> 303 https://keycloak.kind.local:8443/realms/localdev/protocol/openid-connect/auth
                   ?client_id=argocd&redirect_uri=https%3A%2F%2Fargocd.kind.local%2Fauth%2Fcallback
                   &response_type=code&scope=openid+profile+email+groups
example id token: {'iss': '.../realms/localdev', 'aud': 'argocd',
                   'preferred_username': 'dev', 'groups': ['platform-admins']}
in-cluster: keycloak.kind.local -> 172.21.0.1, port 8443 reachable from a pod
```

## Known limitations and open points

- **Port 8443 leaks into every URL** (issuer, redirect URIs), as 3443 does for
  Harbor, because 80/443 are kept free for the cluster ingress. Alternatives:
  give Keycloak its own host address, or put one reverse proxy in front of both.
- **CoreDNS entry is cluster-local state** and has to be re-applied after every
  `cluster.sh up`.
- **`--optimized` needs a build step**; see step 1.
- **keycloak-config-cli variable syntax and variable names are unverified** in
  this setup; they are documented in its README and should be checked when
  implementing.
- **Harbor's `auth_mode` switch only works while no other local users exist.**
- **Harbor's OIDC users need a CLI secret** for `docker login`, not their
  Keycloak password.
- **Keycloak plus PostgreSQL cost roughly 700 MB RAM.** With Harbor and the
  cluster running, that's tight on this host; both Compose projects can be
  stopped when unused.
- **Untested, like every plan here:** everything is checked against upstream
  documentation, Harbor's source and the running setup, but not yet executed.
