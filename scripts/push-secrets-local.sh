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

SSH="ssh -i ${DEPLOY_KEY_FILE} -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 deploy@${SERVER_IP}"

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
MATCHER_PASS=$(   extract 'MATCHER_ACCOUNT_PASSWORD')
MATCHER_HASH=$(   extract 'MATCHER_API_KEY_HASH')
MATCHER_SEED=$(   extract 'MATCHER_SEED')
BACKUP_KEY=$(     extract 'BACKUP_OBJ_ACCESS_KEY')
BACKUP_SECRET=$(  extract 'BACKUP_OBJ_SECRET_KEY')
REDIS_PASS=$(     extract 'REDIS_PASSWORD')
NODE_API_KEY=$(   extract 'MAIN_NODE_REST_API_KEY')
DEFAULT_MATCHER=$(extract 'DEFAULT_MATCHER')
ADMIN_CLIENT_ID=$(extract 'ADMIN_DASHBOARD_GITHUB_OAUTH_CLIENT_ID')
ADMIN_CLIENT_SEC=$(extract 'ADMIN_DASHBOARD_GITHUB_OAUTH_CLIENT_SECRET')
ADMIN_JWT=$(      extract 'ADMIN_DASHBOARD_JWT_SECRET')
GITHUB_PAT=$(     extract 'ADMIN_DASHBOARD_GITHUB_PAT')
BACKUP_ACCESS=$(  extract 'BACKUP_OBJ_ACCESS_KEY')
BACKUP_SECRET_K=$(extract 'BACKUP_OBJ_SECRET_KEY')
BACKUP_BUCKET=$(  extract 'BACKUP_OBJ_BUCKET')
BACKUP_ENDPOINT=$(extract 'BACKUP_OBJ_ENDPOINT')
GRAFANA_URL=$(    extract 'GRAFANA_URL')
SENTRY_TOKEN=$(   extract 'SENTRY_AUTH_TOKEN')

if [[ -z "${DEFAULT_MATCHER:-}" ]]; then
  DEFAULT_MATCHER=$(curl -sf "https://${NETWORK}-matcher.decentralchain.io/matcher" 2>/dev/null | tr -d '"' || echo "")
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
    printf 'REDIS_URL=redis://:%s@127.0.0.1:6379/\n' "${REDIS_PASS}"
  fi
  [[ -n "${NODE_API_KEY:-}" ]] && printf 'MAIN_NODE_REST_API_KEY=%s\n' "${NODE_API_KEY}"
  printf 'DEFAULT_MATCHER=%s\n'                       "${DEFAULT_MATCHER}"
  printf 'RATE_PAIR_ACCEPTANCE_VOLUME_THRESHOLD=%s\n' "${RATE_PAIR_ACCEPTANCE_VOLUME_THRESHOLD:-1}"
  printf 'RATE_THRESHOLD_ASSET_ID=%s\n'               "${RATE_THRESHOLD_ASSET_ID:-DCC}"
  if [[ -n "${ADMIN_CLIENT_ID:-}" ]]; then
    printf 'ADMIN_DASHBOARD_GITHUB_OAUTH_CLIENT_ID=%s\n'     "${ADMIN_CLIENT_ID}"
    printf 'ADMIN_DASHBOARD_GITHUB_OAUTH_CLIENT_SECRET=%s\n' "${ADMIN_CLIENT_SEC}"
    printf 'ADMIN_DASHBOARD_JWT_SECRET=%s\n'                 "${ADMIN_JWT}"
  fi
  [[ -n "${GITHUB_PAT:-}" ]] && printf 'ADMIN_DASHBOARD_GITHUB_PAT=%s\n' "${GITHUB_PAT}"
  if [[ -n "${BACKUP_ACCESS:-}" ]]; then
    printf 'BACKUP_OBJ_ACCESS_KEY=%s\n'  "${BACKUP_ACCESS}"
    printf 'BACKUP_OBJ_SECRET_KEY=%s\n'  "${BACKUP_SECRET_K}"
    printf 'BACKUP_OBJ_BUCKET=%s\n'      "${BACKUP_BUCKET}"
    printf 'BACKUP_OBJ_ENDPOINT=%s\n'    "${BACKUP_ENDPOINT}"
  fi
  [[ -n "${GRAFANA_URL:-}" ]]  && printf 'GRAFANA_URL=%s\n'        "${GRAFANA_URL}"
  [[ -n "${SENTRY_TOKEN:-}" ]] && printf 'SENTRY_AUTH_TOKEN=%s\n'  "${SENTRY_TOKEN}"
} | $SSH "sudo tee /tmp/secrets-patch.env > /dev/null && \
  sudo touch /opt/dcc/secrets/${NETWORK}.env && \
  sudo bash -c 'cat /tmp/secrets-patch.env /opt/dcc/secrets/${NETWORK}.env \
    | awk -F= \"!seen[\\\$1]++\" > /tmp/secrets-merged.env \
    && mv /tmp/secrets-merged.env /opt/dcc/secrets/${NETWORK}.env \
    && rm -f /tmp/secrets-patch.env \
    && chmod 640 /opt/dcc/secrets/${NETWORK}.env \
    && chown root:deploy /opt/dcc/secrets/${NETWORK}.env'"
