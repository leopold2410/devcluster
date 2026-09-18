terraform {
  required_version = "~> 1.16"
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "5.12.0"
    }
  }
  # Local state, next to this file (update-setup-06). It contains secrets - the Keycloak client
  # secret and the test secret's value - and is git-ignored.
}
