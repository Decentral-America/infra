#!/usr/bin/env bash
# Unit test for scripts/check-self-hosted-labels.py (the public-repo guard of the matcher self-hosted runners).
# Run: bash scripts/tests/check-self-hosted-labels.test.sh   (needs python3 + PyYAML)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
G="${ROOT}/scripts/check-self-hosted-labels.py"
FX="${ROOT}/scripts/tests/fixtures/self-hosted-guard"
fail() { echo "FAIL: $*" >&2; exit 1; }
python3 -c 'import yaml' 2>/dev/null || python3 -m pip install --quiet 'pyyaml==6.0.3'

python3 "$G" --path "$FX/ok" >/dev/null || fail "a clean workflow (comments and prose may mention the labels) was rejected"
for d in "$FX"/bad-*; do
  set +e; out=$(python3 "$G" --path "$d" 2>&1); rc=$?; set -e
  [[ $rc -eq 1 ]] || fail "$(basename "$d"): expected exit 1, got $rc: $out"
  grep -q '::error file=' <<<"$out" || fail "$(basename "$d"): no annotation"
done
# infra's own workflows must pass (infra is public).
python3 "$G" --path "${ROOT}/.github/workflows" >/dev/null || fail "infra's own workflows target the matcher runners"
echo "PASS check-self-hosted-labels ($(find "$FX" -maxdepth 1 -name 'bad-*' | wc -l | tr -d ' ') rejection cases)"
