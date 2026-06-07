# ──────────────────────────────────────────────────────────────────────────────
# OpenTofu root configuration for DecentralChain Linode infrastructure
#
# Provider: linode/linode ~> 3.13 (security floor: v3.9.0 — CVE-2026-27900)
# State:    Linode Object Storage (S3-compatible backend)
# Workspaces: mainnet | stagenet | testnet
# ──────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.12.0" # floor: 1.11.4 (SECURITY: malicious .zip in tofu init)

  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 3.13" # floor: 3.9.0 (CVE-2026-27900 sensitive-info-in-logs)
    }
  }

  # Cloudflare R2 is S3-compatible and has a permanent free tier.
  # State is partitioned by workspace: env:/<workspace>/terraform.tfstate
  # Region and endpoint are passed at runtime via -backend-config=backend.hcl
  # (written by provision.yml / drift-detect.yml using CF_ACCOUNT_ID + R2 credentials).
  # Create bucket first: Cloudflare Dashboard → R2 → Create bucket → dcc-tofu-state

  # State encryption (OpenTofu ≥ 1.7 native AES-256-GCM).
  # Passphrase is passed via TF_VAR_state_encryption_passphrase env var (GitHub secret).
  # Even if R2 credentials are compromised, the state file is unreadable without the passphrase.
  # NOTE: sensitive=true suppresses log output but does NOT prevent plaintext state storage
  # without this encryption block — both are required for full protection.
  encryption {
    key_provider "pbkdf2" "state" {
      passphrase = var.state_encryption_passphrase
    }
    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.state
    }
    state {
      method = method.aes_gcm.state
      # Migration fallback: allows reading existing unencrypted state from R2.
      # On the next successful write, OpenTofu re-encrypts automatically.
      # Remove this fallback block once all workspaces have been applied at least once.
      fallback {}
    }
    plan {
      method = method.aes_gcm.state
      fallback {}
    }
  }

  backend "s3" {
    bucket = "dcc-tofu-state"
    key    = "terraform.tfstate" # workspace prefix added automatically: env:/<workspace>/terraform.tfstate

    # R2 is S3-compatible but not AWS — suppress AWS-specific endpoint calls.
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true

    # R2 uses path-style URLs: endpoint/bucket (not bucket.endpoint).
    # Without this the SDK tries virtual-hosted style which R2 rejects with 404.
    use_path_style = true

    # Workspaces are stored as: env:/<workspace>/terraform.tfstate
    workspace_key_prefix = "env:"

    # Native S3 state locking via conditional writes (OpenTofu ≥ 1.10).
    # R2 supports conditional writes — no DynamoDB required.
    # Creates a .tflock object alongside the state file in the bucket.
    use_lockfile = true

    # region and endpoint are intentionally omitted here.
    # They are injected at runtime via -backend-config=backend.hcl:
    #   region   = "auto"
    #   endpoint = "https://<CF_ACCOUNT_ID>.r2.cloudflarestorage.com"
  }
}

provider "linode" {
  # LINODE_TOKEN env var is set by the GHA workflow; do not hardcode here.
}

# ── Network-specific locals ───────────────────────────────────────────────────
locals {
  network = terraform.workspace # mainnet | stagenet | testnet

  # Chain IDs: mainnet=63 ('?'), stagenet=83 ('S'), testnet=33 ('!')
  chain_id = lookup({
    mainnet  = 63
    stagenet = 83
    testnet  = 33
  }, local.network, 33) # default to testnet for validation

  # Linode region — centralise here for easy migration
  region = var.linode_region

  # Tags applied to all resources for cost allocation
  tags = ["dcc", local.network]
}

