# Vault's configuration as code (update-setup-06).
# Token and CA come from VAULT_TOKEN and VAULT_CACERT, set by vault/tf.sh.
provider "vault" {
  address = var.vault_addr
}

# --- KV v2 ------------------------------------------------------------------------
resource "vault_mount" "secret" {
  path        = "secret"
  type        = "kv"
  options     = { version = "2" }
  description = "Application secrets for the dev cluster"
}

# --- Policies ---------------------------------------------------------------------
resource "vault_policy" "admin" {
  name   = "admin"
  policy = <<-EOT
    path "*" {
      capabilities = ["create", "read", "update", "patch", "delete", "list", "sudo"]
    }
  EOT
}

# What the cluster's ExternalSecrets may read: secrets, and their metadata for listing.
resource "vault_policy" "eso_read" {
  name   = "eso-read"
  policy = <<-EOT
    path "${vault_mount.secret.path}/data/*" {
      capabilities = ["read"]
    }
    path "${vault_mount.secret.path}/metadata/*" {
      capabilities = ["read", "list"]
    }
  EOT
}

# --- People: OIDC login with Keycloak ------------------------------------------------
resource "vault_jwt_auth_backend" "oidc" {
  path                  = "oidc"
  type                  = "oidc"
  description           = "Keycloak, realm localdev"
  oidc_discovery_url    = var.keycloak_issuer
  oidc_discovery_ca_pem = var.root_ca_pem # Keycloak's certificate comes from the local CA
  oidc_client_id        = "vault"
  oidc_client_secret    = var.oidc_client_secret
  default_role          = "default"
}

resource "vault_jwt_auth_backend_role" "default" {
  backend         = vault_jwt_auth_backend.oidc.path
  role_name       = "default"
  role_type       = "oidc"
  user_claim      = "preferred_username"
  groups_claim    = "groups"
  oidc_scopes     = ["profile", "email", "groups"]
  bound_audiences = ["vault"]
  allowed_redirect_uris = [
    "https://vault.kind.local:8200/ui/vault/auth/oidc/oidc/callback",
    "http://localhost:8250/oidc/callback",
  ]
  token_policies = ["default"]
  token_ttl      = 3600 * 8
}

# Keycloak group platform-admins -> Vault policy admin. An external group gets its
# members from the groups claim at every login, through the alias.
resource "vault_identity_group" "platform_admins" {
  name     = "platform-admins"
  type     = "external"
  policies = [vault_policy.admin.name]
}

resource "vault_identity_group_alias" "platform_admins" {
  name           = "platform-admins" # the value in the groups claim
  mount_accessor = vault_jwt_auth_backend.oidc.accessor
  canonical_id   = vault_identity_group.platform_admins.id
}

# --- The cluster: Kubernetes auth ------------------------------------------------------
resource "vault_auth_backend" "kubernetes" {
  type        = "kubernetes"
  path        = "kubernetes"
  description = "The kind cluster dev"
}

resource "vault_kubernetes_auth_backend_config" "kind" {
  backend              = vault_auth_backend.kubernetes.path
  kubernetes_host      = var.kubernetes_host # dev-control-plane:6443, on the kind network
  kubernetes_ca_cert   = var.kubernetes_ca_pem
  disable_local_ca_jwt = true # Vault is not a pod
  # No token_reviewer_jwt: Vault reviews each login with the client's own JWT, which is why
  # that service account is bound to system:auth-delegator (ADR-0024).
}

resource "vault_kubernetes_auth_backend_role" "external_secrets" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "external-secrets"
  bound_service_account_names      = ["vault-auth"]
  bound_service_account_namespaces = ["external-secrets"]
  token_policies                   = [vault_policy.eso_read.name]
  token_ttl                        = 3600
  # No audience: the same JWT authenticates the TokenReview call, so it must keep the API
  # server's default audience.
}

# --- The test secret -----------------------------------------------------------------------
# Seeded by Terraform; its value is Vault's business afterwards, so a change made in Vault
# (the rotation test) is not reverted by the next apply.
resource "vault_kv_secret_v2" "hello" {
  mount = vault_mount.secret.path
  name  = "demo/hello"
  data_json = jsonencode({
    greeting = "hello from vault"
  })
  lifecycle {
    ignore_changes = [data_json]
  }
}
