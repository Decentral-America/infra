#!/usr/bin/env bash
# Tests for scripts/docker-state-textfile.sh with a stubbed docker. Run: bash scripts/tests/docker-state-textfile.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${ROOT}/scripts/docker-state-textfile.sh"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "${T}/bin"
cat > "${T}/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  ps) printf 'c1\nc2\n' ;;
  inspect) printf '/grafana-testnet 4 true false\n/alloy-init-testnet 0 false true\n' ;;
esac
STUB
chmod +x "${T}/bin/docker"
PATH="${T}/bin:${PATH}" bash "${SUT}" "${T}/tf/docker_state.prom"
f="${T}/tf/docker_state.prom"
grep -qx 'dcc_container_restart_count{name="grafana-testnet"} 4' "${f}" || fail "restart count"
grep -qx 'dcc_container_running{name="grafana-testnet"} 1' "${f}" || fail "running"
grep -qx 'dcc_container_running{name="alloy-init-testnet"} 0' "${f}" || fail "not running"
grep -qx 'dcc_container_oom_killed{name="alloy-init-testnet"} 1' "${f}" || fail "oom"
[[ -z "$(find "${T}/tf" -name '.docker_state.*')" ]] || fail "temp file left behind"
echo "PASS docker-state-textfile"
