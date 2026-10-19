#!/usr/bin/env bash
# Tests for scripts/render-caddyfile.sh. Run: bash scripts/tests/render-caddyfile.test.sh
# `caddy validate` of the same output runs as a separate CI step (needs docker).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${ROOT}/scripts/render-caddyfile.sh"
TFVARS="${ROOT}/terraform/testnet.tfvars"
fail() { echo "FAIL: $*" >&2; exit 1; }

out="$(NODE_API_KEY=k-node E2E_BYPASS_KEY=k-bypass SELF_IP=192.0.2.10 bash "${SUT}" "${TFVARS}")"

# Every local upstream overwrites X-Real-IP with the TCP peer (data-service trusts that header).
n_local=$(grep -cE '^\s*reverse_proxy 127\.0\.0\.1:[0-9]+ \{$' <<<"${out}")
n_xrip=$(grep -cE '^\s*header_up X-Real-IP \{remote_host\}$' <<<"${out}")
[[ "${n_local}" -ge 8 ]] || fail "expected >= 8 local reverse_proxy blocks, got ${n_local}"
[[ "${n_local}" == "${n_xrip}" ]] || fail "${n_local} local upstreams but ${n_xrip} X-Real-IP overrides"
# No upstream through "localhost" (may resolve to ::1 once services bind 127.0.0.1 only).
if grep -qE 'reverse_proxy localhost' <<<"${out}"; then fail "localhost upstream present"; fi
# Edge rate limits on data-service and websocket hosts.
grep -q 'zone ds_per_ip' <<<"${out}" || fail "no ds_per_ip zone"
grep -q 'zone ws_per_ip' <<<"${out}" || fail "no ws_per_ip zone"
grep -q 'not remote_ip 192.0.2.10 127.0.0.1 ::1' <<<"${out}" || fail "self IP not exempt"
# Secrets appear only where intended.
[[ "$(grep -c 'k-node' <<<"${out}")" == "1" ]] || fail "node key must appear exactly once"
# Every site block logs through the redacted snippet (no raw access log leaking keys/query strings).
n_sites=$(grep -cE '^[^[:space:]#(}][^{]*\{$' <<<"${out}")
n_redacted=$(grep -cE '^\s*import redacted_log$' <<<"${out}")
[[ "${n_sites}" -ge 6 ]] || fail "expected >= 6 site blocks, got ${n_sites}"
[[ "${n_sites}" == "${n_redacted}" ]] || fail "${n_sites} site blocks but ${n_redacted} 'import redacted_log'"
# The matcher answers its own CORS headers; Caddy must strip them (else browsers see two values).
matcher_block=$(awk '/^[^[:space:]#(}][^{]*\{$/ {if (blk ~ /127\.0\.0\.1:6886/) {print blk}; blk=""} {blk = blk $0 "\n"} END {if (blk ~ /127\.0\.0\.1:6886/) print blk}' <<<"${out}")
[[ -n "${matcher_block}" ]] || fail "matcher site block (127.0.0.1:6886) not found"
grep -qE '^\s*header_down -Access-Control-Allow-Origin$' <<<"${matcher_block}" || fail "matcher does not strip Access-Control-Allow-Origin"
grep -qE '^\s*header_down -Access-Control-Allow-Credentials$' <<<"${matcher_block}" || fail "matcher does not strip Access-Control-Allow-Credentials"
# Node API denylist matchers must all exist.
for m in @admin_paths @admin_sign @admin_peers_write @wallet_write; do
  grep -qE "^\s*${m}( |\$)" <<<"${out}" || fail "node denylist matcher ${m} missing"
done
# Fail closed without SELF_IP.
if NODE_API_KEY=a E2E_BYPASS_KEY=b bash "${SUT}" "${TFVARS}" >/dev/null 2>&1; then fail "missing SELF_IP accepted"; fi
# AUD-140: Grafana may be framed only by the admin dashboard.
grep -q 'Content-Security-Policy "frame-ancestors https://testnet-admin.decentralchain.io"' <<<"${out}" || fail "grafana frame-ancestors"
echo "PASS render-caddyfile"
