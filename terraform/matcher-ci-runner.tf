# ──────────────────────────────────────────────────────────────────────────────
# matcher CI runner host (modules/matcher-ci-runner, runbooks/matcher-ci-runner.md)
#
# One dedicated Linode next to the testnet VPS (same region) running ephemeral,
# repository-level GitHub Actions runners for the PRIVATE matcher repository
# only. Enabled in testnet.tfvars; the testnet workspace owns it so that
# drift-detect.yml covers it like every other resource.
#
# The VPS Prometheus scrapes its node_exporter (job matcher-ci-runner): the
# runner firewall admits :9100 from the VPS public IPv4 only, and the VPS gets a
# matching egress rule (main.tf allow-matcher-ci-metrics-out).
#
# The backend IP comes from a DATA source on purpose: the backend firewall's
# egress rule needs the runner's IP, so reading linode_instance.backend here
# would close a dependency cycle (backend -> its firewall -> runner -> runner
# firewall -> backend).
# ──────────────────────────────────────────────────────────────────────────────

data "linode_instances" "backend_for_ci" {
  count = var.matcher_ci_runner_enabled ? 1 : 0

  filter {
    name   = "label"
    values = ["dcc-backend-${local.network}"]
  }
}

locals {
  backend_public_ipv4_for_ci = var.matcher_ci_runner_enabled ? flatten([
    for inst in data.linode_instances.backend_for_ci[0].instances : [
      for ip in inst.ipv4 : "${ip}/32" if !cidrcontains(local.linode_private_ipv4_range, ip)
    ]
  ]) : []
}

module "matcher_ci_runner" {
  source = "./modules/matcher-ci-runner"
  count  = var.matcher_ci_runner_enabled ? 1 : 0

  region               = local.region
  type                 = var.matcher_ci_runner_type
  slots                = var.matcher_ci_runner_slots
  slot_memory          = var.matcher_ci_runner_slot_memory
  ssh_public_key       = var.matcher_ci_runner_ssh_public_key
  ssh_allowed_ipv4     = var.matcher_ci_runner_ssh_allowed_ips
  metrics_allowed_ipv4 = local.backend_public_ipv4_for_ci
  tags                 = concat(local.tags, ["ci"])
}
