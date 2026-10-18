# Matcher audit (repo + live testnet deployment), 2026-10-18

Scope: `/Users/jourlez/Documents/Code/Blockchain/Ecosystem/matcher` (origin/main = `124f1013c`) and the live
`matcher-testnet` container on 50.116.30.244. Read-only. Standard: REPO-AUDIT-PROMPT.md. Everything below was
checked today. Nothing was carried over from AUDIT-REPORT.md without re-checking.

Totals: BLOCKER 0 · HIGH 3 · MEDIUM 6 · LOW 13 · INFO 9

---

## HIGH

### H1: The matcher's vendored node protos are stale. Its own node-extension artifacts are unsafe on node 1.8.0, and the live node runs a hand-stripped plugin binary built from a 3.5-month-old commit
- **Evidence**
  - `matcher:dex-grpc/src/main/protobuf/dcc/block.proto:70-75` has `FinalizationVoting` with 4 fields.
  - The canonical schema in `DecentralChain:packages/sdk/protobuf-schemas/proto/dcc/block.proto:86` adds `repeated HotStuffEquivocationProof hotstuff_conflicts = 5` plus the HotStuffVote and QuorumCertificate messages, about 80 lines missing in the matcher copy. node-scala consumes `protobuf-schemas 1.6.6` (`node-scala:project/Dependencies.scala:44`).
  - `dex-grpc/build.sbt` comment: "Proto sources are vendored ... (v1.6.3)".
  - A `grpc.jar` built from matcher main therefore contains `io.decentralchain.protobuf.block.*` classes that shadow the node's own classes. This is the failure class behind the 2026-10-04 miner `NoSuchMethodError` and the 5 FATAL shutdowns (infra `scripts/check-plugin-shadowing.sh` header; TESTNET-FINAL-PLAN RC3: "Rebuilding from matcher main does NOT fix it").
  - The live plugins are `/opt/dcc/plugins/testnet/{ext,grpc}.jar`, and their sha256 equals infra `plugins/testnet/*.jar` (f777444a…, 6894379…).
  - The MANIFEST `Implementation-Version: 0.0.0-0767d2468…`, 2026-06-29. That is 320 commits behind matcher main and was hand-stripped in infra `c08ff6b` and `9ea3991`.
  - The plugin was compiled against node 1.6.x-era `node`/`grpc-server` APIs and now runs inside node v1.8.0 (`/node/version`).
- **Why it matters**
  - The only thing keeping the node alive is an out-of-band binary that can't be reproduced from any repo, plus a guard script.
  - The matcher repo's own outputs would crash the node if installed: the CI `plugin-jars` artifact (ci.yml:137-151), the deb/zip from `packageAll`, and the dex-ext Docker image.
  - Binary-compat breaks in code paths not exercised yet (the NoSuchMethodError class) stay latent.
- **Fix**
  - Delete the vendored `dcc/*.proto` from dex-grpc and depend on `protobuf-schemas` (same version as node-scala), using it only as an include path so only `com/decentralchain/dex/**` classes are generated.
  - Build ext.jar and grpc.jar from matcher main in CI against the live node version.
  - Run `check-plugin-shadowing.sh` in matcher CI against the live node image.
  - Publish the jars with provenance, and have infra consume that artifact instead of committed binaries.

### H2: No matcher integration, E2E or OWASP test has run in CI since August, yet four major refactors were merged and deployed
- **Evidence**
  - `ci.yml:268` and `ci.yml:321` say integration-dex-integration-it and integration-dex-it run on `if: startsWith(github.ref, 'refs/tags/v')`.
  - `owasp-audit.yml` and `nightly-network-tests.yml` trigger only on `push: tags: ['v*']` or workflow_dispatch.
  - The newest tag is `v2.4.21`, dated 2023-02-07 (GraphQL refs query). No CI run has ever had a tag head branch (`gh run list -w CI -e push` filtered on `v*` returns `[]`).
  - Tag-only gating began at `873921f26` (2026-08-12).
  - Since then these were merged with only unit tests: sbt 2 migration, all-deps and Scala bump (`1e190d9ef`), sttp3→4 migration (`947e790ba`), and Docker sbt 2 rewrites (`cbcb93e81`, `7331f634d`).
  - Last OWASP run: 2026-09-28 on `b9fd98669`, before the all-deps bump.
  - Network/chaos suites: one manual dispatch on 2026-10-06 (`c2f07b47f`).
  - The latest main CI run shows both Integration jobs `skipped`.
