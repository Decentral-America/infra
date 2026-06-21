#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# DCC Backend Bootstrap StackScript (Debian 12)
#
# Runs on first boot via Linode StackScript. Idempotent -- safe to re-run.
# UDF variables are injected by OpenTofu at instance creation time.
#
# <UDF name="DEPLOY_PUBLIC_KEY" label="Deploy SSH public key" />
# <UDF name="NETWORK"           label="Network name (mainnet/stagenet/testnet)" />
# <UDF name="CHAIN_ID"          label="DCC chain ID (63/83/33)" />
# <UDF name="POSTGRES_HOST"     label="PostgreSQL host" default="localhost" />
# <UDF name="POSTGRES_PORT"     label="PostgreSQL port" default="5432" />
# <UDF name="POSTGRES_USER"     label="PostgreSQL user" default="dcc" />
# <UDF name="POSTGRES_DATABASE" label="PostgreSQL database name" default="" />
# <UDF name="DEFAULT_MATCHER"   label="DCC matcher blockchain address" />
# <UDF name="RATE_PAIR_ACCEPTANCE_VOLUME_THRESHOLD" label="Rate pair acceptance volume threshold (must be > 0 for data-service)" default="1" />
# <UDF name="RATE_THRESHOLD_ASSET_ID" label="Rate threshold asset ID" default="DCC" />
# <UDF name="BLOCKCHAIN_UPDATES_URL" label="DCC node Blockchain Updates gRPC URL (e.g. grpc://localhost:6881)" />
# <UDF name="SCANNER_DOMAIN"      label="Scanner/block-explorer domain for Caddy TLS" default="" />
# <UDF name="DATA_SERVICE_DOMAIN" label="Data-service API domain for Caddy TLS" default="" />
# <UDF name="WEBSOCKET_DOMAIN"    label="WebSocket API domain for Caddy TLS (wss://)" default="" />
# <UDF name="NODE_DOMAIN"         label="DCC node REST API domain for Caddy TLS" default="" />
# <UDF name="MATCHER_DOMAIN"      label="DCC matcher REST API domain for Caddy TLS" default="" />
# <UDF name="ACME_EMAIL"          label="ACME/Let's Encrypt email for TLS cert expiry alerts (optional)" default="" />
# <UDF name="BACKUP_OBJ_BUCKET"   label="Object storage bucket name for pg_dump backups (leave empty to disable)" default="" />
# <UDF name="BACKUP_OBJ_ENDPOINT" label="Object storage endpoint for rclone S3 provider" default="" />
#
# SENSITIVE SECRETS ARE NOT ACCEPTED VIA UDF.
# POSTGRES_PASSWORD, MAIN_NODE_WALLET_SEED, MAIN_NODE_WALLET_PASSWORD,
# MATCHER_ACCOUNT_PASSWORD, MATCHER_API_KEY_HASH,
# BACKUP_OBJ_ACCESS_KEY, BACKUP_OBJ_SECRET_KEY
# are all injected post-boot via SSH push (SOPS-encrypted secrets file)
# by the provision.yml workflow. They never transit Linode infrastructure.
# ----------------------------------------------------------------------------
set -euo pipefail

# -- Logging ------------------------------------------------------------------
# Redirect stdout/stderr to bootstrap.log. The log is restricted to root:adm
# (mode 0640) because credential-related commands may echo sensitive values.
# We use `set +x` before credential operations as an additional safeguard.
exec > >(tee /var/log/bootstrap.log) 2>&1
chmod 640 /var/log/bootstrap.log

echo "[bootstrap] Starting DCC backend node bootstrap for network: $NETWORK"

# Suppress all dpkg/debconf interactive prompts -- required for unattended
# operation. Without this, apt-get upgrade blocks on config file conflicts
# (e.g. openssh-server sshd_config updates) and hangs indefinitely.
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true

# -- System updates ------------------------------------------------------------
install -m 0755 -d /etc/apt/keyrings
apt-get update -qq
# --force-confnew: always install the package maintainer's latest config.
# bootstrap.sh then applies our hardening on top via sed -- so we get
# upstream security patches AND our customisations.
apt-get upgrade -y -qq \
  -o Dpkg::Options::="--force-confnew"
apt-get install -y -qq \
  curl \
  ca-certificates \
  gnupg \
  lsb-release

