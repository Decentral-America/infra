variable "linode_region" {
  description = "Linode region slug"
  type        = string
  default     = "us-central" # Dallas
}

variable "linode_type" {
  description = "Linode instance plan (g6-standard-4 = 4 vCPU / 8 GB for testnet)"
  type        = string
  default     = "g6-standard-4"
}

variable "state_encryption_passphrase" {
  description = "Passphrase for OpenTofu state file AES-256-GCM encryption on R2. Passed as TF_VAR_state_encryption_passphrase."
  type        = string
  sensitive   = true
}

variable "root_password" {
  description = "Root password for the Linode instance. Required by Linode API at instance creation time."
  type        = string
  sensitive   = true
}

variable "deploy_ssh_public_key" {
  description = "Ed25519 public key for the deploy user. Injected into authorized_keys via StackScript UDF."
  type        = string
}

# ── PostgreSQL (co-located, same server) ─────────────────────────────────────

variable "postgres_host" {
  description = "PostgreSQL hostname. Default localhost for co-located deployments."
  type        = string
  default     = "localhost"
}

variable "postgres_port" {
  description = "PostgreSQL port."
  type        = string
  default     = "5432"
}

variable "postgres_user" {
  description = "PostgreSQL role name for the application."
  type        = string
  default     = "dcc"
}

variable "postgres_database" {
  description = "PostgreSQL database name. Defaults to dcc_<network> (derived from workspace)."
  type        = string
  default     = ""
}

# ── Matcher ───────────────────────────────────────────────────────────────────

variable "DEFAULT_MATCHER" {
  description = "DCC blockchain address of the DEX matcher (used by data-service to validate order settlement)."
  type        = string
}

# ── Runtime config ────────────────────────────────────────────────────────────

variable "rate_pair_acceptance_volume_threshold" {
  description = "Minimum trade volume for rate pair acceptance in data-service."
  type        = string
  default     = "0"
}

variable "rate_threshold_asset_id" {
  description = "Asset ID used as the rate calculation threshold in data-service."
  type        = string
  default     = "DCC"
}

variable "blockchain_updates_url" {
  description = "DCC node Blockchain Updates gRPC endpoint for blockchain-postgres-sync. Use grpc:// for localhost only."
  type        = string
  validation {
    condition     = can(regex("^grpcs?://[^:]+:6881$", var.blockchain_updates_url))
    error_message = "blockchain_updates_url must use grpc:// or grpcs:// scheme on port 6881."
  }
  validation {
    condition = (
      startswith(var.blockchain_updates_url, "grpcs://") ||
      can(regex("^grpc://(localhost|127\\.0\\.0\\.1):6881$", var.blockchain_updates_url))
    )
    error_message = "Non-localhost blockchain_updates_url must use grpcs:// (encrypted)."
  }
}

# ── Caddy TLS ─────────────────────────────────────────────────────────────────

variable "scanner_domain" {
  description = "Public domain for the scanner, proxied by Caddy with automatic TLS. Leave empty to skip."
  type        = string
  default     = ""
}

variable "data_service_domain" {
  description = "Public domain for the data-service API, proxied by Caddy with automatic TLS. Leave empty to skip."
  type        = string
  default     = ""
}

variable "acme_email" {
  description = "Email for Let's Encrypt ACME cert expiry notifications. Optional."
  type        = string
  default     = ""
}

# ── Off-site backup (non-sensitive — credentials injected via SOPS SSH push) ──

variable "backup_obj_bucket" {
  description = "Object storage bucket name for pg_dump off-site upload. Leave empty to disable."
  type        = string
  default     = ""
}

variable "backup_obj_endpoint" {
  description = "Object storage endpoint URL for rclone S3 provider. Leave empty to disable."
  type        = string
  default     = ""
}

# ── LKE peer-node cluster ─────────────────────────────────────────────────────

variable "lke_enabled" {
  description = "Whether to provision the LKE peer-node cluster. Set true in testnet/mainnet.tfvars."
  type        = bool
  default     = false
}

variable "lke_region" {
  description = "Linode region for the LKE cluster (may differ from backend region)."
  type        = string
  default     = "eu-central" # Frankfurt
}

variable "lke_k8s_version" {
  description = "Kubernetes version for LKE. Must be a version supported by Linode at apply time."
  type        = string
  default     = "1.35"
}

variable "lke_node_type" {
  description = "Linode plan for LKE worker nodes. Shared CPU for testnet, dedicated for mainnet generators."
  type        = string
  default     = "g6-standard-2" # 2 vCPU / 4 GB shared — testnet default
}

variable "lke_node_count" {
  description = "Number of worker nodes in the LKE pool."
  type        = number
  default     = 1
}

variable "lke_ha" {
  description = "Enable LKE HA control plane (3-replica etcd). IRREVERSIBLE — must be set at cluster creation. Required for mainnet."
  type        = bool
  default     = false
}

variable "lke_ssh_allowed_ips" {
  description = "IPv4 CIDRs allowed to SSH into LKE worker nodes. Must not be 0.0.0.0/0 in production."
  type        = list(string)
  default     = []
  validation {
    condition     = length(var.lke_ssh_allowed_ips) > 0
    error_message = "lke_ssh_allowed_ips must contain at least one CIDR. Never use 0.0.0.0/0."
  }
}
