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
# <UDF name="BLOCKCHAIN_UPDATES_URL"              label="DCC node Blockchain Updates gRPC URL (e.g. grpc://mainnet-node.decentralchain.io:6881)" />
# <UDF name="MATCHER_ACCOUNT_PASSWORD"            label="DEX Matcher account.dat encryption password" default="" private="true" />
# <UDF name="MATCHER_API_KEY_HASH"                label="DEX Matcher API key hash (Base58-encoded SHA256)" default="" private="true" />
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

# ── SSH hardening ─────────────────────────────────────────────────────────────
# Disable root password login (key-based root access preserved for emergency).
# Disable all password authentication — SSH keys only.
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
systemctl restart sshd
echo "[bootstrap] SSH hardened: PermitRootLogin=prohibit-password, PasswordAuthentication=no"

# ── Directory structure ───────────────────────────────────────────────────────
install -d -m 755 -o deploy -g deploy \
  /opt/dcc/compose \
  /opt/dcc/secrets \
  /opt/dcc/data/node-wallet-${NETWORK} \
  /opt/dcc/data/matcher-${NETWORK} \
  /opt/dcc/config/matcher-${NETWORK}

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
#
# IMPORTANT — printf, not heredoc:
# An unquoted heredoc (<<EOF) expands shell metacharacters inside the body, so
# POSTGRES_PASSWORD values containing $, `, \, or ! are silently corrupted.
# printf '%s' never interprets its argument as a format string, making it safe
# for all password values regardless of content. (Audit finding F-07.)
{
  printf '# DecentralChain %s secrets — managed by OpenTofu bootstrap\n' "${NETWORK}"
  printf '# DO NOT store this file in version control.\n'
  printf 'NETWORK=%s\n'                                "${NETWORK}"
  printf 'CHAIN_ID=%s\n'                               "${CHAIN_ID}"
  printf '# PostgreSQL\n'
  printf 'POSTGRES_PASSWORD=%s\n'                      "${POSTGRES_PASSWORD}"
  printf 'POSTGRES_USER=dcc\n'
  printf 'POSTGRES_DB=dcc_%s\n'                        "${NETWORK}"
  printf 'PGHOST=localhost\n'
  printf 'PGPORT=5432\n'
  printf 'PGDATABASE=dcc_%s\n'                         "${NETWORK}"
  printf 'PGUSER=dcc\n'
  printf 'PGPASSWORD=%s\n'                             "${POSTGRES_PASSWORD}"
  printf '# DCC public endpoints (scanner uses these at runtime)\n'
  printf 'DCC_NODE_URL=%s\n'                           "${DCC_NODE_URL}"
  printf 'DCC_MATCHER_URL=%s\n'                        "${DCC_MATCHER_URL}"
  printf 'DCC_DATA_SERVICE_URL=%s\n'                   "${DCC_DATA_SERVICE_URL}"
  printf '# blockchain-postgres-sync gRPC endpoint (provided as UDF at instance creation)\n'
  printf 'BLOCKCHAIN_UPDATES_URL=%s\n'                 "${BLOCKCHAIN_UPDATES_URL}"
  printf '# Data-service matcher config\n'
  printf 'DEFAULT_MATCHER=%s\n'                        "${DEFAULT_MATCHER}"
  printf 'RATE_PAIR_ACCEPTANCE_VOLUME_THRESHOLD=%s\n'  "${RATE_PAIR_ACCEPTANCE_VOLUME_THRESHOLD}"
  printf 'RATE_THRESHOLD_ASSET_ID=%s\n'                "${RATE_THRESHOLD_ASSET_ID}"
  printf '# DEX Matcher secrets\n'
  printf 'MATCHER_ACCOUNT_PASSWORD=%s\n'               "${MATCHER_ACCOUNT_PASSWORD}"
  printf 'MATCHER_API_KEY_HASH=%s\n'                   "${MATCHER_API_KEY_HASH}"
} > "/opt/dcc/secrets/${NETWORK}.env"

chmod 640 "/opt/dcc/secrets/${NETWORK}.env"
chown root:deploy "/opt/dcc/secrets/${NETWORK}.env"

# ── Matcher network-specific config ──────────────────────────────────────────
# The DEX matcher image includes this file via:
#   include "/var/lib/decentralchain-dex/config/local.conf"
# in dex.conf. The file is bind-mounted from /opt/dcc/config/matcher-<NETWORK>/.
#
# gRPC targets point to node-scala running on the same host.
# Port 6887 = DEX extension; 6881 = BlockchainUpdates extension.
#
# address-scheme-character: single byte that encodes the network.
# DCC mainnet=63='?', stagenet=83='S', testnet=33='!'.
case "$CHAIN_ID" in
  63) ADDR_SCHEME="?" ;;   # mainnet
  83) ADDR_SCHEME="S" ;;   # stagenet
  33) ADDR_SCHEME="!" ;;   # testnet
  *)  ADDR_SCHEME="D" ;;   # devnet / unknown — fail loudly at matcher startup
esac

{
  printf '# DecentralChain DEX Matcher local config — managed by OpenTofu bootstrap\n'
  printf '# Network: %s  Chain ID: %s\n' "${NETWORK}" "${CHAIN_ID}"
  printf '# DO NOT store this file in version control.\n'
  printf 'waves.dex {\n'
  printf '  address-scheme-character = "%s"\n'                             "${ADDR_SCHEME}"
  printf '  waves-blockchain-client.grpc.target = "127.0.0.1:6887"\n'
  printf '  waves-blockchain-client.blockchain-updates-grpc.target = "127.0.0.1:6881"\n'
  printf '  account-storage {\n'
  printf '    type = "encrypted-file"\n'
  printf '    encrypted-file {\n'
  printf '      path = "/var/lib/decentralchain-dex/account.dat"\n'
  printf '      password = "%s"\n'                                          "${MATCHER_ACCOUNT_PASSWORD}"
  printf '    }\n'
  printf '  }\n'
  printf '  rest-api.api-key-hashes = ["%s"]\n'                            "${MATCHER_API_KEY_HASH}"
  printf '}\n'
} > "/opt/dcc/config/matcher-${NETWORK}/local.conf"

chmod 640 "/opt/dcc/config/matcher-${NETWORK}/local.conf"
chown root:deploy "/opt/dcc/config/matcher-${NETWORK}/local.conf"

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