- **Why it matters**: The matcher's settlement, order-book and node-interaction E2E suites (117+ dex-it suites) are the real gate. Right now they gate a release event that never happens.
- **Fix**: Either cut real release tags (v3.x) before each deploy, or add a `workflow_dispatch` or pre-deploy job that runs the full sharded dex-it and dex-integration-it, and make `deploy-matcher.yml` `needs:` it. Run OWASP on a weekly schedule; NVD data changes without any code change.

### H3: The matcher container receives the whole shared secrets env file (~40 keys), including non-testnet org credentials
- **Evidence**
  - `infra:compose/matcher.yml` declares `env_file: /opt/dcc/secrets/${NETWORK}.env`. It is byte-identical to the live `/opt/dcc/compose/matcher.yml` (diff empty).
  - `docker inspect matcher-testnet` Config.Env includes the following keys. Only names are listed here; values were not recorded in this report: ADMIN_DASHBOARD_GITHUB_PAT, ADMIN_DASHBOARD_GITHUB_OAUTH_CLIENT_SECRET, ADMIN_DASHBOARD_JWT_SECRET, SENTRY_AUTH_TOKEN, POSTGRES__PASSWORD/PGPASSWORD, REDIS_PASSWORD/REPO__PASSWORD, NODE_REST_API_KEY, MAIN_NODE_REST_API_KEY, MATCHER_ACCOUNT_SEED, MATCHER_ACCOUNT_PASSWORD, DCC_FAUCET_SEED, DCC_WALLET_SEED, DCC_WALLET_PASSWORD, DCC_CANARY_SEED.
  - The matcher reads its config only from local.conf (compose comment: "no hardcoded env vars"), so it needs none of these.
  - TESTNET-FINAL-PLAN.md:145 records "env-file sprawl … per-service env files for mainnet (testnet seeds are public by decision)" as accepted/deferred. That rationale covers testnet seeds. It does not cover a GitHub PAT, an OAuth client secret or a Sentry token, which are real org credentials.
- **Why it matters**: The matcher is an internet-facing JVM HTTP service. Any RCE, deserialization bug or `/proc/self/environ` read in it, or in any other container given the same env file, leaks GitHub, Sentry and admin-dashboard credentials.
- **Fix**: Per-service env files. The matcher needs no env_file at all (its secrets already live in local.conf). Rotate the PAT, OAuth secret and Sentry token if there is any doubt.

## MEDIUM

### M1: The live image was deployed from an unmerged feature branch, the deploy has no CI gate, and "Deploy Matcher" on main is still red
- **Evidence**
  - `gh run list`: Deploy Matcher success 2026-10-10T01:49 on branch `fix/dockerfile-sbt2-package` @41790d262 (workflow_dispatch). That PR's own CI started at 01:37.
  - The last Deploy Matcher on main (`c2f07b47f`, 00:37) failed and was never re-run after #33 merged (`42037efb7`).
  - `deploy-matcher.yml` has no `needs:`/`workflow_run` link to CI and can be dispatched from any ref.
  - The repo secret `TESTNET_DEPLOY_SSH_KEY` was updated 2026-10-10T02:36:55Z, after the last successful deploy. The deploy path with the current key is unverified.
  - Mitigating: `git diff --stat 41790d262 42037efb7` is empty, and `41790d262..origin/main` changes only `renovate.json`. So the running code equals main.
  - SECURITY.md says "'current' is whatever is deployed from the tip of `main`", which was false for this deploy.
- **Fix**: Restrict the deploy to `refs/heads/main` (an `if: github.ref == 'refs/heads/main'` check or an environment branch rule). Require a green CI/integration run for the SHA. Re-run Deploy Matcher on main once to turn the status green and prove the rotated key.

### M2: The pinned node version 1.7.0 doesn't match the live node v1.8.0, and the label is misleading
- **Evidence**
  - `dccNode.sbt:3` (`dccNodeVersion := "1.7.0"`), `ci.yml:33` and `nightly-network-tests.yml` all pin 1.7.0.
  - `dex-ext/build.sbt:121` bases the dex-ext IT image on `ghcr.io/decentral-america/node-scala:${dccNodeVersion}`, which is the July 25 image. It is the only semver image tag (packages API) and the only release.
  - `setup-dcc-jvm-deps/action.yml` publishes node-scala **main HEAD** to Maven under the version string "1.7.0". So compile-time classes are 1.8.0-era but labelled 1.7.0, while the IT runtime node really is 1.7.0.
  - node-scala `version.sbt` = 1.8.0, with no tag or release. The live node reports `DecentralChain v1.8.0`. The dex-ext deb says "Compatible with 1.7.0 node version" (`dex-ext/build.sbt:44`).
  - Also listed as open in TESTNET-FINAL-PLAN.md:88.
