#!/bin/bash
# Roll ONE testnet LKE node to the ConfigMap + StatefulSet in a given nodes.yaml, then verify it.
# Usage: scripts/roll-testnet-node.sh <dcc-gen-0|dcc-gen-1|dcc-val-0> [path/to/nodes.yaml]
# Needs KUBECONFIG for cluster 663401, kubectl, jq, python3 + PyYAML. See runbooks/staggered-node-rollout.md.
set -u
NODE=$1; FILE=${2:-clusters/testnet/apps/nodes.yaml}; POD=$NODE-0
CM=${NODE#dcc-}-config
MAIN=https://testnet-node.decentralchain.io
TMP=$(mktemp)
python3 - "$FILE" "$NODE" "$CM" > "$TMP" <<'PY' || exit 1
import sys, yaml
f, node, cm = sys.argv[1:]
docs = [d for d in yaml.safe_load_all(open(f)) if d]
sel = [d for d in docs if (d['kind'], d['metadata']['name']) in (('ConfigMap', cm), ('StatefulSet', node))]
assert len(sel) == 2, f"expected ConfigMap {cm} + StatefulSet {node}, found {len(sel)}"
yaml.safe_dump_all(sel, sys.stdout, sort_keys=False)
PY
before=$(kubectl -n dcc get pod "$POD" -o jsonpath='{.status.startTime}')
# Same field manager as Flux, so the later Flux apply of the identical spec is a no-op.
kubectl apply --server-side --field-manager=kustomize-controller --force-conflicts -f "$TMP" || exit 1
kubectl -n dcc rollout status "statefulset/$NODE" --timeout=600s || exit 1
for i in $(seq 1 30); do
  m=$(curl -s -m 5 $MAIN/blocks/height | jq .height); mf=$(curl -s -m 5 $MAIN/blocks/height/finalized | jq .height)
  p=$(kubectl --request-timeout=15s -n dcc exec "$POD" -c node -- wget -qO- localhost:6869/blocks/height 2>/dev/null | jq .height)
  echo "$(date -u +%T) main=$m fin=$mf lag=$((m-mf)) $POD=$p"
  if [ -n "$p" ] && [ $((m-p)) -le 2 ] && [ $((m-mf)) -le 5 ] && [ "$i" -ge 3 ]; then break; fi
  sleep 20
done
echo "start: $before -> $(kubectl -n dcc get pod "$POD" -o jsonpath='{.status.startTime}')  (unchanged = nothing rolled)"
echo "image: $(kubectl -n dcc get pod "$POD" -o jsonpath='{.status.containerStatuses[0].imageID}')"
echo "restarts: $(kubectl -n dcc get pod "$POD" -o jsonpath='{.status.containerStatuses[0].restartCount}')"
logs=$(kubectl -n dcc logs "$POD" -c node --since=15m)
echo "InvalidStateHash: $(grep -c InvalidStateHash <<<"$logs")  class-linkage: $(grep -c -E 'NoSuchMethodError|NoClassDefFoundError|AbstractMethodError' <<<"$logs")"
rm -f "$TMP"
