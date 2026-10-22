#!/bin/bash
# One soak sample: height, finalized lag, committee size, InvalidStateHash counts,
# pod restarts and the canary's recent Job results. Appends one line to ${SOAK_DIR}/soak.log.
# Usage: SOAK_DIR=<dir> DEPLOY_KEY=<ssh key> scripts/soak-sample.sh
# Needs: curl, jq, ssh, kubectl, linode-cli (only to refresh the kubeconfig), gh.
set -uo pipefail
D="${SOAK_DIR:?set SOAK_DIR to the directory holding soak.log and the kubeconfig}"
KEY="${DEPLOY_KEY:?set DEPLOY_KEY to the testnet deploy SSH key}"
N=https://testnet-node.decentralchain.io
export KUBECONFIG="${D}/kc"
kubectl --request-timeout=20s -n dcc get pods >/dev/null 2>&1 || { linode-cli lke kubeconfig-view 663401 --text --no-headers | base64 -d > "${D}/kc"; chmod 600 "${D}/kc"; }
h=$(curl -s -m 10 "${N}/blocks/height" | jq .height); f=$(curl -s -m 10 "${N}/blocks/height/finalized" | jq .height)
c=$(curl -s -m 10 "${N}/generators/at/${h}" | jq length)
ish_main=$(ssh -o BatchMode=yes -o ConnectTimeout=10 -i "${KEY}" deploy@50.116.30.244 'docker logs --since 6h node-scala-testnet 2>&1 | grep -c InvalidStateHash' 2>/dev/null)
ish_lke=0; rs=""
for p in dcc-gen-0-0 dcc-gen-1-0 dcc-val-0-0; do
  n=$(kubectl --request-timeout=60s -n dcc logs "${p}" -c node --since=6h 2>/dev/null | grep -c InvalidStateHash); ish_lke=$((ish_lke+n))
  rs="${rs}$(kubectl --request-timeout=20s -n dcc get pod "${p}" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null),"
done
# The canary runs in-cluster now (CronJob canary-transaction); Kubernetes keeps only its last 5 Jobs.
canary=$(kubectl --request-timeout=20s -n dcc get jobs -l app=canary-transaction -o json 2>/dev/null | jq -r '[.items[] | select(.status.succeeded != null or .status.failed != null)] | "\(map(select(.status.succeeded == 1)) | length)/\(length)"')
echo "$(date -u +%FT%TZ) h=${h} fin=${f} lag=$((h-f)) committee=${c} ISH(main6h)=${ish_main} ISH(lke6h)=${ish_lke} podRestarts=${rs%,} canary(last5jobs)=${canary}" | tee -a "${D}/soak.log"