- **Why it matters**: The integration suites, when they run at all, test against a node without HotStuff, T5 or feature-26 behaviour, which is exactly where H1's shadowing hazard lives.
- **Fix**: Cut node-scala v1.8.0 (tag and image), bump `dccNodeVersion` and the CI env together, and check out node-scala at that tag in the composite action instead of HEAD.

### M3: The PR "Security Scan (Trivy)" gate checks nothing
- **Evidence**
  - `ci.yml:623-631` runs a Trivy `fs` scan of `.`.
  - The latest main run's job log (job 115058356287) shows `Number of language-specific files num=0` and an empty Report Summary.
  - The sbt build has no lockfile that Trivy can read.
  - The only effective dependency CVE signal is Dependabot through the post-merge SBOM upload (SBOM 305 packages, 0 open alerts). OWASP is effectively off (H2).
- **Fix**: Scan the staged runtime classpath (`trivy rootfs` on `sbom-scan/`, or the SBOM via `trivy sbom`) on PRs, or run `trivy image` on a PR-built image.

### M4: The live order→settlement path hasn't been exercised since the node redeploy, and matcher monitoring is liveness-only
- **Evidence**
  - `/transactions/address/31VMNV…/limit/100` shows 22 ExchangeTransactions (v2) from h49027 to h53463. The last one was 2026-10-11 15:40 UTC.
  - Chain height is now 73258. node-scala-testnet was recreated 2026-10-15T15:53 with a new image (revision fb4e980).
  - infra `admin-e2e.yml` was last dispatched 2026-10-11 15:38. It has no schedule, and its comment defers to the canary, which does transfers and not matcher orders.
  - `monitoring/exporter.py:74` only probes `GET /matcher` for liveness.
  - Matcher `kamon.enable = no` (application.conf:931), so there are no matcher metrics.
  - `monitoring/config.alloy:72-86` parses matcher logs as JSON for a `level` label, but matcher logs are plain text. The Loki series for `{container="matcher-testnet"}` has no `level` label (checked).
  - Positive evidence: the matcher is synced (`StatusTransitions Normal + Appended h=73261`) and recovered by itself after the node restart (UTX stream errors only between 15:53:17 and 15:53:36 on 10-15).
- **Why it matters**: A regression in settlement after the node upgrade would go unnoticed until a user trades.
- **Fix**: Add a scheduled place→match→ExchangeTx canary (two funded accounts, a tiny cross on a fixed pair). Alert on settlement failure, matcher `processedHeight` lag behind the node, and `ERROR` in matcher logs. Fix the Alloy stage with a regex for the logback pattern.

### M5: Three divergent writers of the matcher's local.conf, and two of them would break the live matcher identity
- **Evidence**
  - The live local.conf structure (values masked) matches `infra:.github/workflows/push-secrets.yml:306-337`: `account-storage.type = in-mem`, `seed-in-base-64`, 640 root:113.
  - `infra:scripts/push-secrets-local.sh:208-224` writes `type = "encrypted-file"` + account.dat, with mode 644 root:deploy. That is world-readable, though it then contains only the password.
  - `infra:terraform/scripts/bootstrap.sh:346-363` writes encrypted-file with placeholders.
  - No `account.dat` exists in `/opt/dcc/data/matcher-testnet` (listed).
- **Why it matters**: Running the "local" fallback script or a re-bootstrap would switch the matcher to an encrypted-file key that doesn't exist (startup failure), or to a different key.
- **Fix**: Keep a single generator, the push-secrets.yml template. Make the other two call it or delete their matcher blocks.

### M6: The README is materially inaccurate about how the matcher is built, released and run
- **Evidence** (`matcher:README.md`):
  - Lines 4-13 point to the Releases section and a release badge. `gh release list` is empty.
  - Line 10 says "Fork of Decentral-America/matcher", which is self-referential.
  - Lines 178-186 cite main class `com.decentralchain.Application` and `_local/mainnet.sample.conf`. No `_local/` exists in the tree, and the main class is auto-discovered (`dex/build.sbt:146`).
  - Lines 271-292 use `dcc-dex` binary, service and paths, but the image uses `/usr/share/decentralchain-dex/bin/decentralchain-dex` (`docker/entrypoint.sh:48`).
  - Line 261 links node-scala branch `version-1.2.x`, which doesn't exist (`git ls-remote` is empty).
  - Lines 204-211 carry upstream 2.3.x version history.
  - The actual production path (Docker image + infra compose + push-secrets local.conf + infra plugin jars) isn't documented at all.