# -- PostgreSQL 18 via PGDG ----------------------------------------------------
# Use the official PGDG repo for PostgreSQL 18 (EOL Nov 2030).
# Debian 12 ships PG15 (EOL Nov 2027) by default -- not enterprise-grade longevity.
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  | gpg --dearmor -o /etc/apt/keyrings/pgdg.gpg
chmod a+r /etc/apt/keyrings/pgdg.gpg

echo "deb [arch=$(dpkg --print-architecture) \
  signed-by=/etc/apt/keyrings/pgdg.gpg] \
  https://apt.postgresql.org/pub/repos/apt \
  $(lsb_release -cs)-pgdg main" \
  > /etc/apt/sources.list.d/pgdg.list

apt-get update -qq
apt-get install -y -qq postgresql-18 postgresql-client-18

# -- Docker --------------------------------------------------------------------
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

# -- Automatic security updates -----------------------------------------------
# Applies security-only OS patches automatically.
# Reboots are intentionally suppressed -- we control restarts via deploys.
apt-get install -y -qq unattended-upgrades apt-listchanges
dpkg-reconfigure -f noninteractive unattended-upgrades
cat > /etc/apt/apt.conf.d/52dcc-settings << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
systemctl enable --now unattended-upgrades
echo "[bootstrap] Unattended security upgrades enabled (reboot suppressed)"

# -- Deploy user ---------------------------------------------------------------
if ! id -u deploy &>/dev/null; then
  useradd -m -s /bin/bash deploy
fi

usermod -aG docker deploy

# Grant deploy user passwordless sudo for CI/CD operations.
# Scope is intentionally broad for a deploy user -- access is gated by
# SSH key-only authentication (PasswordAuthentication no, AllowUsers deploy).
echo "deploy ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/deploy
chmod 440 /etc/sudoers.d/deploy
visudo -cf /etc/sudoers.d/deploy \
  || { echo "[bootstrap] FATAL: sudoers syntax error"; exit 1; }

install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
# Idempotent: append only if key not already present (avoid duplicates on re-run)
grep -qF "$DEPLOY_PUBLIC_KEY" /home/deploy/.ssh/authorized_keys 2>/dev/null \
  || echo "$DEPLOY_PUBLIC_KEY" >> /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys

# -- SSH hardening (CIS Debian 12 Benchmark v1.1.0 + Mozilla Modern) ----------
#
# We write to /etc/ssh/sshd_config.d/99-dcc-hardening.conf (a drop-in file)
# rather than modifying sshd_config directly with sed. This approach:
#   1. Survives openssh-server package upgrades without dpkg conflict prompts
#      (the root cause of the interactive dialog that blocked bootstrap)
#   2. Is auditable -- all hardening in one place, not scattered across sed calls
#   3. Takes precedence over sshd_config (Include directive runs alphabetically,
#      99-* always wins over defaults)
#
# Algorithm choices:
#   Ciphers:       chacha20-poly1305 first (no AES timing side-channel),
#                  AES-GCM (authenticated), AES-CTR (counter mode). No CBC.
#   KexAlgorithms: - prefix removes weak algorithms while preserving the full
#                  default list -- including sntrup761x25519-sha512 (post-quantum
#                  hybrid, default since OpenSSH 9.0 on Debian 12 / 9.2p1).
#                  Removes NIST ECDH curves and group14 (2048-bit, weak for 2026).
#   MACs:          ETM (Encrypt-then-MAC) variants first; non-ETM as fallback.
#                  Removes SHA-1 and UMAC-64.

cat > /etc/ssh/sshd_config.d/99-dcc-hardening.conf << 'SSHEOF'
# DCC backend node SSH hardening
# CIS Debian 12 Benchmark v1.1.0 + Mozilla OpenSSH Modern (2025)

# -- Access control -----------------------------------------------------------
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
AllowUsers deploy

# -- Session limits -----------------------------------------------------------
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 0

# -- Disable unused features --------------------------------------------------
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitUserEnvironment no
Compression no
PrintMotd no

# -- Cryptographic algorithm hardening ----------------------------------------
# Ciphers: no CBC mode, no legacy ciphers
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr

