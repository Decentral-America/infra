#!/usr/bin/env bash
# Tests for scripts/set-lke-node-ip.sh on a copy of the repo files. Run: bash scripts/tests/set-lke-node-ip.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "${T}/scripts" "${T}/clusters/testnet/apps" "${T}/node-config/testnet"
cp "${ROOT}/scripts/set-lke-node-ip.sh" "${ROOT}/scripts/config-checksums.py" "${T}/scripts/"
cp "${ROOT}/clusters/testnet/apps/nodes.yaml" "${T}/clusters/testnet/apps/"
cp "${ROOT}/node-config/testnet/dcc.conf" "${T}/node-config/testnet/"
OLD="$(grep -m1 -oE 'declared-address = "[0-9.]+:6863"' "${T}/clusters/testnet/apps/nodes.yaml" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')"
NEW=198.51.100.7
ANN_BEFORE="$(grep -c 'checksum/config' "${T}/clusters/testnet/apps/nodes.yaml")"

if bash "${T}/scripts/set-lke-node-ip.sh" not-an-ip >/dev/null 2>&1; then fail "invalid IP accepted"; fi
bash "${T}/scripts/set-lke-node-ip.sh" "${NEW}" >/dev/null
for port in 6863 6864 6865; do
  grep -q "declared-address = \"${NEW}:${port}\"" "${T}/clusters/testnet/apps/nodes.yaml" || fail "declared-address :${port} not rewritten"
done
[[ "$(grep -c "blacklist-exempt = \[\"50.116.30.244\", \"${NEW}\"\]" "${T}/clusters/testnet/apps/nodes.yaml")" == "3" ]] || fail "nodes.yaml blacklist-exempt"
grep -q "blacklist-exempt = \[\"50.116.30.244\", \"${NEW}\"\]" "${T}/node-config/testnet/dcc.conf" || fail "dcc.conf blacklist-exempt"
if grep -qF "${OLD}" "${T}/clusters/testnet/apps/nodes.yaml" "${T}/node-config/testnet/dcc.conf"; then fail "old IP left"; fi
grep -q '50.116.30.244' "${T}/node-config/testnet/dcc.conf" || fail "main IP clobbered"
(cd "${T}" && python3 scripts/config-checksums.py --check >/dev/null) || fail "checksums stale"
[[ "$(grep -c 'checksum/config' "${T}/clusters/testnet/apps/nodes.yaml")" == "${ANN_BEFORE}" ]] || fail "annotation count changed"
echo "PASS set-lke-node-ip"
