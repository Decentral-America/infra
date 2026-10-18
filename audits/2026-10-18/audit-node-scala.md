# node-scala audit — testnet-final readiness (2026-10-18)

Scope: `/Users/jourlez/Documents/Code/Blockchain/Ecosystem/node-scala` @ origin/main `fb4e980576` (local main == origin/main, fetched today). Live: 4 nodes on image `sha256:8fccecebb65a…` (label `org.opencontainers.image.revision=fb4e980576…`, `version=testnet-latest`), confirmed via `docker inspect` on VPS and `kubectl get pods` on LKE.
Method: read-only. Commands/bytes cited per finding. Two sub-reviews (consensus code; REST auth/CORS) were run in parallel; their top findings were re-verified by me by reading the cited lines (noted "re-verified").

Severity counts: BLOCKER 0 · HIGH 4 · MEDIUM 11 · LOW 16 · INFO 9

---

## HIGH

### NS-H1 — Deployed image ships a groth16 jar with NO Linux native library: RIDE `groth16Verify*` / `bn256Groth16Verify*` are broken on all 4 testnet nodes
- Evidence:
  - Pulled the jar from the live container: `docker exec node-scala-testnet cat /usr/share/dcc/lib/io.decentralchain.groth16-0.2.1.0.jar`. `unzip -l` shows only `META-INF/native/osx64/aarch64/libgroth16_jni.dylib`. The Maven Central `groth16-0.2.1.0.jar` contains `linux64/amd64/libgroth16_jni.so`, `linux64/aarch64`, windows and osx.
  - Ran it: a tiny class calling `com.decentralchain.groth16.bls12.Groth16.verify(...)` in `docker run --platform linux/amd64 eclipse-temurin:25-jre`.
    - With the LIVE jar: `java.lang.UnsatisfiedLinkError: Could not load library. Reasons: [java.lang.LinkageError: Unable to load library groth16_jni]`
    - With the Central jar: `loaded, verify=false`
  - Root cause: `ci.yml` job `docker` (which built the deployed image: tags `testnet-latest`, `testnet-pinned-fb4e980` → digest 8fccec…, per the GHCR versions API) runs `./.github/actions/install-dcc-native-deps` WITHOUT `build-groth16-native: "true"`. It then `mvn install`s groth16 from DecentralChain monorepo HEAD into `~/.m2` with no linux `.so` staged. `build.sbt:255` adds `Resolver.mavenLocal`, so that local jar wins over Central.
  - The `Test` job sets `build-groth16-native: "true"`, so CI tests pass while the shipped artifact is broken.
  - `lang/jvm/.../Global.scala:168-172` calls `Bls12Groth16.verify` / `Bn256Groth16.verify` directly. `UnsatisfiedLinkError` is a `LinkageError`, which `scala.util.control.NonFatal` treats as fatal. So `Try`-based guards such as `InvokeDiffsCommon.scala:747` `case Failure(e)` do NOT catch it, and it propagates out of script evaluation. Not exercised live; I did not send such a tx to the node.
- Why it matters: a documented RIDE built-in is non-functional on testnet. A tx or dApp that calls it throws a fatal error up through UTX / append paths. A node built correctly (publish-node-scala.yml does stage the `.so`) would accept the same tx, which is a fork / stall vector between differently-built nodes. Very likely the same for `mainnet-latest` / `stagenet-latest`, which come from the same job (not verified on prod hosts).
- Fix:
  - Stop source-building pinned-version artifacts that already exist on Central. Drop `Resolver.mavenLocal`, or drop the monorepo `mvn install` from `install-dcc-native-deps`.
  - At minimum, pass `build-groth16-native: "true"` in the `package` and `docker` jobs.
  - Add a smoke step that runs `groth16Verify` inside the built image (extend `UtilApp smoke`).
  - Rebuild and redeploy.

