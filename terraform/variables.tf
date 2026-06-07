variable "linode_region" {
  description = "Linode region slug"
  type        = string
  default     = "us-central" # Dallas — change to preferred region
}

variable "linode_type" {
  description = "Linode instance plan"
  type        = string
  default     = "g6-standard-8" # 8 vCPU / 16 GB RAM — minimum for node-scala (10g) + matcher (4g)
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

variable "postgres_host" {
  description = "PostgreSQL hostname. Default localhost (co-located). Override for managed/remote databases."
  type        = string
  default     = "localhost"
}

variable "postgres_port" {
  description = "PostgreSQL port. Default 5432 (standard). Override for non-standard configurations."
  type        = string
  default     = "5432"
}

variable "postgres_user" {
  description = "PostgreSQL role name. Default dcc. Override for managed databases with different role naming."
  type        = string
  default     = "dcc"
}

variable "postgres_database" {
  description = "PostgreSQL database name. Default dcc_<network>. Override for managed databases."
  type        = string
  default     = ""
}

variable "state_encryption_passphrase" {
  description = "Passphrase for OpenTofu state file AES-GCM encryption on R2. Passed as TF_VAR_state_encryption_passphrase."
  type        = string
  sensitive   = true
}

variable "postgres_password" {
  description = "DEPRECATED: no longer passed via StackScript UDF. Kept to avoid breaking existing state. Will be removed in a future cleanup."
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
  description = "DCC node Blockchain Updates gRPC endpoint URL for blockchain-postgres-sync (e.g. grpc://mainnet-node.decentralchain.io:6881). Use grpc:// for localhost connections only."
  type        = string
  validation {
    condition     = can(regex("^grpcs?://[^:]+:6881$", var.blockchain_updates_url))
    error_message = "blockchain_updates_url must use grpc:// or grpcs:// scheme and port 6881 (BlockchainUpdates). Got: ${var.blockchain_updates_url}"
  }
  validation {
    # Enforce grpcs:// for non-localhost connections (Audit P6 HIGH-5).
    # Unencrypted grpc:// is only safe for localhost/127.0.0.1 connections.
    condition = (
      startswith(var.blockchain_updates_url, "grpcs://") ||
      can(regex("^grpc://(localhost|127\\.0\\.0\\.1):6881$", var.blockchain_updates_url))
    )
    error_message = "Non-localhost blockchain_updates_url must use grpcs:// (encrypted). Unencrypted grpc:// is only permitted for localhost/127.0.0.1."
  }
}

variable "matcher_account_password" {
  description = "DEPRECATED: no longer passed via StackScript UDF. Injected via SOPS SSH push. Kept to avoid breaking existing state."
  type        = string
  sensitive   = true
  default     = ""
}

variable "matcher_api_key_hash" {
  description = "DEPRECATED: no longer passed via StackScript UDF. Injected via SOPS SSH push. Kept to avoid breaking existing state."
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

# ── PostgreSQL off-site backup (Linode Object Storage or S3-compatible) ───────
# rclone copies completed pg_dump archives to object storage after each backup.
# Leave all four variables empty to disable off-site backup (local rotation only).

variable "backup_obj_access_key" {
  description = "DEPRECATED: no longer passed via StackScript UDF. Injected via SOPS SSH push. Kept to avoid breaking existing state."
  type        = string
  sensitive   = true
  default     = ""
}

variable "backup_obj_secret_key" {
  description = "DEPRECATED: no longer passed via StackScript UDF. Injected via SOPS SSH push. Kept to avoid breaking existing state."
  type        = string
  sensitive   = true
  default     = ""
}

variable "backup_obj_bucket" {
  description = "Object storage bucket name for pg_dump off-site upload (e.g. dcc-backups-mainnet). Leave empty to disable off-site backup."
  type        = string
  default     = ""
}

variable "backup_obj_endpoint" {
  description = "Object storage endpoint URL for rclone S3 provider (e.g. us-east-1.linodeobjects.com for Linode Object Storage). Leave empty to disable off-site backup."
  type        = string
  default     = ""
}

# ── Node wallet ──────────────────────────────────────────────────────────────
# The node-scala entrypoint injects these into a temp config file (chmod 600)
# and unsets the env vars immediately after reading them.

variable "node_wallet_seed" {
  description = "DEPRECATED: no longer passed via StackScript UDF. Injected via SOPS SSH push. Kept to avoid breaking existing state."
  type        = string
  sensitive   = true
  default     = ""
}

variable "node_wallet_password" {
  description = "DEPRECATED: no longer passed via StackScript UDF. Injected via SOPS SSH push. Kept to avoid breaking existing state."
  type        = string
  sensitive   = true
  default     = ""
}
