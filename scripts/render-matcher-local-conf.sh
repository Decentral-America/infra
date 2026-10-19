#!/usr/bin/env bash
# The ONE writer of the matcher's local.conf (push-secrets.yml and
# scripts/push-secrets-local.sh both pipe this output to
# /opt/dcc/config/matcher-<network>/local.conf). bootstrap.sh writes only a
# fail-closed skeleton that keeps the matcher from starting until this runs.
#
# In-mem account storage with the real account seed. Without
# seed-in-base-64 the matcher silently signs as KeyPair(empty).
# No redis/postgres blocks: the matcher uses neither (order-history and the
# Redis client are off by default), and the old blocks carried passwords for
# a database that does not exist (2026-10-18 audit).
#
# Usage: NETWORK=testnet CHAIN_ID=33 MATCHER_SEED_B64=... MATCHER_HASH=... [MATCHER_HASH_2=...] render-matcher-local-conf.sh
# MATCHER_HASH_2 is optional: a second accepted api-key hash (SOPS MATCHER_API_KEY_HASH_2), added alongside the
# first so a second operator/automation key works without touching the first.set -euo pipefail
: "${NETWORK:?NETWORK must be set}"
: "${CHAIN_ID:?CHAIN_ID must be set}"
: "${MATCHER_SEED_B64:?MATCHER_SEED_B64 must be set (SOPS MATCHER_SEED_BASE64)}"
: "${MATCHER_HASH:?MATCHER_HASH must be set (SOPS MATCHER_API_KEY_HASH)}"

case "${CHAIN_ID}" in
  63) ADDR_SCHEME="?" ;;
  83) ADDR_SCHEME="S" ;;
  33) ADDR_SCHEME="!" ;;
  *)  echo "render-matcher-local-conf: unknown CHAIN_ID ${CHAIN_ID}" >&2; exit 1 ;;
esac

printf '# DecentralChain DEX Matcher local config -- written by scripts/render-matcher-local-conf.sh (SOPS)\n'
printf '# Network: %s  Chain ID: %s\n' "${NETWORK}" "${CHAIN_ID}"
printf 'dcc.dex {\n'
printf '  address-scheme-character = "%s"\n' "${ADDR_SCHEME}"
printf '  dcc-blockchain-client.grpc.target = "127.0.0.1:6887"\n'
printf '  dcc-blockchain-client.blockchain-updates-grpc.target = "127.0.0.1:6881"\n'
# The matcher restarts a node stream after `no-data-timeout` without a message (default 1m).
# With a 30s average block delay ~14% of block gaps exceed 60s (max seen 163s, 2026-10-05), so
# 1m restarted both streams ~13-22 times an hour on an idle chain. 5m is the IT-suite value.
printf '  dcc-blockchain-client.grpc.no-data-timeout = 5m\n'
printf '  dcc-blockchain-client.blockchain-updates-grpc.no-data-timeout = 5m\n'
printf '  account-storage.type = in-mem\n'
printf '  account-storage.in-mem.seed-in-base-64 = "%s"\n' "${MATCHER_SEED_B64}"
if [ -n "${MATCHER_HASH_2:-}" ]; then
  printf '  rest-api.api-key-hashes = ["%s", "%s"]\n' "${MATCHER_HASH}" "${MATCHER_HASH_2}"
else
  printf '  rest-api.api-key-hashes = ["%s"]\n' "${MATCHER_HASH}"
fi
# The image's dex.conf binds 0.0.0.0; only Caddy (host network, 127.0.0.1:6886) needs the REST API.
printf '  rest-api.address = "127.0.0.1"\n'
printf '}\n'
