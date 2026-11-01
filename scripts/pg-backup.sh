#!/usr/bin/env bash
# Daily logical backup of the VPS Postgres databases to Cloudflare R2 (DR.md, ECO-85).
#
# Dumps bps_<network> (BPS chain index; data-service reads it) and admin_<network> (admin dashboard)
# with pg_dump -Fc as the local `postgres` OS user (peer auth over the Unix socket, the same access
# bootstrap.sh uses), checks each dump with pg_restore --list, and uploads it through the Cloudflare
# Worker dcc-ops-monitor (PUT /backup/<db>-<UTC stamp>.dump), which stores it in R2 as
#   pg/<db>-<YYYYmmddTHHMMSSZ>.dump
# No S3 credentials exist on the VPS. The Worker verifies the X-Content-SHA256 we send and enforces
# retention (newest 7 per database, daily cron), so this script never deletes anything remotely.
# A dump larger than the Worker limit (95 MB) fails loudly; see DR.md before the databases grow.
#
# Credentials: read from a root-only env file, never from argv or the log:
#   /opt/dcc/secrets/backup-<network>.env  (mode 600, root)
#     BACKUP_WORKER_URL     (https://dcc-ops-monitor.<subdomain>.workers.dev)
#     BACKUP_UPLOAD_TOKEN   (bearer token; also the Worker secret of the same name)
#
# Success is exported for node-exporter's textfile collector:
#   dcc_backup_last_success_timestamp_seconds{kind="pg",target="<db>"}
#   dcc_backup_last_size_bytes{kind="pg",target="<db>"}
# A database whose backup failed keeps its previous sample, so its timestamp ages and an
# alert on `time() - dcc_backup_last_success_timestamp_seconds > 26h` catches it.
#
# Usage: pg-backup.sh <network>
# Scheduled by dcc-pg-backup@<network>.timer (host/systemd/, installed by terraform/scripts/bootstrap.sh).
# Exit status: 0 only if every database was dumped, verified and uploaded.
set -euo pipefail

NETWORK="${1:?usage: pg-backup.sh <network>}"
case "${NETWORK}" in
  testnet|stagenet|mainnet) ;;
  *) echo "pg-backup: unknown network '${NETWORK}'" >&2; exit 2 ;;
esac

CRED_FILE="${CRED_FILE:-/opt/dcc/secrets/backup-${NETWORK}.env}"
WORK_DIR="${WORK_DIR:-/var/backups/dcc}"
LOG_FILE="${LOG_FILE:-/var/log/dcc/pg-backup.log}"
TEXTFILE="${TEXTFILE:-/var/lib/node_exporter/textfile/dcc_pg_backup.prom}"
MAX_BYTES="${MAX_BYTES:-99614720}"   # 95 MiB, the Worker's per-upload limit
DATABASES="${DATABASES:-bps_${NETWORK} admin_${NETWORK}}"

