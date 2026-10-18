#!/usr/bin/env bash
# CI SSH setup with a PINNED host key (ssh/known_hosts). Every workflow that
# talks to a server runs this once, then calls plain `ssh`/`scp`; the config
# written here enforces StrictHostKeyChecking=yes against the pinned key.
#
# Usage: DEPLOY_KEY=<OpenSSH private key, raw or base64> scripts/ssh-setup.sh <host>
# Writes ~/.ssh/deploy_key, ~/.ssh/known_hosts, ~/.ssh/config.
set -euo pipefail
HOST="${1:?usage: ssh-setup.sh <host>}"
: "${DEPLOY_KEY:?DEPLOY_KEY must be set}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN="${ROOT}/ssh/known_hosts"

if ! grep -qE "^${HOST//./\\.} ssh-ed25519 " "${PIN}"; then
  echo "::error::no pinned ssh-ed25519 host key for ${HOST} in ssh/known_hosts; add it via PR (see the file header)" >&2
  exit 1
fi

install -d -m 700 "${HOME}/.ssh"
if printf '%s' "${DEPLOY_KEY}" | grep -q -- '-----BEGIN '; then
  printf '%s\n' "${DEPLOY_KEY}" > "${HOME}/.ssh/deploy_key"
else
  printf '%s' "${DEPLOY_KEY}" | base64 -d > "${HOME}/.ssh/deploy_key"
fi
chmod 600 "${HOME}/.ssh/deploy_key"
grep -v '^#' "${PIN}" > "${HOME}/.ssh/known_hosts"
chmod 644 "${HOME}/.ssh/known_hosts"
cat > "${HOME}/.ssh/config" <<CFG
Host ${HOST}
  IdentityFile ${HOME}/.ssh/deploy_key
  IdentitiesOnly yes
  StrictHostKeyChecking yes
  UserKnownHostsFile ${HOME}/.ssh/known_hosts
  HostKeyAlgorithms ssh-ed25519
  ConnectTimeout 15
  ServerAliveInterval 30
CFG
chmod 600 "${HOME}/.ssh/config"
echo "ssh-setup: pinned host key for ${HOST} installed"
