# ──────────────────────────────────────────────────────────────────────────────
# OpenTofu test: validates configuration syntax and variable constraints
# Run: tofu test (from terraform/ directory)
# ──────────────────────────────────────────────────────────────────────────────

variables {
  root_password          = "test-password-do-not-use"
  deploy_ssh_public_key  = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyDoNotUse test@ci"
  postgres_password      = "test-postgres-password"
  DEFAULT_MATCHER        = "3PC9BfRwJWWiw9AREE2B3eWzCks3CYtg4yo"
  blockchain_updates_url = "grpcs://mainnet-node.decentralchain.io:6881"
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
