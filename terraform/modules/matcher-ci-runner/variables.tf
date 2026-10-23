variable "label" {
  description = "Linode label of the runner host. deploy-monitoring-stack.yml resolves the Prometheus target by this label."
  type        = string
  default     = "dcc-matcher-ci-runner"
}

variable "region" {
  description = "Linode region. Same region as the backend VPS (us-central, Dallas)."
  type        = string
}

variable "type" {
  description = "Linode plan. Sized from measured dex-it shard usage, see runbooks/matcher-ci-runner.md."
  type        = string
  default     = "g6-dedicated-8"

  validation {
    condition     = can(regex("^g[0-9]+-dedicated-", var.type))
    error_message = "The matcher CI runner must be a dedicated-CPU plan (g6-dedicated-*, g7-dedicated-*, ...): shared CPU caused the dex-it starvation it replaces."
  }
}

variable "image" {
  description = "Base image. Ubuntu 24.04 (kernel 6.8): supported by sysbox 0.7.1 and the same kernel line as GitHub's ubuntu-24.04 runners."
  type        = string
  default     = "linode/ubuntu24.04"
}

variable "slots" {
  description = "Ephemeral runners kept ready at all times (one fresh sysbox container per job)."
  type        = number
  default     = 2

  validation {
    condition     = var.slots >= 1 && var.slots <= 4
    error_message = "slots must be between 1 and 4."
  }
}

variable "slot_memory" {
  description = "Hard memory limit of one runner container (docker --memory, equal --memory-swap)."
  type        = string
  default     = "7g"

  validation {
    condition     = can(regex("^[0-9]+g$", var.slot_memory))
    error_message = "slot_memory must be whole gigabytes, e.g. 7g."
  }
}

variable "github_repository" {
  description = "The ONLY repository the runners register to (repository-level runners). Must be private."
  type        = string
  default     = "Decentral-America/matcher"
}

variable "runner_label" {
  description = "Custom runner label. Only matcher workflows may use it; infra's self-hosted-runner-guard.yml rejects it in public repositories."
  type        = string
  default     = "matcher-ci"
}

variable "ssh_public_key" {
  description = "Public key of the `ops` admin user (the only SSH login). The private key is in secrets/matcher-ci-runner.env (SOPS)."
  type        = string

  validation {
    condition     = can(regex("^ssh-ed25519 ", var.ssh_public_key))
    error_message = "ssh_public_key must be an ssh-ed25519 public key."
  }
}

variable "ssh_allowed_ipv4" {
  description = "IPv4 CIDRs allowed to reach SSH (cloud firewall and host nftables)."
  type        = list(string)

  validation {
    condition     = length(var.ssh_allowed_ipv4) > 0 && alltrue([for c in var.ssh_allowed_ipv4 : can(cidrhost(c, 0)) && c != "0.0.0.0/0"])
    error_message = "ssh_allowed_ipv4 must be a non-empty list of CIDRs and must not be 0.0.0.0/0."
  }
}

variable "metrics_allowed_ipv4" {
  description = "IPv4 CIDRs allowed to scrape node_exporter on :9100 (the backend VPS Prometheus). Empty: no metrics ingress."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Linode tags."
  type        = list(string)
  default     = []
}
