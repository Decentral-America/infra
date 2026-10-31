#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Local equivalent of push-secrets.yml — use when the GitHub Actions environment
# gate blocks the automated path (e.g. the 'testnet' environment requires manual
# approval but you need to push secrets immediately).
#
# Prerequisites:
#   - sops v3.13.1 installed (brew install sops / apt install sops)
#   - SOPS_AGE_KEY set to the age private key for this network (from KeeWeb)
#   - DEPLOY_SSH_KEY set to the base64-encoded Ed25519 deploy private key (from KeeWeb)
#     or the key file path set via --key-file <path>
#
# Usage:
#   export SOPS_AGE_KEY="AGE-SECRET-KEY-..."
#   export DEPLOY_SSH_KEY="<base64-encoded-private-key>"
#   ./scripts/push-secrets-local.sh testnet <server_ip>
#
#   # If you already have the decoded key file:
#   ./scripts/push-secrets-local.sh testnet <server_ip> --key-file ~/.ssh/dcc-testnet-deploy
#
# Getting the server IP:
#   dig +short testnet-node.decentralchain.io
#   # or from tofu state: (cd terraform && tofu output backend_ip)
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Args ──────────────────────────────────────────────────────────────────────
NETWORK="${1:-}"
SERVER_IP="${2:-}"
KEY_FILE=""

# Parse optional flags
shift 2 2>/dev/null || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --key-file) KEY_FILE="$2"; shift 2 ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

if [[ -z "${NETWORK}" || -z "${SERVER_IP}" ]]; then
  echo "Usage: $0 <network> <server_ip> [--key-file <path>]"
  echo "  network:   testnet | stagenet | mainnet"
  echo "  server_ip: IPv4 of the Linode backend server"
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_FILE="${REPO_ROOT}/secrets/${NETWORK}.env"

if [[ ! -f "${SECRETS_FILE}" ]]; then
  echo "[push-secrets] FATAL: secrets file not found: ${SECRETS_FILE}"
  exit 1
fi

# ── Validate env ──────────────────────────────────────────────────────────────
if [[ -z "${SOPS_AGE_KEY:-}" ]]; then
  echo "[push-secrets] FATAL: SOPS_AGE_KEY is not set."
  echo "  Export the age private key for ${NETWORK} from KeeWeb:"
  echo "    export SOPS_AGE_KEY=\"AGE-SECRET-KEY-...\""
  exit 1
fi

# ── SSH key setup ─────────────────────────────────────────────────────────────
TMPDIR_SECRETS="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_SECRETS}"' EXIT

if [[ -n "${KEY_FILE}" ]]; then
  if [[ ! -f "${KEY_FILE}" ]]; then
    echo "[push-secrets] FATAL: key file not found: ${KEY_FILE}"
    exit 1
  fi
  DEPLOY_KEY_FILE="${TMPDIR_SECRETS}/deploy_key"
  cp "${KEY_FILE}" "${DEPLOY_KEY_FILE}"
  chmod 600 "${DEPLOY_KEY_FILE}"
elif [[ -n "${DEPLOY_SSH_KEY:-}" ]]; then
  DEPLOY_KEY_FILE="${TMPDIR_SECRETS}/deploy_key"
  echo "${DEPLOY_SSH_KEY}" | base64 -d > "${DEPLOY_KEY_FILE}"
  chmod 600 "${DEPLOY_KEY_FILE}"
else
  echo "[push-secrets] FATAL: No deploy key provided."
  echo "  Either set DEPLOY_SSH_KEY (base64-encoded) or pass --key-file <path>."
  exit 1
fi

# Pinned host key only (ssh/known_hosts); refuse a host that is not pinned.
if ! grep -qE "^${SERVER_IP//./\\.} ssh-ed25519 " "${REPO_ROOT}/ssh/known_hosts"; then
  echo "[push-secrets] FATAL: ${SERVER_IP} has no pinned host key in ssh/known_hosts (see its header)"
  exit 1
fi
SSH="ssh -i ${DEPLOY_KEY_FILE} -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${REPO_ROOT}/ssh/known_hosts -o HostKeyAlgorithms=ssh-ed25519 -o ConnectTimeout=10 deploy@${SERVER_IP}"

