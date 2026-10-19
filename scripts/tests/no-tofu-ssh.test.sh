#!/usr/bin/env bash
# No workflow or script may bypass the pinned SSH host keys in ssh/known_hosts (AUD-047).
# The single allowed exception is push-secrets' trust_new_host_key path for a brand-new,
# not-yet-pinned server; those lines carry the marker `tofu-ok:`.
# Run: bash scripts/tests/no-tofu-ssh.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
hits="$(grep -rnE 'StrictHostKeyChecking[= ](no|accept-new)|ssh-keyscan' \
  "${ROOT}/.github/workflows" "${ROOT}/scripts" "${ROOT}/monitoring/scripts" \
  | grep -v 'tofu-ok:' | grep -v '/scripts/tests/' || true)"
if [[ -n "${hits}" ]]; then
  echo "${hits}"
  echo "FAIL: host-key checking is bypassed (see above); use scripts/ssh-setup.sh" >&2
  exit 1
fi
echo "PASS no-tofu-ssh"
