#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal ${{ }} and backticks are the test data
# Tests for scripts/secrets-inventory.py (offline mode). Run: bash scripts/tests/secrets-inventory.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "${T}/infra/.github/workflows" "${T}/matcher/.github/workflows" "${T}/infra/.github/archived-workflows"
printf 'env:\n  K: ${{ secrets.USED_KEY }}\n' > "${T}/infra/.github/workflows/a.yml"
printf 'env:\n  K: ${{ secrets.USED_KEY }}\n  L: ${{ secrets.USED_KEY_TWO }}\n' > "${T}/matcher/.github/workflows/b.yaml"
printf 'env:\n  K: ${{ secrets.ONLY_ARCHIVED }}\n' > "${T}/infra/.github/archived-workflows/old.yml"
cat > "${T}/names.json" <<'JSON'
[{"scope": "org", "name": "USED_KEY", "updated": "2026-10-01"},
 {"scope": "infra repo", "name": "ONLY_ARCHIVED", "updated": "2026-06-01"},
 {"scope": "infra env testnet", "name": "USED_KEY_TWO", "updated": "2026-10-02"}]
JSON
out="$(python3 "${ROOT}/scripts/secrets-inventory.py" --eco "${T}" --names-file "${T}/names.json")"
grep -qF '| org | `USED_KEY` | 2026-10-01 | infra:a.yml, matcher:b.yaml |' <<<"${out}" || fail "USED_KEY refs"
grep -qF '| infra env testnet | `USED_KEY_TWO` | 2026-10-02 | matcher:b.yaml |' <<<"${out}" || fail "word boundary / env scope"
grep -qF '| infra repo | `ONLY_ARCHIVED` | 2026-06-01 | **unreferenced** |' <<<"${out}" || fail "archived refs must not count"
grep -qx '3 secrets, 1 unreferenced.' <<<"${out}" || fail "summary line"
echo "PASS secrets-inventory"