mkdir -p "$(dirname "${LOG_FILE}")"
exec > >(tee -a "${LOG_FILE}") 2>&1
log() { printf '%s pg-backup[%s]: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${NETWORK}" "$*"; }

[[ -r "${CRED_FILE}" ]] || { log "FATAL: cannot read ${CRED_FILE} (backup Worker credentials)"; exit 1; }
# Read only the two keys we need; the file is not sourced, so nothing in it is executed.
cred() { grep -m1 -E "^$1=" "${CRED_FILE}" | cut -d= -f2- || true; }
BACKUP_WORKER_URL="$(cred BACKUP_WORKER_URL)"
BACKUP_UPLOAD_TOKEN="$(cred BACKUP_UPLOAD_TOKEN)"
for v in BACKUP_WORKER_URL BACKUP_UPLOAD_TOKEN; do
  [[ -n "${!v}" ]] || { log "FATAL: ${v} empty (missing key in ${CRED_FILE})"; exit 1; }
done
BACKUP_WORKER_URL="${BACKUP_WORKER_URL%/}"
[[ "${BACKUP_WORKER_URL}" == https://* ]] || { log "FATAL: BACKUP_WORKER_URL must be https://"; exit 1; }

install -d -m 700 "${WORK_DIR}"
# The bearer goes to curl through a 0600 header file, so it never appears in argv (ps) or the log.
AUTH_HDR="${WORK_DIR}/.auth-header"
trap 'rm -f "${AUTH_HDR}"' EXIT
( umask 077; printf 'Authorization: Bearer %s\n' "${BACKUP_UPLOAD_TOKEN}" > "${AUTH_HDR}" )
unset BACKUP_UPLOAD_TOKEN
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
rc=0

backup_db() {
  local db="$1" f name sum size resp code
  name="${db}-${STAMP}.dump"
  f="${WORK_DIR}/${name}"
  log "dumping ${db}"
  runuser -u postgres -- pg_dump --format=custom --compress=6 "${db}" > "${f}"
  # A truncated or corrupt archive fails here, before anything is uploaded.
  pg_restore --list "${f}" > /dev/null
  size="$(wc -c < "${f}" | tr -d ' ')"
  (( size > 0 )) || { log "ERROR: ${name} is empty"; return 1; }
  (( size <= MAX_BYTES )) || { log "ERROR: ${name} is ${size} bytes, over the Worker limit of ${MAX_BYTES} (DR.md)"; return 1; }
  sum="$(sha256sum "${f}" | cut -d' ' -f1)"
  resp="${WORK_DIR}/.resp-${db}"
  # --fail: any HTTP >= 400 (401 bad token, 413 too large, 422 hash mismatch) is a non-zero exit.
  curl --fail --silent --show-error --retry 3 --retry-all-errors --max-time 1800 \
       -T "${f}" -H "@${AUTH_HDR}" -H "X-Content-SHA256: ${sum}" \
       -o "${resp}" "${BACKUP_WORKER_URL}/backup/${name}"
  # The Worker echoes the stored size; it must equal what we sent.
  code="$(tr -d '\n' < "${resp}")"; rm -f "${resp}"
  [[ "${code}" == *"\"size\":${size}"* ]] || { log "ERROR: unexpected Worker reply for ${name}: ${code}"; return 1; }
  log "uploaded pg/${name} (${size} bytes, sha256 ${sum})"
  printf '%s %s\n' "$(date -u +%s)" "${size}" > "${WORK_DIR}/.ok-${db}"
}

for db in ${DATABASES}; do
  # Subshell: a failure in one database must not skip the other. Not in an `if`/`||` context,
  # where bash would silently disable errexit inside the subshell.
  rm -f "${WORK_DIR}/.ok-${db}"
  set +e
  ( set -euo pipefail; backup_db "${db}" )
  st=$?
  set -e
  if (( st != 0 )); then
    log "ERROR: backup of ${db} FAILED (exit ${st})"
    rm -f "${WORK_DIR}/.ok-${db}"
    rc=1
  fi
  # The local copy is removed once uploaded; after a failure it is kept for inspection or a manual
  # upload, and the find below drops such leftovers after 3 days so the disk cannot fill.
  (( st != 0 )) || rm -f "${WORK_DIR}/${db}-${STAMP}.dump"
done
find "${WORK_DIR}" -maxdepth 1 -name '*.dump' -mtime +3 -delete

# Textfile metrics: fresh samples for databases that succeeded; previous samples kept for the rest.
mkdir -p "$(dirname "${TEXTFILE}")"
tmp="$(mktemp "$(dirname "${TEXTFILE}")/.dcc_pg_backup.XXXXXX")"
{
  echo '# TYPE dcc_backup_last_success_timestamp_seconds gauge'
  echo '# TYPE dcc_backup_last_size_bytes gauge'
  for db in ${DATABASES}; do
    if [[ -f "${WORK_DIR}/.ok-${db}" ]]; then
      read -r ts size < "${WORK_DIR}/.ok-${db}"
      printf 'dcc_backup_last_success_timestamp_seconds{kind="pg",target="%s"} %s\n' "${db}" "${ts}"
      printf 'dcc_backup_last_size_bytes{kind="pg",target="%s"} %s\n' "${db}" "${size}"
      rm -f "${WORK_DIR}/.ok-${db}"
    elif [[ -f "${TEXTFILE}" ]]; then
      grep -F "{kind=\"pg\",target=\"${db}\"}" "${TEXTFILE}" || true
    fi
  done
} > "${tmp}"
chmod 644 "${tmp}"
mv -f "${tmp}" "${TEXTFILE}"

if (( rc == 0 )); then log "done: ${DATABASES}"; else log "done WITH FAILURES (exit ${rc})"; fi
exit "${rc}"
