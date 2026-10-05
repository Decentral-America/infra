# Custom Caddy build with the caddy-ratelimit module (github.com/mholt/caddy-ratelimit).
# The stock caddy:*-alpine image does not include this module — rate limiting
# on the node/matcher REST domains requires it. See infra/.github/workflows/
# update-caddy.yml for the actual `rate_limit` directives that use it.
#
# Built and pushed by .github/workflows/build-caddy-ratelimit.yml, referenced
# by digest in compose/caddy.yml — not built on the server.

# renovate: image=caddy tag=2.11.4-builder-alpine
FROM caddy:2.11.7-builder-alpine@sha256:a576be4d0ba99e7259e98268cbac2e2c897feeab8b7b49885cd3cac5409523f8 AS builder

# Pinned to a specific commit, not a version tag — caddy-ratelimit has only ever
# cut one release (v0.1.0) and master has since moved 7 commits ahead of it.
# Bump this SHA deliberately; check github.com/mholt/caddy-ratelimit/commits
# before doing so, since there's no changelog to diff against.
RUN xcaddy build \
    --with github.com/mholt/caddy-ratelimit@5625512f24f6f59d6f64fb3aafe5eecff0b286db

# renovate: image=caddy tag=2.11.4-alpine
FROM caddy:2.11.7-alpine@sha256:d76116d819d5162f464b0f2cd09bd28c568a86148c7bc539ce17c33eb22d8bbb
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
