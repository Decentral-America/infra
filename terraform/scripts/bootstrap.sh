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
# <UDF name="SCANNER_DOMAIN"      label="Scanner/block-explorer domain for Caddy TLS (e.g. explorer.decentralchain.io)" default="" />
# <UDF name="DATA_SERVICE_DOMAIN" label="Data-service API domain for Caddy TLS (e.g. data-service.decentralchain.io)" default="" />
# <UDF name="ACME_EMAIL"          label="ACME/Let's Encrypt email for TLS cert expiry alerts (optional)" default="" />
# <UDF name="BACKUP_OBJ_ACCESS_KEY" label="Object storage access key for pg_dump off-site backup (rclone Linode/S3 provider)" default="" private="true" />
# <UDF name="BACKUP_OBJ_SECRET_KEY" label="Object storage secret key for pg_dump off-site backup" default="" private="true" />
# <UDF name="BACKUP_OBJ_BUCKET"     label="Object storage bucket name for pg_dump backups (e.g. dcc-backups-mainnet)" default="" />
# <UDF name="BACKUP_OBJ_ENDPOINT"   label="Object storage endpoint for rclone S3 provider (e.g. us-east-1.linodeobjects.com)" default="" />
# ────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Logging ──────────────────────────────────────────────────────────────────
# Redirect stdout/stderr to bootstrap.log. The log is restricted to root:adm
# (mode 0640) because credential-related commands may echo sensitive values.
# We use `set +x` before credential operations as an additional safeguard.
exec > >(tee /var/log/bootstrap.log) 2>&1
chmod 640 /var/log/bootstrap.log

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

# ── Automatic security updates ───────────────────────────────────────────────
# Applies security-only OS patches automatically.
# Reboots are intentionally suppressed — we control restarts via deploys.
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

# ── fail2ban (SSH brute-force protection) ────────────────────────────────────
apt-get install -y -qq fail2ban
# SSH jail: 5 failures in 10 min → 1-hour ban.
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
echo "[bootstrap] fail2ban enabled: SSH jail active (5 retries / 10 min → 1 h ban)"

# ── Directory structure ───────────────────────────────────────────────────────
install -d -m 755 -o deploy -g deploy \
  /opt/dcc/compose \
  /opt/dcc/secrets \
  /opt/dcc/data/node-wallet-${NETWORK} \
  /opt/dcc/data/matcher-${NETWORK} \
  /opt/dcc/config/matcher-${NETWORK} \
  /opt/dcc/caddy

# Backup directory: postgres-owned (pg_dump writes here via cron).
install -d -m 750 -o postgres -g postgres /opt/dcc/backups

# Scripts directory: root-owned, executable by the system cron subsystem.
install -d -m 755 /opt/dcc/scripts

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
#
# Suppress trace/verbose output during secret operations (Audit P6 CRITICAL-1).
set +x 2>/dev/null || true
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
echo "[bootstrap] Server secrets written to /opt/dcc/secrets/${NETWORK}.env"

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

# Suppress trace output during credential operations (Audit P6 CRITICAL-1).
set +x 2>/dev/null || true
sudo -u postgres psql -c "
  DO \$\$
  BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'dcc') THEN
      CREATE ROLE dcc LOGIN PASSWORD '${POSTGRES_PASSWORD}';
    END IF;
  END
  \$\$;
" >/dev/null 2>&1

sudo -u postgres psql -tc \
  "SELECT 1 FROM pg_database WHERE datname = 'dcc_${NETWORK}'" \
  | grep -q 1 || \
  sudo -u postgres createdb -O dcc "dcc_${NETWORK}"

# ── PostgreSQL hardening (Audit P6 LOW-3) ────────────────────────────────────
# Enforce scram-sha-256 instead of md5 for password hashing.
# Enable connection logging for security audit trail.
sudo -u postgres psql -c "ALTER SYSTEM SET password_encryption = 'scram-sha-256';" >/dev/null 2>&1
sudo -u postgres psql -c "ALTER SYSTEM SET log_connections = on;" >/dev/null 2>&1
sudo -u postgres psql -c "ALTER SYSTEM SET log_disconnections = on;" >/dev/null 2>&1
systemctl reload postgresql
echo "[bootstrap] PostgreSQL hardened: scram-sha-256, connection logging enabled"

