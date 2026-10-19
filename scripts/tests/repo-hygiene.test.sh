#!/usr/bin/env bash
# Repo hygiene guards from the 2026-10-18 audit. Run: bash scripts/tests/repo-hygiene.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

# AUD-129: exactly one CODEOWNERS, owned by a real account with write access.
[[ ! -e "${ROOT}/CODEOWNERS" ]] || fail "root CODEOWNERS is shadowed by .github/CODEOWNERS; delete it"
grep -qxE '\*[[:space:]]+@jourlez' "${ROOT}/.github/CODEOWNERS" || fail ".github/CODEOWNERS must assign * to @jourlez"
if grep -q '@Decentral-America/' "${ROOT}/.github/CODEOWNERS"; then fail "CODEOWNERS names a team without write access"; fi
# AUD-131/133/134/139: inert or orphaned artifacts stay deleted.
for p in wireguard monitoring/scripts/check-val0.sh .github/workflows/label-hostendpoint-nodes.yml; do
  [[ ! -e "${ROOT}/${p}" ]] || fail "${p} must be deleted"
done
if grep -rq 'StagedGlobalNetworkPolicy' "${ROOT}/clusters"; then fail "inert StagedGlobalNetworkPolicy still in clusters/"; fi
grep -q 'kind: KubeControllersConfiguration' "${ROOT}/clusters/testnet/policy/host-endpoints.yaml" || fail "keep the live KubeControllersConfiguration"
# AUD-137: app containers run by digest.
grep -q 'RepoDigests' "${ROOT}/.github/workflows/deploy-container.yml" || fail "deploy-container must resolve the image to its repo digest"
# AUD-138: a clean drift summary says how much it compared.
grep -q 'resources in state' "${ROOT}/.github/workflows/drift-detect.yml" || fail "drift summary must print the resource count"
echo "PASS repo-hygiene"
