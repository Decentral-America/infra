# ──────────────────────────────────────────────────────────────────────────────
# DCC Testnet — non-sensitive OpenTofu defaults
#
# Committed to the repo. Contains NO secrets.
# Sensitive values (root_password, deploy_ssh_public_key, default_matcher)
# are stored as TF_VAR_* secrets in the infra-testnet-provision GitHub
# environment and injected by provision.yml.
# All application secrets (wallet seed, passwords, API keys) are delivered
# post-boot via SOPS SSH push — they never transit Linode infrastructure.
#
# provision.yml passes -var-file=testnet.tfvars explicitly for the testnet workspace.
# This file is NOT auto-loaded — it is only used when network=testnet.
# ──────────────────────────────────────────────────────────────────────────────

# ── Infrastructure ────────────────────────────────────────────────────────────
linode_region = "us-central"    # Dallas
linode_type   = "g6-standard-4" # 4 vCPU / 8 GB — sufficient for testnet full stack

# ── PostgreSQL (co-located defaults) ──────────────────────────────────────────
# postgres_host     = "localhost"    # default
# postgres_port     = "5432"         # default
# postgres_user     = "dcc"          # default
# postgres_database = "dcc_testnet"  # default (auto from workspace name)

# ── Blockchain updates gRPC (co-located node) ─────────────────────────────────
blockchain_updates_url = "grpc://localhost:6881"

# ── TLS / Caddy ───────────────────────────────────────────────────────────────
scanner_domain      = "testnet.decentralscan.com"
data_service_domain = "testnet-data-service.decentralchain.io"
acme_email          = "ops@decentralamerica.com"

# ── Off-site backup: disabled for testnet ─────────────────────────────────────
# Credentials (access key, secret key) are injected via SOPS SSH push.
# Only bucket/endpoint are needed here — leave empty to disable backup entirely.
backup_obj_bucket   = ""
backup_obj_endpoint = ""

# ── LKE peer-node cluster (Frankfurt) ─────────────────────────────────────────
lke_enabled     = true
lke_region      = "eu-central" # Frankfurt
lke_k8s_version = "1.35"
lke_node_type   = "g6-standard-4" # 4 vCPU / 8 GB — fits 3 JVM nodes + monitoring stack
lke_node_count  = 1
lke_ha          = false # Standard control plane (free). Mainnet uses true.
# SSH access restricted to team IPs. Add VPN egress or office CIDR here.
lke_ssh_allowed_ips = ["201.182.55.117/32"]
