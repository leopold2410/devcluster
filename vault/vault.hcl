# HashiCorp Vault for the dev cluster (update-setup-06, ADR-0023).
# File storage: one node, no high availability, nothing to cluster.
storage "file" {
  path = "/vault/file"
}

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/vault/tls/tls.crt"   # server certificate + issuing CA
  tls_key_file  = "/vault/tls/tls.key"
}

api_addr      = "https://vault.kind.local:8200"
ui            = true
disable_mlock = true                     # single-user dev host; runs without IPC_LOCK
