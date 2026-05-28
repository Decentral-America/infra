variable "linode_region" {
  description = "Linode region slug"
  type        = string
  default     = "us-central"  # Dallas — change to preferred region
}

variable "linode_type" {
  description = "Linode instance plan"
  type        = string
  default     = "g6-standard-8"  # 8 vCPU / 16 GB RAM — minimum for node-scala (10g) + matcher (4g)
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

# ── PostgreSQL off-site backup (Linode Object Storage or S3-compatible) ───────
# rclone copies completed pg_dump archives to object storage after each backup.
# Leave all four variables empty to disable off-site backup (local rotation only).

variable "backup_obj_access_key" {
  description = "Object storage access key for pg_dump off-site upload (rclone S3/Linode provider). Leave empty to disable off-site backup."
  type        = string
  sensitive   = true
  default     = ""
}

variable "backup_obj_secret_key" {
  description = "Object storage secret key for pg_dump off-site upload (rclone S3/Linode provider). Leave empty to disable off-site backup."
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
