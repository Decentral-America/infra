#!/usr/bin/env bash
# Guards the single, fail-closed main-node deploy path (AUD-045/046).
# Run: bash scripts/tests/node-deploy-path.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
W="${ROOT}/.github/workflows"
fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. No workflow starts the main node with `docker run` any more.
if grep -rn -- '--name node-scala' "${W}"; then fail "a workflow starts node-scala with docker run (see above)"; fi
# 2. The tag-based paths stay deleted.
for f in deploy-specific-sha.yml deploy-testnet-release.yml; do
  [[ ! -e "${W}/${f}" ]] || fail "${f} must not exist (tag-based main-node deploy)"
done
# 3. Every main-node workflow goes through node-up.sh and never disables errexit.
for f in update-node-image.yml deploy-node-config.yml restart-host-network.yml; do
  grep -q 'node-up.sh' "${W}/${f}" || fail "${f} does not use scripts/node-up.sh"
  if grep -n 'set +e' "${W}/${f}"; then fail "${f} contains set +e"; fi
done
# 4. The cross-repo reusable deploy refuses the main node.
grep -q 'refuses node-scala' "${W}/deploy-container.yml" || fail "deploy-container.yml must refuse service=node-scala"
# 5. compose/node-scala.yml takes only NODE_SCALA_IMAGE (no IMAGE_TAG fallback).
# shellcheck disable=SC2016  # literal ${...} is the text being searched for
grep -qF 'image: "${NODE_SCALA_IMAGE:?' "${ROOT}/compose/node-scala.yml" || fail "compose/node-scala.yml must require NODE_SCALA_IMAGE"
if grep -q 'IMAGE_TAG' "${ROOT}/compose/node-scala.yml"; then fail "compose/node-scala.yml still mentions IMAGE_TAG"; fi
echo "PASS node-deploy-path"
