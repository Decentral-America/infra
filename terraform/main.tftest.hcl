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
