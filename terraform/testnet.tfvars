# ──────────────────────────────────────────────────────────────────────────────
# DCC Testnet — non-sensitive OpenTofu defaults
#
# Committed to the repo. Contains NO secrets.
# Sensitive values (root_password, postgres_password, node_wallet_seed,
# node_wallet_password, matcher_account_password, matcher_api_key_hash,
# deploy_ssh_public_key, default_matcher) are stored as TF_VAR_* secrets
# on the infra-testnet-provision GitHub environment and injected by provision.yml.
#
# provision.yml passes -var-file=testnet.tfvars explicitly for the testnet workspace.
# This file is NOT auto-loaded — it is only used when network=testnet.
# ──────────────────────────────────────────────────────────────────────────────

# ── Infrastructure ───────────────────────────────────────────────────────────
linode_region = "us-central"    # Dallas
linode_type   = "g6-standard-4" # 4 vCPU / 8 GB — sufficient for testnet full stack

# ── PostgreSQL (co-located defaults) ─────────────────────────────────────────
# postgres_host     = "localhost"       # default
# postgres_port     = "5432"            # default
# postgres_user     = "dcc"             # default
# postgres_database = "dcc_testnet"     # default (auto from workspace name)

# ── Blockchain updates gRPC (co-located node) ─────────────────────────────────
blockchain_updates_url = "grpc://localhost:6881"

# ── TLS / Caddy ──────────────────────────────────────────────────────────────
scanner_domain      = "testnet.decentralscan.com"
data_service_domain = "testnet-data-service.decentralchain.io"
acme_email          = "ops@decentralamerica.com"

# ── Off-site backup: disabled for testnet ────────────────────────────────────
backup_obj_access_key = ""
backup_obj_secret_key = ""
backup_obj_bucket     = ""
backup_obj_endpoint   = ""
