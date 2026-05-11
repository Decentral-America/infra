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