- **Fix**: Rewrite the Install/Run sections around the container deployment, and remove the upstream Waves-era release and DEB text.

## LOW

- **L1: The image's own HEALTHCHECK is broken.**
  - Evidence: `Dockerfile:120-121` uses `wget`, but `docker exec matcher-testnet sh -c 'command -v wget curl'` prints nothing. The compose healthcheck overrides it, so the deploy isn't affected, but anyone running the image directly gets a permanently unhealthy container.
  - Related comment drift: `compose/matcher.yml` says "6886 = 0x1AEE" while the code correctly uses `:1AE6`.
  - Fix: use the same `/proc/net/tcp` check in the Dockerfile.
- **L2: Obsolete JVM flag.** `docker/entrypoint.sh:33` sets `-XX:+ZGenerational`. The startup log says "Ignoring option ZGenerational; support was removed in 24.0". Remove it.
- **L3: The version can't be traced to a commit.**
  - `/matcher/settings` reports `matcherVersion "0.0.0-20261010T014227"`, because `.dockerignore` excludes `.git`, so sbt-git (build.sbt:186-188) can't describe the tag.
  - The image label `org.opencontainers.image.version` is the tag string `matcher-testnet-<sha>`, and `description` is `""`: deploy-matcher's metadata-action overrides the Dockerfile LABELs.
  - Fix: pass `-Dproject.version`/`VERSION` from git in CI into sbt.
- **L4: Production logs at DEBUG.** 242,578 of 309,280 matcher log lines in 7 days are `DEBUG io.grpc.netty.NettyClientHandler` PING frames, plus about 21k each from CombinedStreamActor and BlockchainUpdatesControlledStream. Raise these loggers to INFO in the shipped logback config.
- **L5: Dead secret-bearing config in the live local.conf.** `redis.address` (with password) and the `postgres{}` block are both unused: `redis-internal-client-handler-actor.enabled = false` and `order-history.enable = no` (application.conf:429-431, 820-821). The Postgres part is acknowledged in TESTNET-FINAL-PLAN:145. Drop both from the push-secrets template until those features are enabled.
- **L6: Listeners bind to all interfaces.** Matcher REST binds 0.0.0.0 (`dex/src/main/container/dex.conf:7`) on host networking. Node DEX gRPC 6887 and BlockchainUpdates 6881 also bind 0.0.0.0 (dcc.conf:92-214, `ss -ltn`). They are only protected by the host firewall; an external probe found 6886, 6887 and 6881 filtered. Caddy reaches the matcher on localhost, so bind 127.0.0.1 for defense in depth.
- **L7: The order book is polluted with E2E markets.**
  - `/matcher/orderbook` lists 22 markets. 21 are `E2ETestTkn/DCC` (one per E2E run) and 1 is `DEXPROOF/DCC`. All 22 have 0 bids and 0 asks.
  - `priceAssets: []`, `white-list-only = no`, no blacklists.
  - There are no curated pairs for the exchange UI.
  - Fix: E2E should cancel or reuse a fixed pair, plus a curated `price-assets` and allowed-pairs list.
- **L8: Deploy workflow hygiene** (`deploy-matcher.yml`):
  - The `network` input defaults to `mainnet` (l.9), and there are no MAINNET_* repo secrets.
  - `ssh-keyscan` TOFU (l.174).
  - Mutable `matcher-<net>-latest` tag.
  - Duplicates publish-matcher.yml's build without its `provenance`/`sbom` (publish-matcher.yml:115-116).
  - Fix: default to testnet, pin the host key in a secret, and reuse publish-matcher via `workflow_call`.
- **L9: Stale comments in CI and the Dockerfile.**
  - `ci.yml:234` says "Runs on push to main ONLY, not on PRs", but it is tag-only (l.268).
  - `ci.yml:301` says "Sharded 3 ways", but there are 8 shards.
  - `ci.yml:344-345` says "matcher has never had a versioned release" while v2.4.x tags exist.
  - `Dockerfile:5,32` uses `SBT_VERSION=1.12.11` with sbt-1.12 launcher comments, while the build is `sbt.version=2.0.9`.