# KexAlgorithms: remove weak algorithms via - prefix, preserve PQ hybrid
# (sntrup761x25519-sha512@openssh.com is default on OpenSSH 9.2p1 / Debian 12)
KexAlgorithms -ecdh-sha2-nistp256,-ecdh-sha2-nistp384,-ecdh-sha2-nistp521,-diffie-hellman-group14-sha256,-diffie-hellman-group14-sha1,-diffie-hellman-group1-sha1

# MACs: ETM (Encrypt-then-MAC) variants preferred; remove SHA-1 and UMAC-64
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com,hmac-sha2-512,hmac-sha2-256

# HostKeyAlgorithms: prefer Ed25519 (modern, fast), keep RSA for compatibility
HostKeyAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,rsa-sha2-512,rsa-sha2-256
SSHEOF

chmod 600 /etc/ssh/sshd_config.d/99-dcc-hardening.conf

# Filter out weak Diffie-Hellman moduli (< 3072 bits) from /etc/ssh/moduli
# This hardens the diffie-hellman-group-exchange-sha256 key exchange
awk '$5 >= 3071' /etc/ssh/moduli > /tmp/moduli.safe \
  && mv /tmp/moduli.safe /etc/ssh/moduli \
  && echo "[bootstrap] DH moduli filtered: only >= 3072-bit groups retained"

if sshd -t; then
  systemctl restart sshd
else
  echo "[bootstrap] FATAL: sshd config test failed -- check /etc/ssh/sshd_config.d/99-dcc-hardening.conf"
  exit 1
fi
echo "[bootstrap] SSH hardened: CIS Debian 12 + Mozilla Modern profile applied via drop-in"

