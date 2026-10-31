#!/usr/bin/env bash
# Tests for scripts/pg-backup.sh with stubbed runuser/pg_dump/pg_restore/aws. Run: bash scripts/tests/pg-backup.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${ROOT}/scripts/pg-backup.sh"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "${T}/bin"

# runuser -u postgres -- pg_dump ... <db>: emits a fake archive, or fails for $STUB_FAIL_DB.
cat > "${T}/bin/runuser" <<'STUB'
#!/usr/bin/env bash
[[ "$1 $2 $3" == "-u postgres --" ]] || { echo "runuser: unexpected args $*" >&2; exit 9; }
shift 3
[[ "$1" == pg_dump ]] || { echo "runuser: expected pg_dump" >&2; exit 9; }
db="${!#}"
echo "pg_dump ${db}" >> "${STUB_LOG}"
[[ "${db}" == "${STUB_FAIL_DB:-}" ]] && { echo "pg_dump: connection failed" >&2; exit 1; }
printf 'PGDMP-%s' "${db}"
STUB
cat > "${T}/bin/pg_restore" <<'STUB'
#!/usr/bin/env bash
grep -q '^PGDMP' "${!#}"
STUB
# aws: records every call; list-objects-v2 returns the fake bucket listing in $STUB_KEYS_<db>.
cat > "${T}/bin/aws" <<'STUB'
#!/usr/bin/env bash
echo "aws $*" >> "${STUB_LOG}"
[[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]] || { echo "no creds" >&2; exit 1; }
args=" $* "
if [[ "${args}" == *" list-objects-v2 "* ]]; then
  case "${args}" in
    *"--prefix pg/bps_testnet/"*) printf '%s\n' "${STUB_KEYS_BPS:-None}" ;;
    *) echo None ;;
  esac
fi
exit 0
STUB
chmod +x "${T}/bin/"*

cred="${T}/backup-testnet.env"
printf 'R2_BACKUP_ACCESS_KEY_ID=ak\nR2_BACKUP_SECRET_ACCESS_KEY=test-secret-value-xyz\nR2_BACKUP_ENDPOINT=https://acct.r2.cloudflarestorage.com\n' > "${cred}"
run() {
  env PATH="${T}/bin:${PATH}" STUB_LOG="${T}/calls.log" CRED_FILE="${cred}" WORK_DIR="${T}/work" \
    LOG_FILE="${T}/log/pg-backup.log" TEXTFILE="${T}/tf/dcc_pg_backup.prom" "$@" bash "${SUT}" testnet
}

# 1. Happy path: both databases dumped by name, uploaded under pg/<db>/, 9 old dumps pruned to 7.
: > "${T}/calls.log"
keys=""; for d in 01 02 03 04 05 06 07 08 09; do keys+="pg/bps_testnet/2026-10-${d}T031500Z.dump	pg/bps_testnet/2026-10-${d}T031500Z.sha256	"; done
run STUB_KEYS_BPS="${keys}" >/dev/null || fail "happy path exited non-zero"
grep -qx 'pg_dump bps_testnet' "${T}/calls.log" || fail "bps_testnet not dumped"
grep -qx 'pg_dump admin_testnet' "${T}/calls.log" || fail "admin_testnet not dumped"
grep -qE 's3 cp --only-show-errors .*/bps_testnet-[0-9TZ-]+\.dump s3://dcc-testnet-backups/pg/bps_testnet/[0-9-]+T[0-9]{6}Z\.dump$' "${T}/calls.log" || fail "bps upload key"
grep -qE 's3://dcc-testnet-backups/pg/admin_testnet/[0-9-]+T[0-9]{6}Z\.dump$' "${T}/calls.log" || fail "admin upload key"
grep -q -- '--endpoint-url https://acct.r2.cloudflarestorage.com' "${T}/calls.log" || fail "R2 endpoint not used"
[[ "$(grep -c 's3 rm s3://dcc-testnet-backups/pg/bps_testnet/.*\.dump$' "${T}/calls.log")" == 2 ]] || fail "expected 2 old dumps deleted"
grep -q 's3 rm s3://dcc-testnet-backups/pg/bps_testnet/2026-10-01T031500Z.dump' "${T}/calls.log" || fail "oldest dump not deleted"
if grep -q 's3 rm s3://dcc-testnet-backups/pg/bps_testnet/2026-10-03T' "${T}/calls.log"; then fail "deleted a dump inside the keep window"; fi
f="${T}/tf/dcc_pg_backup.prom"
grep -qE '^dcc_backup_last_success_timestamp_seconds\{kind="pg",target="bps_testnet"\} [0-9]+$' "${f}" || fail "bps metric"
grep -qE '^dcc_backup_last_success_timestamp_seconds\{kind="pg",target="admin_testnet"\} [0-9]+$' "${f}" || fail "admin metric"
[[ -z "$(find "${T}/work" -name '*.dump')" ]] || fail "local dump left behind"
grep -q 'done: bps_testnet admin_testnet' "${T}/log/pg-backup.log" || fail "log file not written"
if grep -q 'test-secret-value-xyz' "${T}/calls.log"; then fail "secret key on an aws command line"; fi

# 2. A failed dump: exit non-zero, nothing uploaded for that DB, the other DB still backed up,
#    and the failed DB keeps its previous metric sample (so its age alerts).
: > "${T}/calls.log"
sed -i.bak 's/target="bps_testnet"} [0-9]*/target="bps_testnet"} 1000/' "${f}"
if run STUB_FAIL_DB=bps_testnet >/dev/null 2>&1; then fail "dump failure did not fail the run"; fi
if grep -q 'pg/bps_testnet/.*\.dump$' "${T}/calls.log"; then fail "failed dump was uploaded"; fi
grep -qE 's3://dcc-testnet-backups/pg/admin_testnet/.*\.dump$' "${T}/calls.log" || fail "other DB skipped after a failure"
grep -qx 'dcc_backup_last_success_timestamp_seconds{kind="pg",target="bps_testnet"} 1000' "${f}" || fail "failed DB lost its previous sample"
grep -q 'ERROR: backup of bps_testnet FAILED' "${T}/log/pg-backup.log" || fail "failure not logged"

# 3. Missing credentials: fail closed before dumping anything.
: > "${T}/calls.log"
if env PATH="${T}/bin:${PATH}" STUB_LOG="${T}/calls.log" CRED_FILE="${T}/nope.env" WORK_DIR="${T}/work" \
     LOG_FILE="${T}/log/pg-backup.log" TEXTFILE="${f}" bash "${SUT}" testnet >/dev/null 2>&1; then
  fail "missing credentials accepted"
fi
[[ ! -s "${T}/calls.log" ]] || fail "dumped without credentials"
# 4. Unknown network rejected.
if bash "${SUT}" devnet >/dev/null 2>&1; then fail "unknown network accepted"; fi
echo "PASS pg-backup"
