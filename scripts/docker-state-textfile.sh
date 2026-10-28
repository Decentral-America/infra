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
  echo '# HELP dcc_container_memory_usage_bytes Working-set memory of the container (docker stats MemUsage, cache excluded).'
  echo '# TYPE dcc_container_memory_usage_bytes gauge'
  echo '# HELP dcc_container_memory_limit_bytes Memory limit of the container (docker stats); the host total when the container has none.'
  echo '# TYPE dcc_container_memory_limit_bytes gauge'
  # One sample per container. Feeds ContainerMemoryNearLimit, so a container is caught before the
  # kernel OOM-kills it (Grafana, 2026-10-11..27). Best effort: a failure here must not stop the state metrics.
  { timeout 20 docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' 2>/dev/null || true; } |
    awk '
      function bytes(v,   n, u) {
        n = v + 0; u = v; gsub(/[0-9.]/, "", u)
        if (u == "KiB") n *= 1024; else if (u == "MiB") n *= 1048576; else if (u == "GiB") n *= 1073741824
        else if (u == "kB") n *= 1000; else if (u == "MB") n *= 1000000; else if (u == "GB") n *= 1000000000
        return n
      }
      NF >= 4 && $3 == "/" {
        printf "dcc_container_memory_usage_bytes{name=\"%s\"} %.0f\n", $1, bytes($2)
        printf "dcc_container_memory_limit_bytes{name=\"%s\"} %.0f\n", $1, bytes($4)
      }'
  ids="$(docker ps -aq)"
  if [[ -n "${ids}" ]]; then
    # shellcheck disable=SC2086
    # A container can be removed between `ps` and `inspect`; inspect then exits non-zero for the
    # missing ID but still prints the others, so tolerate that (`|| true`) and skip it.
    { docker inspect -f '{{.Name}} {{.RestartCount}} {{.State.Running}} {{.State.OOMKilled}}' ${ids} 2>/dev/null || true; } |
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
