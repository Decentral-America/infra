#!/usr/bin/env bash
# Splits the host's master secrets file into one env file per service, so each
# container gets only the variables it reads (2026-10-18 audit: every container
# received the whole <network>.env, including org credentials).
#
# Values are copied byte-for-byte from the master file; nothing is generated
# or rotated here. A service whose required keys are missing from the master
# file is not written, and the script exits 1 (fail closed: compose then
# refuses to start that service instead of starting it without its config).
#
# Usage: render-service-env.sh <network> <master-env> <out-dir>
#   Writes <out-dir>/<service>-<network>.env, mode 640.
#   OWNER=root:deploy (optional) chowns each written file (needs root).
set -euo pipefail

NETWORK="${1:?usage: render-service-env.sh <network> <master-env> <out-dir>}"
MASTER="${2:?usage: render-service-env.sh <network> <master-env> <out-dir>}"
OUT_DIR="${3:?usage: render-service-env.sh <network> <master-env> <out-dir>}"
[[ -r "${MASTER}" ]] || { echo "render-service-env: cannot read ${MASTER}" >&2; exit 1; }

# Required keys per service. Keep in sync with the env_file entries in compose/*.yml.
required_keys() {
  case "$1" in
    node-scala)               echo "DCC_WALLET_SEED DCC_WALLET_PASSWORD" ;;
    scanner)                  echo "DCC_NODE_URL DCC_MATCHER_URL DCC_DATA_SERVICE_URL DCC_CHAIN_ID DCC_FAUCET_SEED REDIS_URL" ;;
    data-service)             echo "PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE DEFAULT_MATCHER RATE_PAIR_ACCEPTANCE_VOLUME_THRESHOLD RATE_THRESHOLD_ASSET_ID" ;;
    blockchain-postgres-sync) echo "BPS_BLOCKCHAIN_UPDATES_URL BPS_CHAIN_ID BPS_REDIS_URL POSTGRES__HOST POSTGRES__PORT POSTGRES__USER POSTGRES__PASSWORD POSTGRES__DATABASE" ;;
    websocket-api)            echo "REPO__PASSWORD" ;;
    admin-dashboard)          echo "ADMIN_DASHBOARD_GITHUB_OAUTH_CLIENT_ID ADMIN_DASHBOARD_GITHUB_OAUTH_CLIENT_SECRET ADMIN_DASHBOARD_JWT_SECRET ADMIN_DASHBOARD_GITHUB_PAT ADMIN_DASHBOARD_PG_DATABASE PGHOST PGPORT PGUSER PGPASSWORD DCC_NODE_URL GRAFANA_URL SENTRY_AUTH_TOKEN" ;;
    postgres-exporter)        echo "PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE" ;;
    alert-webhook)            echo "ADMIN_DASHBOARD_GITHUB_PAT" ;;
    *) echo "render-service-env: unknown service $1" >&2; return 1 ;;
  esac
}
# Optional keys: copied when present, never required.
optional_keys() {
  case "$1" in
    admin-dashboard) echo "TREASURY_SEED" ;;
    scanner)         echo "DCC_FAUCET_AMOUNT DCC_FAUCET_RATE_HOURS DCC_RECAPTCHA_SECRET IPINFO_TOKEN" ;;  # faucet defaults: 10 and 24
    data-service)    echo "MATCHER_SETTINGS_URL RATE_BASE_ASSET_ID LOG_LEVEL" ;;
    *) echo "" ;;
  esac
}
SERVICES="node-scala scanner data-service blockchain-postgres-sync websocket-api admin-dashboard postgres-exporter alert-webhook"

# First KEY=VALUE line for a key, verbatim (push-secrets dedupes the master file).
line_for() { grep -m1 -E "^$1=" "${MASTER}" || true; }

install -d -m 750 "${OUT_DIR}"
rc=0
for svc in ${SERVICES}; do
  out="${OUT_DIR}/${svc}-${NETWORK}.env"
  tmp="$(mktemp "${OUT_DIR}/.${svc}.XXXXXX")"
  missing=""
  {
    printf '# %s: generated from %s by scripts/render-service-env.sh. Do not edit.\n' "${svc}" "$(basename "${MASTER}")"
    for k in $(required_keys "${svc}"); do
      l="$(line_for "${k}")"
      if [[ -z "${l}" ]]; then missing="${missing} ${k}"; continue; fi
      printf '%s\n' "${l}"
    done
    for k in $(optional_keys "${svc}"); do
      l="$(line_for "${k}")"
      [[ -n "${l}" ]] && printf '%s\n' "${l}"
    done
  } > "${tmp}"
  if [[ -n "${missing}" ]]; then
    rm -f "${tmp}"
    echo "render-service-env: ${svc}: missing from ${MASTER}:${missing} -- ${out} NOT written" >&2
    rc=1
    continue
  fi
  chmod 640 "${tmp}"
  [[ -n "${OWNER:-}" ]] && chown "${OWNER}" "${tmp}"
  mv -f "${tmp}" "${out}"
  echo "render-service-env: wrote ${out} ($(grep -vc '^#' "${out}") keys)"
done
exit "${rc}"
