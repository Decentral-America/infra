# Custom Caddy build with the caddy-ratelimit module (github.com/mholt/caddy-ratelimit).
# The stock caddy:*-alpine image does not include this module — rate limiting
# on the node/matcher REST domains requires it. See infra/.github/workflows/
# update-caddy.yml for the actual `rate_limit` directives that use it.
#
# Built and pushed by .github/workflows/build-caddy-ratelimit.yml, referenced
# by digest in compose/caddy.yml — not built on the server.

# renovate: image=caddy tag=2.11.4-builder-alpine
FROM caddy:2.11.4-builder-alpine@sha256:b6a94e74b72261bd536b35acdd22f3577d4e466a9550f2c8d6c8ed6413085d72 AS builder

# Pinned to a specific commit, not a version tag — caddy-ratelimit has only ever
# cut one release (v0.1.0) and master has since moved 7 commits ahead of it.
# Bump this SHA deliberately; check github.com/mholt/caddy-ratelimit/commits
# before doing so, since there's no changelog to diff against.
RUN xcaddy build \
    --with github.com/mholt/caddy-ratelimit@5625512f24f6f59d6f64fb3aafe5eecff0b286db

# renovate: image=caddy tag=2.11.4-alpine
FROM caddy:2.11.4-alpine@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
