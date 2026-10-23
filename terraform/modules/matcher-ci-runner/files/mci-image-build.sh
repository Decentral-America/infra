#!/usr/bin/env bash
# Builds matcher-ci-runner:current: Ubuntu 24.04 (pinned digest, then patched with apt upgrade) + Docker
# Engine + actions/runner. The runner release is the latest one, verified against the SHA-256 that GitHub
# publishes in the release notes; when that lookup fails the pinned fallback below is used. Daily timer:
# keeps the runner within GitHub's support window (runners run with --disableupdate) and the image patched.
set -euo pipefail
FALLBACK_VERSION=2.338.1
FALLBACK_SHA256=08e9ccb3604d2462c24b5e33604dc30810296ca15cc65f23cffd4317eb144c37

version=""; sha=""
if rel=$(curl -fsS --max-time 20 https://api.github.com/repos/actions/runner/releases/latest); then
  version=$(printf '%s' "$rel" | jq -r '.tag_name // empty' | sed 's/^v//')
  sha=$(printf '%s' "$rel" | jq -r '.body // empty' | sed -n 's/.*<!-- BEGIN SHA linux-x64 -->\([0-9a-f]\{64\}\)<!-- END SHA linux-x64 -->.*/\1/p' | head -1)
fi
if ! printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || ! printf '%s' "$sha" | grep -Eq '^[0-9a-f]{64}$'; then
  echo "matcher-ci: could not resolve the latest actions/runner release; using pinned ${FALLBACK_VERSION}" >&2
  version=$FALLBACK_VERSION; sha=$FALLBACK_SHA256
fi

docker build --pull -q -t "matcher-ci-runner:${version}" \
  --build-arg "RUNNER_VERSION=${version}" --build-arg "RUNNER_SHA256=${sha}" \
  --build-arg "BUILD_DATE=$(date -u +%F)" /opt/matcher-ci/runner-image
docker tag "matcher-ci-runner:${version}" matcher-ci-runner:current
# Keep only the current image (plus whatever a running slot still uses; docker refuses to remove those).
docker images --format '{{.Repository}}:{{.Tag}}' matcher-ci-runner | grep -vE ":(current|${version})$" | xargs -r docker rmi >/dev/null 2>&1 || true
docker image prune -f >/dev/null
docker builder prune -af >/dev/null
echo "matcher-ci: runner image matcher-ci-runner:${version} is current"
