#!/usr/bin/env bash
# SECURITY.md "Per-service secrets" table must match what scripts/render-service-env.sh really renders.
# Renders every service from a master file that holds every key the renderer knows, then compares each
# <service>-testnet.env key set with the table row (order-insensitive; "optional" keys included).
# Run: bash scripts/tests/security-key-table.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${ROOT}/scripts/render-service-env.sh"
DOC="${ROOT}/SECURITY.md"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Every KEY the renderer can emit: the words inside its required/optional/db_role case arms.
keys="$(sed -n '/^required_keys()/,/^SERVICES=/p' "${SUT}" | grep -oE '\b[A-Z][A-Z0-9_]{2,}\b' | sort -u)"
for k in ${keys}; do printf '%s=x\n' "${k}"; done > "${T}/master.env"
bash "${SUT}" testnet "${T}/master.env" "${T}/out" >/dev/null || fail "renderer failed on the full master file"

table="$(sed -n '/<!-- key-table:begin -->/,/<!-- key-table:end -->/p' "${DOC}" | grep -E '^\| [a-z]')"
[[ -n "${table}" ]] || fail "key table not found in SECURITY.md"
services="$(sed -n 's/^SERVICES="\(.*\)"$/\1/p' "${SUT}")"
[[ "$(wc -l <<<"${table}" | tr -d ' ')" == "$(wc -w <<<"${services}" | tr -d ' ')" ]] || fail "table rows != renderer services (${services})"
for svc in ${services}; do
  row="$(grep -E "^\| ${svc} \|" <<<"${table}" || true)"
  [[ -n "${row}" ]] || fail "no SECURITY.md row for ${svc}"
  want="$(cut -d'|' -f3 <<<"${row}" | sed -E 's/\([^)]*\)//g; s/optional//g' | tr ';' ',' | tr ',' '\n' | tr -d ' ' | grep -v '^$' | sort -u)"
  got="$(grep -v '^#' "${T}/out/${svc}-testnet.env" | cut -d= -f1 | sort -u)"
  [[ "${want}" == "${got}" ]] || fail "${svc}: SECURITY.md lists [$(tr '\n' ' ' <<<"${want}")] but the renderer writes [$(tr '\n' ' ' <<<"${got}")]"
done
echo "PASS security-key-table"