### NS-H2 — One malformed `EndorseBlock` (negative `endorserIndex`) permanently kills feature-25 endorsement intake on a node (re-verified)
- Evidence:
  - `state/EndorsementStorage.scala:70-73`: the only bound before `GeneratorIndex.checked(msg.endorserIndex)` is `msg.endorserIndex >= size`.
  - `state/GeneratorIndex.scala:10-11`: `require(x >= -1, ...)` THROWS `IllegalArgumentException` for ≤ -2 instead of returning `None`.
  - `network/messages.scala:124` / `BasicMessagesRepo.scala:378-379`: `endorserIndex` is a raw protobuf int32 from the wire, with no range check at decode.
  - `Application.scala:748-754`: `messageObserver.endorseBlocks.foreach { ... endorsementStorage.tryAdd(x) ... }` has no try/catch, and its CancelableFuture is discarded.
  - Monix 3.5.0 `ForeachSubscriber.onNext` bytecode (`javap -c` on `monix-reactive_3-3.5.0.jar`): `NonFatal(ex)` → `onError` → `Ack.Stop`. The subscription ends for good.
  - The throw happens before signature verification. Any P2P peer can trigger it (6868 is public on 50.116.30.244).
  - Inherited from upstream Waves: the same lines exist in `upstream-waves/...:node/src/main/scala/com/wavesplatform/state/EndorsementStorage.scala:60`.
- Why it matters: one 1-message, unauthenticated packet per node silently stops T0 endorsement collection and relay until restart. T0 is the chain's actual (authoritative) finality floor.
- Fix:
  - Make `checked` total (return `None` / `Left` for < -1), or reject `endorserIndex < 0` before calling it.
  - Wrap every `messageObserver.*.foreach` body in `Try` + log, and penalise the peer.
  - Add a unit test proving the subscription survives a bad message.

### NS-H3 — Unauthenticated `HotStuffProposal` lets any peer permanently wedge HotStuff (T2) voting (re-verified)
- Evidence:
  - `network/messages.scala:217`: `HotStuffProposal(view, blockId, justify)` has no signature and no sender.
  - `Application.scala:513-515`: the proposal path calls `hsCoordinator.onProposal` with NO `hsIngressSane` (votes and QCs get it at :519/:525).
  - `HotStuffCoordinator.scala:479-501` `onProposal` checks only `proposalValid(blockId)` (block is on my chain) and staleness. There is no leader check: `HotStuffPacemaker.leaderFor` / `isLeader` is never called on the receive path (`grep leaderFor`).
  - `HotStuffEngine.scala:113-123`: `justify = None` is accepted (`forall`).
  - `HotStuffSafety.safeToVote:35-36` needs only `view > lastVotedView` (plus extends-lock, which holds for the tip). `recordVote` raises `lastVotedView`, and `onLastVotedViewPersist` writes it to disk.
- Why it matters:
  - A proposal with `view=Int.MaxValue` for the current tip makes every honest replica persist `lastVotedView=Int.MaxValue`. No later view can exceed it, and peers' ingress guard drops their votes at that view. HotStuff finality stops network-wide and survives restarts (`HotStuffCoordinator.scala:291` then does `+1` on the restored view, which overflows).
  - Smaller fake views let anyone act as leader for any view.
  - Testnet runs `hotstuff.authoritative = true`. T0 keeps finalizing, so the chain does not halt, but `hotStuffFinalizedHeight` freezes.
- Fix:
  - Sign proposals with the view leader's BLS key and verify `leaderFor(view)`.
  - Apply `HotStuffIngressGuard.sane` to proposal `view` / `justify`, and cap `view ≤ pacemaker.view + K`.
  - Add an adversarial DST test.

### NS-H4 — Required status checks on `main` do not include the unit tests
- Evidence:
  - `gh api repos/Decentral-America/node-scala/branches/main/protection`: `required_status_checks.contexts = ["Build","Security Scan (Trivy)","Semgrep Scan (Scala)"]`, `enforce_admins=false`, `required_approving_review_count=1`.
  - "Check PR" (`sbt checkPR`: fmt + -Werror + unit tests) and "Test" are NOT required.
  - PRs #68, #70–#77: `reviewDecision=REVIEW_REQUIRED`, `reviews=0`, all merged (admin bypass). They did pass Check PR / Test, but nothing enforced it.
  - The "Security Scan (Trivy)" check that IS required scans nothing (NS-M3).
