#!/usr/bin/env bash
# Writes per-container Docker state as Prometheus metrics for node-exporter's
# textfile collector (compose/prometheus.yml mounts / at /host and reads
# /host/var/lib/node_exporter/textfile). Run every minute by
# dcc-docker-state.timer (monitoring/systemd/). Feeds ContainerRestartLoop.
#
# Usage: docker-state-textfile.sh [out-file]
set -euo pipefail
OUT="${1:-/var/lib/node_exporter/textfile/docker_state.prom}"
DIR="$(dirname "${OUT}")"
mkdir -p "${DIR}"
TMP="$(mktemp "${DIR}/.docker_state.XXXXXX")"
trap 'rm -f "${TMP}"' EXIT

{
  echo '# HELP dcc_container_restart_count Docker RestartCount (automatic restarts by the restart policy) per container.'
  echo '# TYPE dcc_container_restart_count counter'
  echo '# HELP dcc_container_running 1 if the container is running.'
  echo '# TYPE dcc_container_running gauge'
  echo '# HELP dcc_container_oom_killed 1 if the container last exited because of an OOM kill.'
  echo '# TYPE dcc_container_oom_killed gauge'
  ids="$(docker ps -aq)"
  if [[ -n "${ids}" ]]; then
    # shellcheck disable=SC2086
    docker inspect -f '{{.Name}} {{.RestartCount}} {{.State.Running}} {{.State.OOMKilled}}' ${ids} |
      while read -r name restarts running oom; do
        name="${name#/}"
        echo "dcc_container_restart_count{name=\"${name}\"} ${restarts}"
        echo "dcc_container_running{name=\"${name}\"} $([[ "${running}" == "true" ]] && echo 1 || echo 0)"
        echo "dcc_container_oom_killed{name=\"${name}\"} $([[ "${oom}" == "true" ]] && echo 1 || echo 0)"
      done
  fi
} > "${TMP}"
chmod 644 "${TMP}"
mv -f "${TMP}" "${OUT}"
trap - EXIT
