#!/usr/bin/env bash
# Consistent chain-state snapshot of ONE LKE node to Cloudflare R2 (DR.md "Chain snapshot", ECO-85).
#
# The node's RocksDB (/var/lib/dcc/data on its chain-data PVC) is only consistent while the node is
# stopped: node-scala has no online checkpoint/export API (DebugApiRoute has none; the offline
# Exporter calls RDB.open, which takes the RocksDB LOCK, so it also needs the node stopped). This is
# the same stop -> tar data/ -> start method as the 2026-08 migrate-state-snapshot recovery.
#
# What it does, for StatefulSet <sts> (default dcc-val-0):
#   1. Preflight: all three LKE StatefulSets ready, main's finality lag <= MAX_LAG, CONFIRM set.
#   2. Suspends Flux (flux-system, then apps; runbooks/staggered-node-rollout.md) so a reconcile
#      cannot scale the node back up mid-copy. Restores the previous suspend state on exit.
#   3. Scales <sts> to 0, mounts its PVC in a short-lived loader pod, streams `tar czf - data`
#      to a local file, records sha256, uploads to
#        s3://dcc-<network>-backups/chain/<sts>/<UTC timestamp>-h<main height>.tar.gz (+ .sha256)
#   4. ALWAYS (trap) deletes the loader pod and scales <sts> back to 1, waits for Ready and for the
#      node to come back within MAX_LAG blocks of main.
#   5. Keeps the newest KEEP (default 7) snapshots for <sts>.
#
# STOPPING A COMMITTEE MEMBER: every LKE node is a generator. With val-0 stopped the committee runs
# on 3 of 4 members (no fault tolerance for the copy window, typically a few minutes). This is
# an Operator decision (DR.md); the script refuses to run without CONFIRM=STOP-<sts>.
#
# Requirements: kubectl (context = the <network> LKE cluster, e.g. from export-kubeconfig.yml), aws
# CLI, curl, jq. R2 credentials from a file (never argv): CRED_FILE with R2_BACKUP_ACCESS_KEY_ID,
# R2_BACKUP_SECRET_ACCESS_KEY, R2_BACKUP_ENDPOINT (same keys as scripts/pg-backup.sh).
#
# Usage: CONFIRM=STOP-dcc-val-0 CRED_FILE=~/r2-backup-testnet.env scripts/chain-snapshot.sh testnet [sts]
set -euo pipefail

NETWORK="${1:?usage: chain-snapshot.sh <network> [statefulset]}"
STS="${2:-dcc-val-0}"
case "${NETWORK}" in
  testnet) MAIN_URL="${MAIN_URL:-https://testnet-node.decentralchain.io}" ;;
  *) echo "chain-snapshot: only testnet has an LKE committee today (got '${NETWORK}')" >&2; exit 2 ;;
esac
# Node REST port inside each pod (hostNetwork; bound to 127.0.0.1, clusters/testnet/apps/nodes.yaml).
case "${STS}" in
  dcc-gen-0) REST_PORT=6869 ;;
  dcc-gen-1) REST_PORT=6870 ;;
  dcc-val-0) REST_PORT=6871 ;;
  *) echo "chain-snapshot: unknown StatefulSet '${STS}'" >&2; exit 2 ;;
esac
[[ "${CONFIRM:-}" == "STOP-${STS}" ]] || {
  echo "chain-snapshot: refusing to stop committee member ${STS} without CONFIRM=STOP-${STS} (Operator decision, DR.md)" >&2
  exit 2
}

NS="${NS:-dcc}"
POD="${STS}-0"
PVC="chain-data-${STS}-0"
LOADER="snapshot-${STS}"
# Same pinned alpine as the archived migrate-state-snapshot.yml loader.
LOADER_IMAGE="${LOADER_IMAGE:-alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6}"
BUCKET="${BUCKET:-dcc-${NETWORK}-backups}"
KEEP="${KEEP:-7}"
MAX_LAG="${MAX_LAG:-20}"
WORK_DIR="${WORK_DIR:-$(mktemp -d)}"
CRED_FILE="${CRED_FILE:?CRED_FILE (R2 credentials file) is required}"

