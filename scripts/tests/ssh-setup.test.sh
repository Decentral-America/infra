#!/usr/bin/env bash
# Tests for scripts/ssh-setup.sh. Run: bash scripts/tests/ssh-setup.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${ROOT}/scripts/ssh-setup.sh"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
KEY=$'-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----'

# 1. Pinned host: raw key, strict config, pinned known_hosts.
HOME="${T}/h1" DEPLOY_KEY="${KEY}" bash "${SUT}" 50.116.30.244 >/dev/null
grep -qx '  StrictHostKeyChecking yes' "${T}/h1/.ssh/config" || fail "StrictHostKeyChecking not yes"
grep -q '^50.116.30.244 ssh-ed25519 ' "${T}/h1/.ssh/known_hosts" || fail "pinned key not installed"
head -1 "${T}/h1/.ssh/deploy_key" | grep -q 'BEGIN OPENSSH' || fail "raw key not written"
# 2. Base64 key is decoded.
HOME="${T}/h2" DEPLOY_KEY="$(printf '%s' "${KEY}" | base64 | tr -d '\n')" bash "${SUT}" 50.116.30.244 >/dev/null
head -1 "${T}/h2/.ssh/deploy_key" | grep -q 'BEGIN OPENSSH' || fail "base64 key not decoded"
# 3. Unpinned host is refused.
if HOME="${T}/h3" DEPLOY_KEY="${KEY}" bash "${SUT}" 192.0.2.99 >/dev/null 2>&1; then fail "unpinned host accepted"; fi
echo "PASS ssh-setup"