- **L10: Orphaned file.** `scalastyle-config.xml` is tracked, but there is no scalastyle plugin in `project/plugins.sbt` (replaced by scalafix, per `.scalafix.conf:1`).
- **L11: Instrumentation agent with nothing consuming it.** The Kanela agent is installed in production (startup log "Kanela agent installed"; kamon executor instrumentation frames appear in stack traces), but `kamon.enable = no`. It adds bytecode instrumentation and Unsafe warnings and is the same agent behind the documented unit-test NPE storms. Drop `-javaagent` or enable kamon with a Prometheus scrape (ties into M4).
- **L12: SECURITY.md has a false statement.** Its "current = tip of main" claim (see M1) is inaccurate, and its supported-versions table (v2.4.x) refers to upstream tags, not DCC releases.
- **L13: Stale runbook.** `infra:runbooks/reset-matcher-testnet.md`:
  - It says "Not executed yet", but the matcher DB was re-created 2026-10-10 (RocksDB IDENTITY 00:42).
  - Its empty-key warning section is now resolved (infra #184; the live config has seed-in-base-64).
  - It says "LevelDB" for what is RocksDB.

## INFO (verified, no action needed)

- **I1:** The running image `matcher@sha256:a5afd5b3…` has label revision `41790d262`. Its tree equals origin/main except `renovate.json`.
- **I2:** The container is healthy with 0 restarts since 2026-10-10T01:53, using 1.04 GiB of 2 GiB with a 1g heap. RocksDB data and logs persist across recreation on the bind mount and the anonymous log volume (gc.log from Sep 17 still present). It is synced with the node and survived a node restart unattended.
- **I3:** Matcher account 31VMNV… has 10,000,000.066 DCC. The public key matches `/matcher`. Settings are `orderFee dynamic baseFee 300000`, `rates {DCC:1}`, `networkByte 33`, and `exchange-tx-base-fee 300000`.
- **I4:** The live plugin jars are byte-identical to infra `plugins/testnet` (see H1 for their provenance problem).
- **I5:** Container hardening is good: `read_only`, `cap_drop: ALL`, `no-new-privileges`, config mounted read-only, local.conf 640 root:113, and 1 API-key hash configured. Private routes reject requests without the key ("Provided API key is not correct").
- **I6:** Caddy applies a 300 req/min/IP rate limit to the matcher with an E2E bypass header; the token is not in the public infra git (`git grep` count 0). It also has a CORS allowlist, HSTS preload and nosniff.
- **I7:** Order v4 is disabled by upstream default (`order-v-4-start-offset = Long.Max`, application.conf:207), so `orderVersions` is [1,2,3]. This is deliberate upstream behaviour; enable it explicitly if v4 orders are wanted.
- **I8:** Dependabot has 0 open alerts and the dependency graph has 305 packages (SBOM upload works). Unit/compile/scalafmt/scalafix CI on main is green (run 38321496749).
- **I9:** Matcher log errors over the last 7 days: 25 WARN (19 UTX stream reconnects during the 10-15 node restart, 6 malformed-header bot requests) and 0 ERROR. No settlement failures were logged.

## Process note

While inspecting the container env and grepping local.conf, a redaction regex didn't match and some secret values were printed to this auditor's session output. Nothing was written to any file or report, and nothing left the machine beyond the existing SSH session. If the session transcript is considered sensitive, treat the GitHub PAT, OAuth secret, Sentry token, Redis and Postgres passwords as exposed to the transcript. This strengthens H3's rotation advice.

## Phase coverage
- **Covered:** P0 orientation; P4 security (secrets, deps, Trivy/OWASP, container, TLS/CORS/rate-limit, authz on private routes); P5/P6 testing and CI/CD (all 5 workflows read, run history, job logs); P7 doc truth (README, SECURITY.md, runbook, CI comments); P8 reliability (restart/reconnect evidence, health, resources, logs); P9 persistence (RocksDB data dir, events queue, order-history).
- **Light:** P1 (debt markers counted: TODO 7, HACK 1, @nowarn 2, scalafix:off 12; orphan file found; no dead-code tool run); P2/P3 (no Fowler/SOLID pass on Scala code; the prior audit's OrderValidator Either-pattern judgment wasn't re-done); P12.
- **Skipped:** P10 (N/A, no UI); P11 licensing (the prior audit's GPL check wasn't re-run).
- **Not done (read-only/cost):** placing a live order; running dex-it locally (>15 min); Trivy on the deployed image (private GHCR pull).
