#!/usr/bin/env bash
# Tests for scripts/node-up.sh with stubbed docker/curl. Run: bash scripts/tests/node-up.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${ROOT}/scripts/node-up.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
NEW="ghcr.io/decentral-america/node-scala@sha256:$(printf 'a%.0s' $(seq 1 64))"
OLD="ghcr.io/decentral-america/node-scala@sha256:$(printf 'b%.0s' $(seq 1 64))"

# Stub state lives in $S: running (true|false), image (what inspect reports),
# label, heights (one per line, consumed by curl), up_rc, docker.log.
setup() {
  S="$(mktemp -d)"; mkdir -p "${S}/bin"; touch "${S}/compose.yml"
  echo true > "${S}/running"; echo "${OLD}" > "${S}/image"; echo node-scala-testnet > "${S}/label"
  echo 0 > "${S}/up_rc"; : > "${S}/docker.log"
  cat > "${S}/bin/docker" <<STUB
#!/usr/bin/env bash
S="${S}"
echo "docker \$* NODE_SCALA_IMAGE=\${NODE_SCALA_IMAGE:-}" >> "\${S}/docker.log"
case "\$1" in
  inspect)
    case "\$3" in
      *State.Running*) cat "\${S}/running" ;;
      *Config.Image*)  [ -s "\${S}/image" ] && cat "\${S}/image" || exit 1 ;;
      *Labels*)        cat "\${S}/label" ;;
    esac ;;
  compose)
    rc=\$(cat "\${S}/up_rc"); [ "\$rc" = 0 ] && echo "\${NODE_SCALA_IMAGE}" > "\${S}/image"; exit "\$rc" ;;
  pull|rm|logs) exit 0 ;;
esac
STUB
  cat > "${S}/bin/curl" <<STUB
#!/usr/bin/env bash
S="${S}"
h=\$(head -1 "\${S}/heights"); sed -i.bak 1d "\${S}/heights" 2>/dev/null || true
[ -n "\$h" ] || exit 7
echo "{\"height\":\$h}"
STUB
  chmod +x "${S}/bin/docker" "${S}/bin/curl"
}
run() { PATH="${S}/bin:${PATH}" COMPOSE_FILE_PATH="${S}/compose.yml" POLL_SECONDS=1 ADVANCE_WINDOW_SECONDS=2 bash "${SUT}" "$@"; }

# 1. Non-digest image is refused before any docker call.
setup
if run ghcr.io/decentral-america/node-scala:testnet-latest >/dev/null 2>&1; then fail "tag accepted"; fi
[[ ! -s "${S}/docker.log" ]] || fail "docker called for a tag image"

# 2. Happy path: up, running on NEW, height advances -> exit 0, no rollback.
setup; printf '100\n101\n' > "${S}/heights"
run "${NEW}" >/dev/null 2>&1 || fail "happy path failed"
[[ "$(grep -c '^docker compose ' "${S}/docker.log")" == "1" ]] || fail "expected exactly one compose up"
grep -q '^docker compose .* up -d --force-recreate --wait ' "${S}/docker.log" || fail "compose up must force-recreate"

# 3. Container not running after up -> exit 1 and rollback to OLD.
setup; echo false > "${S}/running"; printf '100\n101\n100\n101\n' > "${S}/heights"
if run "${NEW}" >/dev/null 2>&1; then fail "not-running accepted"; fi
grep -q "NODE_SCALA_IMAGE=${OLD}" "${S}/docker.log" || fail "no rollback to previous image"

# 4. Height stuck -> exit 1.
setup; printf '100\n100\n100\n100\n100\n100\n100\n100\n' > "${S}/heights"
if run "${NEW}" >/dev/null 2>&1; then fail "stuck height accepted"; fi

# 5. compose up fails -> exit 1.
setup; echo 1 > "${S}/up_rc"
if run "${NEW}" >/dev/null 2>&1; then fail "failed compose up accepted"; fi

# 6. A docker-run container (no compose label) is removed before compose up.
setup; echo "" > "${S}/label"; printf '100\n101\n' > "${S}/heights"
run "${NEW}" >/dev/null 2>&1 || fail "migration path failed"
grep -q '^docker rm -f node-scala-testnet' "${S}/docker.log" || fail "unlabeled container not removed"
echo "PASS node-up"
