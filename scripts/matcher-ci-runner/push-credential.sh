#!/usr/bin/env bash
# Installs the runner host's GitHub credential from SOPS (secrets/matcher-ci-runner.env) over SSH.
# GitHub App (GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, GITHUB_APP_PRIVATE_KEY_B64) or GITHUB_PAT.
# The values travel only over the pinned SSH session (stdin), are written root:root 0600, never printed,
# and never transit Linode (they are not in user data). Removes any bootstrap registration token.
#   scripts/matcher-ci-runner/push-credential.sh            (host from MCI_HOST or the Linode label)
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "$0")/common.sh"
cred=$(sops -d --input-type dotenv --output-type dotenv "$SECRETS" | grep -E '^(GITHUB_APP_ID|GITHUB_APP_INSTALLATION_ID|GITHUB_APP_PRIVATE_KEY_B64|GITHUB_PAT)=' || true)
if ! grep -q '^GITHUB_APP_PRIVATE_KEY_B64=' <<<"$cred" && ! grep -q '^GITHUB_PAT=' <<<"$cred"; then
  echo "no GitHub App or PAT in ${SECRETS}; see runbooks/matcher-ci-runner.md (create-github-app.sh)" >&2; exit 1
fi
printf '%s\n' "$cred" | mci_ssh 'sudo install -m 0600 -o root -g root /dev/stdin /etc/matcher-ci/credential.env \
  && sudo rm -f /etc/matcher-ci/registration-token /run/matcher-ci/installation-token \
  && sudo /opt/matcher-ci/mci-lib.sh cred-mode && sudo systemctl start matcher-ci-heartbeat.service'
echo "credential installed on $(mci_host)"