# ── Verify SOPS is available ──────────────────────────────────────────────────
if ! command -v sops &>/dev/null; then
  echo "[push-secrets] FATAL: sops not found. Install with: brew install sops"
  exit 1
fi
echo "[push-secrets] Using sops $(sops --version 2>&1 | head -1)"

# ── Wait for SSH (up to 2 min — server should already be running) ─────────────
echo "[push-secrets] Testing SSH connectivity to ${SERVER_IP}..."
for i in $(seq 1 12); do
  if $SSH "echo ready" 2>/dev/null; then echo "[push-secrets] SSH ready."; break; fi
  [ "${i}" -eq 12 ] && { echo "[push-secrets] FATAL: SSH timeout after 2 min"; exit 1; }
  echo "[push-secrets] Waiting for SSH ($((i * 10))s)..."
  sleep 10
done

# ── Wait for bootstrap marker ─────────────────────────────────────────────────
echo "[push-secrets] Checking for bootstrap-complete marker..."
for i in $(seq 1 6); do
  if $SSH "test -f /opt/dcc/.bootstrap-complete" 2>/dev/null; then
    echo "[push-secrets] Bootstrap complete."; break
  fi
  [ "${i}" -eq 6 ] && { echo "[push-secrets] FATAL: bootstrap not complete after 1 min"; exit 1; }
  echo "[push-secrets] Waiting for bootstrap ($((i * 10))s)..."
  sleep 10
done

# ── Decrypt SOPS ──────────────────────────────────────────────────────────────
echo "[push-secrets] Decrypting ${SECRETS_FILE}..."
set +e
SECRETS=$(sops --decrypt "${SECRETS_FILE}" 2>&1)
SOPS_EXIT=$?
set -e
if [ "${SOPS_EXIT}" -ne 0 ]; then
  echo "[push-secrets] FATAL: SOPS decryption failed:"
  echo "${SECRETS}"
  exit 1
fi
echo "[push-secrets] SOPS decryption successful."

# ── Extract values ────────────────────────────────────────────────────────────
extract() { printf '%s' "${SECRETS}" | grep "^${1}=" | cut -d= -f2- || true; }

PG_PASS=$(        extract 'POSTGRES_PASSWORD')
WALLET_SEED=$(    extract 'MAIN_NODE_WALLET_SEED')
WALLET_PASS=$(    extract 'MAIN_NODE_WALLET_PASSWORD')
MATCHER_HASH=$(   extract 'MATCHER_API_KEY_HASH')
MATCHER_HASH_2=$( extract 'MATCHER_API_KEY_HASH_2')
REDIS_PASS=$(     extract 'REDIS_PASSWORD')
NODE_API_KEY=$(   extract 'MAIN_NODE_REST_API_KEY')
DEFAULT_MATCHER=$(extract 'DEFAULT_MATCHER')
DEFAULT_MATCHER_ADDRESS=$(extract 'DEFAULT_MATCHER_ADDRESS')
ADMIN_CLIENT_ID=$(extract 'ADMIN_DASHBOARD_GITHUB_OAUTH_CLIENT_ID')
ADMIN_CLIENT_SEC=$(extract 'ADMIN_DASHBOARD_GITHUB_OAUTH_CLIENT_SECRET')
ADMIN_JWT=$(      extract 'ADMIN_DASHBOARD_JWT_SECRET')
GITHUB_PAT=$(     extract 'ADMIN_DASHBOARD_GITHUB_PAT')
GRAFANA_URL=$(    extract 'GRAFANA_URL')
SENTRY_TOKEN=$(   extract 'SENTRY_AUTH_TOKEN')
TREASURY_SEED=$(  extract 'TREASURY_SEED')
DCC_RO_PASS=$(    extract 'DCC_RO_PASSWORD')       # Postgres role dcc_ro (data-service)
DCC_PAIRS_PASS=$( extract 'DCC_PAIRS_PASSWORD')    # Postgres role dcc_pairs (pairs daemon)
AM_SMTP_USER=$(   extract 'ALERTMANAGER_SMTP_USERNAME')  # Alertmanager email receiver
AM_SMTP_PASS=$(   extract 'ALERTMANAGER_SMTP_PASSWORD')
R2_BACKUP_KEY_ID=$(   extract 'R2_BACKUP_ACCESS_KEY_ID')   # off-account backups (DR.md)
R2_BACKUP_SECRET=$(   extract 'R2_BACKUP_SECRET_ACCESS_KEY')
R2_BACKUP_ENDPOINT=$( extract 'R2_BACKUP_ENDPOINT')