# ── rclone v1.74.2 (for PostgreSQL off-site backup) ─────────────────────────
# Install from the official Debian package — no curl-pipe-to-sh pattern.
# Only installed if BACKUP_OBJ_BUCKET is non-empty; safe no-op otherwise.
if [[ -n "${BACKUP_OBJ_BUCKET:-}" ]]; then
  echo "[bootstrap] Installing rclone for off-site backup..."
  RCLONE_DEB="rclone-v1.74.2-linux-amd64.deb"
  RCLONE_URL="https://github.com/rclone/rclone/releases/download/v1.74.2/${RCLONE_DEB}"
  # SHA-256 of rclone-v1.74.2-linux-amd64.deb (from rclone.org SHA256SUMS)
  RCLONE_SHA256="$(curl -fsSL https://github.com/rclone/rclone/releases/download/v1.74.2/SHA256SUMS \
    | grep "${RCLONE_DEB}" | awk '{print $1}')"
  curl -fsSL "${RCLONE_URL}" -o "/tmp/${RCLONE_DEB}"
  echo "${RCLONE_SHA256}  /tmp/${RCLONE_DEB}" | sha256sum --check --status \
    || { echo "[bootstrap] FATAL: rclone SHA256 mismatch — aborting"; exit 1; }
  dpkg -i "/tmp/${RCLONE_DEB}"
  rm -f "/tmp/${RCLONE_DEB}"
  echo "[bootstrap] rclone $(rclone version --check 2>/dev/null || rclone version | head -1) installed"

  # Write rclone config for the postgres OS user (cron runs as postgres).
  # Config uses environment variables for credentials — NOT stored in config file.
  # RCLONE_S3_ACCESS_KEY_ID and RCLONE_S3_SECRET_ACCESS_KEY are set in the cron env.
  install -d -m 700 -o postgres -g postgres /var/lib/postgresql/.config/rclone
  cat > /var/lib/postgresql/.config/rclone/rclone.conf << 'RCLONEEOF'
[dcc-backup]
type = s3
provider = Linode
env_auth = false
RCLONEEOF
  # Credentials are injected via env vars in pg-backup.sh — nothing sensitive in the config.
  chown postgres:postgres /var/lib/postgresql/.config/rclone/rclone.conf
  chmod 600 /var/lib/postgresql/.config/rclone/rclone.conf
  echo "[bootstrap] rclone config written for postgres user"
fi

# ── PostgreSQL daily backup ──────────────────────────────────────────────────
# Writes a compressed pg_dump to /opt/dcc/backups/ and rotates after 7 days.
# If BACKUP_OBJ_BUCKET is set, also uploads to Linode Object Storage via rclone.
# Runs at 02:00 UTC daily under the postgres OS user.
cat > /opt/dcc/scripts/pg-backup.sh << 'CRONEOF'
#!/usr/bin/env bash
# DCC PostgreSQL daily backup — rotate last 7 days, optional off-site upload.
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

# ── Off-site upload via rclone ─────────────────────────────────────────────
# Only runs if BACKUP_OBJ_BUCKET is non-empty.
# Credentials are injected via cron environment (Audit P6 CRITICAL-4).
# RCLONE_S3_ACCESS_KEY_ID and RCLONE_S3_SECRET_ACCESS_KEY are set in crontab,
# NOT embedded in this script.
BACKUP_OBJ_BUCKET="__BACKUP_OBJ_BUCKET__"
BACKUP_OBJ_ENDPOINT="__BACKUP_OBJ_ENDPOINT__"

if [[ -n "${BACKUP_OBJ_BUCKET}" && -n "${BACKUP_OBJ_ENDPOINT}" ]]; then
  # Credentials must be set in the cron environment — see crontab setup below.
  if [[ -z "${RCLONE_S3_ACCESS_KEY_ID:-}" || -z "${RCLONE_S3_SECRET_ACCESS_KEY:-}" ]]; then
    echo "[pg-backup] $(date -Iseconds) ERROR: rclone credentials not set in environment — skipping off-site upload" >&2
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
      # Off-site failure is non-fatal — local backup is already complete.
      echo "[pg-backup] $(date -Iseconds) WARNING: off-site upload failed (local backup preserved)" >&2
    fi
  fi
