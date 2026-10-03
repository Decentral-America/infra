#!/usr/bin/env bash
# Fails if the node-scala testnet image digest differs between the VPS main
# node (node-config/testnet/vps-image.env, the single source of truth read by
# deploy-node-config.yml / restart-host-network.yml / update-node-image.yml)
# and the three LKE StatefulSets (gen-0 / gen-1 / val-0) in
# clusters/testnet/apps/nodes.yaml.
#
# Rule D6 (RELAUNCH-20260904.md section 5.3): every node on a chain runs the
# same binary. It was violated on paper from 2026-09-21 to 2026-10 (LKE on
# sha256:0346f624..., VPS on sha256:b0d559cf...) with nothing to flag it.
#
# Also fails if any workflow hardcodes a node-scala digest again instead of
# sourcing vps-image.env (the PR#88 "tag-drift bomb" class).
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE_RE='node-scala@sha256:[0-9a-f]{64}'
NODES=clusters/testnet/apps/nodes.yaml
VPS_ENV=node-config/testnet/vps-image.env
EXPECTED_LKE_REFS=3

fail() { echo "::error::$*"; exit 1; }

[ -f "$NODES" ] || fail "$NODES not found"
[ -f "$VPS_ENV" ] || fail "$VPS_ENV not found"

LKE_COUNT=$(grep -cE "$IMAGE_RE" "$NODES" || true)
[ "$LKE_COUNT" = "$EXPECTED_LKE_REFS" ] \
  || fail "expected $EXPECTED_LKE_REFS digest-pinned node-scala refs in $NODES, found $LKE_COUNT"
LKE=$(grep -oE "$IMAGE_RE" "$NODES" | sort -u)

# Source in a subshell so nothing else from the file leaks into this script.
# shellcheck disable=SC1090
VPS_IMAGE=$( (source "$VPS_ENV"; printf '%s' "${NODE_SCALA_IMAGE:-}") )
[ -n "$VPS_IMAGE" ] || fail "NODE_SCALA_IMAGE is empty after sourcing $VPS_ENV"
VPS=$(printf '%s\n' "$VPS_IMAGE" | grep -oE "$IMAGE_RE" || true)
[ -n "$VPS" ] || fail "NODE_SCALA_IMAGE in $VPS_ENV is not digest-pinned: $VPS_IMAGE"

echo "LKE (x$LKE_COUNT): $LKE"
echo "VPS:          $VPS"

[ "$(printf '%s\n' "$LKE" | wc -l | tr -d ' ')" = "1" ] \
  || fail "LKE StatefulSets in $NODES pin different node-scala digests: $(echo "$LKE" | tr '\n' ' ')"
[ "$LKE" = "$VPS" ] \
  || fail "node-scala digest differs between LKE ($LKE) and VPS ($VPS); update $VPS_ENV or $NODES so all four nodes match"

HARDCODED=$(grep -lE "$IMAGE_RE" .github/workflows/*.yml || true)
[ -z "$HARDCODED" ] \
  || fail "workflow(s) hardcode a node-scala digest instead of sourcing $VPS_ENV: $HARDCODED"

echo "OK: all four testnet nodes pin the same node-scala digest"
