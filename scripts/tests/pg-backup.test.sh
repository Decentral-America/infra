#!/usr/bin/env bash
# Tests for scripts/pg-backup.sh with stubbed runuser/pg_dump/pg_restore/curl. Run: bash scripts/tests/pg-backup.test.sh
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
# curl: records every call (including the -H @file contents' presence, not its value). Emulates the
# Worker: replies {"size":N} for the uploaded file, or fails like --fail for $STUB_CURL_FAIL.
cat > "${T}/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "${STUB_LOG}"
file="" out="" url="" hdrfile=""
while (( $# )); do
  case "$1" in
    -T) file="$2"; shift 2 ;;
    -o) out="$2"; shift 2 ;;
    -H) [[ "$2" == @* ]] && hdrfile="${2#@}"; shift 2 ;;
    --retry|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
grep -q '^Authorization: Bearer .' "${hdrfile}" || { echo "no auth header file" >&2; exit 22; }
[[ -n "${STUB_CURL_FAIL:-}" && "${url}" == *"${STUB_CURL_FAIL}"* ]] && { echo "curl: (22) The requested URL returned error: 401" >&2; exit 22; }
printf '{"key":"x","size":%s}' "$(wc -c < "${file}" | tr -d ' ')" > "${out}"
STUB
chmod +x "${T}/bin/"*

cred="${T}/backup-testnet.env"
printf 'BACKUP_WORKER_URL=https://w.example.workers.dev\nBACKUP_UPLOAD_TOKEN=test-secret-value-xyz\n' > "${cred}"
run() {
  env PATH="${T}/bin:${PATH}" STUB_LOG="${T}/calls.log" CRED_FILE="${cred}" WORK_DIR="${T}/work" \
    LOG_FILE="${T}/log/pg-backup.log" TEXTFILE="${T}/tf/dcc_pg_backup.prom" "$@" bash "${SUT}" testnet
}

# 1. Happy path: both databases dumped by name and PUT to the Worker as <db>-<stamp>.dump.
: > "${T}/calls.log"
run >/dev/null || fail "happy path exited non-zero"
grep -qx 'pg_dump bps_testnet' "${T}/calls.log" || fail "bps_testnet not dumped"
grep -qx 'pg_dump admin_testnet' "${T}/calls.log" || fail "admin_testnet not dumped"
grep -qE -- '-T [^ ]*/bps_testnet-[0-9]{8}T[0-9]{6}Z\.dump .*https://w\.example\.workers\.dev/backup/bps_testnet-[0-9]{8}T[0-9]{6}Z\.dump$' "${T}/calls.log" || fail "bps upload"
grep -qE 'backup/admin_testnet-[0-9]{8}T[0-9]{6}Z\.dump$' "${T}/calls.log" || fail "admin upload"
grep -q -- '--fail' "${T}/calls.log" || fail "curl --fail missing"
grep -qE -- '-H X-Content-SHA256: [0-9a-f]{64}' "${T}/calls.log" || fail "sha256 header missing"
f="${T}/tf/dcc_pg_backup.prom"
grep -qE '^dcc_backup_last_success_timestamp_seconds\{kind="pg",target="bps_testnet"\} [0-9]+$' "${f}" || fail "bps metric"
grep -qE '^dcc_backup_last_success_timestamp_seconds\{kind="pg",target="admin_testnet"\} [0-9]+$' "${f}" || fail "admin metric"
[[ -z "$(find "${T}/work" -name '*.dump')" ]] || fail "local dump left behind after success"
[[ ! -e "${T}/work/.auth-header" ]] || fail "auth header file left behind"
grep -q 'done: bps_testnet admin_testnet' "${T}/log/pg-backup.log" || fail "log file not written"
if grep -rq 'test-secret-value-xyz' "${T}/calls.log" "${T}/log"; then fail "token leaked to argv or log"; fi

# 2. A failed dump: exit non-zero, nothing uploaded for that DB, the other DB still backed up,
#    and the failed DB keeps its previous metric sample (so its age alerts).
: > "${T}/calls.log"
sed -i.bak 's/target="bps_testnet"} [0-9]*/target="bps_testnet"} 1000/' "${f}"
if run STUB_FAIL_DB=bps_testnet >/dev/null 2>&1; then fail "dump failure did not fail the run"; fi
if grep -q 'backup/bps_testnet-' "${T}/calls.log"; then fail "failed dump was uploaded"; fi
grep -qE 'backup/admin_testnet-.*\.dump$' "${T}/calls.log" || fail "other DB skipped after a failure"
grep -qx 'dcc_backup_last_success_timestamp_seconds{kind="pg",target="bps_testnet"} 1000' "${f}" || fail "failed DB lost its previous sample"
grep -q 'ERROR: backup of bps_testnet FAILED' "${T}/log/pg-backup.log" || fail "failure not logged"

# 2b. Worker rejects the upload (e.g. 401/413/422): exit non-zero, metric sample kept, local copy kept.
: > "${T}/calls.log"
if run STUB_CURL_FAIL=backup/admin_testnet >/dev/null 2>&1; then fail "upload failure did not fail the run"; fi
grep -q 'ERROR: backup of admin_testnet FAILED' "${T}/log/pg-backup.log" || fail "upload failure not logged"
grep -qE 'backup/bps_testnet-' "${T}/calls.log" || fail "other DB skipped after upload failure"
[[ -n "$(find "${T}/work" -name 'admin_testnet-*.dump')" ]] || fail "failed upload's local copy was removed"
if grep -rq 'test-secret-value-xyz' "${T}/log"; then fail "token leaked to log"; fi
rm -f "${T}"/work/*.dump

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