MATCHER_SEED_B64=$(extract 'MATCHER_SEED_BASE64')
# The matcher key comes from SOPS only (never read back from the live matcher: it echoes whatever
# key it runs on, including an empty-seed key).
if [[ -z "${DEFAULT_MATCHER:-}" || -z "${MATCHER_SEED_B64:-}" || -z "${DEFAULT_MATCHER_ADDRESS:-}" ]]; then
  echo "[push-secrets] FATAL: DEFAULT_MATCHER, MATCHER_SEED_BASE64 and DEFAULT_MATCHER_ADDRESS must all be in ${SECRETS_FILE}"
  exit 1
fi

echo "[push-secrets] Keys extracted: PG=${#PG_PASS} WALLET=${#WALLET_SEED} REDIS=${#REDIS_PASS} NODE_API=${#NODE_API_KEY} GRAFANA=${#GRAFANA_URL} SENTRY=${#SENTRY_TOKEN}"

# ── 1. Upsert secrets file on server ─────────────────────────────────────────
echo "[push-secrets] Uploading secrets patch..."
{
  printf '# Sensitive values — injected via SSH push (SOPS)\n'
  printf 'PGPASSWORD=%s\n'           "${PG_PASS}"
  printf 'POSTGRES__PASSWORD=%s\n'   "${PG_PASS}"
  printf 'DCC_WALLET_SEED=%s\n'      "${WALLET_SEED}"
  printf 'DCC_WALLET_PASSWORD=%s\n'  "${WALLET_PASS}"
  if [[ -n "${REDIS_PASS:-}" ]]; then
    printf 'REDIS_PASSWORD=%s\n'     "${REDIS_PASS}"
    printf 'REPO__PASSWORD=%s\n'     "${REDIS_PASS}"
    printf 'BPS_REDIS_URL=redis://:%s@127.0.0.1:6379/\n' "${REDIS_PASS}"  # BPS reads envy::prefixed("BPS_")
  fi
  [[ -n "${NODE_API_KEY:-}" ]] && printf 'MAIN_NODE_REST_API_KEY=%s\n' "${NODE_API_KEY}"
  # data-service's DEFAULT_MATCHER is the matcher ADDRESS, not the public key.
  printf 'DEFAULT_MATCHER=%s\n'                       "${DEFAULT_MATCHER_ADDRESS:?DEFAULT_MATCHER_ADDRESS missing from SOPS}"
  printf 'RATE_PAIR_ACCEPTANCE_VOLUME_THRESHOLD=%s\n' "${RATE_PAIR_ACCEPTANCE_VOLUME_THRESHOLD:-1}"
  printf 'RATE_THRESHOLD_ASSET_ID=%s\n'               "${RATE_THRESHOLD_ASSET_ID:-DCC}"
  if [[ -n "${ADMIN_CLIENT_ID:-}" ]]; then
    printf 'ADMIN_DASHBOARD_GITHUB_OAUTH_CLIENT_ID=%s\n'     "${ADMIN_CLIENT_ID}"
    printf 'ADMIN_DASHBOARD_GITHUB_OAUTH_CLIENT_SECRET=%s\n' "${ADMIN_CLIENT_SEC}"
    printf 'ADMIN_DASHBOARD_JWT_SECRET=%s\n'                 "${ADMIN_JWT}"
  fi
  [[ -n "${GITHUB_PAT:-}" ]] && printf 'ADMIN_DASHBOARD_GITHUB_PAT=%s\n' "${GITHUB_PAT}"
  [[ -n "${GRAFANA_URL:-}" ]]  && printf 'GRAFANA_URL=%s\n'        "${GRAFANA_URL}"
  [[ -n "${SENTRY_TOKEN:-}" ]] && printf 'SENTRY_AUTH_TOKEN=%s\n'  "${SENTRY_TOKEN}"
  # Last line of the group: an `if`, not `[[ ]] &&`, so an absent TREASURY_SEED does not make
  # the group return 1 and abort the script under `set -o pipefail`.
  if [[ -n "${TREASURY_SEED:-}" ]]; then printf 'TREASURY_SEED=%s\n' "${TREASURY_SEED}"; fi
  # Role passwords for data-service (dcc_ro) and the pairs daemon (dcc_pairs); the renderer
  # refuses to write those env files without them (fail closed).
  if [[ -n "${DCC_RO_PASS:-}" ]]; then printf 'DCC_RO_PASSWORD=%s\n' "${DCC_RO_PASS}"; fi
  if [[ -n "${DCC_PAIRS_PASS:-}" ]]; then printf 'DCC_PAIRS_PASSWORD=%s\n' "${DCC_PAIRS_PASS}"; fi
  # Alertmanager SMTP; the renderer fails closed without both (alertmanager-<network>.env).
  if [[ -n "${AM_SMTP_USER:-}" && -n "${AM_SMTP_PASS:-}" ]]; then
    printf 'ALERTMANAGER_SMTP_USERNAME=%s\nALERTMANAGER_SMTP_PASSWORD=%s\n' "${AM_SMTP_USER}" "${AM_SMTP_PASS}"
  fi
} | $SSH "sudo tee /tmp/secrets-patch.env > /dev/null && \
  sudo touch /opt/dcc/secrets/${NETWORK}.env && \
  sudo bash -c 'cat /tmp/secrets-patch.env /opt/dcc/secrets/${NETWORK}.env \
    | awk -F= \"!seen[\\\$1]++\" > /tmp/secrets-merged.env \
    && mv /tmp/secrets-merged.env /opt/dcc/secrets/${NETWORK}.env \
    && rm -f /tmp/secrets-patch.env \
    && chmod 640 /opt/dcc/secrets/${NETWORK}.env \
    && chown root:deploy /opt/dcc/secrets/${NETWORK}.env'"