# -- fail2ban (SSH brute-force protection) ------------------------------------
apt-get install -y -qq fail2ban
# SSH jail: 5 failures in 10 min -> 1-hour ban.
cat > /etc/fail2ban/jail.d/sshd.conf << 'EOF'
[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 5
bantime  = 3600
findtime = 600
EOF
systemctl enable --now fail2ban
echo "[bootstrap] fail2ban enabled: SSH jail active (5 retries / 10 min -> 1 h ban)"

# -- Directory structure -------------------------------------------------------
install -d -m 755 -o deploy -g deploy \
  /opt/dcc/compose \
  /opt/dcc/secrets \
  "/opt/dcc/data/node-wallet-${NETWORK}" \
  "/opt/dcc/data/matcher-${NETWORK}" \
  "/opt/dcc/config/matcher-${NETWORK}" \
  "/opt/dcc/config/node-${NETWORK}" \
  /opt/dcc/caddy

# -- External Docker volumes ---------------------------------------------------
# Declared as external in compose files so the volume name is independent of
# the compose project name. Compose-managed volumes are named {project}_{vol},
# so changing --project-name orphans the data. Pre-creating them here with a
# fixed name prevents data loss if the project name ever changes.
docker volume create "dcc-node-state-${NETWORK}" 2>/dev/null || true
echo "[bootstrap] External Docker volumes created for ${NETWORK}"

# -- Node network config placeholder ------------------------------------------
# node-scala's entrypoint.sh only injects wallet secrets (DCC_WALLET_SEED,
# DCC_WALLET_PASSWORD) when /etc/dcc/dcc.conf exists. Write a minimal placeholder
# so the file exists at boot. The deploy-container.yml workflow overwrites this
# with the full genesis/chain config from infra/node-config/<network>/dcc.conf
# before starting the container on every deploy.
# This placeholder alone is not sufficient to run the node -- it intentionally
# fails fast with a clear error if deployed without the CI push step.
printf '# Placeholder -- deploy-container.yml will overwrite this before docker compose up.\n' \
  > "/opt/dcc/config/node-${NETWORK}/dcc.conf"
chmod 644 "/opt/dcc/config/node-${NETWORK}/dcc.conf"
echo "[bootstrap] Node config placeholder written: /opt/dcc/config/node-${NETWORK}/dcc.conf"

# Backup directory: postgres-owned (pg_dump writes here via cron).
install -d -m 750 -o postgres -g postgres /opt/dcc/backups

# Scripts directory: root-owned, executable by the system cron subsystem.
install -d -m 755 /opt/dcc/scripts

# -- Network-specific public endpoints ----------------------------------------
# These are public URLs -- not secrets, but network-dependent config.
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
    DCC_MATCHER_URL="https://testnet-matcher.decentralchain.io/matcher"
    DCC_DATA_SERVICE_URL="https://testnet-data-service.decentralchain.io/v0"
    ;;
esac

# -- Server secrets file (non-sensitive values only) ---------------------------
# Sensitive values (PGPASSWORD, DCC_WALLET_SEED, DCC_WALLET_PASSWORD,
# MATCHER_ACCOUNT_PASSWORD, MATCHER_API_KEY_HASH, RCLONE credentials) are
# NOT written here. They are appended by the SSH push step in provision.yml
# using SOPS-decrypted secrets. This file is safe to create with UDF values.
set +x 2>/dev/null || true
{
  printf '# DecentralChain %s runtime config -- non-sensitive values\n' "${NETWORK}"
  printf '# Sensitive values are appended by provision.yml SSH push (SOPS).\n'
  printf '# DO NOT store this file in version control.\n'
  printf 'NETWORK=%s\n'                                "${NETWORK}"
  printf 'CHAIN_ID=%s\n'                               "${CHAIN_ID}"
  printf '# PostgreSQL connection (password appended by SSH push)\n'
  printf 'PGHOST=%s\n'                                 "${POSTGRES_HOST}"
  printf 'PGPORT=%s\n'                                 "${POSTGRES_PORT}"
  printf 'PGDATABASE=%s\n'                             "${POSTGRES_DATABASE}"
  printf 'PGUSER=%s\n'                                 "${POSTGRES_USER}"
  # BPS (blockchain-postgres-sync) reads Postgres config with POSTGRES__ prefix
  # via envy::prefixed("POSTGRES__"). Mirror the same values under that prefix.
  printf 'POSTGRES__HOST=%s\n'                         "${POSTGRES_HOST}"
  printf 'POSTGRES__PORT=%s\n'                         "${POSTGRES_PORT}"
  printf 'POSTGRES__DATABASE=%s\n'                     "${POSTGRES_DATABASE}"
  printf 'POSTGRES__USER=%s\n'                         "${POSTGRES_USER}"
  printf '# DCC public endpoints\n'
  printf 'DCC_NODE_URL=%s\n'                           "${DCC_NODE_URL}"
  printf 'DCC_MATCHER_URL=%s\n'                        "${DCC_MATCHER_URL}"
  printf 'DCC_DATA_SERVICE_URL=%s\n'                   "${DCC_DATA_SERVICE_URL}"
  printf 'BLOCKCHAIN_UPDATES_URL=%s\n'                 "${BLOCKCHAIN_UPDATES_URL}"
  printf 'DEFAULT_MATCHER=%s\n'                        "${DEFAULT_MATCHER}"
  printf 'RATE_PAIR_ACCEPTANCE_VOLUME_THRESHOLD=%s\n'  "${RATE_PAIR_ACCEPTANCE_VOLUME_THRESHOLD}"
  printf 'RATE_THRESHOLD_ASSET_ID=%s\n'                "${RATE_THRESHOLD_ASSET_ID}"
} > "/opt/dcc/secrets/${NETWORK}.env"

chmod 640 "/opt/dcc/secrets/${NETWORK}.env"
chown root:deploy "/opt/dcc/secrets/${NETWORK}.env"
echo "[bootstrap] Non-sensitive config written to /opt/dcc/secrets/${NETWORK}.env"
echo "[bootstrap] Awaiting SSH push for sensitive secrets (PGPASSWORD, wallet seed, matcher credentials)"

# -- Matcher network-specific config ------------------------------------------
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
  *)  ADDR_SCHEME="D" ;;   # devnet / unknown -- fail loudly at matcher startup
esac

# Write matcher config skeleton -- sensitive values injected by SSH push.
# MATCHER_ACCOUNT_PASSWORD and MATCHER_API_KEY_HASH are never passed via UDF.
# provision.yml SSH push rewrites this file with real values after boot.
{
  printf '# DecentralChain DEX Matcher local config -- skeleton written by bootstrap\n'
  printf '# Network: %s  Chain ID: %s\n' "${NETWORK}" "${CHAIN_ID}"
  printf '# SENSITIVE VALUES (password, api-key-hashes) are injected by SSH push (SOPS).\n'
  printf 'dcc.dex {\n'
  printf '  address-scheme-character = "%s"\n'                             "${ADDR_SCHEME}"
  printf '  dcc-blockchain-client.grpc.target = "127.0.0.1:6887"\n'
  printf '  dcc-blockchain-client.blockchain-updates-grpc.target = "127.0.0.1:6881"\n'
  printf '  account-storage {\n'
  printf '    type = "encrypted-file"\n'
  printf '    encrypted-file {\n'
  printf '      path = "/var/lib/decentralchain-dex/account.dat"\n'
  printf '      password = "PLACEHOLDER_INJECTED_BY_SSH_PUSH"\n'
  printf '    }\n'
  printf '  }\n'
  printf '  rest-api.api-key-hashes = ["PLACEHOLDER_INJECTED_BY_SSH_PUSH"]\n'
  printf '}\n'
} > "/opt/dcc/config/matcher-${NETWORK}/local.conf"

