#!/usr/bin/env bash
# BOOTSTRAP ONLY, until the GitHub App credential is installed (push-credential.sh).
# Mints a 1-hour runner registration token with YOUR gh login (it can register runners to the matcher
# repository and nothing else), pushes it to the runner host over the pinned SSH session (stdin, never
# printed) and, with --loop, refreshes it every 40 minutes and sets MATCHER_CI_RUNNER_HEARTBEAT every
# 2 minutes while the host reports at least one registered runner (the host cannot set the variable
# itself without the App). Stop with Ctrl-C; the host stops registering new runners within an hour.
#   scripts/matcher-ci-runner/bootstrap-registration-token.sh [--loop]
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "$0")/common.sh"
push_token() {
  local json
  json=$(gh api -X POST "repos/${REPO}/actions/runners/registration-token")
  printf 'REGISTRATION_TOKEN=%s\nEXPIRES_AT=%s\n' "$(jq -r .token <<<"$json")" \
    "$(date -j -u -f '%Y-%m-%dT%H:%M:%S' "$(jq -r .expires_at <<<"$json" | cut -c1-19)" +%s 2>/dev/null || date -u -d "$(jq -r .expires_at <<<"$json")" +%s)" \
    | mci_ssh 'sudo install -m 0600 -o root -g root /dev/stdin /etc/matcher-ci/registration-token'
  echo "$(date -u +%TZ) registration token refreshed on $(mci_host)"
}
heartbeat() {
  local ready
  ready=$(mci_ssh 'ls /run/matcher-ci/ 2>/dev/null | grep -c "\.ready$" || true')
  if [ "${ready:-0}" -gt 0 ]; then gh variable set MATCHER_CI_RUNNER_HEARTBEAT -R "$REPO" --body "$(date +%s)" >/dev/null; fi
}
push_token
[ "${1:-}" = --loop ] || exit 0
last=$(date +%s)
while :; do
  heartbeat || echo "$(date -u +%TZ) heartbeat failed" >&2
  if [ $(( $(date +%s) - last )) -ge 2400 ]; then push_token || echo "token refresh failed" >&2; last=$(date +%s); fi
  sleep 120
done