echo "[push-secrets] Secrets file updated (upsert — no duplicates)."

# ── 2. Set postgres password ──────────────────────────────────────────────────
$SSH "sudo -u postgres psql" << PGEOF
ALTER ROLE dcc WITH PASSWORD \$dccpw\$${PG_PASS}\$dccpw\$;
PGEOF
echo "[push-secrets] Postgres password set."

# ── 3. Write matcher local.conf ───────────────────────────────────────────────
MATCHER_PASS_ESC=$(printf '%s' "${MATCHER_PASS}" | python3 -c "
import sys, json
raw = sys.stdin.read()
print(json.dumps(raw)[1:-1], end='')
")
CHAIN_ID=$($SSH "grep '^CHAIN_ID=' /opt/dcc/secrets/${NETWORK}.env | cut -d= -f2")
case "${CHAIN_ID}" in
  63) ADDR_SCHEME="?" ;;
  83) ADDR_SCHEME="S" ;;
  33) ADDR_SCHEME="!" ;;
  *)  ADDR_SCHEME="D" ;;
esac
{
  printf '# DecentralChain DEX Matcher local config -- written by SSH push (SOPS)\n'
  printf 'dcc.dex {\n'
  printf '  address-scheme-character = "%s"\n'  "${ADDR_SCHEME}"
  printf '  dcc-blockchain-client.grpc.target = "127.0.0.1:6887"\n'
  printf '  dcc-blockchain-client.blockchain-updates-grpc.target = "127.0.0.1:6881"\n'
  printf '  account-storage {\n'
  printf '    type = "encrypted-file"\n'
  printf '    encrypted-file {\n'
  printf '      path = "/var/lib/decentralchain-dex/account.dat"\n'
  printf '      password = "%s"\n' "${MATCHER_PASS_ESC}"
  printf '    }\n'
  printf '  }\n'
  printf '  rest-api.api-key-hashes = ["%s"]\n' "${MATCHER_HASH}"
  printf '}\n'
} | $SSH "sudo tee /opt/dcc/config/matcher-${NETWORK}/local.conf > /dev/null && \
          sudo chmod 644 /opt/dcc/config/matcher-${NETWORK}/local.conf && \
          sudo chown root:deploy /opt/dcc/config/matcher-${NETWORK}/local.conf"
echo "[push-secrets] Matcher config written."

# ── 4. Generate matcher account.dat if MATCHER_SEED is set ───────────────────
if [[ -n "${MATCHER_SEED:-}" ]]; then
  MATCHER_IMAGE="ghcr.io/decentral-america/matcher:matcher-${NETWORK}-latest"
  GEN_SCRIPT="
    set -euo pipefail
    ACCOUNT_DAT=/opt/dcc/data/matcher-${NETWORK}/account.dat
    if [ -f \"\$ACCOUNT_DAT\" ]; then echo '[push-secrets] account.dat exists — skip.'; exit 0; fi
    if ! docker image inspect '${MATCHER_IMAGE}' >/dev/null 2>&1; then
      echo '[push-secrets] WARNING: matcher image not pulled — account.dat deferred.'; exit 0
    fi
    printf '%s\n%s\n%s\n' '${MATCHER_SEED}' '${MATCHER_PASS}' '${MATCHER_PASS}' \
      | docker run --rm -i --network none \
          -v /opt/dcc/data/matcher-${NETWORK}:/var/lib/decentralchain-dex \
          '${MATCHER_IMAGE}' \
          /usr/share/decentralchain-dex/bin/decentralchain-dex \
          create-account-storage \
          --output-directory /var/lib/decentralchain-dex \
          --seed-format raw-string
    echo '[push-secrets] account.dat created.'
  "
  $SSH "bash -s" <<< "${GEN_SCRIPT}"
fi

# ── 5. Inject backup credentials into postgres crontab ───────────────────────
if [[ -n "${BACKUP_KEY:-}" && -n "${BACKUP_SECRET:-}" ]]; then
  EXISTING_CRON=$($SSH "sudo crontab -u postgres -l 2>/dev/null | grep -v '^RCLONE' || true")
  {
    printf 'RCLONE_S3_ACCESS_KEY_ID=%s\n'     "${BACKUP_KEY}"
    printf 'RCLONE_S3_SECRET_ACCESS_KEY=%s\n' "${BACKUP_SECRET}"
    printf '%s\n' "${EXISTING_CRON}"
  } | $SSH "sudo crontab -u postgres -"
  echo "[push-secrets] Backup credentials injected into postgres crontab."
fi

echo ""
echo "[push-secrets] Done. All secrets pushed to ${NETWORK} @ ${SERVER_IP}."
echo "[push-secrets] Restart services to pick up new secrets:"
echo "  ssh deploy@${SERVER_IP} 'sudo systemctl restart dcc-stack'"
