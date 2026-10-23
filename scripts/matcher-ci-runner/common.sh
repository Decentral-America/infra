#!/usr/bin/env bash
# Shared by the operator scripts in scripts/matcher-ci-runner/. Source it.
# Needs: sops + the testnet age key (SOPS_AGE_KEY_FILE), the runner's pinned host key in ssh/known_hosts.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SECRETS="${ROOT}/secrets/matcher-ci-runner.env"
KNOWN_HOSTS="${ROOT}/ssh/known_hosts"
export REPO="${MCI_REPO:-Decentral-America/matcher}"
: "${SOPS_AGE_KEY_FILE:=${HOME}/.config/sops/age/keys.txt}"; export SOPS_AGE_KEY_FILE

# Runner host IP: $MCI_HOST, else the Linode labelled dcc-matcher-ci-runner (linode-cli).
mci_host() {
  if [ -n "${MCI_HOST:-}" ]; then echo "$MCI_HOST"; return; fi
  linode-cli linodes list --label dcc-matcher-ci-runner --json | jq -r '.[0].ipv4[] | select(startswith("192.168.") | not)' | head -1
}

# One value from the SOPS file, decrypted in memory only.
mci_secret() { sops -d --extract "[\"$1\"]" "$SECRETS" 2>/dev/null; }

# ssh to ops@host with the ops key from SOPS (temp file, removed on exit) and the PINNED host key.
mci_ssh() {
  local host key; host=$(mci_host)
  key=$(mktemp); chmod 600 "$key"
  # shellcheck disable=SC2064
  trap "rm -f '$key'" RETURN
  mci_secret OPS_SSH_KEY_B64 | base64 -d > "$key"
  ssh -i "$key" -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" \
      -o BatchMode=yes -o ConnectTimeout=15 "ops@${host}" "$@"
}
