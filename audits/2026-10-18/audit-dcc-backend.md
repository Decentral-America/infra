# DCC testnet backend audit: BPS, data-service, websocket-api

Date: 2026-10-18. Auditor scope: `DecentralChain/apps/{blockchain-postgres-sync,data-service,websocket-api}`, their DB (`bps_testnet`), Redis, Dockerfiles, `deploy-*.yml`, CI, and the infra compose/Caddy/Prometheus wiring that serves them. Method: REPO-AUDIT-PROMPT.md ("verify, don't guess"). Every claim below comes from a command run today: SSH to 50.116.30.244, psql against `bps_testnet`, node REST (localhost:6869 and public), public data-service and websocket endpoints, and source on `origin/main` (a68d20af4). This audit made no changes. A few scratch scripts were put in `~deploy/.aud` on the VPS and removed afterwards. No secret values were printed.

Chain height at audit time: ~73,290. BPS `bps_last_synced_height` matched it (no lag).

---

## BLOCKER

### BE-01 [BLOCKER] The BPS index mixes two chains: heights 1-1741 (including genesis) come from the dead pre-relaunch chain
- **Evidence**
  - A full comparison of block IDs for heights 1..73200 (BPS `blocks_microblocks.id` against node `/blocks/headers/seq`) found **1741 mismatches, exactly the contiguous range 1-1741**. Heights 1742-73200 match exactly.
  - BPS height 1 has `time_stamp 2026-08-31 10:39:47`. The node's height 1 is from `2026-09-04 16:32:59`, the 09-04 relaunch genesis.
  - `uid` jumps from 8726773 at h1741 (2026-09-01) to 8780302 at h1742 (2026-09-06).
  - `GET https://testnet-data-service.decentralchain.io/v0/transactions/genesis` returns 5 old-chain genesis txs (IDs `3Mn9UU…`, `52Z7CJ…`, …) with amounts of 0.1-0.4 DCC. The real genesis (node `/blocks/at/1`) has different IDs (`5x3NNY…`, `ac3fCp…`, …) and amounts of 10M-40M DCC.
  - BPS holds 7 txs in h≤1741 that do not exist on the live chain. The live chain has 12 txs there that BPS lacks.
  - `dcc_data` also has 894 heights with two rows from different chains or forks (see BE-13).
  - `infra/runbooks/reset-bps-testnet.md` says: "Status: written 2026-10-01 … **Not executed yet**." `infra/RELAUNCH-20260904.md:636-640` predicted that restarting BPS against a new chain with the old DB "at worst write[s] corrupt records". That has happened.
