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
# ────────────────────────────────────────────────────────────────────────────
set -euo pipefail
exec > >(tee /var/log/bootstrap.log) 2>&1

echo "[bootstrap] Starting DCC backend node bootstrap for network: $NETWORK"

# ── System updates ────────────────────────────────────────────────────────────
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
  curl \
  ca-certificates \
  gnupg \
  lsb-release \
  postgresql \
  postgresql-client

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
echo "$DEPLOY_PUBLIC_KEY" >> /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys

# ── Directory structure ───────────────────────────────────────────────────────
install -d -m 755 -o deploy -g deploy \
  /opt/dcc/compose \
  /opt/dcc/secrets

# ── Server secrets file ───────────────────────────────────────────────────────
# Tier 3 secrets: never stored in GitHub. Written once here by bootstrap.
# Containers source this file at startup.
cat > "/opt/dcc/secrets/${NETWORK}.env" << EOF
# DecentralChain $NETWORK secrets — managed by OpenTofu bootstrap
# DO NOT store this file in version control.
NETWORK=$NETWORK
CHAIN_ID=$CHAIN_ID
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_USER=dcc
POSTGRES_DB=dcc_${NETWORK}
PGHOST=localhost
PGPORT=5432
PGDATABASE=dcc_${NETWORK}
PGUSER=dcc
PGPASSWORD=${POSTGRES_PASSWORD}
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
# The GHCR_TOKEN is passed as a GHA secret during docker pull steps.
# Nothing to configure here — the CI action handles login.

echo "[bootstrap] Bootstrap complete. Network: $NETWORK, Chain ID: $CHAIN_ID"