chmod 640 "/opt/dcc/config/matcher-${NETWORK}/local.conf"
chown root:deploy "/opt/dcc/config/matcher-${NETWORK}/local.conf"

# -- PostgreSQL setup ----------------------------------------------------------
systemctl enable --now postgresql

# Create the dcc role with a TEMPORARY random password.
# The real POSTGRES_PASSWORD (from SOPS) is set by the SSH push step in
# provision.yml immediately after bootstrap completes, before any service starts.
# The temp password is never stored, transmitted, or logged.
set +x 2>/dev/null || true
TEMP_POSTGRES_PASS=$(openssl rand -hex 32)
sudo -u postgres psql -c "
  DO \$\$
  BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'dcc') THEN
      CREATE ROLE dcc LOGIN PASSWORD '${TEMP_POSTGRES_PASS}';
    END IF;
  END
  \$\$;
" >/dev/null 2>&1
TEMP_POSTGRES_PASS=""
unset TEMP_POSTGRES_PASS

sudo -u postgres psql -tc \
  "SELECT 1 FROM pg_database WHERE datname = 'dcc_${NETWORK}'" \
  | grep -q 1 || \
  sudo -u postgres createdb -O dcc "dcc_${NETWORK}"

# -- PostgreSQL hardening (Audit P6 LOW-3) ------------------------------------
# Enforce scram-sha-256 instead of md5 for password hashing.
# Enable connection logging for security audit trail.
sudo -u postgres psql -c "ALTER SYSTEM SET password_encryption = 'scram-sha-256';" >/dev/null 2>&1
sudo -u postgres psql -c "ALTER SYSTEM SET log_connections = on;" >/dev/null 2>&1
sudo -u postgres psql -c "ALTER SYSTEM SET log_disconnections = on;" >/dev/null 2>&1
systemctl reload postgresql
echo "[bootstrap] PostgreSQL hardened: scram-sha-256, connection logging enabled"

# -- rclone v1.74.3 (for PostgreSQL off-site backup) -------------------------
# Install from the official Debian package -- no curl-pipe-to-sh pattern.
# Only installed if BACKUP_OBJ_BUCKET is non-empty; safe no-op otherwise.
if [[ -n "${BACKUP_OBJ_BUCKET:-}" ]]; then
  echo "[bootstrap] Installing rclone for off-site backup..."
  RCLONE_DEB="rclone-v1.74.3-linux-amd64.deb"
  RCLONE_URL="https://github.com/rclone/rclone/releases/download/v1.74.3/${RCLONE_DEB}"
  RCLONE_SHA256="408cde598307dedc26b7108553cb2147a8d2d12853100447e802f47454582ecc"
  curl -fsSL "${RCLONE_URL}" -o "/tmp/${RCLONE_DEB}"
  echo "${RCLONE_SHA256}  /tmp/${RCLONE_DEB}" | sha256sum --check --status \
    || { echo "[bootstrap] FATAL: rclone SHA256 mismatch -- aborting"; exit 1; }
  dpkg -i "/tmp/${RCLONE_DEB}"
  rm -f "/tmp/${RCLONE_DEB}"
  echo "[bootstrap] rclone $(rclone version --check 2>/dev/null || rclone version | head -1) installed"

  # Write rclone config for the postgres OS user (cron runs as postgres).
  # Config uses environment variables for credentials -- NOT stored in config file.
  # RCLONE_S3_ACCESS_KEY_ID and RCLONE_S3_SECRET_ACCESS_KEY are set in the cron env.
  install -d -m 700 -o postgres -g postgres /var/lib/postgresql/.config/rclone
  cat > /var/lib/postgresql/.config/rclone/rclone.conf << 'RCLONEEOF'
