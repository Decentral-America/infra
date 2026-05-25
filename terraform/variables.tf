variable "linode_region" {
  description = "Linode region slug"
  type        = string
  default     = "us-central"  # Dallas — change to preferred region
}

variable "linode_type" {
  description = "Linode instance plan"
  type        = string
  default     = "g6-standard-2"  # 2 vCPU / 4 GB RAM
}

variable "root_password" {
  description = "Root password for the Linode instance (use a strong random value)"
  type        = string
  sensitive   = true
}

variable "deploy_ssh_public_key" {
  description = "Ed25519 public key for the deploy user (corresponds to DEPLOY_SSH_KEY secret)"
  type        = string
}

variable "postgres_password" {
  description = "PostgreSQL password written to /opt/dcc/secrets/<network>.env on the server"
  type        = string
  sensitive   = true
}

variable "default_matcher" {
  description = "DCC blockchain address of the matcher (data-service config, per network)"
  type        = string
}

variable "rate_pair_acceptance_volume_threshold" {
  description = "Minimum trade volume for rate pair acceptance in data-service"
  type        = string
  default     = "0"
}

variable "rate_threshold_asset_id" {
  description = "Asset ID used as the rate calculation threshold in data-service"
  type        = string
  default     = "DCC"
}

variable "blockchain_updates_url" {
  description = "DCC node Blockchain Updates gRPC endpoint URL for blockchain-postgres-sync (e.g. grpc://mainnet-node.decentralchain.io:6881)"
  type        = string
  validation {
    condition     = can(regex("^grpcs?://[^:]+:6881$", var.blockchain_updates_url))
    error_message = "blockchain_updates_url must use grpc:// or grpcs:// scheme and port 6881 (BlockchainUpdates). Got: ${var.blockchain_updates_url}"
  }
}

variable "matcher_account_password" {
  description = "DEX Matcher account.dat encryption password (used to decrypt the matcher wallet on startup)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "matcher_api_key_hash" {
  description = "DEX Matcher API key hash (Base58-encoded SHA256 of the API key) for authenticated REST endpoints"
  type        = string
  sensitive   = true
  default     = ""
}

variable "scanner_domain" {
  description = "Public domain for the scanner/block-explorer, proxied by Caddy with automatic TLS (e.g. explorer.decentralchain.io). Leave empty to skip Caddy config for scanner."
  type        = string
  default     = ""
}

variable "data_service_domain" {
  description = "Public domain for the data-service REST API, proxied by Caddy with automatic TLS (e.g. data-service.decentralchain.io). Leave empty to skip Caddy config for data-service."
  type        = string
  default     = ""
}

variable "acme_email" {
  description = "Email address for Let's Encrypt ACME cert expiry notifications (optional). If empty, certificates are requested anonymously."
  type        = string
  default     = ""
}
