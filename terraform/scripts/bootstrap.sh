#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────────────────
# DCC Backend Bootstrap StackScript (Debian 12)
#
# Runs on first boot via Linode StackScript. Idempotent — safe to re-run.
# UDF variables are injected by OpenTofu at instance creation time.
#
# <UDF name="DEPLOY_PUBLIC_KEY" label="Deploy SSH public key" />
# <UDF name="NETWORK"           label="Network name (mainnet/stagenet/testnet)" />
# <UDF name="CHAIN_ID"          label="DCC chain ID (63/83/33)" />
# <UDF name="POSTGRES_PASSWORD" label="PostgreSQL password" default="" private="true" />
# <UDF name="DEFAULT_MATCHER"   label="DCC matcher blockchain address" />
# <UDF name="RATE_PAIR_ACCEPTANCE_VOLUME_THRESHOLD" label="Rate pair acceptance volume threshold" default="0" />
# <UDF name="RATE_THRESHOLD_ASSET_ID" label="Rate threshold asset ID" default="DCC" />
# <UDF name="BLOCKCHAIN_UPDATES_URL" label="DCC node Blockchain Updates gRPC URL (e.g. grpc://mainnet-node.decentralchain.io:6881)" />
# ────────────────────────────────────────────────────────────────────────────
set -euo pipefail
exec > >(tee /var/log/bootstrap.log) 2>&1

echo "[bootstrap] Starting DCC backend node bootstrap for network: $NETWORK"

# ── System updates ────────────────────────────────────────────────────────────
install -m 0755 -d /etc/apt/keyrings
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
  curl \
  ca-certificates \
  gnupg \
  lsb-release

# ── PostgreSQL 17 via PGDG ────────────────────────────────────────────────────
# Use the official PGDG repo for PostgreSQL 17 (EOL Nov 2029).
# Debian 12 ships PG15 (EOL Nov 2027) by default — not enterprise-grade longevity.
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  | gpg --dearmor -o /etc/apt/keyrings/pgdg.gpg
chmod a+r /etc/apt/keyrings/pgdg.gpg

echo "deb [arch=$(dpkg --print-architecture) \
  signed-by=/etc/apt/keyrings/pgdg.gpg] \
  https://apt.postgresql.org/pub/repos/apt \
  $(lsb_release -cs)-pgdg main" \
  > /etc/apt/sources.list.d/pgdg.list

apt-get update -qq
apt-get install -y -qq postgresql-17 postgresql-client-17

# ── Docker ────────────────────────────────────────────────────────────────────
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) \
  signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

systemctl enable --now docker

# ── Deploy user ───────────────────────────────────────────────────────────────
if ! id -u deploy &>/dev/null; then
  useradd -m -s /bin/bash deploy
fi

usermod -aG docker deploy

install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
# Idempotent: append only if key not already present (avoid duplicates on re-run)
grep -qF "$DEPLOY_PUBLIC_KEY" /home/deploy/.ssh/authorized_keys 2>/dev/null \
  || echo "$DEPLOY_PUBLIC_KEY" >> /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys

# ── Directory structure ───────────────────────────────────────────────────────
install -d -m 755 -o deploy -g deploy \
  /opt/dcc/compose \
  /opt/dcc/secrets

# ── Network-specific public endpoints ────────────────────────────────────────
# These are public URLs — not secrets, but network-dependent config.
case "$NETWORK" in
  mainnet)
    DCC_NODE_URL="https://mainnet-node.decentralchain.io"
    DCC_MATCHER_URL="https://mainnet-matcher.decentralchain.io/matcher"
    DCC_DATA_SERVICE_URL="https://data-service.decentralchain.io/v0"
    ;;
  stagenet)
    DCC_NODE_URL="https://stagenet-node.decentralchain.io"
    DCC_MATCHER_URL="https://stagenet-matcher.decentralchain.io/matcher"
    DCC_DATA_SERVICE_URL="https://stagenet-data-service.decentralchain.io/v0"
    ;;
  testnet)
    DCC_NODE_URL="https://testnet-node.decentralchain.io"
    DCC_MATCHER_URL="https://matcher.decentralchain.io/matcher"
    DCC_DATA_SERVICE_URL="https://testnet-data-service.decentralchain.io/v0"
    ;;
esac

# ── Server secrets file ───────────────────────────────────────────────────────
# Tier 3 secrets: never stored in GitHub. Written once here by bootstrap.
# Containers source this file at startup via env_file: in docker-compose.
# Note: heredoc content goes to cat's stdin, NOT stdout — not captured by tee.
cat > "/opt/dcc/secrets/${NETWORK}.env" << EOF
# DecentralChain $NETWORK secrets — managed by OpenTofu bootstrap
# DO NOT store this file in version control.
NETWORK=$NETWORK
CHAIN_ID=$CHAIN_ID
# PostgreSQL
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_USER=dcc
POSTGRES_DB=dcc_${NETWORK}
PGHOST=localhost
PGPORT=5432
PGDATABASE=dcc_${NETWORK}
PGUSER=dcc
PGPASSWORD=${POSTGRES_PASSWORD}
# DCC public endpoints (scanner uses these at runtime)
DCC_NODE_URL=${DCC_NODE_URL}
DCC_MATCHER_URL=${DCC_MATCHER_URL}
DCC_DATA_SERVICE_URL=${DCC_DATA_SERVICE_URL}
# blockchain-postgres-sync gRPC endpoint (provided as UDF at instance creation)
BLOCKCHAIN_UPDATES_URL=${BLOCKCHAIN_UPDATES_URL}
# Data-service matcher config
DEFAULT_MATCHER=${DEFAULT_MATCHER}
RATE_PAIR_ACCEPTANCE_VOLUME_THRESHOLD=${RATE_PAIR_ACCEPTANCE_VOLUME_THRESHOLD}
RATE_THRESHOLD_ASSET_ID=${RATE_THRESHOLD_ASSET_ID}
EOF

chmod 640 "/opt/dcc/secrets/${NETWORK}.env"
chown root:deploy "/opt/dcc/secrets/${NETWORK}.env"

# ── PostgreSQL setup ──────────────────────────────────────────────────────────
systemctl enable --now postgresql

sudo -u postgres psql -c "
  DO \$\$
  BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'dcc') THEN
      CREATE ROLE dcc LOGIN PASSWORD '${POSTGRES_PASSWORD}';
    END IF;
  END
  \$\$;
"

sudo -u postgres psql -tc \
  "SELECT 1 FROM pg_database WHERE datname = 'dcc_${NETWORK}'" \
  | grep -q 1 || \
  sudo -u postgres createdb -O dcc "dcc_${NETWORK}"

# ── GHCR authentication for docker pull ──────────────────────────────────────
# GHCR login is handled per-deploy in deploy-container.yml by passing
# GHCR_TOKEN via appleboy/ssh-action envs: parameter. Nothing to configure here.

echo "[bootstrap] Bootstrap complete. Network: $NETWORK, Chain ID: $CHAIN_ID"
