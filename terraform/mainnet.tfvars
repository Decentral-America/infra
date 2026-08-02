# ──────────────────────────────────────────────────────────────────────────────
# DCC Mainnet — non-sensitive OpenTofu defaults
#
# STATUS: config-only, staged for Phase 6 (see docs/superpowers/plans/
# 2026-08-02-launch-readiness.md, Task 14). This file is `tofu plan`-reviewable
# but MUST NOT be applied until the Phase 6 gate (audit sign-off, 60-day T0
# soak, 8-week operator notice) clears. Applying `lke_ha = true` is
# IRREVERSIBLE (see terraform/lke.tf:32-36) — there is no downgrade path.
#
# Committed to the repo. Contains NO secrets.
# Sensitive values (root_password, deploy_ssh_public_key, DEFAULT_MATCHER) are
# stored as TF_VAR_* secrets in the infra-mainnet-provision GitHub environment
# and injected by provision.yml — same pattern as testnet, see testnet.tfvars
# header. DEFAULT_MATCHER in particular does not exist yet: the mainnet matcher
# account is created fresh at Task 16 genesis time, not here.
# NOTE: there is no `postgres_password` OpenTofu variable. The PostgreSQL
# password and all other application secrets (wallet seed, passwords, API
# keys) are delivered post-boot via SOPS SSH push from secrets/mainnet.env
# (already provisioned, see infra/.sops.yaml) — they never transit Linode
# infrastructure or this tfvars file.
#
# provision.yml passes -var-file=mainnet.tfvars explicitly for the mainnet workspace.
# This file is NOT auto-loaded — it is only used when network=mainnet.
# ──────────────────────────────────────────────────────────────────────────────

# ── Infrastructure (backend Linode instance) ──────────────────────────────────
linode_region = "us-central"    # Dallas — same DC as testnet; no mainnet-specific reason to move
linode_type   = "g6-standard-4" # 4 vCPU / 8 GB — same as testnet; README suggests this size for full PG history

# ── PostgreSQL (co-located defaults) ──────────────────────────────────────────
# postgres_host     = "localhost"    # default
# postgres_port     = "5432"         # default
# postgres_user     = "dcc"          # default
# postgres_database = "dcc_mainnet"  # default (auto from workspace name)

# ── Blockchain updates gRPC (co-located node) ─────────────────────────────────
blockchain_updates_url = "grpc://localhost:6881"

# ── TLS / Caddy ───────────────────────────────────────────────────────────────
# Domains confirmed against infra/README.md's existing mainnet variable tables
# (Layer 5 exchange env + Layer 7 on-server env, both already documented there).
scanner_domain      = "decentralscan.com"
data_service_domain = "data-service.decentralchain.io"
node_domain         = "mainnet-node.decentralchain.io"
matcher_domain      = "mainnet-matcher.decentralchain.io"
acme_email          = "ops@decentralamerica.com"

# PLACEHOLDER — not yet documented anywhere in the repo (README only lists
# node/matcher/data-service/explorer for mainnet). Following the node/matcher
# "mainnet-<service>" convention for consistency, but confirm these against
# actual DNS plans before Phase 6 apply; do not treat as settled.
websocket_domain = "mainnet-ws.decentralchain.io"
admin_domain     = "mainnet-admin.decentralchain.io"
grafana_domain   = "grafana.decentralchain.io"

# ── Off-site backup: removed ──────────────────────────────────────────────────
# The former R2 / object-storage blockchain backup has been removed entirely.
# Chain state is not backed up; every node re-syncs from peers. Same for mainnet.

# ── LKE peer-node cluster (Frankfurt) ─────────────────────────────────────────
lke_enabled     = true
lke_region      = "eu-central" # Frankfurt — same as testnet
lke_k8s_version = "1.35"

# Dedicated CPU (not shared) for mainnet generators — no noisy-neighbor jitter
# on block production/HotStuff round timing. "g6-dedicated-2" (2 dedicated
# vCPU / 4 GB) is Linode's real dedicated-CPU plan ID (the "g6-dedicated-N"
# family, N = vCPU count) — this matches what terraform/lke.tf:12 already
# names, so no correction needed there. NOT verified against a live
# `linode-cli linodes types` call (no API credentials invoked for this
# config-only task, see README's `linode-cli linodes types` note) — confirm
# it's still current before Phase 6 apply.
lke_node_type = "g6-dedicated-2"

# >=2 nodes is the whole point: pod anti-affinity (preferredDuringScheduling in
# clusters/testnet/apps/nodes.yaml) is a no-op with 1 node and only spreads
# gen-0/gen-1 across separate hosts once there are 2+ to spread across. That
# manifest's affinity rule is generic (role: generator label selector, no
# testnet-specific values) and needs no changes to work for a mainnet
# cluster — but it currently lives under clusters/testnet/, so an actual
# mainnet apply will need a parallel clusters/mainnet/ tree (new ConfigMaps
# with mainnet chain config/genesis, new StatefulSets, new secrets). That's
# out of scope for Task 14 (Terraform-only) — tracked as a Task 16 prerequisite.
lke_node_count = 2

# HA control plane (3-replica etcd), $60/mo. IRREVERSIBLE — must be set at
# cluster creation, no downgrade path (terraform/lke.tf:32-36). This is the
# flag Task 16 Step 3 calls "the irreversible HA flip."
lke_ha = true

# SSH access restricted to team IPs — same CIDR as testnet for now (same team,
# same office/VPN egress). Add mainnet-specific CIDRs here if the ops team
# changes before Phase 6.
lke_ssh_allowed_ips = ["201.182.55.117/32"]
