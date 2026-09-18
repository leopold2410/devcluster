# Values vault/tf.sh passes as TF_VAR_* from identity/out, pki/out and vault/out.

variable "vault_addr" {
  type    = string
  default = "https://vault.kind.local:8200"
}

variable "keycloak_issuer" {
  type    = string
  default = "https://keycloak.kind.local:8443/realms/localdev"
}

variable "oidc_client_secret" {
  description = "Secret of Keycloak client \"vault\" (identity/out/vault-client-secret)"
  type        = string
  sensitive   = true
}

variable "root_ca_pem" {
  description = "Local root CA (pki/out/root-ca.crt); Keycloak's certificate chains to it"
  type        = string
}

variable "kubernetes_host" {
  description = "The API server, as Vault reaches it on the kind network"
  type        = string
  default     = "https://dev-control-plane:6443"
}

variable "kubernetes_ca_pem" {
  description = "The cluster's CA (vault/out/k8s-ca.crt); changes with every new cluster"
  type        = string
}