- **Why it matters:** data-service, scanner and exchange serve wrong history for the first 1741 blocks, including wrong genesis distribution. `TESTNET-FINAL-PLAN.md:792` only checks "BPS max height ≈ chain height", so the corruption is invisible to the planned acceptance check. It also shows a code gap: on resume, BPS does not verify ancestry (that its stored block at height N equals the node's block N, or that the genesis ID matches). `start_rollback_depth: 1` is the only protection, and it did not catch a re-genesis.
- **Fix**
  1. Execute `runbooks/reset-bps-testnet.md`: drop and recreate `bps_testnet`, migrate, resync from 1.
  2. In BPS, on startup compare the stored genesis block ID, and the block ID at the resume height, with the node. Refuse to run (fail loudly) on mismatch.
  3. Change the acceptance check to compare block IDs at sample heights, not just max height.

### BE-02 [BLOCKER] The websocket-api pipeline is dead: BPS never publishes to Redis (env var name mismatch)
- **Evidence**
  - BPS startup log (2026-10-10T13:33:44): `"REDIS_URL not set — Redis publishing disabled"`, config dump `redis_url: None`.
  - BPS reads config with `envy::prefixed("BPS_")` (`src/lib/config/consumer.rs:80`). The variable must therefore be `BPS_REDIS_URL`, which the BPS README documents correctly.
  - `infra/.github/workflows/push-secrets.yml:183-190` writes only `REDIS_URL=redis://…`, with the comment "BPS reads REDIS_URL", which is wrong. The container env has `REDIS_URL` and no `BPS_REDIS_URL` (names checked with `docker inspect`).
  - Live test with a Node `WebSocket` client against `wss://testnet-ws.decentralchain.io/ws`:
    - Subscribed to `topic://transactions?type=all&address=31LAqg…` (sends a transfer every 15 min) for 15 min.
    - Transfer `GdKgCTmYx2…` landed at h73288 (16:00:13Z) and was indexed by data-service.
    - **Zero `update` messages arrived, only pings.** The final log shows `{ ping: 21 }` and 0 updates. The server closed the session with code 1001 ("going away") at about 16:05:54Z, roughly 9.5 min in, before the planned 15 min. The cause of that close was not investigated (it could be a Caddy reload or an idle policy).
  - Redis: 714 `topic://state/*` keys. Their embedded timestamps are 2026-06-20..21 (an earlier chain), with no TTL. An example key `…/m_bool_1781961047` returns `"subscribed","value":"true"` over ws while the node says `no data for this key`. `pubsub_channels:0`.
- **Why it matters:** the only purpose of websocket-api is real-time updates. It accepts connections and passes its healthcheck and the `dcc_service_up{service="websocket"}` probe, but delivers nothing live. It also serves stale state from a dead chain as current values. Nothing alerts on this (BE-07).
- **Fix**
  1. In push-secrets, write `BPS_REDIS_URL` (or make BPS accept the unprefixed name).
  2. Flush the stale `topic://state/*` keys, and give state keys a TTL or clear them on re-genesis.
  3. Add an end-to-end canary: subscribe, wait for the canary transfer, alert if absent.

---

## HIGH

### BE-03 [HIGH] BPS loses about 99.9% of CommitToGeneration (type 19) txs: microblock squash cascade-deletes them
- **Evidence**
  - Every node tx in heights 1742-73200 was classified as present or absent in BPS. All types 3-18 are 100% present. **Type 19: 1350 on chain, 1350 missing.** `txs_19` holds 8 rows in total: 6 from the dead chain and 2 in the live range (h34417, h53402).
  - Mechanism, traced:
    - The migration `2026-06-28-000000_add_txs_19…/up.sql` creates `txs_19` standalone, **without `INHERITS (txs)`** (psql: "Number of child tables: 18"). It also has `block_uid … REFERENCES blocks_microblocks(uid) ON DELETE CASCADE`.
    - `squash_microblocks` (`src/lib/consumer/mod.rs:1074-1097`) calls `update_transactions_references`, which updates only `txs` and therefore its children txs_1..18. It then calls `delete_microblocks`.
    - The txs_19 rows still point at the microblock uid, so they are cascade-deleted.
  - Live trace for h73110:
    - BPS log: `Handle microblock 2ru9iM… height = 73110` → `1 transactions handled` → saved.
    - Node: that block contains type-19 `2LuYC2HM…`.
    - `txs_19` has no row at 73110.
  - There is no squash test and no txs_19 test (`tests/` greps empty).
  - The BPS README claims "Full coverage" and "type-19 (CommitToGeneration) enabled".
- **Why it matters:** silent permanent data loss for the DCC-specific consensus transaction. `txs_19` is not a child of `txs`, so `/transactions/all` can never show type 19 either, and data-service has no type-19 route.
- **Fix:** Add a migration making `txs_19` inherit `txs`, or explicitly `UPDATE txs_19 SET block_uid` in `update_transactions_references` and `rollback_transactions`. Add a regression test covering microblock → keyblock squash with a type-19 tx. Resync (combine with BE-01).

### BE-04 [HIGH] `DEFAULT_MATCHER` holds the matcher **public key**, but data-service uses it as an **address**
- **Evidence**
  - The `DEFAULT_MATCHER` value in `/opt/dcc/secrets/testnet.env` starts with `BEtB…` and is 44 chars. Node `/addresses/publicKey/BEtB5b2k…` gives `31VMNVAvVh67dPZ41nMnYZvhoZFW7wwPrmq`.
  - data-service loads it as `defaultMatcherAddress` (`loadConfig.ts:113`) and uses it as the default `matcher` filter in `http/candles/parse.ts:121` and `http/pairs/parse.ts:39,79`.
  - `infra/README.md:685` and `terraform/main.tf:314` both say "matcher blockchain address". `TESTNET-FINAL-PLAN.md:123` records it being set to `BEtB5b2k…` (infra #184).
  - Live, for the same pair and hour:
    - `/v0/candles/A5Uq…/DCC?…interval=1h` without a matcher → `txsCount:0`.
    - With `&matcher=31VMNV…` → `txsCount:1, volume 500`.
- **Why it matters:** every default-matcher view (candles, pairs and rate defaults used by exchange/scanner) is empty even though 22 exchange txs and 286 candle rows exist.
- **Fix:** Set `DEFAULT_MATCHER` to the address `31VMNV…`, or split it into `DEFAULT_MATCHER_ADDRESS` and `MATCHER_PUBLIC_KEY` if another consumer needs the key. Check the other services that read `DEFAULT_MATCHER` before changing it.

### BE-05 [HIGH] The data-service rate limiter can be bypassed with a spoofed `X-Real-IP`, and it is the only rate limit on that host
- **Evidence**
  - `src/middleware/rateLimiter.ts` keys on `x-real-ip` first and claims "X-Real-IP cannot be spoofed by external clients".
  - The live Caddyfile block for `testnet-data-service.decentralchain.io` is a bare `reverse_proxy localhost:8080`, with no `header_up` and no `rate_limit`. Caddy passes client-sent `X-Real-IP` through unchanged.
  - Live test against `/version`:
    - 125 requests, each with a different `X-Real-IP` → 125×200.
    - 125 requests with one fixed fake `X-Real-IP` → 120×200 then 5×429.
    - So the client header alone selects the bucket.
  - Each unique key also adds a Map entry kept for 60 s (memory growth driven by the attacker).
  - Unlike `testnet-node`, the data-service and websocket hosts have no Caddy `rate_limit` (see BE-10).
- **Why it matters:** the only DoS control on a public, unauthenticated API is defeated by one header. Without a Postgres statement timeout (BE-15), a flood of heavy queries can exhaust the pool of 20 connections. The same code ships to mainnet.
- **Fix:** In Caddy, `header_up X-Real-IP {remote_host}`, overwriting any client-supplied value. Add a Caddy `rate_limit` zone for data-service. In the app, only trust the header when the socket peer is loopback.

---

## MEDIUM

### BE-06 [MEDIUM] data-service returns 500 for every not-found or invalid ID; the error path crashes inside the logger
- **Evidence**
  - These all return `{"message":"Internal Server Error"}` [500]:
    - `GET /v0/assets/<valid-shaped nonexistent id>`
    - `/v0/transactions/transfer/<nonexistent>`
    - `/assets/.env`
    - `/aliases/.env`
  - The HTTP specs assert 404 for the same cases (`assets.http.spec.ts:46`, `aliases.http.spec.ts:16`, `transfer.http.spec.ts:147`). They pass locally (`pnpm run test:http`: 64/64) because the test app factory never subscribes the logger.
  - Production log: `TypeError: Cannot read properties of undefined (reading 'message') at EventEmitter.createEvent` (`src/logger/index.ts:27-35` dereferences `data.error.message`). That throw inside `onFailure` (`http/_common/index.ts:76-79`) turns the intended 404/400 into a `ResolverError` 500, and the original error is lost from the logs.
  - `test-http` is **not run in CI**: `ci.yml:150` runs only `-t test`, and `vitest.config.ts` includes only `*.test.ts`.
  - Related: `?senders[]=abc%2Cdef%7D` → 500. Unvalidated input is spliced into a Postgres array literal (`exchange/repo/sql/filters.ts:19`), producing a DB error rather than a 400. It is escaped, so this is not SQL injection.
- **Why it matters:** clients get wrong status codes, real errors become invisible, scanners can push error volume up cheaply, and a test suite that would have caught a regression never runs.
- **Fix:** Make `createEvent` defensive (`data?.error?.message ?? String(data)`). Wire the real logger in the HTTP test factory. Add `test-http` to CI. Validate `senders` against base58 address format.

### BE-07 [MEDIUM] No alerting on BPS sync lag, BPS down, or data/stream freshness
- **Evidence**
  - Prometheus rule groups (`/api/v1/rules`) are `dcc-testnet-capacity`, `-critical` and `-infra`. **No rule references `bps_*`**, although `bps_up` and `bps_last_synced_height` are scraped (`job=bps` up).
  - `dcc_service_up` treats any HTTP status below 500 as up, so websocket stays "up" while delivering nothing (BE-02).
  - data-service `/readiness` checks only the DB connection, not data freshness.
- **Why it matters:** the historic BPS failure (stream lost, process alive, fixed in #119/#120) and BE-02 are exactly the kind of failure that stays invisible until a user reports it.
- **Fix:** Add alerts:
  - `max(dcc_block_height{node="main-node"}) - bps_last_synced_height > N for 10m`
  - `bps_up == 0`
  - a ws end-to-end canary metric

### BE-08 [MEDIUM] Deployed data-service and BPS images carry fixed HIGH CVEs, so a rebuild and redeploy is owed
- **Evidence:** `trivy image --severity HIGH,CRITICAL --ignore-unfixed` on the deployed images:

  | Image | HIGH CVEs (fixed upstream) |
  |---|---|
  | `data-service:1e3b9886` | `libssl3`/`libcrypto3` CVE-2026-14456 (3.5.7-r0 → 3.5.8-r0) |
  | `blockchain-postgres-sync:fd2ec1ab` | `curl`/`libcurl4t64` CVE-2026-8286, CVE-2026-8927, CVE-2026-92392 (deb13u5 → u7) |
  | `websocket-api:cc30f566` | none |

  None of these CVEs is in `infra/.trivyignore`. The deploy gate (`deploy-container.yml:111-120`, `exit-code 1`) would block these exact images today.
- **Delta since deploy:**
  - **BPS:** `fd2ec1abff` is the latest commit touching BPS, so there is no code delta.
  - **data-service:** `1e3b9886..main` contains dependency bumps only (`d78b17ae6`, `72035b48d`), and the image runs `effect@3.21.4`.
  - **websocket-api:** `cc30f566..main` contains a Cargo dependency bump and base images `rust:1.98-slim` / distroless `cc-debian13` (`88c187b24`, `72035b48d`).
  - `cargo audit` on the BPS lockfile: rustls 0.23.45, RUSTSEC-2026-0346 (medium, 4.0) plus 0347/0348/0349 (low), published 2026-10-14.
- **Fix:** Rebuild and redeploy data-service and BPS (fold this into the BE-01/03 resync). Bump rustls to ≥0.23.46. Consider dropping `curl` from the BPS runtime and using a static healthcheck binary as websocket-api does.

### BE-09 [MEDIUM] The websocket-api `Cargo.lock` is gitignored, so builds cannot be reproduced and the audit scans the wrong tree
- **Evidence**
  - `apps/websocket-api/.gitignore:2` is `Cargo.lock`, and `git check-ignore` confirms it.
  - The Dockerfile runs `cargo chef` / `cargo build --release` without `--locked`.
  - The local untracked lock (2026-06-18) resolves `axum-test 20.1.0`, while `Cargo.toml` says `axum-test = "21"`, which is proof of drift.
  - CI `cargo audit` audits whatever it resolves at run time. BPS, by contrast, tracks its `Cargo.lock`.
- **Why it matters:** the deployed binary's dependency set is not recorded anywhere, so you cannot rebuild a past release, and audit results are not about what shipped.
- **Fix:** Commit `Cargo.lock`, and build with `--locked` in the Dockerfile and CI.

### BE-10 [MEDIUM] Public data-service and websocket hosts have no edge rate limiting, and websocket-api has no per-IP connection or subscription limits
- **Evidence**
  - The Caddyfile `testnet-node` block uses `rate_limit` zones. The `testnet-data-service` and `testnet-ws` blocks have none, and no `cors_allowlist` import either. The app CORS of `*` is intentional.
  - websocket-api enforces only a global `MAX_CONNECTIONS=10000` (`server.rs:80,139`), with no per-IP cap and no per-client subscription cap (grep of `websocket.rs`/`client.rs`/`config.rs`).
- **Why it matters:** one client can take all 10k slots, or flood data-service (BE-05).
- **Fix:** Add Caddy `rate_limit` zones for both hosts, plus a per-IP connection and per-client subscription cap in websocket-api.

### BE-11 [MEDIUM] data-service and BPS share one Postgres role that owns everything; the read-only API has full write and DDL rights
- **Evidence:**
  - `pg_roles`: only `postgres` and `dcc`.
  - BPS (writer), data-service and the pairs daemon all connect as `dcc` (`PGUSER=dcc`), and `dcc` owns all tables (`\dt+`).
  - data-service runs every query through `sql.unsafe(knexQuery.toString())` (`db/driver/pg.ts:100-103`), which uses client-side escaping rather than server-side parameters. A prior SQLi was found in this service (AUDIT-REPORT item 00, fixed).
- **Why it matters:** the blast radius of any future injection is the whole index, including `DROP`. It also makes "the data service is read-only" (README) unenforced.
- **Fix:** Create a `dcc_ro` role with `SELECT` on the public tables for data-service (plus a narrow `pairs` write grant for the daemon if it is deployed).

### BE-12 [MEDIUM] The CodeQL rationale for excluding Rust is false; BPS and websocket-api get no SAST
- **Evidence:**
  - `codeql.yml:37-41` says "rust — vendored in Rust native addons only".
  - BPS (7,320 lines) and websocket-api (3,873 lines) are first-party Rust services that are deployed publicly.
  - Code-scanning has 2 open alerts, both JS (#113 test file, #114 `packages/sdk/amm`). Neither touches these apps.
- **Fix:** Add `rust` to the CodeQL matrix, or correct the comment and document the deliberate gap.

---

## LOW

- **BE-13 [LOW]** `dcc_data` is inconsistent and never rolled back.
  - 73,333 rows covering 72,440 distinct heights, with 894 duplicate heights (up to h72461) and 820 missing heights in 1742..73290.
  - The PK is on `quantity` (`waves_data_pkey`) with `ON CONFLICT DO NOTHING` (`repo/pg.rs:225-232`), and no rollback path touches it.
  - It is read only via the `assets` view (max quantity), so the current DCC supply is still correct (it matched node `/blockchain/rewards`).
  - Fix: key it by height, and roll back with the block.
- **BE-14 [LOW]** data-service has no graceful shutdown. Node runs as PID 1 (`docker top`) with `Init=nil` and no SIGTERM handler (grep for `process.on` is empty). `docker stop` waits 10 s then SIGKILLs, dropping in-flight requests. The startup `.catch` only logs. Fix: add a SIGTERM handler that drains `serve()` and closes the pool, or use `init: true`.
- **BE-15 [LOW]** There is no Postgres `statement_timeout` in production: `PGSTATEMENTTIMEOUT` is unset in the container env, so `loadConfig.ts:84-88` gives `false`. Hono's 30 s `timeout()` aborts the HTTP response, but the query keeps holding a pool connection. Fix: set `PGSTATEMENTTIMEOUT=25000`.
- **BE-16 [LOW]** Alias recipients are returned bare. A transfer to an alias shows `recipient:"e2e-mu3vfj0l"`, while the node shows `alias:!:e2e-mu3vfj0l` (tx `EtPnED7u…`, h30034). The cause is `extract_recipient_alias` in BPS `convert.rs`. Clients cannot pass the value back to the node unchanged. The other 24 of 25 random transfers matched the node on every field.
- **BE-17 [LOW]** Services bind to all interfaces: data-service `*:8080`, websocket-api `0.0.0.0:8081`, BPS metrics `0.0.0.0:9090` (`ss -ltnp`). External probes found all of them filtered, so a firewall protects them. But code comments ("loopback-bound 127.0.0.1:8080" in `rateLimiter.ts`, and the compose comment) are false. Fix: bind to 127.0.0.1.
- **BE-18 [LOW]** Every backend container receives the whole `/opt/dcc/secrets/testnet.env`. Variable names only were confirmed in BPS, data-service and websocket-api: `ADMIN_DASHBOARD_GITHUB_PAT`, `ADMIN_DASHBOARD_GITHUB_OAUTH_CLIENT_SECRET`, `ADMIN_DASHBOARD_JWT_SECRET`, `SENTRY_AUTH_TOKEN`, `MATCHER_ACCOUNT_SEED`, `DCC_FAUCET_SEED`, `DCC_WALLET_SEED`. This is listed as accepted/deferred in `TESTNET-FINAL-PLAN.md:145`. Noted because the GitHub PAT and OAuth secret are not testnet-public keys. Use per-service env files before mainnet.
- **BE-19 [LOW]** The pairs daemon is not deployed. `pairs` has 0 rows, and `/v0/pairs` and `/v0/matchers/*/pairs` always return `[]`. No container runs `dist/daemons/pairs` (`docker ps`). Deploy the daemon (cron/sidecar) or document the endpoints as unsupported.
- **BE-20 [LOW]** Deploys are not gated on CI.
  - `deploy-data-service.yml`, `deploy-bps.yml` and `deploy-websocket-api.yml` fire on tag or `workflow_dispatch` from any ref. Only the BPS and ws deploys run `cargo nextest` first; the data-service deploy runs no tests.
  - `deploy-websocket-api.yml` re-implements the infra `deploy-container.yml` flow inline (duplicated, drift-prone).
  - The reusable workflow is pinned to infra `1bf177ab` (2026-09-28), and infra main has moved on since (`d885646` dependency bump).
- **BE-21 [LOW]** Docs have drifted:
  - BPS README: "Current testnet image `fbece975a`" (deployed is `fd2ec1ab`), and "use `0` for genesis" (compose and runbook say 0 is rejected; use 1).
  - data-service README: base URLs `api.testnet.decentral.exchange` (no DNS) and `api.decentral.exchange` (resolves to an unrelated 66.29.134.117); default port 3000 (deployed on 8080); "never writes to PostgreSQL" (the pairs daemon truncates and fills `pairs`).
  - websocket-api compose comment: "Caddy forwards WSS → ws://127.0.0.1:8080" (actual 8081).
  - BPS compose comment: "debian:12-slim runtime" (image is deb13).
  - websocket-api has no README, and its `Cargo.toml` `repository` points to the retired `Decentral-America/websocket-api`.
- **BE-22 [LOW]** Orphaned and stale artifacts:
  - `apps/data-service/package/package.json` is a tracked copy of the `effect@3.21.2` package manifest, which Renovate keeps bumping.
  - `apps/data-service/mainnet.sql` contains Waves mainnet matcher addresses and is unreferenced.
  - There are 11 obsolete `*.test.js.snap` files next to the `.ts.snap` files.
  - `package.json` `test:it` references the non-existent `variables.testnet.env`.
  - `src/logger/winston.ts` actually builds a pino logger.
  - The DB index `candles_assets_id_idx` is partial on Waves address `3PEjHv3…` and can never be used.
  - The `waves_data_pkey` name is left over from the Waves rename.
- **BE-23 [LOW]** The DCC asset's `timestamp` is reported as `2016-04-11T21:00:00Z` (the Waves genesis date) by `/v0/assets?ids=DCC`.
- **BE-24 [LOW]** The access log is very verbose: every request is logged twice with all headers (~122k lines/week). 400s from parse errors (`Max limit 100 exceeded`, `Date is not valid`) are logged at level 50 (error), which hides real errors. Redact or limit headers, and log 4xx at warn or info.

## INFO (verified OK or context)

- **INFO-1** The 2026-10-15 partition-drill rollback (~63445-63454) left **no orphans**:
  - Block IDs for 63435-63465 match the node exactly.
  - No BPS tx in 1742-73200 is absent from the chain, and no tx has the wrong height or type.
  - Rollback and microblock handling are correct for txs_1..18.
- **INFO-2** Data integrity for 1742+ (other than type 19):
  - Exchange txs match the node (amount, price, fee, timestamp, asset pair, after decimal normalisation).
  - Candles for the matcher address are correct.
  - The DCC supply matches node `totalDccAmount`.
  - Asset details match the node.
- **INFO-3** BPS is at chain tip (`bps_last_synced_height` 73283 when Prometheus was queried; node 73280-73290 during the audit). Over 7 days of BPS logs there are only 3 stream-lost WARNs, all auto-resubscribed (#119 works), and zero `Skipping transaction` warnings.
- **INFO-4** websocket-api handles protocol errors correctly (an invalid topic gets an `error` code 3). One Redis disconnect at 2026-10-10 03:22 (Redis restart) recovered (`pubsub_patterns:1`).
- **INFO-5** DB health: `bps_testnet` is 62 MB, autovacuum is current, dead tuples are below 2.5%, there are 4 backends out of `max_connections` 100, and disk use is 18%. Redis uses 1.9 MB of 256 MB with `volatile-lru`. The non-TTL state keys can never be evicted under that policy; this is minor now but relevant to BE-02.
- **INFO-6** The VPS compose files for all three apps, plus redis, caddy and prometheus, are byte-identical to infra `origin/main`. All containers are healthy. Resource limits are set (BPS 1g, data-service 512m, websocket-api 256m), with `read_only`, `cap_drop ALL` and `no-new-privileges`.
- **INFO-7** `pnpm audit --prod --filter @decentralchain/data-service...` found no known vulnerabilities. CI for bps.yml at `fd2ec1ab` and websocket-api.yml at `62143f1a` is green. Both gate fmt, clippy `-D warnings`, nextest, and cargo-deny/cargo-audit.
- **INFO-8** No exchange txs have occurred since h53463 (2026-10-11). The node agrees (22 type-7 txs in total). This is matcher or traffic scope, not a backend defect.

## Phase coverage

| Phase | Covered |
|---|---|
| 0 Orientation | READMEs, project.json, CI configs, compose/Caddy/Prometheus, deployment topology |
| 1 Debt / orphans | BE-22 |
| 2-3 Smells, architecture, 12-factor | Shutdown, config-in-env mismatches, env sprawl, port binding |
| 4 Security | Rate limiting/spoofing, CORS, injection probe, least privilege, secrets (names only), trivy, cargo/pnpm audit, code-scanning |
| 5 Tests and CI gates | Ran `test:http`; found CI omissions |
| 6 Release | Deployed versus main, deploy gating, rollback logic, workflow pins |
| 7 Docs versus reality | BE-21 |
| 8 Reliability / observability | Alerts, timeouts, pool, logs |
| 9 Data and migrations | Full block-ID and tx reconciliation against the node, rollback window, inheritance and FK cascade, down.sql present for all 5 migrations, orphan index |

Not covered: no BPS or websocket-api local cargo test run (CI green was used as evidence instead), and no mutation testing. Phase 10 (accessibility and i18n) does not apply.