[dcc-backup]
type = s3
provider = Linode
env_auth = false
RCLONEEOF
  # Credentials are injected via env vars in pg-backup.sh -- nothing sensitive in the config.
  chown postgres:postgres /var/lib/postgresql/.config/rclone/rclone.conf
  chmod 600 /var/lib/postgresql/.config/rclone/rclone.conf
  echo "[bootstrap] rclone config written for postgres user"
fi

# -- PostgreSQL daily backup --------------------------------------------------
# Writes a compressed pg_dump to /opt/dcc/backups/ and rotates after 7 days.
# If BACKUP_OBJ_BUCKET is set, also uploads to Linode Object Storage via rclone.
# Runs at 02:00 UTC daily under the postgres OS user.
cat > /opt/dcc/scripts/pg-backup.sh << 'CRONEOF'
#!/usr/bin/env bash
# DCC PostgreSQL daily backup -- rotate last 7 days, optional off-site upload.
set -euo pipefail
NETWORK="__NETWORK__"
DATE=$(date +%Y-%m-%d_%H%M%S)
BACKUP_DIR="/opt/dcc/backups"
BACKUP_FILE="${BACKUP_DIR}/dcc_${NETWORK}_${DATE}.sql.gz"

pg_dump "dcc_${NETWORK}" | gzip > "${BACKUP_FILE}"
chmod 640 "${BACKUP_FILE}"

# Prune backups older than 7 days (suppress "no matches" on fresh installs)
find "${BACKUP_DIR}" -name "dcc_${NETWORK}_*.sql.gz" -mtime +7 -delete 2>/dev/null || true

echo "[pg-backup] $(date -Iseconds) local backup complete: ${BACKUP_FILE}"

# -- Off-site upload via rclone ---------------------------------------------
# Only runs if BACKUP_OBJ_BUCKET is non-empty.
# Credentials are injected via cron environment (Audit P6 CRITICAL-4).
# RCLONE_S3_ACCESS_KEY_ID and RCLONE_S3_SECRET_ACCESS_KEY are set in crontab,
# NOT embedded in this script.
BACKUP_OBJ_BUCKET="__BACKUP_OBJ_BUCKET__"
BACKUP_OBJ_ENDPOINT="__BACKUP_OBJ_ENDPOINT__"

if [[ -n "${BACKUP_OBJ_BUCKET}" && -n "${BACKUP_OBJ_ENDPOINT}" ]]; then
  # Credentials must be set in the cron environment -- see crontab setup below.
  if [[ -z "${RCLONE_S3_ACCESS_KEY_ID:-}" || -z "${RCLONE_S3_SECRET_ACCESS_KEY:-}" ]]; then
    echo "[pg-backup] $(date -Iseconds) ERROR: rclone credentials not set in environment -- skipping off-site upload" >&2
  else
    export RCLONE_S3_ENDPOINT="${BACKUP_OBJ_ENDPOINT}"
    export RCLONE_CONFIG_DCC_BACKUP_TYPE=s3
    export RCLONE_CONFIG_DCC_BACKUP_PROVIDER=Linode
    export RCLONE_CONFIG_DCC_BACKUP_ENV_AUTH=false

    if rclone copyto \
      "${BACKUP_FILE}" \
      ":s3,provider=Linode,endpoint=${BACKUP_OBJ_ENDPOINT}:${BACKUP_OBJ_BUCKET}/$(basename "${BACKUP_FILE}")" \
      --no-traverse \
      2>&1; then
      echo "[pg-backup] $(date -Iseconds) off-site upload complete: s3://${BACKUP_OBJ_BUCKET}/$(basename "${BACKUP_FILE}")"
    else
      # Off-site failure is non-fatal -- local backup is already complete.
      echo "[pg-backup] $(date -Iseconds) WARNING: off-site upload failed (local backup preserved)" >&2
    fi
  fi
fi
CRONEOF
# Inject the actual network name and backup config at bootstrap time.
# All values are alphanumeric or empty -- safe for sed substitution.
# Credentials are NOT embedded in the script -- they are passed via crontab env.
sed -i "s/__NETWORK__/${NETWORK}/" /opt/dcc/scripts/pg-backup.sh
sed -i "s|__BACKUP_OBJ_BUCKET__|${BACKUP_OBJ_BUCKET:-}|" /opt/dcc/scripts/pg-backup.sh
sed -i "s|__BACKUP_OBJ_ENDPOINT__|${BACKUP_OBJ_ENDPOINT:-}|" /opt/dcc/scripts/pg-backup.sh
chmod 750 /opt/dcc/scripts/pg-backup.sh
chown postgres:postgres /opt/dcc/scripts/pg-backup.sh

