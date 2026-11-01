#!/usr/bin/env bash
# Daily logical backup of the VPS Postgres databases to Cloudflare R2 (DR.md, ECO-85).
#
# Dumps bps_<network> (BPS chain index; data-service reads it) and admin_<network> (admin dashboard)
# with pg_dump -Fc as the local `postgres` OS user (peer auth over the Unix socket, the same access
# bootstrap.sh uses), checks each dump with pg_restore --list, uploads it to
#   s3://dcc-<network>-backups/pg/<db>/<UTC timestamp>.dump   (plus a .sha256 next to it)
# and keeps the newest KEEP (default 7) dumps per database, deleting older ones.
#
# Credentials: R2 keys are read from a root-only env file, never from argv:
#   /opt/dcc/secrets/backup-<network>.env  (mode 600, root)
#     R2_BACKUP_ACCESS_KEY_ID, R2_BACKUP_SECRET_ACCESS_KEY, R2_BACKUP_ENDPOINT
#     (https://<cloudflare account id>.r2.cloudflarestorage.com)
#
# Success is exported for node-exporter's textfile collector:
#   dcc_backup_last_success_timestamp_seconds{kind="pg",target="<db>"}
#   dcc_backup_last_size_bytes{kind="pg",target="<db>"}
# A database whose backup failed keeps its previous sample, so its timestamp ages and an
# alert on `time() - dcc_backup_last_success_timestamp_seconds > 26h` catches it.
#
# Usage: pg-backup.sh <network>
# Scheduled by dcc-pg-backup@<network>.timer (host/systemd/, installed by terraform/scripts/bootstrap.sh).
# Exit status: 0 only if every database was dumped, verified, uploaded and pruned.
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
KEEP="${KEEP:-7}"
BUCKET="${BUCKET:-dcc-${NETWORK}-backups}"
DATABASES="${DATABASES:-bps_${NETWORK} admin_${NETWORK}}"

mkdir -p "$(dirname "${LOG_FILE}")"
exec > >(tee -a "${LOG_FILE}") 2>&1
log() { printf '%s pg-backup[%s]: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${NETWORK}" "$*"; }

[[ -r "${CRED_FILE}" ]] || { log "FATAL: cannot read ${CRED_FILE} (R2 credentials)"; exit 1; }
# Read only the three keys we need; the file is not sourced, so nothing in it is executed.
cred() { grep -m1 -E "^$1=" "${CRED_FILE}" | cut -d= -f2- || true; }
AWS_ACCESS_KEY_ID="$(cred R2_BACKUP_ACCESS_KEY_ID)"
AWS_SECRET_ACCESS_KEY="$(cred R2_BACKUP_SECRET_ACCESS_KEY)"
R2_ENDPOINT="$(cred R2_BACKUP_ENDPOINT)"
for v in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY R2_ENDPOINT; do
  [[ -n "${!v}" ]] || { log "FATAL: ${v} empty (missing key in ${CRED_FILE})"; exit 1; }
done
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
# R2 ignores the region but the SDK requires one; "auto" is what Cloudflare documents.
export AWS_DEFAULT_REGION=auto
s3() { aws --endpoint-url "${R2_ENDPOINT}" "$@"; }

install -d -m 700 "${WORK_DIR}"
STAMP="$(date -u +%Y-%m-%dT%H%M%SZ)"
rc=0

# Delete all but the newest KEEP objects under a prefix. Keys embed a sortable UTC timestamp.
prune() {
  local prefix="$1" keys n
  keys="$(s3 s3api list-objects-v2 --bucket "${BUCKET}" --prefix "${prefix}" \
            --query 'Contents[].Key' --output text)"
  keys="$(tr '\t' '\n' <<<"${keys}" | grep -E '\.dump$' | sort || true)"
  n="$(grep -c . <<<"${keys}" || true)"
  if (( n <= KEEP )); then log "retention ${prefix}: ${n} dump(s), nothing to delete"; return 0; fi
  head -n "$(( n - KEEP ))" <<<"${keys}" | while IFS= read -r k; do
    s3 s3 rm "s3://${BUCKET}/${k}" >/dev/null
    s3 s3 rm "s3://${BUCKET}/${k%.dump}.sha256" >/dev/null || true
    log "retention ${prefix}: deleted ${k}"
  done
}

backup_db() {
  local db="$1" f key sum size
  f="${WORK_DIR}/${db}-${STAMP}.dump"
  key="pg/${db}/${STAMP}.dump"
  log "dumping ${db}"
  runuser -u postgres -- pg_dump --format=custom --compress=6 "${db}" > "${f}"
  # A truncated or corrupt archive fails here, before anything is uploaded.
  pg_restore --list "${f}" > /dev/null
  size="$(wc -c < "${f}" | tr -d ' ')"
  sum="$(sha256sum "${f}" | cut -d' ' -f1)"
  s3 s3 cp --only-show-errors "${f}" "s3://${BUCKET}/${key}"
  printf '%s  %s\n' "${sum}" "${STAMP}.dump" | s3 s3 cp --only-show-errors - "s3://${BUCKET}/${key%.dump}.sha256"
  log "uploaded s3://${BUCKET}/${key} (${size} bytes, sha256 ${sum})"
  prune "pg/${db}/"
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
  rm -f "${WORK_DIR}/${db}-${STAMP}.dump"
done

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
