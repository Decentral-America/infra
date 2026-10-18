#!/usr/bin/env bash
# Tests for scripts/render-service-env.sh. Run: bash scripts/tests/render-service-env.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${ROOT}/scripts/render-service-env.sh"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

cat > "${T}/master.env" <<'ENV'
# master
PGPASSWORD=pg=with=equals
POSTGRES__PASSWORD=pg=with=equals
DCC_WALLET_SEED=word1 word2 word3
DCC_WALLET_PASSWORD=wp
REDIS_PASSWORD=rp
REPO__PASSWORD=rp
BPS_REDIS_URL=redis://:rp@127.0.0.1:6379/
REDIS_URL=redis://:rp@127.0.0.1:6379
MAIN_NODE_REST_API_KEY=nodekey
DCC_FAUCET_SEED=faucet seed
DCC_CANARY_SEED=canary seed
DEFAULT_MATCHER=31VMNVAvVh67dPZ41nMnYZvhoZFW7wwPrmq
RATE_PAIR_ACCEPTANCE_VOLUME_THRESHOLD=1
RATE_THRESHOLD_ASSET_ID=DCC
ADMIN_DASHBOARD_GITHUB_OAUTH_CLIENT_ID=cid
ADMIN_DASHBOARD_GITHUB_OAUTH_CLIENT_SECRET=csec
ADMIN_DASHBOARD_JWT_SECRET=jwt
ADMIN_DASHBOARD_GITHUB_PAT=pat
ADMIN_DASHBOARD_PG_DATABASE=admin_testnet
GRAFANA_URL=https://grafana.example
SENTRY_AUTH_TOKEN=sentry
TREASURY_SEED=treasury seed
DCC_CHAIN_ID=33
DCC_NODE_URL=https://node.example
DCC_MATCHER_URL=https://matcher.example
DCC_DATA_SERVICE_URL=https://ds.example/v0
DCC_FAUCET_AMOUNT=100
DCC_FAUCET_RATE_HOURS=24
PGHOST=localhost
PGPORT=5432
PGUSER=dcc
PGDATABASE=bps_testnet
POSTGRES__HOST=localhost
POSTGRES__PORT=5432
POSTGRES__USER=dcc
POSTGRES__DATABASE=bps_testnet
BPS_BLOCKCHAIN_UPDATES_URL=grpc://localhost:6881
BPS_CHAIN_ID=33
ENV

# 1. Happy path: every service file is written, values are byte-identical.
bash "${SUT}" testnet "${T}/master.env" "${T}/out" >/dev/null
for svc in node-scala scanner data-service blockchain-postgres-sync websocket-api admin-dashboard postgres-exporter alert-webhook; do
  [[ -f "${T}/out/${svc}-testnet.env" ]] || fail "${svc}-testnet.env not written"
  while IFS= read -r line; do
    [[ "${line}" == \#* ]] && continue
    grep -qxF -- "${line}" "${T}/master.env" || fail "${svc}: line not byte-identical to master: ${line%%=*}"
  done < "${T}/out/${svc}-testnet.env"
done
# 2. Org credentials never reach the public-facing services.
for svc in scanner data-service websocket-api blockchain-postgres-sync node-scala; do
  if grep -qE '^(ADMIN_DASHBOARD_GITHUB_PAT|ADMIN_DASHBOARD_GITHUB_OAUTH_CLIENT_SECRET|ADMIN_DASHBOARD_JWT_SECRET|SENTRY_AUTH_TOKEN)=' "${T}/out/${svc}-testnet.env"; then
    fail "${svc} received an org credential"
  fi
done
# 3. Exact key sets for two representative services.
[[ "$(grep -v '^#' "${T}/out/node-scala-testnet.env" | cut -d= -f1 | tr '\n' ' ')" == "DCC_WALLET_SEED DCC_WALLET_PASSWORD " ]] || fail "node-scala key set"
[[ "$(grep -v '^#' "${T}/out/websocket-api-testnet.env" | cut -d= -f1 | tr '\n' ' ')" == "REPO__PASSWORD " ]] || fail "websocket-api key set"
grep -q '^TREASURY_SEED=treasury seed$' "${T}/out/admin-dashboard-testnet.env" || fail "admin-dashboard lacks optional TREASURY_SEED"
# 4. Mode 640.
mode="$(stat -c %a "${T}/out/scanner-testnet.env" 2>/dev/null || stat -f %Lp "${T}/out/scanner-testnet.env")"
[[ "${mode}" == "640" ]] || fail "mode ${mode} != 640"
# 5. Fail closed: a missing required key -> that file is not (re)written and exit 1.
grep -v '^REPO__PASSWORD=' "${T}/master.env" > "${T}/broken.env"
if bash "${SUT}" testnet "${T}/broken.env" "${T}/out2" >/dev/null 2>&1; then fail "expected exit 1 on missing key"; fi
[[ ! -f "${T}/out2/websocket-api-testnet.env" ]] || fail "websocket-api file written despite missing key"
[[ -f "${T}/out2/scanner-testnet.env" ]] || fail "unrelated service not written"
echo "PASS render-service-env"