- Why it matters: for a consensus codebase, the only enforced gates are compile + two scanners. A red unit-test run cannot block a merge, and nothing reviews it.
- Fix: add "Check PR" and "Test" to the required contexts. Keep admin-merge as the documented single-maintainer exception, but record it.

## MEDIUM

### NS-M1 — Gossip marks HotStuff votes/QCs "seen" before validating them, and the seen-key omits the signature: honest votes can be pre-empted (re-verified)
- Evidence:
  - `Application.scala:463-470` `hsGossipOnce` puts the key and relays BEFORE `hsIngressSane` and before any BLS check.
  - Keys at :519/:525 are `s"v:${v.view}:${v.phase}:${v.blockId}:${v.voterIndex}"` and `s"q:${qc.view}:${qc.phase}:${qc.blockId}"`. All of these are predictable in the happy path.
- Why it matters: a peer that front-runs junk-signed votes or QCs under those keys causes the genuine ones to be dropped on every node, and floods the junk network-wide. This is HotStuff liveness only (T0 unaffected), but cheap and repeatable.
- Fix: validate (sanity + signature) before marking seen or relaying, and include a signature hash in the key.

### NS-M2 — RocksDB JNI in the running image (10.2.1) differs from the version compiled and unit-tested (10.10.1.1)
- Evidence:
  - `project/Dependencies.scala:140-141`: `rocksdbjni % "10.10.1.1"`, with the comment "fat JAR issue (#13893) resolved in 10.5.1+".
  - `docker/Dockerfile`: `ARG ROCKSDB_VERSION=10.2.1`. The tarball's rocksdbjni is `--exclude`d and replaced.
  - Live: `ls /usr/share/dcc/lib | grep rocks` shows `org.rocksdb.rocksdbjni-10.2.1-linux64.jar` on the VPS and on all 3 LKE pods.
  - The mismatch has existed since `0b6f3caede` (2026-05-30).
  - Renovate's dashboard does not track the Dockerfile ARG.