fi
CRONEOF
# Inject the actual network name and backup config at bootstrap time.
# All values are alphanumeric or empty — safe for sed substitution.
# Credentials are NOT embedded in the script — they are passed via crontab env.
sed -i "s/__NETWORK__/${NETWORK}/" /opt/dcc/scripts/pg-backup.sh
sed -i "s|__BACKUP_OBJ_BUCKET__|${BACKUP_OBJ_BUCKET:-}|" /opt/dcc/scripts/pg-backup.sh
sed -i "s|__BACKUP_OBJ_ENDPOINT__|${BACKUP_OBJ_ENDPOINT:-}|" /opt/dcc/scripts/pg-backup.sh
chmod 750 /opt/dcc/scripts/pg-backup.sh
chown postgres:postgres /opt/dcc/scripts/pg-backup.sh

# Install as postgres crontab (02:00 UTC daily).
# Backup credentials are passed via crontab environment variables — NOT embedded
# in the backup script. This prevents credential leakage via script file reads.
# (Audit P6 CRITICAL-4)
{
  if [[ -n "${BACKUP_OBJ_ACCESS_KEY:-}" && -n "${BACKUP_OBJ_SECRET_KEY:-}" ]]; then
    printf 'RCLONE_S3_ACCESS_KEY_ID=%s\n' "${BACKUP_OBJ_ACCESS_KEY}"
    printf 'RCLONE_S3_SECRET_ACCESS_KEY=%s\n' "${BACKUP_OBJ_SECRET_KEY}"
  fi
  printf '%s\n' "0 2 * * * /opt/dcc/scripts/pg-backup.sh >> /var/log/pg-backup.log 2>&1"
} | crontab -u postgres -
echo "[bootstrap] PostgreSQL daily backup cron installed (02:00 UTC, 7-day local retention${BACKUP_OBJ_BUCKET:+, off-site: ${BACKUP_OBJ_BUCKET}})"

# ── GHCR authentication for docker pull ──────────────────────────────────────
# GHCR login is handled per-deploy in deploy-container.yml by passing
# GHCR_TOKEN via appleboy/ssh-action envs: parameter. Nothing to configure here.

# ── Caddy TLS reverse proxy ──────────────────────────────────────────────────
# Caddy terminates HTTPS for scanner (→ localhost:3000) and data-service
# (→ localhost:8080). Certificates are obtained automatically from Let's Encrypt.
# SCANNER_DOMAIN and DATA_SERVICE_DOMAIN are optional UDF variables.
# If neither is set, Caddy is not configured (services are reachable via SSH
# tunnel or internal network only).
if [[ -n "${SCANNER_DOMAIN:-}" ]] || [[ -n "${DATA_SERVICE_DOMAIN:-}" ]]; then

  # ── Write Caddyfile ────────────────────────────────────────────────────────
  # Using printf (not heredoc) to safely embed UDF variables that may contain
  # special characters (same rationale as the secrets file above).
  {
    printf '# Generated by DCC bootstrap — do not edit manually\n'
    printf '{\n'
    # Restrict admin API to a Unix socket — prevents network-accessible config
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
      # OWASP 2026: disable the legacy XSS auditor — setting to 1 can itself
      # introduce XSS vulnerabilities in old browsers. Modern browsers ignore it.
      printf '        X-XSS-Protection "0"\n'
      # CSP for the block explorer SSR app (React Router v7 / Vite 8).
      # unsafe-inline in script-src is required for React Router's hydration
      # inline script (window.__DCC_CONFIG__) — no nonce provider at Caddy layer.
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
      printf '}\n'
    fi
  } > /opt/dcc/caddy/Caddyfile
  chmod 644 /opt/dcc/caddy/Caddyfile
  chown deploy:deploy /opt/dcc/caddy/Caddyfile
  echo "[bootstrap] Caddyfile written to /opt/dcc/caddy/Caddyfile"

  # ── Download caddy.yml and start Caddy ────────────────────────────────────
  # infra repo is public — no auth needed. This runs at bootstrap time so
  # Caddy is available before the first application deploy.
  curl -fsSL \
    "https://raw.githubusercontent.com/Decentral-America/infra/main/compose/caddy.yml" \
    -o /opt/dcc/compose/caddy.yml
  chown deploy:deploy /opt/dcc/compose/caddy.yml

  NETWORK="${NETWORK}" docker compose -f /opt/dcc/compose/caddy.yml up -d
  echo "[bootstrap] Caddy TLS reverse proxy started"
fi

echo "[bootstrap] Bootstrap complete. Network: $NETWORK, Chain ID: $CHAIN_ID"