# ── Backend servers ───────────────────────────────────────────────────────────
# One Linode instance per network, hosting:
#   - scanner (port 3000)
#   - data-service (port 8080)
#   - blockchain-postgres-sync (internal)
#   - PostgreSQL (local, not exposed externally)
resource "linode_instance" "backend" {
  label  = "dcc-backend-${local.network}"
  region = local.region
  type   = var.linode_type # e.g. "g6-standard-2" (2 vCPU, 4 GB)

  image     = "linode/debian12"
  root_pass = var.root_password

  tags = local.tags

  # Firewall — allow SSH (22), HTTP (80), HTTPS (443).
  # Direct access to port 3000 (scanner) and 8080 (data-service) is closed;
  # those services bind to loopback only and are proxied by Caddy with auto-TLS.
  firewall_id = linode_firewall.backend.id

  # Bootstrap script: install Docker, PostgreSQL, create deploy user, set up directories.
  # SENSITIVE secrets (wallet seed, passwords, API keys) are NOT passed here.
  # They are pushed via SSH by provision.yml after the instance boots, using
  # SOPS-encrypted secrets/testnet.env decrypted with the age key (AGE_SECRET_KEY).
  # This keeps sensitive values out of Linode's infrastructure entirely.
  stackscript_id = linode_stackscript.bootstrap.id
  stackscript_data = {
    DEPLOY_PUBLIC_KEY                     = var.deploy_ssh_public_key
    NETWORK                               = local.network
    CHAIN_ID                              = tostring(local.chain_id)
    POSTGRES_HOST                         = var.postgres_host
    POSTGRES_PORT                         = var.postgres_port
    POSTGRES_USER                         = var.postgres_user
    POSTGRES_DATABASE                     = var.postgres_database != "" ? var.postgres_database : "dcc_${local.network}"
    DEFAULT_MATCHER                       = var.default_matcher
    RATE_PAIR_ACCEPTANCE_VOLUME_THRESHOLD = var.rate_pair_acceptance_volume_threshold
    RATE_THRESHOLD_ASSET_ID               = var.rate_threshold_asset_id
    BLOCKCHAIN_UPDATES_URL                = var.blockchain_updates_url
    SCANNER_DOMAIN                        = var.scanner_domain
    DATA_SERVICE_DOMAIN                   = var.data_service_domain
    ACME_EMAIL                            = var.acme_email
    BACKUP_OBJ_BUCKET                     = var.backup_obj_bucket
    BACKUP_OBJ_ENDPOINT                   = var.backup_obj_endpoint
  }

  # Prevent accidental destruction of the backend server.
  # To intentionally tear down, temporarily set this to false, apply, then destroy.
  lifecycle {
    prevent_destroy = true
  }
}

resource "linode_firewall" "backend" {
  label = "dcc-firewall-${local.network}"

  inbound_policy  = "DROP"
  outbound_policy = "DROP"

  # ── Egress rules (Audit P6 MEDIUM-8) ───────────────────────────────────────
  # Whitelist required outbound traffic only. A compromised container cannot
  # exfiltrate data to arbitrary destinations.
  outbound {
    label    = "allow-dns"
    action   = "ACCEPT"
    protocol = "UDP"
    ports    = "53"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  outbound {
    label    = "allow-ntp"
    action   = "ACCEPT"
    protocol = "UDP"
    ports    = "123"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  outbound {
    label    = "allow-http"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "80"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  outbound {
    label    = "allow-https"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "443"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  outbound {
    # DCC P2P outbound — required for blockchain peer connections.
    label    = "allow-p2p-out"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "6868"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  inbound {
    label    = "allow-ssh"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "22"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  inbound {
    label    = "allow-http"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "80"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  inbound {
    label    = "allow-https"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "443"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  inbound {
    # DCC node P2P (node-go and node-scala). Required for blockchain peer discovery.
    # node-go binds :6868, node-scala binds :6868 — same port, one node at a time.
    label    = "allow-node-p2p"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "6868"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  tags = local.tags
}

# ── Bootstrap StackScript ─────────────────────────────────────────────────────
# Runs on first boot. Installs Docker, creates deploy user, writes server .env.
resource "linode_stackscript" "bootstrap" {
  label       = "dcc-bootstrap-${local.network}"
  description = "DecentralChain backend node bootstrap"
  is_public   = false

  images = ["linode/debian12"]

  # Non-sensitive UDF variables injected at instance creation time.
  # SENSITIVE secrets (passwords, seeds, API keys) are NOT in this list —
  # they are pushed post-boot via SSH (push-secrets.yml) using SOPS encryption.
  # <UDF name="DEPLOY_PUBLIC_KEY" label="Deploy SSH public key" />
  # <UDF name="NETWORK" label="Network name" />
  # <UDF name="CHAIN_ID" label="DCC chain ID" />
  # <UDF name="DEFAULT_MATCHER" label="DCC matcher blockchain address" />
  # <UDF name="RATE_PAIR_ACCEPTANCE_VOLUME_THRESHOLD" label="Rate pair acceptance volume threshold" default="0" />
  # <UDF name="RATE_THRESHOLD_ASSET_ID" label="Rate threshold asset ID" default="DCC" />
  # <UDF name="BLOCKCHAIN_UPDATES_URL" label="DCC node Blockchain Updates gRPC URL" />
  script = file("${path.module}/scripts/bootstrap.sh")
}