log() { printf '%s chain-snapshot[%s/%s]: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${NETWORK}" "${STS}" "$*"; }
die() { log "FATAL: $*"; exit 1; }

[[ -r "${CRED_FILE}" ]] || die "cannot read ${CRED_FILE}"
cred() { grep -m1 -E "^$1=" "${CRED_FILE}" | cut -d= -f2- || true; }
AWS_ACCESS_KEY_ID="$(cred R2_BACKUP_ACCESS_KEY_ID)"
AWS_SECRET_ACCESS_KEY="$(cred R2_BACKUP_SECRET_ACCESS_KEY)"
R2_ENDPOINT="$(cred R2_BACKUP_ENDPOINT)"
for v in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY R2_ENDPOINT; do [[ -n "${!v}" ]] || die "${v} empty in ${CRED_FILE}"; done
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION=auto
s3() { aws --endpoint-url "${R2_ENDPOINT}" "$@"; }
k() { kubectl -n "${NS}" "$@"; }

main_height() { curl -fsS -m 15 "${MAIN_URL}/blocks/height" | jq -r .height; }
main_lag() {
  local h f
  h="$(main_height)"; f="$(curl -fsS -m 15 "${MAIN_URL}/blocks/height/finalized" | jq -r .height)"
  echo $(( h - f ))
}
node_height() { k exec "${POD}" -c node -- wget -qO- "http://127.0.0.1:${REST_PORT}/blocks/height" 2>/dev/null | jq -r .height; }

# -- 1. Preflight ----------------------------------------------------------------------------------
for s in dcc-gen-0 dcc-gen-1 dcc-val-0; do
  r="$(k get statefulset "${s}" -o jsonpath='{.status.readyReplicas}')"
  [[ "${r}" == 1 ]] || die "${s} readyReplicas=${r:-0}; never stop a node while another is down"
done
lag="$(main_lag)"
(( lag <= MAX_LAG )) || die "main finality lag ${lag} > ${MAX_LAG}; finality is already degraded"
H0="$(main_height)"
log "preflight OK: 3/3 LKE nodes ready, main height ${H0}, finality lag ${lag}"

# -- 2. Flux suspend (parent first), restored on exit ------------------------------------------------
ks_suspended() { kubectl -n flux-system get kustomization "$1" -o jsonpath='{.spec.suspend}' 2>/dev/null || true; }
set_suspend() { kubectl -n flux-system patch kustomization "$1" --type merge -p "{\"spec\":{\"suspend\":$2}}" >/dev/null; }
PREV_FS="$(ks_suspended flux-system)"; PREV_APPS="$(ks_suspended apps)"
SCALED_DOWN=0
cleanup() {
  local st=$?
  set +e
  k delete pod "${LOADER}" --ignore-not-found --wait=true >/dev/null 2>&1
  if (( SCALED_DOWN )); then
    log "scaling ${STS} back to 1"
    k scale statefulset "${STS}" --replicas=1
    k rollout status statefulset "${STS}" --timeout=20m || log "ERROR: ${STS} not Ready after 20m -- investigate NOW"
  fi
  # Resume in reverse order (child, then parent), and only what this run suspended.
  [[ "${PREV_APPS}" == true ]] || set_suspend apps false
  [[ "${PREV_FS}" == true ]] || set_suspend flux-system false
  rm -rf "${WORK_DIR}"
  exit "${st}"
}
trap cleanup EXIT
set_suspend flux-system true
set_suspend apps true
log "Flux suspended (flux-system, apps)"

# -- 3. Stop, copy, upload --------------------------------------------------------------------------
SCALED_DOWN=1
k scale statefulset "${STS}" --replicas=0
k wait --for=delete "pod/${POD}" --timeout=5m || die "${POD} did not terminate"
log "${STS} stopped"
OV=$(jq -cn --arg img "${LOADER_IMAGE}" --arg pvc "${PVC}" '{spec:{
  securityContext:{runAsUser:999,runAsGroup:999,runAsNonRoot:true},
  containers:[{name:"loader",image:$img,command:["sh","-c","sleep 3600"],
    volumeMounts:[{name:"d",mountPath:"/var/lib/dcc",readOnly:true}]}],
  volumes:[{name:"d",persistentVolumeClaim:{claimName:$pvc,readOnly:true}}]}}')
k run "${LOADER}" --image="${LOADER_IMAGE}" --restart=Never --overrides="${OV}" --command -- sh -c "sleep 3600" >/dev/null
k wait --for=condition=Ready "pod/${LOADER}" --timeout=3m
STAMP="$(date -u +%Y-%m-%dT%H%M%SZ)"
NAME="${STAMP}-h${H0}.tar.gz"
f="${WORK_DIR}/${NAME}"
k exec "${LOADER}" -- tar czf - -C /var/lib/dcc data > "${f}"
k delete pod "${LOADER}" --wait=true >/dev/null
gzip -t "${f}" || die "archive failed gzip -t"
size="$(wc -c < "${f}" | tr -d ' ')"
(( size > 1000000 )) || die "archive only ${size} bytes; refusing to upload"
log "archive ${size} bytes; restarting ${STS} before the upload"
# Restart the node as soon as the copy is done; the upload does not need it stopped.
k scale statefulset "${STS}" --replicas=1
k rollout status statefulset "${STS}" --timeout=20m || die "${STS} not Ready after 20m"
SCALED_DOWN=0
sum="$(sha256sum "${f}" | cut -d' ' -f1)"
key="chain/${STS}/${NAME}"
s3 s3 cp --only-show-errors "${f}" "s3://${BUCKET}/${key}"
printf '%s  %s\n' "${sum}" "${NAME}" | s3 s3 cp --only-show-errors - "s3://${BUCKET}/${key%.tar.gz}.sha256"
log "uploaded s3://${BUCKET}/${key} sha256 ${sum}"

# -- 4. The node must come back to the tip -----------------------------------------------------------
for _ in $(seq 1 60); do
  nh="$(node_height || echo 0)"; mh="$(main_height)"
  (( mh - nh <= MAX_LAG )) && { log "${STS} back at ${nh} (main ${mh})"; break; }
  sleep 10
done
(( mh - nh <= MAX_LAG )) || die "${STS} at ${nh}, main at ${mh} after 10 min"

# -- 5. Retention ----------------------------------------------------------------------------------
keys="$(s3 s3api list-objects-v2 --bucket "${BUCKET}" --prefix "chain/${STS}/" --query 'Contents[].Key' --output text)"
keys="$(tr '\t' '\n' <<<"${keys}" | grep -E '\.tar\.gz$' | sort || true)"
n="$(grep -c . <<<"${keys}" || true)"
if (( n > KEEP )); then
  head -n "$(( n - KEEP ))" <<<"${keys}" | while IFS= read -r old; do
    s3 s3 rm "s3://${BUCKET}/${old}" >/dev/null
    s3 s3 rm "s3://${BUCKET}/${old%.tar.gz}.sha256" >/dev/null || true
    log "retention: deleted ${old}"
  done
fi
log "done"
