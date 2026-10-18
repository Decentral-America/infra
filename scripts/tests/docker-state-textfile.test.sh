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
  ps) [[ "${STUB_MODE:-}" == empty ]] || printf 'c1\nc2\n' ;;
  inspect)
    printf '/grafana-testnet 4 true false\n'
    if [[ "${STUB_MODE:-}" == gone ]]; then
      echo "Error: No such object: c2" >&2; exit 1   # c2 removed between ps and inspect
    fi
    printf '/alloy-init-testnet 0 false true\n' ;;
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

# A container removed between `ps` and `inspect` must not abort the run; the others are still written.
g="${T}/gone/docker_state.prom"
STUB_MODE=gone PATH="${T}/bin:${PATH}" bash "${SUT}" "${g}" 2>/dev/null || fail "run aborted when a container vanished"
grep -qx 'dcc_container_restart_count{name="grafana-testnet"} 4' "${g}" || fail "surviving container missing"
if grep -q 'alloy-init-testnet' "${g}"; then fail "vanished container reported"; fi
# No containers at all: headers only, no samples, success.
e="${T}/empty/docker_state.prom"
STUB_MODE=empty PATH="${T}/bin:${PATH}" bash "${SUT}" "${e}" || fail "empty run failed"
grep -q '^# TYPE dcc_container_running gauge$' "${e}" || fail "empty: headers missing"
if grep -q '^dcc_container_' "${e}"; then fail "empty: unexpected samples"; fi
echo "PASS docker-state-textfile"