- Why it matters: production storage runs an engine version CI never unit-tests (only node-it, via the same Dockerfile, sees it). A JNI API used by 10.10 but absent in 10.2 would only fail at runtime.
- Fix: align the Dockerfile ARG with Dependencies (or stop replacing the jar now that #13893 is fixed), and add a Renovate regex manager for it.

### NS-M3 — The required "Security Scan (Trivy)" gate scans zero dependencies; there is no JVM dependency-vulnerability gate at all
- Evidence:
  - The repo has no lockfile (`git ls-files | grep -E '\.lock$|pom.xml'` returns nothing).
  - Local `trivy fs --scanners vuln --severity HIGH,CRITICAL .` reports `Number of language-specific files num=0` and `WARN Supported files for scanner(s) not found`, with an empty report table.
  - `on-push-default-branch.yml` job "Update Dependency Graph" has no submission step (`grep -n submission` finds nothing), so GitHub has no sbt graph. Dependabot shows 0 alerts because it sees nothing.
  - Counter-evidence: `trivy image` on the deployed digest scanned 132 jars and found 0 HIGH/CRITICAL. The only hits were OS `openssl` / `libssl3t64` CVE-2026-84782 (NS-L14).
- Why it matters: the gate looks enforcing but cannot fail on a vulnerable JVM dependency.
- Fix: add `sbt-dependency-submission` (or `sbt-dependency-lock` + Trivy), and/or `trivy image` on the built image as a required check.

### NS-M4 — Shipped artifacts are not reproducible or pinned: monorepo HEAD rebuilds replace pinned Central jars; three matrix images per commit; misleading `sha-` tag
- Evidence:
  - `install-dcc-native-deps`, `check-pr.yaml` and `publish-node-scala.yml` check out `Decentral-America/DecentralChain` at its default branch (no `ref:`) and `mvn install` curve25519 / blst / groth16 / protobuf-schemas.
  - Live jars differ from Central: sha256 of live `io.decentralchain.blst-0.3.16.0.jar` is `1b286a…` vs Central `e576ea…`; curve25519 `3586cc…` vs `7d56a1…`; groth16 as in NS-H1.
  - `dtolnay/rust-toolchain` uses `toolchain: stable` (floating).
  - `ci.yml` `docker` matrix `[mainnet, testnet, stagenet]` passes no network build-arg (identical inputs). It produced 3 digests for fb4e980 (mainnet 153fb7…, testnet 8fccec…, stagenet 9e9636…), and the shared `sha-fb4e980` tag points to the STAGENET digest, not the deployed one (GHCR versions API).
  - `Dockerfile` also runs `apt-get upgrade -y`.
  - The deployed image comes from `ci.yml`, not `publish-node-scala.yml`, so it has no `attest-build-provenance` (only buildx's default minimal provenance).
- Why it matters: the same version string can contain different native code per build (this is how NS-H1 happened), and `sha-<commit>` does not identify the deployed image.
- Fix: consume Central artifacts (pin by version + checksum), build once and re-tag per network, and use publish-node-scala.yml (with attestation) as the only release path.

### NS-M5 — The genesis-replay check cannot catch the bug class it exists for
- Evidence:
  - `genesis-replay-check.yml`: `min-height` default `'2500'` on both schedule and dispatch, while the known divergences were at heights 2640 (2026-09-01), 3325 and 56355 (see NS-M7). The live chain is at 73,274.
  - It exits 0 as soon as height ≥ 2500.
  - The error text still says "not the known/tracked height-3325 issue", which is stale (fixed).
  - It builds with plain `sbt buildTarballsForDocker`, without `install-dcc-native-deps`.
  - Run history: failure 2026-09-21, 09-28 and 10-05 (3 consecutive weeks red), then success 10-10 (dispatch) and 10-12.
- Why it matters: the weekly "regression check" passes before the first height that ever diverged.
- Fix: replay to (live height − small margin) or at least past the last known-divergence height plus the last penalty proof (> 56355), with a longer timeout or a snapshot-assisted replay.

### NS-M6 — The deployed commit and its consensus change (#77) have no CI node-it run
- Evidence:
  - `gh run list --workflow node-it.yml`: the last run on main is `104ddc70e8` (2026-10-11), and no run exists for `fix/hotstuff-equivocation-penalty`, `6ffedcf406` or `fb4e980576`.
  - The PR #77 body lists only unit suites run locally ("1012 succeeded").
  - checkPR runs no node-it (`check-pr.yaml` comment block). This matches the standing rule "node-it for consensus".
- Why it matters: the live consensus build was never exercised multi-node in CI. #77 changes `BlockDiffer.calculatePenalties`, a state-hash path.
- Fix: dispatch node-it `finalization.*` (and an equivocation drill scenario) on `fb4e980576` and archive the result, or make node-it a required post-merge gate for consensus paths.

### NS-M7 — Replay safety depends on an operator config key; the default `hotStuffEquivocationPenaltyHeight = 0` means "penalise from genesis"
- Evidence:
  - `settings/BlockchainSettings.scala:87` `hotStuffEquivocationPenaltyHeight: Int = 0`.
  - `BlockDiffer.scala:371` gates on it.
  - Testnet's `60000` lives only in infra `node-config/testnet/dcc.conf` and the 3 ConfigMaps (verified identical, and live == repo).
  - A historical proof is in block 56354 (PR #77 body).
  - The bundled `node/decentralchain-testnet.conf` (last touched 2026-06-08, genesis timestamp 1780810901602) is stale and lacks the key.
- Why it matters: any testnet node started from a config missing this key debits the historical proof and hits `InvalidStateHash` around height 56355. That is the same failure class as 2640/3325.
- Fix: hard-code per-chain activation (genesis-signature-keyed, like `PatchAtHeight`), or make the key mandatory for CUSTOM chains. Delete or refresh the stale bundled config.

### NS-M8 — HotStuff quorum weight uses live balance and still counts proven equivocators (re-verified)
- Evidence: `state/Blockchain.scala:315-317`: `GeneratorInfo(GeneratorIndex(idx), address, blsPk, blockchain.balance(address))`. That is the current balance, not the generating balance at the target height, and `conflictGenerators` is not filtered.
- Why it matters: two nodes at different tips can disagree on whether a QC meets 2/3. With `authoritative = true`, that means a different advisory floor per node. A forfeited equivocator still adds weight.
- Fix: use the generating balance at a height derived from the target, and exclude conflict generators.

### NS-M9 — The miner silently drops the initial-snapshot error and forges a block with no state hash
- Evidence: `mining/Miner.scala:178-186` `createInitialBlockSnapshot(...).toOption.map{...}`. A `Left` (e.g. `calculatePenalties` "Invalid penalized generator index") becomes `stateHash = None`, and that only surfaces later as `InvalidStateHash` on append. Nothing is logged.
- Why it matters: this is exactly the diagnostic gap that made 2640/3325 slow to root-cause.
- Fix: log the `Left` and return a mining `TemporaryFailure` with the message.

### NS-M10 — The unbounded legacy `_NUL_` BLS DST verify-fallback re-widens the H2 cross-context surface
- Evidence:
  - `crypto/bls/BlsUtils.scala:42` `BlsLegacyDomainSeparationTag`.
  - It is used verify-only at `HotStuffQuorum.scala:60,66`, `BlockEndorsement.scala:62,74` and `CommitToGenerationTransaction.scala:104`, with no height or activation bound.
  - Its justification (scaladoc :25-41) is legacy bytes on the "testnet-relaunch chain". The current chain's genesis is `timestamp=1788539579643` = 2026-09-04 16:32 UTC (`/blocks/headers/at/1`), and both the v2 split (`448d56557f`) and the fallback (`95abde3f01`) are ancestors of tag `testnet-relaunch-20260904`.
  - Not verified: whether any legacy-tag signature exists on the current chain (that needs a replay with the fallback disabled).
- Why it matters: any signer can still produce `_NUL_` signatures that verify in all three contexts. Safety reverts to the "distinct encoding lengths" argument that audit H2 called a latent trap.
- Fix: replay the live chain with the fallback disabled. If it is clean, delete the fallback; otherwise bound it to heights ≤ the last legacy signature.

### NS-M11 — `docs/hotstuff-audit-readiness.md` (the auditor entry point) is stale and self-contradictory
- Evidence:
  - Banner: "updated 2026-08-04 … frozen at `9c49632398` … image `sha-9c49632`". The last edit was 2026-09-03 (`git log`), and `git log 9c49632398..origin/main -- consensus/hotstuff` lists 27 commits (incl. #66 epoch hand-off, #67 pacemaker restart, #74, #77).
  - §5 table line 129 and the T8 row say `_POP_/_ENDORSE_/_HSVOTE_` are "the ONLY tags used anywhere in production (the legacy shared `_NUL_` tag was deleted 2026-09-02)". The code still verifies under `_NUL_` (NS-M10), and the doc's own §7 item 9 (lines 301-305) says the fallback was reintroduced.
  - T5 row says "live testnet exercise pending", but the drill ran 2026-10-13 (PR #77 body: proof in block 56354).
  - NS-H3 / M1 attack surfaces (unsigned proposal, pre-validation gossip) are not in the threat table.
- Why it matters: an external auditor would start from a wrong baseline.
- Fix: re-baseline to `fb4e980576`, reconcile §5/T8 with §7, and add rows for H3 / M1 / H2.

## LOW

### NS-L1 — Unknown config keys are silently ignored
- Evidence: deployed `dcc.conf` has `rest-api.cors = yes`, but `RestAPISettings.scala` has no `cors` field (`corsHeaders` only). My key cross-check (`dcc.conf` keys vs code identifiers) found no other unread node key (`dex.*` belongs to the matcher extension).
- Why it matters: there is no strict-key validation, so a typo in a consensus key would be silently defaulted. Compare NS-M7.
- Fix: remove the dead key. Consider pureconfig `ProductHint(allowUnknownKeys = false)` for the `dcc.blockchain`/`hotstuff`/`miner` subtrees.

### NS-L2 — `GET /addresses/seq/{from}/{to}` lists wallet addresses without an API key
- Evidence: `AddressApiRoute.scala:213-219`. `/addresses` returns 403 but `/addresses/seq/0/5` returns 200 live (via REST sub-review). Same as upstream.
- Fix: `withAuth`, or add it to Caddy's denylist.

### NS-L3 — `GET /utils/seed*` is public and returns server-generated seeds
- Evidence: `UtilsApiRoute.scala:218-224`, 200 live.
- Fix: block it in Caddy or remove the route.

### NS-L4 — Caddy injects the API key for `/peers/all|connected|…`, publishing committee topology
- Evidence: infra `update-caddy.yml` `@protected`. `/peers/connected` returns 200 live with IPs and node names. The routes are auth-gated in code (`PeersApiRoute.scala:25-30`).
- Fix: reduced view or a client allowlist.

### NS-L5 — BlockchainUpdates gRPC is hard-bound to 0.0.0.0
- Evidence: `grpc-server/.../events/BlockchainUpdates.scala:37`. Only compose's `127.0.0.1:6881` mapping and the firewall protect it (6881 is filtered on both IPs).
- Fix: add a `host` setting with default `127.0.0.1`.

### NS-L6 — 13 open Semgrep code-scanning alerts, triaged; none is an exploitable defect
- #68 `insecure-random` `UtilApp.scala:29`: FALSE POSITIVE. `scala.util.Random` only creates throwaway BLS keys in `doSmokeTest` (:377/:382).
- #67 / #64 `node-it.yml:99,120` (`inputs.suite`) and #65 `nightly-slow-tests.yml:36` (`inputs.seed-count`): REAL but low. workflow_dispatch inputs are interpolated into `run:`, and only write-access users can dispatch. Fix: pass via `env:`.
- #63 `on-release-published.yml:36` `github.ref_name`: low. Tags need write access. Fix: `env:`.
- #59 `ci.yml:280` `github.base_ref`: low. It must be an existing base branch. Fix: `env:`.
- #60 `ci.yml:303` curl|sh of oasdiff install.sh from mutable tag `v1.26.0`: low/real. Pin by commit SHA or verify a checksum of install.sh.
- #52 / #53 `deploy-node-scala.yml:45,60` `secrets: inherit`: low. The callee is SHA-pinned (infra `cd76adef…`); pass explicit secrets.
- #54–#57 `renovate.json:14-29` missing `minimumReleaseAge`: valid hygiene. Add `"minimumReleaseAge": "3 days"`.

### NS-L7 — A voter can appear in both `fv.valid` and `hotstuffConflicts`
- Evidence: `state/appender/package.scala:308-339` (consensus sub-review). Finality weight is unaffected because conflicts are dropped, but the block is accepted.
- Fix: add `raiseWhen(fv.valid.contains(...))`.

### NS-L8 — Miner/appender portfolio-netting asymmetry
- Evidence: `BlockDiffer.scala:497-502` vs `:170-172`. If the penalised address is the miner and its reward exactly equals the deposit, the miner emits a zero-delta balance entry that the appender skips, so the state hash differs (consensus sub-review; practically unreachable).
- Fix: net in the miner as well.

### NS-L9 — Equivocations on the last ~`settledDepth` heights of a period can never be included
- Evidence: `Miner.scala:805` folds only `p.committeeEpoch == forgeHeightPeriodIndex`.
- Fix: also accept the previous epoch inside the transition window.

### NS-L10 — `HotStuffCoordinator._detectedEquivocations` is written and read across threads with no `@volatile`
- Evidence: the miner thread reads it via `Application.scala:454`. Worst case is a stale immutable Vector.
- Fix: `@volatile`.

### NS-L11 — Version string is hard-coded and does not identify the build
- Evidence:
  - `version.sbt` has `ThisBuild / version := "1.8.0"`.
  - `-Dproject.version=…` in publish-node-scala.yml:118 is a no-op, as `on-push-default-branch.yml:145` itself notes.
  - Live `/node/version` returns `"DecentralChain v1.8.0"`.
  - No `v1.8.0` tag exists (`git ls-remote --tags`: latest `v1.7.0`, 2026-07-25).
  - Every build since 09-02 reports 1.8.0.
- Fix: derive the version from `git describe` (sbt-git is already present), and tag the testnet-final release.

### NS-L12 — README and bundled configs are misleading
- `README.md:28-39` says `java -jar node/target/dcc-all*.jar`. No assembly plugin or `dcc-all` artifact exists (`grep assembly|dcc-all` in build files: none).
- "A network configuration file from node/" points to `node/decentralchain-testnet.conf`, which is a different, dead genesis (2026-06-07) and is not packaged (`node/build.sbt:82` packages only the sample).

### NS-L13 — `deploy-node-scala.yml`: dangerous default and mislabelled tag
- `network` defaults to `mainnet`.
- The image tag uses `${{ github.sha }}` while the build uses `inputs.ref`, so a ref-dispatched image is labelled with the wrong commit.
- Fix: no default, and tag with the resolved ref SHA (publish output `ghd.sha`).

### NS-L14 — Deployed image has OS-level HIGH CVE-2026-84782
- Evidence: `trivy image` on 8fccec… reports `openssl` / `libssl3t64` 3.0.13-0ubuntu3.15, fixed in 3.0.13-0ubuntu3.16.
- Fix: rebuild (base digest bump pending in Renovate).

### NS-L15 — Renovate is configured but not delivering
- No Renovate PR has been created since #2 (May). The dashboard (issue #3, updated 10-16) shows ~33 updates "Awaiting Schedule" despite PR #65 widening the schedule, and 10 orphan `renovate/*` branches from 2026-09-14, 35 commits behind.
- Lookup failures for web3j, grpc, sttp, sbt-sonatype, scalajs-stubs and action-surefire-report mean those dependencies get no updates.
- Fix: debug the schedule/timezone (`"* * * * 1"` with `America/Costa_Rica`). Fix the `undefined` package names, which come from Dependencies.scala helper functions Renovate can't parse.

### NS-L16 — Test gaps for recent fixes
- `c80c4d1c39` (#68, lang "long overflow" JIT fast-throw) has no dedicated test.
- `6905359779` (drill RawBytes) has no test.
- checkPR runs `node-tests` including `SlowTest` (50 seeds), while ci.yml excludes it (`-l com.decentralchain.tags.SlowTest`), so the two "unit test" gates differ.
- Covered:
  - #68 grace: `KeyBlockReferenceAfterGraceSuite`
  - #70/#71/#73: `UtxPriorityPoolSpecification`
  - #72: `PendingTransactionRetrySpec`, `TimedTransactionPublisherSpec`
  - #74: `KeyBlockReferenceAfterGraceSuite` (extended)
  - #77: `HotStuffEquivocationPenaltySuite` (also checks miner/appender hash agreement via testkit `Domain.scala:520`)
  - #75/#76: test/tooling only

## INFO

### NS-I1 — Clone and branch hygiene
- `fix/height-3325-and-hotstuff-slashing` (local only, 14 commits ahead / 188 behind, 2026-08-23):
  - Its T5 work is superseded on main (`HotStuffEquivocationProof` etc. exist there).
  - 3325 is fixed on main (`ade354adcb` is an ancestor).
  - It still holds two regression tests absent from main: `BlockDifferTest` "a commitment round spanning two blocks … does not diverge the state hash" and "the same commitment-round shape, repeated for a second rotation …". It also holds `docs/height-3325-diagnostic-log.md`.
  - Recommend cherry-picking the tests, then deleting the branch.
- `feat/equivocation-drill-tool` (local + remote): superseded. Its diff vs main is just #77 reversed plus a test-path rename.
- `fix/genesis-replay-stale-peer` and `fix/nodeit-keep-committee-during-fault`: patch-equivalent to main (`git cherry` `-`).
- 20 local branches fully merged, and local `dev` tracks a deleted remote (`[origin/dev: gone]`).
- 12+ merged remote branches not deleted.
- 2 untracked local plan files `docs/superpowers/plans/2026-09-12-inprocess-{peer-stall-detection,self-commit-generation}.md` are not on origin.
- No stashes or worktrees.

### NS-I2 — F-1: `authoritative = true` finality is advisory, not enforcing
- Documented deliberate-prudent at `HotStuffSettings.scala` scaladoc and audit-readiness banner.
- `/blocks/height/finalized` = 73272 vs tip 73274 (it advances), but it does not refuse reorgs.

### NS-I3 — All recent PRs were admin-merged with zero reviews
- Single maintainer; bus factor 1 on consensus code. Ties to NS-H4.

### NS-I4 — `docs/hotstuff-HANDOFF.md` (2026-08-04) is stale
- "all work on node-scala `dev`": dev was deleted.
- Image `dev-hotstuff` and version `v1.6.3` are both outdated.

### NS-I5 — Debt markers and skipped tests
- 4 TODO/FIXME in `node/src/main` (the consensus ones at `FinalizationState.scala:93-94` and `EndorsementStorage.scala:16` are not live risks).
- 3 `@nowarn` / `SuppressWarnings`.
- 10 `ignore(...)` tests, all upstream-inherited perf or legacy cases.

### NS-I6 — Verified clean: consensus config parity
- The `dcc.blockchain` section (functionality, rewards, genesis, pre-activated 1–25, `generation-period-length=100`, penalty height 60000) and `features.supported=[26]` are byte-identical across main / gen-0 / gen-1 / val-0.
- Live `/etc/dcc/dcc.conf` on the VPS equals `infra/node-config/testnet/dcc.conf`, and the 3 live ConfigMaps equal `nodes.yaml` (diff modulo comments and secrets).
- All 4 nodes run digest 8fccec… with 0 restarts since 2026-10-15T15:53Z.

### NS-I7 — Verified clean: other areas
- Image JVM dependencies: Trivy found 0 HIGH/CRITICAL across 132 jars.
- Sensitive REST routes are all `withAuth` in code, with constant-time compare and empty-hash = deny.
- The Caddy denylist resists case, `//`, `%2F` and dot-segment bypasses.
- The REST and gRPC ports are filtered from the internet; only P2P 6868 is open.
- No `Random` or floating point in diff/validation; the state-hash builder uses a sorted set; carry-fee is a single shared function for miner and appender (the 2640 fix holds).

### NS-I8 — CI health (live)
- Main `fb4e980576`: Build, Test, Package, Docker×3, Trivy, Semgrep and Dependency-Graph all green.
- Nightly slow tests green 10-14..10-18.
- Genesis replay green 10-12 (but see NS-M5).
- No scheduled job is currently red.

### NS-I9 — Known items, confirmed status unchanged
- `quorum=0` on main is by design.
- `slashing-enabled = no` on all 4, so the #77 forfeiture path is exercised only in unit tests.
- Task 6.1 has no evidence (not re-investigated).
- TwoNodesFinalization flake: not re-run.

---

## Phase coverage
- Phase 0 orientation: full.
- Phase 1 debt markers / dead code: partial (grep-based; no dead-code tool for Scala 3 run).
- Phase 2/3 code smells and architecture: partial (consensus paths only; no `sbt dependencyTree` / jdeps graph run).
- Phase 4 security: full for REST / P2P-message / CI-injection / dependency surfaces, partial for crypto (read-level).
- Phase 5 tests: partial (gates, skips, coverage of #68–#77; did not run the suite locally; no mutation testing).
- Phase 6 CI/CD: full (live runs, branch protection, image provenance, tags).
- Phase 7 docs: partial (README, audit-readiness, HANDOFF sampled; RUNBOOK not fully traced).
- Phase 8 reliability: partial (Monix subscription failure mode found; no load or perf testing).
- Phase 9 data: N/A beyond state-hash / replay (covered in M5 / M7).
- Phase 10: N/A.
- Phase 11 licensing: not covered.
- Phase 12: lightweight (bus factor, review signal).
- Not run: full `sbt checkPR` locally (> 15 min), node-it, a live groth16 tx, a replay with the legacy DST disabled.
