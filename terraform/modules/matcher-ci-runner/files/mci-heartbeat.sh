#!/usr/bin/env bash
# Every 2 minutes (matcher-ci-heartbeat.timer):
#   * when at least one slot has a registered runner, sets the matcher repository variable
#     MATCHER_CI_RUNNER_HEARTBEAT to the current epoch. ci.yml's precheck reads it to decide, in
#     seconds and without spending minutes, whether the self-hosted runners are alive (a job for an
#     offline self-hosted label would otherwise sit queued for up to 24 hours).
#   * removes this host's OFFLINE runner registrations that no slot owns any more (a container that
#     died before taking a job leaves one behind);
#   * exports host-level metrics for the VPS Prometheus (alerts: monitoring/alerts.yml, matcher-ci group).
set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=mci-lib.sh
source /opt/matcher-ci/mci-lib.sh
install -d -m 0700 "$MCI_RUN"

now=$(date +%s)
mode=$(mci_cred_mode)
ready=0; for f in "$MCI_RUN"/slot-*.ready; do [ -e "$f" ] && ready=$((ready + 1)); done
active=$(systemctl list-units 'matcher-ci-slot@*' --state=active --no-legend --plain 2>/dev/null | wc -l | tr -d ' ')
last_ok=$(cat /var/lib/matcher-ci/heartbeat_ok_ts 2>/dev/null || echo 0)
api_ok=0; busy=-1; online=-1

if [ "$mode" = app ] || [ "$mode" = pat ]; then
  if [ "$ready" -gt 0 ]; then
    body=$(jq -cn --arg v "$now" '{name: "MATCHER_CI_RUNNER_HEARTBEAT", value: $v}')
    if mci_gh PATCH "repos/${MCI_REPO}/actions/variables/MATCHER_CI_RUNNER_HEARTBEAT" "$body" >/dev/null 2>&1 \
       || mci_gh POST "repos/${MCI_REPO}/actions/variables" "$body" >/dev/null 2>&1; then
      api_ok=1; last_ok=$now; echo "$now" > /var/lib/matcher-ci/heartbeat_ok_ts
    else
      mci_log "heartbeat: could not update MATCHER_CI_RUNNER_HEARTBEAT"
    fi
  fi
  if runners=$(mci_gh GET "repos/${MCI_REPO}/actions/runners?per_page=100" 2>/dev/null); then
    host="mci-$(hostname -s)-"
    owned=$(cat "$MCI_RUN"/slot-*.name 2>/dev/null || true)
    busy=$(printf '%s' "$runners" | jq --arg h "$host" '[.runners[] | select(.name | startswith($h)) | select(.busy)] | length')
    online=$(printf '%s' "$runners" | jq --arg h "$host" '[.runners[] | select(.name | startswith($h)) | select(.status == "online")] | length')
    printf '%s' "$runners" | jq -r --arg h "$host" '.runners[] | select(.name | startswith($h)) | select(.status == "offline") | "\(.id) \(.name)"' |
      while read -r id name; do
        if ! printf '%s\n' "$owned" | grep -qx "$name"; then
          mci_gh DELETE "repos/${MCI_REPO}/actions/runners/${id}" >/dev/null 2>&1 && mci_log "removed stale offline runner ${name}"
        fi
      done
  fi
fi

mode_num=0; case "$mode" in app) mode_num=3 ;; pat) mode_num=2 ;; regtoken) mode_num=1 ;; esac
mci_metrics matcher_ci <<M
# HELP matcher_ci_runner_slots_desired Ephemeral runner slots configured (MCI_SLOTS).
# TYPE matcher_ci_runner_slots_desired gauge
matcher_ci_runner_slots_desired ${MCI_SLOTS:-0}
# HELP matcher_ci_runner_slots_active Slot supervisor units currently active.
# TYPE matcher_ci_runner_slots_active gauge
matcher_ci_runner_slots_active ${active}
# HELP matcher_ci_runner_slots_registered Slots whose runner reported "Listening for Jobs" (idle or busy).
# TYPE matcher_ci_runner_slots_registered gauge
matcher_ci_runner_slots_registered ${ready}
# HELP matcher_ci_runner_busy Runners of this host that GitHub reports busy (-1: unknown, no API credential).
# TYPE matcher_ci_runner_busy gauge
matcher_ci_runner_busy ${busy}
# HELP matcher_ci_runner_online Runners of this host that GitHub reports online (-1: unknown).
# TYPE matcher_ci_runner_online gauge
matcher_ci_runner_online ${online}
# HELP matcher_ci_runner_credential_mode 3 GitHub App, 2 fine-grained PAT, 1 bootstrap registration token, 0 none.
# TYPE matcher_ci_runner_credential_mode gauge
matcher_ci_runner_credential_mode ${mode_num}
# HELP matcher_ci_runner_heartbeat_success_timestamp_seconds Last successful update of MATCHER_CI_RUNNER_HEARTBEAT.
# TYPE matcher_ci_runner_heartbeat_success_timestamp_seconds gauge
matcher_ci_runner_heartbeat_success_timestamp_seconds ${last_ok}
# HELP matcher_ci_runner_heartbeat_api_ok 1 if this tick reached the GitHub API.
# TYPE matcher_ci_runner_heartbeat_api_ok gauge
matcher_ci_runner_heartbeat_api_ok ${api_ok}
M
