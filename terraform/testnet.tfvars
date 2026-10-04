# ──────────────────────────────────────────────────────────────────────────────
# DCC Testnet — non-sensitive OpenTofu defaults
#
# Committed to the repo. Contains NO secrets.
# Sensitive values (root_password, deploy_ssh_public_key, DEFAULT_MATCHER)
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
websocket_domain    = "testnet-ws.decentralchain.io"
node_domain         = "testnet-node.decentralchain.io"
matcher_domain      = "testnet-matcher.decentralchain.io"
admin_domain        = "testnet-admin.decentralchain.io"
grafana_domain      = "grafana.testnet.decentralchain.io"
acme_email          = "ops@decentralamerica.com"

# ── Off-site backup: removed ──────────────────────────────────────────────────
# The former R2 / object-storage blockchain backup has been removed entirely.
# Chain state is not backed up; every node re-syncs from peers.

# ── LKE peer-node cluster (Frankfurt) ─────────────────────────────────────────
lke_enabled     = true
lke_region      = "eu-central" # Frankfurt
lke_k8s_version = "1.35"
# "Shared 8 GB bundle": ONE g6-standard-4 worker runs gen-0, gen-1 and val-0 plus
# Flux (source + kustomize controllers) and the chain metrics-exporter. Monitoring
# lives on the VPS. cluster-diagnostics.yml prints the node's real allocatable vs
# requested figures.
lke_node_type  = "g6-standard-4" # 4 vCPU / 8 GB
lke_node_count = 1
lke_ha         = false # Standard control plane (free). Mainnet uses true.

# No extra pools. The former role=exchange pool (2x g6-standard-2, pool 946807)
# only hosted the copied production web stack, now archived in
# archive/production-exchange-stack/.

# SSH access restricted to team IPs. Add VPN egress or office CIDR here.
lke_ssh_allowed_ips = ["201.182.55.117/32"]
# The chain metrics-exporter NodePort is opened to the backend VPS's own public
# IP, read from linode_instance.backend in lke.tf. No IP literal lives here, so a
# restored VPS with a new address needs only `tofu apply`, not a tfvars edit.
