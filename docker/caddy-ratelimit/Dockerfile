# Custom Caddy build with the caddy-ratelimit module (github.com/mholt/caddy-ratelimit).
# The stock caddy:*-alpine image does not include this module — rate limiting
# on the node/matcher REST domains requires it. See infra/.github/workflows/
# update-caddy.yml for the actual `rate_limit` directives that use it.
#
# Built and pushed by .github/workflows/build-caddy-ratelimit.yml, referenced
# by digest in compose/caddy.yml — not built on the server.

# renovate: image=caddy tag=2.11.4-builder-alpine
FROM caddy:2.11.4-builder-alpine@sha256:0aa610043dab5da82ad0a0268e46bb852785e6f5160f12f1c6fe3f42903d7e1b AS builder

# Pinned to a specific commit, not a version tag — caddy-ratelimit has only ever
# cut one release (v0.1.0) and master has since moved 7 commits ahead of it.
# Bump this SHA deliberately; check github.com/mholt/caddy-ratelimit/commits
# before doing so, since there's no changelog to diff against.
RUN xcaddy build \
    --with github.com/mholt/caddy-ratelimit@5625512f24f6f59d6f64fb3aafe5eecff0b286db

# renovate: image=caddy tag=2.11.4-alpine
FROM caddy:2.11.4-alpine@sha256:6aeddd44c3078b0f9a35206472a11420648a79c184603ef95957d0a20044cb2b
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
