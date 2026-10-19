#!/usr/bin/env bash
# The ONE way the VPS main node container is (re)created: docker compose with a
# digest-pinned image (node-config/<network>/vps-image.env). Runs ON the VPS;
# update-node-image.yml / deploy-node-config.yml / restart-host-network.yml pipe it over ssh.
#
# Fails closed (2026-10-18 audit: the old `docker run` copies ran under `set +e`
# and reported success with no node running). Success requires ALL of:
#   - compose `up --wait` returns (container healthy, see compose/node-scala.yml),
#   - the container is Running on exactly the requested image,
#   - no class-linkage error in its log,
#   - /blocks/height advances within ADVANCE_WINDOW_SECONDS.
# Always --force-recreate: callers run this to apply a new image, new plugin jars or a new
# dcc.conf (a bind-mounted file, invisible to compose's change detection).
# On failure it recreates the previous image (if there was one) and exits 1.
#
# Usage: node-up.sh <ghcr.io/...@sha256:<64 hex>> [network]
set -euo pipefail

IMG="${1:?usage: node-up.sh <image@sha256:digest> [network]}"
NETWORK="${2:-testnet}"
NAME="node-scala-${NETWORK}"
PROJECT="${NAME}"
COMPOSE="${COMPOSE_FILE_PATH:-/opt/dcc/compose/node-scala.yml}"
REST="${NODE_REST:-http://127.0.0.1:6869}"
WAIT_UP="${WAIT_UP_SECONDS:-600}"
ADVANCE_WINDOW="${ADVANCE_WINDOW_SECONDS:-300}"
POLL="${POLL_SECONDS:-15}"

die() { echo "::error::node-up: $*" >&2; exit 1; }
[[ "${IMG}" =~ @sha256:[0-9a-f]{64}$ ]] || die "image must be pinned by digest (got ${IMG})"
[[ -f "${COMPOSE}" ]] || die "${COMPOSE} not found"
(( POLL >= 1 )) || die "POLL_SECONDS must be >= 1"

height() { curl -sf -m 5 "${REST}/blocks/height" | python3 -c 'import json,sys; print(json.load(sys.stdin)["height"])'; }

up() {
  NODE_SCALA_IMAGE="$1" NETWORK="${NETWORK}" \
    docker compose -p "${PROJECT}" -f "${COMPOSE}" up -d --force-recreate --wait --wait-timeout "${WAIT_UP}" node-scala
}

verify() {
  local want="$1" running image linkage h1 h2 waited
  running="$(docker inspect -f '{{.State.Running}}' "${NAME}" 2>/dev/null || true)"
  [[ "${running}" == "true" ]] || { echo "node-up: ${NAME} is not running" >&2; return 1; }
  image="$(docker inspect -f '{{.Config.Image}}' "${NAME}" 2>/dev/null || true)"
  [[ "${image}" == "${want}" ]] || { echo "node-up: ${NAME} runs ${image}, expected ${want}" >&2; return 1; }
  linkage="$(docker logs --since 10m "${NAME}" 2>&1 | grep -cE 'NoSuchMethodError|NoClassDefFoundError|LinkageError|IncompatibleClassChangeError|AbstractMethodError' || true)"
  [[ "${linkage}" == "0" ]] || { echo "node-up: ${linkage} class-linkage error(s) in the node log" >&2; return 1; }
  h1="$(height)" || { echo "node-up: REST ${REST} not answering" >&2; return 1; }
  waited=0
  while (( waited < ADVANCE_WINDOW )); do
    sleep "${POLL}"; waited=$(( waited + POLL ))
    h2="$(height || echo "${h1}")"
    if (( h2 > h1 )); then echo "node-up: height ${h1} -> ${h2}"; return 0; fi
  done
  echo "node-up: height stuck at ${h1} for ${ADVANCE_WINDOW}s" >&2
  return 1
}

PREV="$(docker inspect -f '{{.Config.Image}}' "${NAME}" 2>/dev/null || true)"
echo "node-up: previous image: ${PREV:-<none>}; target: ${IMG}"
docker pull "${IMG}"

# One-time migration: a container created by `docker run` has no compose label,
# and compose cannot adopt it (name conflict). Remove it; the state volume stays.
LABEL="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "${NAME}" 2>/dev/null || true)"
if [[ -n "${PREV}" && "${LABEL}" != "${PROJECT}" ]]; then
  echo "node-up: removing ${NAME} (compose project '${LABEL:-<none>}' != '${PROJECT}'); volume node-state-${NETWORK} is kept"
  docker rm -f "${NAME}"
fi

if up "${IMG}" && verify "${IMG}"; then
  echo "node-up: OK ${NAME} on ${IMG}"
  exit 0
fi

echo "::error::node-up: deploy of ${IMG} failed" >&2
if [[ -n "${PREV}" && "${PREV}" != "${IMG}" ]]; then
  echo "node-up: rolling back to ${PREV}"
  if up "${PREV}" && verify "${PREV}"; then
    echo "node-up: rolled back to ${PREV}; the deploy itself FAILED"
  else
    echo "::error::node-up: rollback to ${PREV} also failed -- manual intervention required" >&2
  fi
fi
exit 1
