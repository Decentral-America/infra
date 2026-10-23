# ──────────────────────────────────────────────────────────────────────────────
# OpenTofu test: validates configuration syntax and variable constraints
# Run: tofu test (from terraform/ directory)
# ──────────────────────────────────────────────────────────────────────────────

# No Linode API in CI: mock the provider. Linode ids are numbers and the backend's ipv4 must be
# non-empty (outputs.tf indexes it); the mock's default random strings fail those type checks.
mock_provider "linode" {
  mock_resource "linode_firewall" {
    defaults = { id = "1001" }
  }
  mock_resource "linode_instance" {
    defaults = { id = "1003", ipv4 = ["192.0.2.10"], ipv6 = "2001:db8::10/128" }
  }
  mock_resource "linode_stackscript" {
    defaults = { id = "1002" }
  }
  # The matcher CI runner reads the backend's IP through a data source (matcher-ci-runner.tf).
  mock_data "linode_instances" {
    defaults = { instances = [] }
  }
}

variables {
  state_encryption_passphrase = "test-passphrase-do-not-use-0123456789"
  root_password               = "test-password-do-not-use"
  deploy_ssh_public_key       = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyDoNotUse test@ci"
  postgres_password           = "test-postgres-password"
  DEFAULT_MATCHER             = "3PC9BfRwJWWiw9AREE2B3eWzCks3CYtg4yo"
  blockchain_updates_url      = "grpcs://mainnet-node.decentralchain.io:6881"
  # Required (validation rejects an empty list); test-only documentation CIDR.
  lke_ssh_allowed_ips = ["192.0.2.1/32"]
}

run "validate_configuration" {
  command = plan

  # Expect plan to succeed (no provider API calls needed for validation)
  assert {
    condition     = var.root_password != ""
    error_message = "Configuration should be syntactically valid"
  }
}

run "reject_unencrypted_non_localhost_grpc" {
  command = plan

  variables {
    blockchain_updates_url = "grpc://remote-node.example.com:6881"
  }

  expect_failures = [
    var.blockchain_updates_url,
  ]
}

run "accept_unencrypted_localhost_grpc" {
  command = plan

  variables {
    blockchain_updates_url = "grpc://localhost:6881"
  }

  assert {
    condition     = var.blockchain_updates_url == "grpc://localhost:6881"
    error_message = "Localhost grpc:// should be accepted"
  }
}

# ── matcher CI runner host (matcher-ci-runner.tf, modules/matcher-ci-runner) ──

run "matcher_ci_runner_disabled_by_default" {
  command = plan

  assert {
    condition     = length(module.matcher_ci_runner) == 0
    error_message = "The runner host must be opt-in (matcher_ci_runner_enabled)"
  }
}

run "matcher_ci_runner_enabled" {
  command = plan

  variables {
    matcher_ci_runner_enabled         = true
    matcher_ci_runner_ssh_public_key  = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyDoNotUse ops@test"
    matcher_ci_runner_ssh_allowed_ips = ["192.0.2.1/32"]
  }

  assert {
    condition     = module.matcher_ci_runner[0].ipv4 == "192.0.2.10"
    error_message = "the runner's public IPv4 must come from its ipv4 set"
  }
}

run "matcher_ci_runner_module_firewall_and_host_key" {
  command = apply

  module {
    source = "./modules/matcher-ci-runner"
  }

  variables {
    region               = "us-central"
    ssh_public_key       = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyDoNotUse ops@test"
    ssh_allowed_ipv4     = ["192.0.2.1/32"]
    metrics_allowed_ipv4 = ["192.0.2.10/32"]
  }

  assert {
    condition     = linode_firewall.runner.inbound_policy == "DROP" && linode_firewall.runner.outbound_policy == "DROP"
    error_message = "both firewall policies must be DROP"
  }

  assert {
    condition = toset([for r in linode_firewall.runner.inbound : "${r.protocol}/${r.ports}/${join(",", r.ipv4)}"]) == toset([
      "TCP/22/192.0.2.1/32", "TCP/9100/192.0.2.10/32",
    ])
    error_message = "inbound must be exactly SSH from the operators and node_exporter from the VPS"
  }

  assert {
    condition     = toset([for r in linode_firewall.runner.outbound : "${r.protocol}/${r.ports}"]) == toset(["UDP/53", "TCP/53", "UDP/123", "TCP/80", "TCP/443"])
    error_message = "outbound must be exactly DNS, NTP, HTTP and HTTPS"
  }

  assert {
    condition     = startswith(split(" ", output.known_hosts)[1], "ssh-ed25519") && output.host_key_fingerprint != ""
    error_message = "the host key must be generated here and pinned (ed25519)"
  }

  assert {
    condition     = linode_instance.runner.backups_enabled == false && length(linode_instance.runner.authorized_keys) == 1
    error_message = "the runner is stateless (no backups) and has exactly one admin key"
  }
}

run "matcher_ci_runner_module_no_metrics_ingress_without_vps" {
  command = plan

  module {
    source = "./modules/matcher-ci-runner"
  }

  variables {
    region           = "us-central"
    ssh_public_key   = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyDoNotUse ops@test"
    ssh_allowed_ipv4 = ["192.0.2.1/32"]
  }

  assert {
    condition     = length(linode_firewall.runner.inbound) == 1
    error_message = "without a VPS address only SSH may be open"
  }
}

run "matcher_ci_runner_rejects_open_ssh" {
  command = plan

  module {
    source = "./modules/matcher-ci-runner"
  }

  variables {
    region           = "us-central"
    ssh_public_key   = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyDoNotUse ops@test"
    ssh_allowed_ipv4 = ["0.0.0.0/0"]
  }

  expect_failures = [var.ssh_allowed_ipv4]
}

run "matcher_ci_runner_rejects_shared_cpu" {
  command = plan

  module {
    source = "./modules/matcher-ci-runner"
  }

  variables {
    region           = "us-central"
    type             = "g6-standard-8"
    ssh_public_key   = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyDoNotUse ops@test"
    ssh_allowed_ipv4 = ["192.0.2.1/32"]
  }

  expect_failures = [var.type]
}
