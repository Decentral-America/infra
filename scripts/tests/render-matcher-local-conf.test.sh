#!/usr/bin/env bash
# Tests for scripts/render-matcher-local-conf.sh. Run: bash scripts/tests/render-matcher-local-conf.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${ROOT}/scripts/render-matcher-local-conf.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

out="$(NETWORK=testnet CHAIN_ID=33 MATCHER_SEED_B64=c2VlZA== MATCHER_HASH=hash1 bash "${SUT}")"
grep -qx '  address-scheme-character = "!"' <<<"${out}" || fail "address scheme"
grep -qx '  account-storage.type = in-mem' <<<"${out}" || fail "in-mem storage"
grep -qx '  account-storage.in-mem.seed-in-base-64 = "c2VlZA=="' <<<"${out}" || fail "seed line"
grep -qx '  rest-api.api-key-hashes = \["hash1"\]' <<<"${out}" || fail "api key hash"
grep -qx '  rest-api.address = "127.0.0.1"' <<<"${out}" || fail "matcher REST must bind 127.0.0.1"
if grep -qE 'encrypted-file|redis\.address|postgres|password' <<<"${out}"; then fail "dead/unsafe block present"; fi
# Fail closed on a missing seed or an unknown chain id.
if NETWORK=testnet CHAIN_ID=33 MATCHER_SEED_B64='' MATCHER_HASH=h bash "${SUT}" >/dev/null 2>&1; then fail "empty seed accepted"; fi
if NETWORK=testnet CHAIN_ID=99 MATCHER_SEED_B64=s MATCHER_HASH=h bash "${SUT}" >/dev/null 2>&1; then fail "unknown chain accepted"; fi
# Single writer: no other file may hand-build the matcher config.
if grep -n "printf 'dcc.dex {" "${ROOT}/.github/workflows/push-secrets.yml" "${ROOT}/scripts/push-secrets-local.sh"; then
  fail "a second inline writer of local.conf exists (see above)"
fi
grep -q 'render-matcher-local-conf.sh' "${ROOT}/.github/workflows/push-secrets.yml" || fail "push-secrets.yml does not use the renderer"
grep -q 'render-matcher-local-conf.sh' "${ROOT}/scripts/push-secrets-local.sh" || fail "push-secrets-local.sh does not use the renderer"
echo "PASS render-matcher-local-conf"
