#!/usr/bin/env bash
# One ephemeral runner, one job, then everything is deleted. systemd (matcher-ci-slot@N.service,
# Restart=always) starts the next one, so N slots always have a fresh runner waiting.
#
#   1. mint a registration token (never printed; passed to the container through a 0600 env file
#      that is deleted as soon as the container has started)
#   2. docker run --runtime=sysbox-runc: a NEW container with its own Docker daemon on a NEW
#      volume; registers with --ephemeral, takes exactly one job, exits
#   3. delete the container and the volume, verify nothing of the slot is left, export metrics
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=mci-lib.sh
source /opt/matcher-ci/mci-lib.sh

SLOT="${1:?slot number}"
STATE=/var/lib/matcher-ci
IMAGE=matcher-ci-runner:current
CNAME="mci-slot-${SLOT}"
install -d -m 0700 "$MCI_RUN" "$STATE"

counter() { local f="$STATE/slot-${SLOT}.$1"; echo $(( $(cat "$f" 2>/dev/null || echo 0) + ${2:-1} )) > "$f"; }
value() { cat "$STATE/slot-${SLOT}.$1" 2>/dev/null || echo 0; }

write_metrics() { # up(0/1)
  mci_metrics "matcher_ci_slot_${SLOT}" <<M
# HELP matcher_ci_runner_slot_up 1 while this slot has a registered runner container (idle or running a job).
# TYPE matcher_ci_runner_slot_up gauge
matcher_ci_runner_slot_up{slot="${SLOT}"} ${1}
# HELP matcher_ci_runner_slot_jobs_total Runner containers that ran to completion in this slot.
# TYPE matcher_ci_runner_slot_jobs_total counter
matcher_ci_runner_slot_jobs_total{slot="${SLOT}"} $(value jobs)
# HELP matcher_ci_runner_slot_cleanup_failures_total Jobs after which the slot's container or volume could not be removed.
# TYPE matcher_ci_runner_slot_cleanup_failures_total counter
matcher_ci_runner_slot_cleanup_failures_total{slot="${SLOT}"} $(value cleanup_failures)
# HELP matcher_ci_runner_slot_registration_failures_total Registration-token or container start failures.
# TYPE matcher_ci_runner_slot_registration_failures_total counter
matcher_ci_runner_slot_registration_failures_total{slot="${SLOT}"} $(value registration_failures)
# HELP matcher_ci_runner_slot_last_job_memory_peak_bytes cgroup memory.peak of the last finished runner container.
# TYPE matcher_ci_runner_slot_last_job_memory_peak_bytes gauge
matcher_ci_runner_slot_last_job_memory_peak_bytes{slot="${SLOT}"} $(value last_peak)
# HELP matcher_ci_runner_slot_last_job_seconds Lifetime of the last finished runner container.
# TYPE matcher_ci_runner_slot_last_job_seconds gauge
matcher_ci_runner_slot_last_job_seconds{slot="${SLOT}"} $(value last_seconds)
# HELP matcher_ci_runner_slot_ready_timestamp_seconds When the current runner reported "Listening for Jobs".
# TYPE matcher_ci_runner_slot_ready_timestamp_seconds gauge
matcher_ci_runner_slot_ready_timestamp_seconds{slot="${SLOT}"} $(value ready_ts)
M
}

# Leftovers of a crashed predecessor (host reboot, OOM-killed supervisor).
docker rm -f "$CNAME" >/dev/null 2>&1 || true
docker volume ls -q --filter "label=matcher-ci.slot=${SLOT}" | xargs -r docker volume rm -f >/dev/null || true
rm -f "$MCI_RUN/slot-${SLOT}.name" "$MCI_RUN/slot-${SLOT}.ready"
write_metrics 0

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  mci_log "slot ${SLOT}: runner image ${IMAGE} missing; building it"; /opt/matcher-ci/mci-image-build.sh
fi

if ! REG=$(mci_registration_token); then
  counter registration_failures; write_metrics 0
  sleep 60; exit 1
fi

NAME="mci-$(hostname -s)-s${SLOT}-$(date +%s)"
VOL="mci-s${SLOT}-$(date +%s)-${RANDOM}"
ENVF=$(mktemp "$MCI_RUN/env.XXXXXX"); chmod 600 "$ENVF"
cleanup_env() { rm -f "$ENVF"; }
trap cleanup_env EXIT
printf 'MCI_REG_TOKEN=%s\nMCI_RUNNER_NAME=%s\nMCI_REPO_URL=%s\nMCI_LABELS=%s\n' \
  "$REG" "$NAME" "$MCI_REPO_URL" "$MCI_LABELS" > "$ENVF"
unset REG

docker volume create --label "matcher-ci.slot=${SLOT}" "$VOL" >/dev/null
started=$(date +%s)
if ! CID=$(docker run -d --name "$CNAME" --hostname "$NAME" --runtime=sysbox-runc \
      --label "matcher-ci.slot=${SLOT}" \
      --memory "$MCI_SLOT_MEMORY" --memory-swap "$MCI_SLOT_MEMORY" --pids-limit 65536 \
      --env-file "$ENVF" -v "${VOL}:/var/lib/docker" "$IMAGE"); then
  cleanup_env; counter registration_failures
  docker rm -f "$CNAME" >/dev/null 2>&1 || true; docker volume rm -f "$VOL" >/dev/null 2>&1 || true
  write_metrics 0; sleep 30; exit 1
fi
cleanup_env
echo "$NAME" > "$MCI_RUN/slot-${SLOT}.name"
mci_log "slot ${SLOT}: started ${NAME} (container ${CID:0:12}, volume ${VOL})"

# Stream the runner's log to the journal; record readiness and the cgroup memory peak while it lives.
docker logs -f "$CID" 2>&1 | sed -u "s/^/[${NAME}] /" &
LOGPID=$!
cg="/sys/fs/cgroup/system.slice/docker-${CID}.scope"
peak=0; ready=0
while [ "$(docker inspect -f '{{.State.Running}}' "$CID" 2>/dev/null || echo false)" = true ]; do
  [ -r "$cg/memory.peak" ] && peak=$(cat "$cg/memory.peak" 2>/dev/null || echo "$peak")
  if [ "$ready" = 0 ] && docker logs "$CID" 2>&1 | grep -q "Listening for Jobs"; then
    ready=1; date +%s > "$STATE/slot-${SLOT}.ready_ts"; touch "$MCI_RUN/slot-${SLOT}.ready"
    write_metrics 1
  fi
  sleep 5
done
rc=$(docker inspect -f '{{.State.ExitCode}}' "$CID" 2>/dev/null || echo unknown)
kill "$LOGPID" 2>/dev/null || true
echo "$peak" > "$STATE/slot-${SLOT}.last_peak"
echo $(( $(date +%s) - started )) > "$STATE/slot-${SLOT}.last_seconds"
mci_log "slot ${SLOT}: ${NAME} exited ${rc} after $(value last_seconds)s, memory.peak $((peak / 1048576)) MiB"

# Nothing of this job may survive: the container (workspace, tool cache, credentials), and the volume
# that held its Docker daemon (images, containers, networks of the job).
docker rm -f "$CID" >/dev/null 2>&1 || true
docker volume rm -f "$VOL" >/dev/null 2>&1 || true
rm -f "$MCI_RUN/slot-${SLOT}.name" "$MCI_RUN/slot-${SLOT}.ready"
if /opt/matcher-ci/mci-verify-clean.sh "$SLOT" "$VOL"; then
  counter jobs
else
  counter jobs; counter cleanup_failures
fi
write_metrics 0