echo "[push-secrets] Secrets file updated (upsert — no duplicates)."

# ── 1-seed. Seed-if-absent keys the per-service renderer requires ────────────
# A freshly provisioned host has none of these in the master file. An existing line is never
# overwritten (live values stay byte-identical). Values go over stdin, never into the log.
case "${NETWORK}" in
  testnet)  SEED_CHAIN_ID="33" ;;
  stagenet) SEED_CHAIN_ID="83" ;;
  mainnet)  SEED_CHAIN_ID="63" ;;
  *)        echo "[push-secrets] ERROR: unknown NETWORK '${NETWORK}' -- cannot derive DCC_CHAIN_ID"; exit 1 ;;
esac
# shellcheck disable=SC2016  # runs on the server, not here
SEED_SH='f=$1; [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ] && echo >> "$f"; while IFS= read -r l; do k=${l%%=*}; grep -q "^${k}=" "$f" || printf "%s\n" "$l" >> "$f"; done'
{
  printf 'DCC_CHAIN_ID=%s\n'                      "${SEED_CHAIN_ID}"
  printf 'ADMIN_DASHBOARD_PG_DATABASE=admin_%s\n' "${NETWORK}"
  if [[ -n "${REDIS_PASS:-}" ]]; then
    printf 'REDIS_URL=redis://:%s@127.0.0.1:6379/\n' "${REDIS_PASS}"
  fi
} | $SSH "sudo bash -c '${SEED_SH}' seed /opt/dcc/secrets/${NETWORK}.env"
echo "[push-secrets] Seeded absent DCC_CHAIN_ID / ADMIN_DASHBOARD_PG_DATABASE / REDIS_URL (existing lines untouched)."