# Install as postgres crontab (02:00 UTC daily).
# Backup credentials are passed via crontab environment variables -- NOT embedded
# in the backup script. This prevents credential leakage via script file reads.
# (Audit P6 CRITICAL-4)
# Install backup crontab WITHOUT credentials.
# RCLONE_S3_ACCESS_KEY_ID and RCLONE_S3_SECRET_ACCESS_KEY are injected by
# the SSH push step in provision.yml (SOPS). They never transit Linode UDFs.
{
  printf '%s\n' "0 2 * * * /opt/dcc/scripts/pg-backup.sh >> /var/log/pg-backup.log 2>&1"
} | crontab -u postgres -
echo "[bootstrap] PostgreSQL daily backup cron installed (credentials injected by SSH push)"

# -- GHCR authentication for docker pull --------------------------------------
# GHCR login is handled per-deploy in deploy-container.yml by passing
# GHCR_TOKEN via appleboy/ssh-action envs: parameter. Nothing to configure here.

# -- Caddy TLS reverse proxy --------------------------------------------------
# Caddy terminates HTTPS for scanner (-> localhost:3000) and data-service
# (-> localhost:8080). Certificates are obtained automatically from Let's Encrypt.
# SCANNER_DOMAIN and DATA_SERVICE_DOMAIN are optional UDF variables.
# If neither is set, Caddy is not configured (services are reachable via SSH
# tunnel or internal network only).
if [[ -n "${SCANNER_DOMAIN:-}" ]] || [[ -n "${DATA_SERVICE_DOMAIN:-}" ]] || [[ -n "${WEBSOCKET_DOMAIN:-}" ]] || [[ -n "${NODE_DOMAIN:-}" ]] || [[ -n "${MATCHER_DOMAIN:-}" ]]; then

  # -- Write Caddyfile --------------------------------------------------------
  # Using printf (not heredoc) to safely embed UDF variables that may contain
  # special characters (same rationale as the secrets file above).
  {
    printf '# Generated by DCC bootstrap -- do not edit manually\n'
    printf '{\n'
    # Restrict admin API to a Unix socket -- prevents network-accessible config
    # manipulation. Healthcheck uses the socket via curl --unix-socket.
    # (Audit P6 HIGH-6)
    printf '    admin unix//run/caddy/admin.sock\n'
    if [[ -n "${ACME_EMAIL:-}" ]]; then
      printf '    email %s\n' "${ACME_EMAIL}"
    fi
    printf '}\n\n'

    if [[ -n "${SCANNER_DOMAIN:-}" ]]; then
      printf '%s {\n' "${SCANNER_DOMAIN}"
      printf '    reverse_proxy localhost:3000\n'
      printf '    header {\n'
      printf '        Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"\n'
      printf '        X-Content-Type-Options "nosniff"\n'
      printf '        X-Frame-Options "DENY"\n'
      printf '        Referrer-Policy "strict-origin-when-cross-origin"\n'
      # OWASP 2026: disable the legacy XSS auditor -- setting to 1 can itself
      # introduce XSS vulnerabilities in old browsers. Modern browsers ignore it.
      printf '        X-XSS-Protection "0"\n'
      # CSP for the block explorer SSR app (React Router v7 / Vite 8).
      # unsafe-inline in script-src is required for React Router's hydration
      # inline script (window.__DCC_CONFIG__) -- no nonce provider at Caddy layer.
      # frame-ancestors 'none' supersedes X-Frame-Options for CSP-aware browsers.
      printf '        Content-Security-Policy "default-src '\''self'\''; script-src '\''self'\'' '\''unsafe-inline'\''; style-src '\''self'\'' '\''unsafe-inline'\''; img-src '\''self'\'' data: blob: https:; font-src '\''self'\'' data:; connect-src '\''self'\'' https://*.decentralchain.io wss://*.decentralchain.io; worker-src '\''self'\'' blob:; frame-ancestors '\''none'\''; base-uri '\''self'\''; form-action '\''self'\''; object-src '\''none'\''"\n'
      # Disable all browser APIs the block explorer does not need.
      printf '        Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()"\n'
      # COOP: prevent Spectre cross-origin leaks by isolating the browsing context.
      printf '        Cross-Origin-Opener-Policy "same-origin"\n'
      printf '        -Server\n'
      printf '    }\n'
      printf '    encode gzip zstd\n'
      printf '    log\n'
      printf '}\n\n'
    fi

    if [[ -n "${DATA_SERVICE_DOMAIN:-}" ]]; then
      printf '%s {\n' "${DATA_SERVICE_DOMAIN}"
      printf '    reverse_proxy localhost:8080\n'
      printf '    header {\n'
      printf '        Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"\n'
      printf '        X-Content-Type-Options "nosniff"\n'
      printf '        Referrer-Policy "strict-origin-when-cross-origin"\n'
      printf '        -Server\n'
      printf '    }\n'
      printf '    encode gzip zstd\n'
      printf '    log\n'
      printf '}\n\n'
    fi

    if [[ -n "${WEBSOCKET_DOMAIN:-}" ]]; then
      printf '%s {\n' "${WEBSOCKET_DOMAIN}"
      # reverse_proxy with websocket upgrade -- Caddy handles the Upgrade header
      # automatically when the upstream speaks WebSocket protocol.
      printf '    reverse_proxy localhost:8081\n'
      printf '    header {\n'
      printf '        Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"\n'
      printf '        X-Content-Type-Options "nosniff"\n'
      printf '        Referrer-Policy "strict-origin-when-cross-origin"\n'
      printf '        -Server\n'
      printf '    }\n'
      printf '    log\n'
      printf '}\n\n'
    fi

    if [[ -n "${NODE_DOMAIN:-}" ]]; then
      printf '%s {\n' "${NODE_DOMAIN}"
      # Node REST API also serves WebSocket on the same port -- Caddy upgrades automatically.
      printf '    reverse_proxy localhost:6869\n'
      printf '    header {\n'
      printf '        Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"\n'
      printf '        X-Content-Type-Options "nosniff"\n'
      printf '        Referrer-Policy "strict-origin-when-cross-origin"\n'
      printf '        Access-Control-Allow-Origin "*"\n'
      printf '        -Server\n'
      printf '    }\n'
      printf '    log\n'
      printf '}\n\n'
    fi

    if [[ -n "${MATCHER_DOMAIN:-}" ]]; then
      printf '%s {\n' "${MATCHER_DOMAIN}"
      printf '    reverse_proxy localhost:6886\n'
      printf '    header {\n'
      printf '        Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"\n'
      printf '        X-Content-Type-Options "nosniff"\n'
      printf '        Referrer-Policy "strict-origin-when-cross-origin"\n'
      printf '        Access-Control-Allow-Origin "*"\n'
      printf '        -Server\n'
      printf '    }\n'
      printf '    log\n'
      printf '}\n'
    fi
  } > /opt/dcc/caddy/Caddyfile
  chmod 644 /opt/dcc/caddy/Caddyfile
  chown deploy:deploy /opt/dcc/caddy/Caddyfile
  echo "[bootstrap] Caddyfile written to /opt/dcc/caddy/Caddyfile"

  # -- Download caddy.yml and start Caddy ------------------------------------
  # infra repo is public -- no auth needed. This runs at bootstrap time so
  # Caddy is available before the first application deploy.
  curl -fsSL \
    "https://raw.githubusercontent.com/Decentral-America/infra/main/compose/caddy.yml" \
    -o /opt/dcc/compose/caddy.yml
  chown deploy:deploy /opt/dcc/compose/caddy.yml

  NETWORK="${NETWORK}" docker compose -f /opt/dcc/compose/caddy.yml up -d
  echo "[bootstrap] Caddy TLS reverse proxy started"
fi

echo "[bootstrap] Bootstrap complete. Network: $NETWORK, Chain ID: $CHAIN_ID"

# Signal to provision.yml SSH push step that bootstrap is done and the server
# is ready to receive sensitive secrets (PGPASSWORD, wallet seed, matcher creds).
touch /opt/dcc/.bootstrap-complete
chmod 644 /opt/dcc/.bootstrap-complete
echo "[bootstrap] Ready for SSH secrets push. Waiting for provision.yml to inject sensitive values."
