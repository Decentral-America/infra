#!/usr/bin/env bash
# Unit tests for the matcher CI runner host (terraform/modules/matcher-ci-runner/files).
# Run: bash scripts/tests/matcher-ci-runner.test.sh   (needs openssl, jq; CI also runs `nft -c` on the rendered ruleset)
# shellcheck disable=SC2016,SC1091  # literal patterns; the library is sourced from a computed path
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
M="${ROOT}/terraform/modules/matcher-ci-runner"
F="${M}/files"
fail() { echo "FAIL: $*" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# Every file the module ships through user data exists, and nothing under files/ is left unshipped.
mapfile -t shipped < <(sed -n 's/.*src = "\([^"]*\)".*/\1/p' "${M}/main.tf" | sort)
mapfile -t present < <(cd "$F" && find . -type f | sed 's|^\./||' | sort)
[[ "${shipped[*]}" == "${present[*]}" ]] || fail "files/ and main.tf host_files differ: shipped=[${shipped[*]}] present=[${present[*]}]"

# Secret hygiene: no xtrace in anything that handles a token.
for f in "$F"/mci-*.sh "$F"/runner-image/entrypoint.sh; do
  if grep -nE '^[^#]*set -[a-z]*x' "$f"; then fail "$f enables xtrace (would print tokens)"; fi
done
# Pinned downloads: every curl'd release artifact is checked against a sha256 or a pinned key fingerprint.
grep -q 'SYSBOX_SHA256=[0-9a-f]\{64\}' "$F/install.sh" || fail "sysbox not sha256-pinned"
grep -q 'NODE_EXPORTER_SHA256=[0-9a-f]\{64\}' "$F/install.sh" || fail "node_exporter not sha256-pinned"
grep -q 'DOCKER_APT_KEY_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88' "$F/install.sh" || fail "docker apt key not pinned"
grep -qE '^FROM ubuntu:24\.04@sha256:[0-9a-f]{64}$' "$F/runner-image/Dockerfile" || fail "runner base image not digest-pinned"
grep -q 'sha256sum -c' "$F/runner-image/Dockerfile" || fail "actions/runner tarball not sha256-checked"
grep -q 'FALLBACK_SHA256=[0-9a-f]\{64\}' "$F/mci-image-build.sh" || fail "runner fallback not pinned"
# Isolation: a job never gets the host Docker socket, always sysbox, always --ephemeral, always memory-capped.
if grep -rn 'docker.sock' "$F" | grep -v '^\s*#'; then fail "host docker socket referenced"; fi
grep -q -- '--runtime=sysbox-runc' "$F/mci-slot.sh" || fail "slots must use sysbox-runc"
grep -q -- '--ephemeral' "$F/runner-image/entrypoint.sh" || fail "runner must register --ephemeral"
grep -q -- '--memory "$MCI_SLOT_MEMORY" --memory-swap "$MCI_SLOT_MEMORY"' "$F/mci-slot.sh" || fail "slot memory cap"
grep -q 'docker volume rm -f "$VOL"' "$F/mci-slot.sh" || fail "per-job volume must be deleted"
grep -q '"icc": false' "$F/docker-daemon.json" || fail "inter-container traffic must be off"

# nftables rendering.
cat > "$T/config.env" <<C
MCI_SSH_ALLOWED_V4=203.0.113.5/32,198.51.100.0/24
MCI_METRICS_ALLOWED_V4=192.0.2.10/32
C
out=$(MCI_CONFIG="$T/config.env" MCI_NFT_TMPL="$F/matcher-ci.nft.tmpl" bash "$F/mci-lib.sh" render-nft)
grep -qF 'elements = { 203.0.113.5/32, 198.51.100.0/24 }' <<<"$out" || fail "ssh set not rendered"
grep -qF 'elements = { 192.0.2.10/32 }' <<<"$out" || fail "metrics set not rendered"
grep -q '@' <<<"$(grep 'elements' <<<"$out")" && fail "unrendered placeholder"
grep -qx 'table inet matcher_ci' <<<"$out" || fail "own table"
grep -qx 'delete table inet matcher_ci' <<<"$out" || fail "idempotent reload"
if grep -v '^[[:space:]]*#' <<<"$out" | grep -q flush; then fail "a flush would delete Docker's rules"; fi
[[ $(grep -c 'policy drop;' <<<"$out") == 2 ]] || fail "input and output must default-drop"
grep -q '169.254.0.0/16' <<<"$out" || fail "jobs must not reach the metadata service"
grep -qF 'ip saddr @ssh_v4 tcp dport 22 accept' <<<"$out" || fail "ssh rule"
grep -qF 'ip saddr @metrics_v4 tcp dport 9100 accept' <<<"$out" || fail "metrics rule"
[[ $(grep -c 'dport 22\|dport 9100' <<<"$out") == 2 ]] || fail "only ssh and metrics ingress"
echo 'MCI_SSH_ALLOWED_V4=203.0.113.5/32' > "$T/c2.env"
out2=$(MCI_CONFIG="$T/c2.env" MCI_NFT_TMPL="$F/matcher-ci.nft.tmpl" bash "$F/mci-lib.sh" render-nft)
grep -qF 'elements = { 192.0.2.1 }' <<<"$out2" || fail "empty metrics allowlist must render the unroutable placeholder"
echo "$out" > "$T/rendered.nft"   # CI: sudo nft -c -f (see ci.yml)

# Credential modes, registration token handling, GitHub App JWT.
export MCI_CONFIG="$T/none" MCI_CRED="$T/cred.env" MCI_REGTOKEN="$T/regtoken" MCI_RUN="$T/run"
mkdir -p "$MCI_RUN"
mode() { bash "$F/mci-lib.sh" cred-mode; }
[[ $(mode) == none ]] || fail "no files -> none"
printf 'REGISTRATION_TOKEN=AAA\nEXPIRES_AT=%s\n' $(( $(date +%s) + 3000 )) > "$MCI_REGTOKEN"
[[ $(mode) == regtoken ]] || fail "regtoken mode"
# shellcheck source=/dev/null
tok=$(source "$F/mci-lib.sh"; mci_registration_token) || fail "valid bootstrap token rejected"
[[ "$tok" == AAA ]] || fail "bootstrap token value"
printf 'REGISTRATION_TOKEN=AAA\nEXPIRES_AT=%s\n' $(( $(date +%s) + 30 )) > "$MCI_REGTOKEN"
if (source "$F/mci-lib.sh"; mci_registration_token) 2>/dev/null; then fail "an expiring bootstrap token must be refused"; fi
echo 'GITHUB_PAT=x' > "$MCI_CRED"
[[ $(mode) == pat ]] || fail "pat mode (credential wins over a bootstrap token)"
openssl genrsa -out "$T/app.pem" 2048 2>/dev/null
openssl rsa -in "$T/app.pem" -pubout -out "$T/app.pub" 2>/dev/null
printf 'GITHUB_APP_ID=12345\nGITHUB_APP_INSTALLATION_ID=678\nGITHUB_APP_PRIVATE_KEY_B64=%s\n' "$(openssl base64 -A < "$T/app.pem")" > "$MCI_CRED"
[[ $(mode) == app ]] || fail "app mode"
# shellcheck source=/dev/null
jwt=$(source "$F/mci-lib.sh"; source "$MCI_CRED"; mci_app_jwt)
IFS=. read -r h p s <<<"$jwt"
unb64() { local x="$1"; x="${x//-/+}"; x="${x//_//}"; while (( ${#x} % 4 )); do x="$x="; done; printf '%s' "$x" | openssl base64 -d -A; }
[[ $(unb64 "$h" | jq -r .alg) == RS256 ]] || fail "jwt alg"
[[ $(unb64 "$p" | jq -r .iss) == 12345 ]] || fail "jwt iss"
(( $(unb64 "$p" | jq -r '.exp - .iat') <= 600 )) || fail "jwt lifetime above GitHub's 10 minutes"
unb64 "$s" > "$T/sig"
printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -verify "$T/app.pub" -signature "$T/sig" >/dev/null || fail "jwt signature does not verify"
[[ -z "$(ls -A "$MCI_RUN")" ]] || fail "the decoded private key must not stay on disk"

echo "PASS matcher-ci-runner"
