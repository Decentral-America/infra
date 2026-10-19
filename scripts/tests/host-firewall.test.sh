#!/usr/bin/env bash
# Structural checks for the VPS host firewall (AUD-052). CI also runs `nft -c` on both files.
# Run: bash scripts/tests/host-firewall.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
E="${ROOT}/host/nftables/dcc-host.nft"
O="${ROOT}/host/nftables/dcc-host-observe.nft"
for f in "${E}" "${O}"; do
  [[ -f "${f}" ]] || fail "missing ${f}"
  # Idempotent reload of our own table only; never a ruleset flush.
  grep -qx 'table inet dcc_host' "${f}" || fail "${f}: missing 'table inet dcc_host'"
  grep -qx 'delete table inet dcc_host' "${f}" || fail "${f}: missing 'delete table inet dcc_host'"
  if grep -v '^[[:space:]]*#' "${f}" | grep -q 'flush'; then fail "${f}: a flush would delete Docker/fail2ban rules"; fi
  grep -q 'hook input priority filter + 10;' "${f}" || fail "${f}: input hook"
  # Exactly the publicly needed ports: SSH, HTTP, HTTPS, P2P; HTTP/3 on udp/443.
  [[ "$(grep -c 'dport' "${f}")" == "2" ]] || fail "${f}: unexpected dport rules"
  grep -qx '    tcp dport { 22, 80, 443, 6868 } accept' "${f}" || fail "${f}: tcp allow set"
  grep -qx '    udp dport 443 accept' "${f}" || fail "${f}: udp/443"
  for r in 'iif "lo" accept' 'ct state established,related accept' 'meta l4proto icmp accept' 'meta l4proto ipv6-icmp accept' 'iifname "docker0" accept'; do
    grep -qF "    ${r}" "${f}" || fail "${f}: missing '${r}'"
  done
done
grep -q 'policy drop;' "${E}" || fail "enforce file must default-drop"
grep -q 'policy accept;' "${O}" || fail "observe file must not drop"
if grep -qE '\bdrop$' "${O}"; then fail "observe file drops packets"; fi
echo "PASS host-firewall"
