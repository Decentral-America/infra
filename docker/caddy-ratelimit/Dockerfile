# Custom Caddy build with the caddy-ratelimit module (github.com/mholt/caddy-ratelimit).
# The stock caddy:*-alpine image does not include this module — rate limiting
# on the node/matcher REST domains requires it. See infra/.github/workflows/
# update-caddy.yml for the actual `rate_limit` directives that use it.
#
# Built and pushed by .github/workflows/build-caddy-ratelimit.yml, referenced
# by digest in compose/caddy.yml — not built on the server.

# renovate: image=caddy tag=2.11.7-builder-alpine
FROM caddy:2.11.9-builder-alpine@sha256:646fee578e680989ca5c7fd1ce6f1de574d19fd71ef2221810cc0510a9f40c86 AS builder

# Pinned to a specific commit, not a version tag — caddy-ratelimit has only ever
# cut one release (v0.1.0) and master has since moved 7 commits ahead of it.
# Bump this SHA deliberately; check github.com/mholt/caddy-ratelimit/commits
# before doing so, since there's no changelog to diff against.
RUN xcaddy build \
    --with github.com/mholt/caddy-ratelimit@5625512f24f6f59d6f64fb3aafe5eecff0b286db \
    --replace golang.org/x/net=golang.org/x/net@v0.60.0 \
    --replace github.com/go-jose/go-jose/v4=github.com/go-jose/go-jose/v4@v4.1.6

# renovate: image=caddy tag=2.11.7-alpine
FROM caddy:2.11.9-alpine@sha256:003a97808e781aa9f7e75cc2f43d34d461099031faf5e20faefb9f61126836f0
# Alpine packages (brotli, curl) are fixed in the repos before the Caddy image is rebuilt.
RUN apk upgrade --no-cache
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
