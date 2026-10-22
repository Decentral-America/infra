#!/usr/bin/env bash
# Runs every infra unit test. CI (ci.yml "Unit tests") and the local pre-push gate both call this.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"
rc=0
for t in scripts/tests/*.test.sh; do
  echo "== ${t}"
  bash "${t}" || rc=1
done
if compgen -G "monitoring/tests/test_*.py" >/dev/null; then
  echo "== monitoring/tests (python)"
  python3 -m unittest discover -s monitoring/tests -p 'test_*.py' || rc=1
fi
if compgen -G "clusters/testnet/apps/monitors/scripts/*.test.mjs" >/dev/null; then
  echo "== in-cluster monitors (node)"
  node --test clusters/testnet/apps/monitors/scripts/*.test.mjs || rc=1
fi
exit "${rc}"
