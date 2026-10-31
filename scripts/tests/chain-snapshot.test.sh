#!/usr/bin/env bash
# Guard tests for scripts/chain-snapshot.sh: it must refuse to stop a committee member unless every
# precondition holds, before touching the cluster. Run: bash scripts/tests/chain-snapshot.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${ROOT}/scripts/chain-snapshot.sh"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "${T}/bin"
# kubectl stub: records calls; reports dcc-gen-1 as NOT ready.
cat > "${T}/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "kubectl $*" >> "${STUB_LOG}"
case " $* " in
  *" get statefulset dcc-gen-1 "*) echo 0 ;;
  *" get statefulset "*) echo 1 ;;
esac
STUB
chmod +x "${T}/bin/kubectl"
printf 'R2_BACKUP_ACCESS_KEY_ID=ak\nR2_BACKUP_SECRET_ACCESS_KEY=fake\nR2_BACKUP_ENDPOINT=https://x.example\n' > "${T}/cred.env"
run() { env PATH="${T}/bin:${PATH}" STUB_LOG="${T}/calls.log" CRED_FILE="${T}/cred.env" WORK_DIR="${T}/w" "$@" bash "${SUT}" testnet dcc-val-0; }

: > "${T}/calls.log"
if run >/dev/null 2>&1; then fail "ran without CONFIRM"; fi
[[ ! -s "${T}/calls.log" ]] || fail "touched the cluster without CONFIRM"
if run CONFIRM=STOP-dcc-gen-0 >/dev/null 2>&1; then fail "CONFIRM for another node accepted"; fi
if env PATH="${T}/bin:${PATH}" CONFIRM=STOP-dcc-val-0 CRED_FILE="${T}/cred.env" bash "${SUT}" mainnet dcc-val-0 >/dev/null 2>&1; then
  fail "non-testnet network accepted"
fi
# Another node not ready: abort in preflight, never scale or suspend anything.
: > "${T}/calls.log"
if run CONFIRM=STOP-dcc-val-0 >/dev/null 2>&1; then fail "ran with dcc-gen-1 not ready"; fi
if grep -qE 'scale|patch' "${T}/calls.log"; then fail "scaled or suspended with a node down"; fi
echo "PASS chain-snapshot"