# ── 1c. R2 backup credentials -> root-only env file (same as push-secrets.yml) ──
if [[ -n "${R2_BACKUP_KEY_ID:-}" && -n "${R2_BACKUP_SECRET:-}" && -n "${R2_BACKUP_ENDPOINT:-}" ]]; then
  printf 'R2_BACKUP_ACCESS_KEY_ID=%s\nR2_BACKUP_SECRET_ACCESS_KEY=%s\nR2_BACKUP_ENDPOINT=%s\n' \
    "${R2_BACKUP_KEY_ID}" "${R2_BACKUP_SECRET}" "${R2_BACKUP_ENDPOINT}" \
    | $SSH "sudo bash -c 'umask 077; cat > /opt/dcc/secrets/backup-${NETWORK}.env.new' && \
            sudo chown root:root /opt/dcc/secrets/backup-${NETWORK}.env.new && \
            sudo chmod 600 /opt/dcc/secrets/backup-${NETWORK}.env.new && \
            sudo mv -f /opt/dcc/secrets/backup-${NETWORK}.env.new /opt/dcc/secrets/backup-${NETWORK}.env"
  echo "[push-secrets] Backup credentials written (backup-${NETWORK}.env, 600 root)."
else
  echo "[push-secrets] WARNING: R2_BACKUP_* not all in SOPS: backup-${NETWORK}.env not written (DR.md)."
fi
unset R2_BACKUP_KEY_ID R2_BACKUP_SECRET

# ── 2. Set postgres password ──────────────────────────────────────────────────
$SSH "sudo -u postgres psql" << PGEOF
ALTER ROLE dcc WITH PASSWORD \$dccpw\$${PG_PASS}\$dccpw\$;
PGEOF
echo "[push-secrets] Postgres password set."

# ── 3. Write matcher local.conf (same renderer as push-secrets.yml) ──────────
CHAIN_ID=$($SSH "grep '^CHAIN_ID=' /opt/dcc/secrets/${NETWORK}.env | cut -d= -f2" || true)
if [[ -z "${CHAIN_ID}" ]]; then
  case "${NETWORK}" in
    testnet)  CHAIN_ID="33" ;;
    stagenet) CHAIN_ID="83" ;;
    mainnet)  CHAIN_ID="63" ;;
    *) echo "[push-secrets] FATAL: unknown network ${NETWORK}"; exit 1 ;;
  esac
fi
MATCHER_CONF=$(NETWORK="${NETWORK}" CHAIN_ID="${CHAIN_ID}" MATCHER_SEED_B64="${MATCHER_SEED_B64}" \
  MATCHER_HASH="${MATCHER_HASH}" MATCHER_HASH_2="${MATCHER_HASH_2}" bash "${REPO_ROOT}/scripts/render-matcher-local-conf.sh")
printf '%s\n' "${MATCHER_CONF}" | $SSH "sudo tee /opt/dcc/config/matcher-${NETWORK}/local.conf.new > /dev/null && \
  sudo chown root:113 /opt/dcc/config/matcher-${NETWORK}/local.conf.new && \
  sudo chmod 640 /opt/dcc/config/matcher-${NETWORK}/local.conf.new && \
  sudo mv -f /opt/dcc/config/matcher-${NETWORK}/local.conf.new /opt/dcc/config/matcher-${NETWORK}/local.conf"
unset MATCHER_CONF
echo "[push-secrets] Matcher config written (in-mem account storage)."

# ── 6. Per-service env files (same as push-secrets.yml) ───────────────────────
# Runs LAST so a missing required key cannot abort the postgres/matcher steps;
# the script still exits non-zero (below) if any service file was skipped.
RENDER_RC=0
$SSH "sudo OWNER=root:deploy bash -s -- ${NETWORK} /opt/dcc/secrets/${NETWORK}.env /opt/dcc/secrets" \
  < "${REPO_ROOT}/scripts/render-service-env.sh" || RENDER_RC=$?
if [[ "${RENDER_RC}" -eq 0 ]]; then
  echo "[push-secrets] Per-service env files written."
else
  echo "[push-secrets] FATAL: per-service env render failed (exit ${RENDER_RC}); see render-service-env lines above."
  exit "${RENDER_RC}"
fi

# ── 5. Inject backup credentials into postgres crontab ───────────────────────
echo ""
echo "[push-secrets] Done. All secrets pushed to ${NETWORK} @ ${SERVER_IP}."
echo "[push-secrets] Restart services to pick up new secrets:"
echo "  ssh deploy@${SERVER_IP} 'sudo systemctl restart dcc-stack'"
exit "${RENDER_RC}"
