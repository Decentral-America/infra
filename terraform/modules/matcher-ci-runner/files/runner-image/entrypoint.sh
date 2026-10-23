#!/usr/bin/env bash
# PID 1 of a runner container: start this job's own Docker daemon, register ONE ephemeral runner, run it.
set -euo pipefail
: "${MCI_REG_TOKEN:?}" "${MCI_RUNNER_NAME:?}" "${MCI_REPO_URL:?}" "${MCI_LABELS:?}"
token="$MCI_REG_TOKEN"; unset MCI_REG_TOKEN

dockerd --log-level=warn > /var/log/dockerd.log 2>&1 &
for _ in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 1; done
docker info >/dev/null 2>&1 || { echo "inner dockerd did not start"; tail -50 /var/log/dockerd.log; exit 1; }

cd /home/runner/actions-runner
runuser -u runner -- env HOME=/home/runner ./config.sh --unattended --ephemeral --disableupdate --replace \
  --url "$MCI_REPO_URL" --token "$token" --name "$MCI_RUNNER_NAME" --labels "$MCI_LABELS" --work _work
unset token
# run.sh exits after the one job (ephemeral); the container then stops and the slot deletes it.
exec runuser -u runner -- env HOME=/home/runner -u MCI_RUNNER_NAME -u MCI_REPO_URL -u MCI_LABELS ./run.sh
