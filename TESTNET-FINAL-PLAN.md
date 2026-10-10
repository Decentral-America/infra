# DCC Testnet Final Launch Plan — 2026-09-23

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Steps marked ⛔ need a fresh, explicit, written go-ahead from the operator (Josué) at that moment; a go-ahead for the plan does not carry into a ⛔ step.

**Goal:** Take the 2026-09-04 relaunch chain from "offline since 2026-09-17, half-verified" to a signed-off "final testnet": every node on one binary, every self-heal in-process, every downstream service reset-procedure written and executed, alerts armed and test-fired, 72h soak recorded, and every stale doc corrected.

**Architecture:** Four nodes: main (Linode VPS `66.228.55.154`, docker-compose, public REST `https://testnet-node.decentralchain.io`, bootstrap seed `quorum=0`) plus gen-0 / gen-1 / val-0 on Linode LKE cluster `dcc-peer-testnet` (namespace `dcc`, StatefulSets, Flux-managed from `Ecosystem/infra/clusters/testnet/apps/nodes.yaml`). Downstream on the VPS: matcher, blockchain-postgres-sync (BPS), data-service, scanner (hosts the faucet), exchange, admin-dashboard, Caddy edge, Prometheus/Alertmanager/Grafana/Loki. Consensus: Waves-NG PoS + DCC HotStuff finality (T0 authoritative endorsements, T2 committee), BLS endorsements.

**Tech Stack:** Scala 3 / sbt 1.12 (node-scala, matcher), TypeScript pnpm monorepo (DecentralChain), OpenTofu + Flux + kubectl (infra), GitHub Actions, SOPS/age secrets, Linode API.

## Ground truth verified 2026-09-23 (do not re-derive)

| Fact | Evidence |
|---|---|
| Height-3325 and height-2640 `InvalidStateHash` stalls both root-caused and fixed in code | node-scala `ade354adcb`, `31d4410ba3`; `CONSENSUS-BUG-INVESTIGATION-REFERENCE.md` §2, §13 |
| Carry-fee fix IS in both live images | `git merge-base --is-ancestor 31d4410ba3 testnet-relaunch-20260904` and `... 2cfdafe860` both true. Reference doc §8/§13 "not yet deployed" is STALE |
| Relaunch chain exists | genesis timestamp `1788539579643` in all 4 configs (infra `3b4cd48`); canary on 2026-09-08 got a real state-check reply from it |
| Image digest DRIFT | LKE x3 = `sha256:0346f624…` (main@`2cfdafe860`, 2026-09-12, has PR #60/#61 + netty fix). VPS workflows x3 = `sha256:b0d559cf…` (tag `testnet-relaunch-20260904`, 15 commits older). Rule D6 "every node runs the same binary" is violated on paper |
| Whole testnet offline since 2026-09-17 ~10:00–14:42Z | canary flips to `fetch failed` at 14:42Z; cluster-diagnostics run 35867921158: 3 LKE workers `NotReady`, 4 pods `Pending` 6d1h; VPS no ping/SSH/HTTP. Same-day loss of VPS + LKE = Linode account-level cause (cf. 2026-07-20 payment lapse) |
| Main node has NEITHER in-process self-heal flag | `node-config/testnet/dcc.conf` lacks `self-commit-to-generation` and `peer-stall-threshold`; the three external crons that covered it were deleted in infra `849148d` |
| PR #152 (fail-loud commit-generators) MERGED 2026-09-04 | `gh pr view 152` → MERGED. `RELAUNCH-20260904.md:541,547,551,642,663,797` say open — STALE |
| protobuf-schemas 1.6.6 IS on Maven Central | HTTP 200 for `protobuf-schemas-1.6.6-protobuf-src.jar`; node-scala `17b87fb047` resolves it. Memory + `hotstuff-audit-readiness.md:319` STALE |
| `CommitteeGapUpcoming` alert EXISTS | `infra/monitoring/alerts.yml:59`. `RELAUNCH-20260904.md:642` STALE |
| Feature 26 vote config present on all 4 nodes | `features.supported = [26]` at `dcc.conf:71`, `nodes.yaml:194,335,465` |
| node-scala `dev` is 14 commits BEHIND `main` | `git rev-list --count origin/dev..origin/main` = 14 |
| `Ecosystem/AUDIT-T2-FINALITY.md` does not exist at HEAD or in history | referenced by memory as the §6 hardening ledger — lost artifact |

## RECOVERY 2026-10-03: Linode deleted everything for non-payment (READ FIRST)

**What happened:** on 2026-10-01 13:36 Linode deleted every Linode on the account, the LKE cluster `dcc-peer-testnet` (615553) and its volumes. The separate production cluster `decentral-cluster` (513120) is also gone. The account now holds only 3 firewalls. Recovery images (`linode-cli images list --is_public false`) are kept until **2026-12-30**; the testnet backend disk is `private/41601991` (21.6 GB). drift-detect reported `clean` throughout, because of the setup-opentofu wrapper bug (fixed in #171).

**Agreed design (operator, 2026-10-03), testnet only, ~$99/mo:**
- **Main server:** 8 GB `g6-standard-4`, Dallas `us-central`, restored from `private/41601991`. No Linode backups: they're deleted along with an instance deleted for non-payment, so they wouldn't help.
- **Cluster:** 1 × 8 GB worker, kept deliberately as the "shared 8 GB bundle" product test. Holds gen-0, gen-1 and val-0, plus Flux trimmed to source-controller + kustomize-controller.
- **Removed from the cluster:** the copied production web stack (archived in the repo), ingress-nginx, cert-manager, the in-cluster kube-prometheus-stack (the VPS is the single monitoring plane) and 4 unused Flux controllers. Volumes are 10 GB.
- **Phase 2, after ~24h healthy:** add generator **gen-2** to the bundle (4 generators gives 1-failure BFT tolerance) and rebalance stake to 2B each by moving 2B from main to gen-2.

- [x] (2026-10-04: Linode **107373605**, IP **50.116.30.244**, running) ⛔ operator: restore the server: `linode-cli linodes create --region us-central --type g6-standard-4 --label dcc-backend-testnet --image private/41601991 --root_pass <new> --firewall_id 35536772 --tags dcc --tags testnet --booted true`. Root password goes in KeeWeb.
- [x] ⛔ operator: merge infra #171 (cleanup, import-backend action, drift-detect fix). Also merged: #172 (firewall_id ignore, backups off) and #173 (new LKE IP).
- [x] (run 37190225545 imported it; run 37191817182 planned 1 add / 3 change / 0 destroy) `provision.yml action=import-backend import_linode_id=<new id>`, then `plan`. Review it: new LKE cluster plus firewall updates, **0 to destroy**.
- [x] (run 37192329030: 1 added, 3 changed, 0 destroyed. LKE **663401**, worker **139.162.144.243**. Flux run 37193711144 installed only 2 controllers) ⛔ operator: `provision.yml action=apply`. Then bootstrap Flux and push secrets.
- [ ] (SiteGround names DONE and serving HTTPS 2026-10-04. PENDING: `testnet.decentralscan.com` at Namecheap (a friend is doing it) and deleting `mainnet-node`) ⛔ operator: DNS. Point every `testnet-*` name, `grafana.testnet` and `testnet.decentralscan.com` at the new IP. Delete the stale `mainnet-node.decentralchain.io` record (its IP has probably been reassigned).
- [ ] Verify: main node height advancing; gen-0, gen-1 and val-0 resynced; finality advancing; record capacity (allocatable, per-node usage) from cluster-diagnostics.
- [x] 2026-10-04 main forging again: the live `dcc.conf` changed 15d → 30d (`generation-is-allowed`; the last block was 16.6 days old). The repo matches. `deploy-node-config` run 37194464782 put main on `0346f624` with the new config.
- [x] 2026-10-04 secrets: org secret `TESTNET_DEPLOY_HOST` (used by about 10 deploy workflows) and env secret `DEPLOY_HOST` (unused) now point to 50.116.30.244. The fingerprint is unchanged, since the restored disk kept its host keys.
- [x] 2026-10-04 `infra-liveness` run 37194820699 green: height advanced, 0 LKE nodes not ready.
- [x] 2026-10-04 capacity (run 37194981169): the 8 GB worker has **6004Mi allocatable** (LKE reserves ~1.9 GB). Requests are 3942Mi, leaving **2062Mi free**: a 4th node (1280Mi) fits with ~780Mi to spare, and a 5th does not.
- [ ] Merge infra **#174** (startupProbe; gen-1 was killed by its liveness probe mid-boot) **after** gen-0, gen-1 and val-0 reach main's height. The merge rolls the pods.
- [ ] ⛔ operator: add `GRAFANA_ADMIN_PASSWORD` to SOPS `secrets/testnet.env` **before** running `deploy-monitoring-stack.yml`. Grafana refuses to start without it. Then run `deploy-monitoring-stack.yml` (lke-chain scrape, new exporters and alerts).
- [ ] Phase 2: gen-2 + stake rebalance (⛔ the operator signs the 2B transfer from main).
- [ ] Production is NOT in scope: its own decision, and its recovery images also expire 2026-12-30.

## Gap audit 2026-10-04 (4 read-only audits: VPS host, LKE + consensus, repos/docs/secrets, CI). Supersedes the "what's next" list

Units: 1 DCC = 10^8. Treasury and matcher hold **10M DCC** each, main 40.5M, gen-0/gen-1 20M each. The plan's "2B" for gen-2 = **20M DCC**.
Already done but unticked above: #174 merged via #175; `GRAFANA_ADMIN_PASSWORD` in SOPS, monitoring deployed, `admin:admin` → 401.

**Launch blockers:**
- [ ] B1 **Committee never reaches 3; every third period is empty.** `/generators/at`: 33701 ∅, 34001 ∅, 34201 {gen-0}, 34301 ∅. Self-commit is rejected at the boundary (`Expected the next period start height (34201), got 34301`), and commit txs don't propagate: main's 34301 commit stayed in main's UTX while gen-0's UTX was empty. The cause is node-side, in node-scala, which is out of scope. ⛔ operator decision needed. Adding gen-2 doesn't help until this is fixed.
- [ ] B2 **T2 finality stalls about 30 min in every empty-committee period**, roughly every 2.5h: 12:40→13:10, 15:12→15:42, and again from 17:44 (finalized 34299 while height was 34354). The Soak Log line 707 "follows today's restarts" is wrong. `HotStuffCommitNotAdvancing` (30m + for 30m) can't catch it.
- [ ] B3 **Main's miner crashes:** 137× `NoSuchMethodError FinalizationVoting$.of` from the stale `plugins/testnet/grpc.jar` (infra `467339f`, 2026-06-29), which vendors old `io.decentralchain.protobuf` classes ahead of the node jar. `update-node-image.yml:41-50` re-copies it on every deploy. Rebuild it from the current matcher without the vendored protobuf.
- [ ] B4 **val-0 can never generate:** it isn't in genesis, its wallet key is wrong (#153), and it makes 0 self-commit attempts. ⛔ Decide: fund it plus fix its key, or redefine the committee as main/gen-0/gen-1(/gen-2) and edit the Phase 9 box.
- [ ] B5 **SECURITY: the treasury seed is public.** `infra/RELAUNCH-20260904.md:126` (public repo, since `2f2c5b9`) contains the literal seed, and its address holds 10M DCC (about 10% of stake). Move the funds to a new KeeWeb-only seed (⛔ operator signs). Also redact lines 122-125 and 549 (the main base64 value plus mnemonic prefixes for gen-0, gen-1 and the matcher) and treat those seeds as weakened.
- [ ] B6 **SECURITY: the matcher runs on `KeyPair(empty)`.** Pubkey `2eEUvy…`, address `31HrVN…`, balance 0, so the DEX can't settle (0 exchange txs on the chain). `DEFAULT_MATCHER` in data-service/scanner is the empty key too. Fix: `seed-in-base-64` = Base64(Keccak256(Blake2b256(00000000‖utf8(mnemonic)))) (= `dcc-dex-cli generate-account-seed --account-nonce 0`), verify it derives `31VMNV…`, re-run push-secrets so `DEFAULT_MATCHER` refreshes, restart data-service. **First** delete or update matcher repo-level `TESTNET_DEPLOY_*` secrets (2026-06-19, old host), which override the org secret.
- [ ] B7 **No alert has ever been delivered.** `alertmanager.yml` reads `/etc/alertmanager/github_token`, which compose never mounts, and `alert-webhook` has no `GITHUB_TOKEN` (unhealthy, 503). The only receiver is GitHub; there is no email. Fix both, then test-fire (5.1).
- [x] ~~B8 No backups~~ (operator: not wanted for testnet). The `pg-backup.sh` cron dumps the nonexistent `dcc_testnet` to an unwritable log; `BACKUP_OBJ_BUCKET=""`; Linode backups are off; nothing off-account. 10-01 proved that peer sync alone doesn't survive an account-level loss.
- [ ] B9 **Explorer + faucet down publicly:** `testnet.decentralscan.com` still points at 66.228.55.154 (Namecheap). The cert renewal window opens about 10-06 and the cert expires 11-05. The faucet was likely never funded on this chain; the canary is at 0 (#148, #177).
- [ ] B10 **Off-box liveness unreliable:** GitHub dropped the crons. `infra-liveness` (*/30) ran on schedule once in 7.5h, and the canary (*/15) runs about every 4-6h. Needs an external uptime checker.

**Root causes found 2026-10-05 (live logs + every block 34401–37766; no node-scala source read). Evidence: session scratchpad `eaa7581d…/scratchpad/` (blocks.json, flog/, node.log, matcher.log, cycles.txt):**
- [ ] RC1 (B1) **Self-commit, three combined defects.** (a) A node only ever mines its own commit, in its own block: all 29 type-19 txs, tx ts = block ts, never relayed, UTX always 0. (b) Off-by-one: while forging x01 (parent x00) the miner targets x01+100, while the validator expects x01 (`Expected the next period start height (x01), got x01+100`), and it **never retries for the rest of the period**: no commit has ever landed at +1, landed offsets are +2..+29. Whoever forges x01 burns its only attempt, which gives the 2→1→0 committee cycle. (c) Main's blocks crash on the stale jar (RC3), so its successful commits die with the block. Code questions: is the target from h+1 vs the validator's parent height? What marks the period "attempted"? Is the commit injected into own blocks only, never broadcast?
- [ ] RC2 (B2) **HotStuff hand-off across committee changes is broken.** All 24 watchdog resets fire 0–5 blocks after a boundary on all 4 nodes within 1s, with HotStuff frozen at **x97**. Class A (16): entering a non-empty period after an empty one. Class B (8): 2→1 member change. `QC rejected: Wrong BLS signature` (v=54316, h=33897) and 5× `QC references unknown committee member` are the same defect: a single-signer QC from the new committee is checked against the block-epoch committee (signer index → wrong key). BLS keys are stable on-chain. The watchdog is acting as the routine recovery. Code question: which committee validates/aggregates a QC for height h, the block's epoch or the tip's epoch?
- [ ] RC3 (B3) **Stale `grpc.jar` (dex-grpc 0767d246, 2026-08-03).** 703/919 classes duplicate the image, 127 differ, and its `FinalizationVoting` has 4 fields where the node has 5. 577× miner `NoSuchMethodError`, plus **5 FATAL shutdowns** 10-04 18:22–18:25 (`hotstuffConflicts()` while decoding a peer microblock → `terminating application`). That caused val-0's/gen-1's/gen-0's 18:2x rollbacks. The next block carrying `finalization_voting` can kill main again. Rebuilding from matcher main does NOT fix it (dex-grpc vendors 4-field `block.proto`). Fix: plugin = `com/decentralchain/dex/**` only, plus a fail-closed guard in `update-node-image.yml` (no `io/decentralchain/(protobuf|events|api)/` in the jar) and a post-start `NoSuchMethodError` check.
- [ ] RC4 **Miner rejects its own block** (`Miner can't endorse its own block`, gen-0 138×, gen-1 136×): in 2-member committees the miner puts its own endorsement into its block, its validator rejects it, and it re-forges 5s later. T0 never runs ahead of HotStuff in 2-member periods, so T0 quorum is apparently never reached. Code question: should the miner filter its own endorsement? Does T0 count the miner's stake implicitly?
- [ ] RC5 **Matcher stream restarts** = 60s idle timeout (`no-data-timeout = 1m`; 13.8% of block gaps > 60s; restarts/h equal gaps>60s/h exactly). Not benign: the running matcher image (81ac7e5d, 2026-07-04, 133 commits behind) lacks 76ede33db/e887a4bbe, so each restart replays ~5k blocks and `processedHeight` only decreases. It also lacks Bug-2 re-broadcast and DEX-1099. Fix: redeploy matcher from main, `no-data-timeout` ≥ 5m.
- T0 does advance on its own in single-member periods (fin 1–3 ahead of HotStuff); in empty periods it tracks tip−100. val-0's first rollback (14:05, startup sync) was benign.

**Diagnosis round 2 (2026-10-06):**
- [x] **ACCEPTED RISK (operator, 2026-10-06: "dont mind that"; testnet only, no re-key, no re-genesis). Every funded key is public.** Main: RELAUNCH:122 used verbatim as UTF-8 seed (nonce 0) derives `31RPEK…` (validated against the treasury derivation). gen-0 + gen-1 full 15-word seeds are in infra history `d4f56eb` (2026-06-10 `get-addrs.yml`; removed in `566026a`, still in history). Matcher full seed around `cfd4c72`. Treasury at line 126. Together that is 100% of the generating stake. Removing them does not help. ⛔ Decide: re-genesis with fresh seeds, or move all balances + re-key the generators and matcher.
- [x] Pre-outage committees: h1–24700 main forged alone. 103 commits, all main, all from the external cron at arbitrary offsets (including x01). The cron was retired `849148d` 2026-09-12 18:48Z, and then **zero** type-19 txs until the outage (132 empty periods), although gen-0 forged ~30% of the blocks. Self-commit was configured on the LKE nodes (`43c4a3f`, 09-12 20:05Z) but never fired pre-outage (cause unknown from chain data; needs code). Halt: h33248 2026-09-17 12:22Z → h33249 2026-10-04 07:50Z. Post-restore: 61/61 commits in own block, all target x01+100, none at offset 0.
- [x] T0 in empty periods: F = max(pin, H−100). 17,771/17,810 samples have lag exactly 100. Pin = x01−2 after a 1-member committee, x01−4 after a 2-member one. The constant 100 equals both `max-rollback` and the period length; the code decides which.
- [x] Stripped `grpc.jar` PROVEN compatible: `scratchpad/jarfix/grpc.jar` sha256 `72b2c37c…201fc1`, 261 entries (only `com/decentralchain/dex/**` + 3 protos). 28,231 refs resolved, 0 unresolved, adds 0 unresolved refs to image classes. Inside the image `PBFinalizationVotings.vanilla` works; the original reproduces `hotstuffConflicts()` NoSuchMethodError. `guard.sh` passes on stripped, fails on original ("shadows 818 image entries").
- [x] GitHub cron drops = org-wide GitHub scheduler degradation since ~2026-08-27 (every cron 4–8h late; high-frequency crons collapse to ~1 run per lag window). Workflows are fine. infra-liveness only reached main 10-04 08:49 (#171). Fix: Cloudflare Worker Cron Trigger → `workflow_dispatch` (canary */15, liveness */30).
- [x] Renovate: configs are valid (`--strict` passes; local runs clean). DecentralChain: Mend's hosted job has been silently dying since 07-19 (dashboard not rewritten since 07-04); exact error is in the Mend portal (operator login). matcher #15 lookups are Maven Central rate-limiting on the shared egress. Fix: self-hosted `renovatebot/github-action` with a cache + `hostRules` for repo1.maven.org.
- [x] Loki query API broken: the frontend advertises 172.19.0.1:9096 but gRPC listens on 127.0.0.1 (460+ connection refused), and it is at 239/256MiB. Fix `monitoring/loki-config.yaml` `frontend.address: 127.0.0.1`. Ingestion is complete (28,215 = 28,215).
- [x] Matcher errors: the earlier "629 blockchain-events / 242 UTX / StopSupervisor" counts were miscounts (Loki has 0 / 86 / 0 for 09-06→now). The 86 UTX errors are 3 bursts = main shutdown 07:51, recreation 10:10, crash loop 18:22–18:25. The "No data" loop is old-image code (`flatMap` = concatMap, so the combined stream is never subscribed; `processedHeight` only decrements, 33147 → 31867), replaying ~8k blocks per restart at DEBUG. Log volume rose from 57k to 911k lines/6h. Fix: matcher from main, testnet DEBUG off.
- [ ] Secrets in container env readable via `docker inspect` (admin GitHub PAT, OAuth secret, JWT secret, Sentry token, Redis password): move to secret files + rotate.
- [ ] matcher network workflow pins `DCC_NODE_VERSION: '1.7.0'` while the live chain runs 1.8.0.

**Diagnosis round 3 (2026-10-06): upstream Waves `version-1.6.x` @ `66faa85e5f` (v1.6.4) (clone in scratchpad/waves). DCC source still classifier-blocked:**
- [x] T0 constant PROVEN = `max-rollback`, not period length: `Blockchain.scala:300-303` `latestFinalized.max(at - maxRollbackLength)`. An empty committee never finalizes (`FinalizationState:102`); quorum = `endorsed*3 >= total*2`, and the miner's own stake counts implicitly (`FinalizationState.scala:111-115`). With 2 equal members the other member's endorsement is required.
- [x] Commit validation rule PROVEN (`CommitToGenerationTransactionDiff.scala:15-18`): target must equal `periodOf(H).next.start`, H = height of the block applying it (key block/liquid block/UTX liquid height). Upstream NG key blocks carry no txs; commits travel in microblocks; an offset-0 commit (microblock of x01) is legal. Committee(P) = commits included in blocks of P−1. Upstream has NO in-process self-commit. → RC1 DCC side INFERRED: DCC's self-commit validates/submits against parent height x00 before x01 is appended, while targeting x01+100. Fix: build after the key block is appended (microblock of x01), target `periodOf(liquid h).next.start`, and retry within the period until it lands.
- [x] RC4 ("Miner can't endorse its own block", `appender/package.scala:376-377`): upstream excludes the miner in 3 places (`BlockEndorser:81`, `EndorsementStorage:64`, `EndorsementFilter:44,52`), added in **eb366602e (2026-02-17), first in v1.6.2**. **DCC logs `…height (35201), got…` with parentheses = the v1.6.0/1.6.1 wording**, so DCC's finality code predates those fixes. Fix: port eb366602e (+ check 1951cc5db/PR #4031, 5b3163b8b, 63398bfc2, 81e856dec). Residual 1.6.4 race: `EndorsementFilter.sameVoting` ignores miner (rarer).
- [ ] RC2 (HotStuff committee hand-off) is DCC-only; it can't be answered from upstream.

**Diagnosis round 4 (2026-10-06): node-scala source at the live commit `2cfdafe860`. All PROVEN in code:**
- [ ] **RC1 self-commit, `mining/Miner.scala`:** (1) `:237` `generationPeriodOf(newBlockHeight)` uses the block being forged (h+1), while `utx.putIfNew` validates at liquid height h. Forging x01 → target x01+100, UTX expects x01 → rejected. (2) `claimSelfCommitAttempt` claims `period.next` BEFORE dispatch and never releases it on `Left(err)`. The rest of the period computes the same target, so it never retries. (3) `maybeSelfCommit` calls `utx.putIfNew` directly; broadcast only happens via `TransactionPublisher`, so the commit is never gossiped and lands only in the node's own microblocks. Fix: target from the liquid height (`blockchain.currentGenerationPeriod.next` of the UTX view), release the claim on rejection, and publish via `TransactionPublisher` (broadcast).
- [ ] **RC2 HotStuff hand-off, `consensus/hotstuff/HotStuffEngine.scala:64,96`:** `acceptableCommitteeEpoch` accepts a QC/justify from epoch current−1 (`HotStuffQuorum.scala:81-82`), but `verifyQC(qc, state.committee)` always uses the CURRENT committee. An old-epoch QC's signer indexes map into the new committee: smaller → "unknown committee member", reordered → wrong key → "Wrong BLS signature". The x97 lock can't be re-justified, so it freezes until WATCHDOG. Fix: verify against the committee of `qc.committeeEpoch` (keep the previous epoch's GeneratorSet in EngineState).
- [ ] **RC4 self-endorsement, `state/BlockEndorser.scala:213-235` + `Miner.scala` key-block `tryCollectSelfWithGrace`:** DCC puts finality voting in KEY blocks (upstream: `None`). `voteSelf` builds its `EndorsementFilter` with miner = the TIP's generator, so it excludes the wrong index. Node M endorses N's tip with M's own index, then forges h+1 carrying it → `appender/package.scala:419` "Miner can't endorse its own block" → 5s retry without it (endorsement lost, T0 never ahead in 2-member periods). Fix: when the miner collects self-round voting for its key block, drop its own index (re-aggregate), or the self-round must exclude the local forging account. (The upstream exclusions eb366602e ARE ported; the parens hint was wrong.)
- [x] Pre-outage "self-commit never fired": `43c4a3f` (LKE self-commit config) only reached main via #156 on **09-21**, after the outage. Pre-outage LKE pods ran `b0d559cf`, which predates PR #60. No running node had self-commit before 10-04.

**Fix work (2026-10-06):**
- [ ] node-scala branch `fix/consensus-selfcommit-hotstuff-endorse` (off main `3708e2e1df`): RC1 + RC2 + RC4 fixed test-first. RED proven for each (RC1 3/3 failing; RC2 3/3 failing with `committeeAt = None`; RC4 voteSelf filter `0 != UnknownCarrierMiner`), all GREEN after. compilePR + full node-tests pending, then PR → operator admin-merge → image → digest bump (second infra PR) → roll all 4 nodes → verify 3 straight periods with full committees and no WATCHDOG at boundaries.
- [ ] infra PR **#179** (RC3 stripped jar + `check-plugin-shadowing.sh` in CI/deploy, post-start linkage check, Loki `frontend.instance_interface_names: [lo]`, matcher `no-data-timeout = 5m`). Rollout: merge → `update-node-image.yml` → `deploy-monitoring-stack.yml` → `push-secrets.yml` + matcher restart.
- [x] matcher #26 closed: the suite passes on main (run 37518365452); the old failure was a release-download 403.

**Rollout 2026-10-07 (bypass mode: merged + rolled out directly):**
- [x] infra #179/#180/#181/#182 merged. All 4 nodes on `e129b0bd…` (= node-scala #66 merge `ecce96a`; pod imageIDs + main `docker inspect`). Main: 0 linkage errors, 0 fatal, 0 InvalidStateHash. Loki query 200 in 0.33s. REDIS_PASSWORD in SOPS (live value proven with PING→PONG), push-secrets `REDIS=40`, matcher restarted with 5m stream timeouts.
- [x] **RC1 proven live: committee for 42001 = {gen0, gen1, main}**, the first full committee on this chain. gen-0's and main's commits for 42001 landed at the start of period 41901 (impossible before).
- [ ] Main missed 41901: self-committed 8s after its restart with 0 peers (first handshake +2 min), so the one broadcast reached nobody. Fix: re-broadcast a pending commit / retry an evicted one → node-scala **#67**.
- [ ] **HotStuff wedged after the simultaneous restart: PRE-EXISTING bug, not RC2.** Restored `lastVotedView` was 382843–382881 on all 4 nodes while the pacemaker restarts at view 0; `safeToVote` needs `proposal.view > lastVotedView`, so ~5 days of 1.2s timeouts before anyone can vote. node-it `FourNodeHotStuffAuthoritativeTestSuite` PASSES on #66 code (fresh nodes). Fix: pacemaker starts at `max(lastVotedView, lockedQC.view)+1` (test RED `0 was not greater than 382843` → GREEN; 216 HotStuff specs pass) → added to **#67**. Do NOT delete last-voted-view.dat (double-vote risk). Finality meanwhile falls back to H−100.
- [ ] Gap: node-scala PR CI never runs the node-it suites; run them locally for any consensus change.

- [x] 2026-10-07 16:18Z: node-scala **#67** (re-broadcast + pacemaker restart fix) merged `4a4abfc` → image `ed0324ce…`; infra **#183** (pin + drop stale `dcc/block.proto` from grpc.jar, flagged by the new guard). LKE first (Flux), then main. **HotStuff resumed within 30s of main's restart** (AUTHORITATIVE commits 42225, 42226; fin lag 3; 0 watchdog, 0 QC rejected, 0 linkage, 0 InvalidStateHash). Check PR's only red was a GitHub API 500 in the surefire report step (9827 tests, 0 failed).
- [x] Monitor `watch2.sh` 16:15→19:25Z: committees 42201–42701 ALL {main,gen0,gen1} (6 consecutive full periods); boundaries 42301/42401/42501/42601 crossed with fin lag 3 throughout; main 402 AUTHORITATIVE commits; 0 watchdog / rejected self-commit / unknown-member / own-endorse / InvalidStateHash / pod restarts. **B1 + B2 CLOSED live.** The 72h soak clock can start from 16:18Z 2026-10-07.

- [x] 2026-10-07 boundaries 42301/42401 crossed with full committees (42201–42501 all {main,gen0,gen1}), fin lag 3 throughout, 0 watchdog/QC-rejected/own/ish. RC2 proven live (member order changed at each boundary).
- [x] Keys verified: KeeWeb FAUCET_SEED/TREASURY_SEED == SOPS DCC_FAUCET_SEED/TREASURY_SEED, each derives its documented address; DCC_CANARY_SEED → 31LAqg…. All 3 had **0 txs on this chain**: the 09-04 genesis funded only 5 addresses and RELAUNCH §10.1 re-fund was never run. Funded from genesis treasury 31LQd8: faucet 1,000,000 (36adAY…), admin treasury 50,000 (7Chm8K…), canary 100 (84m1ew…). Canary green (run 37666136007), #148/#177 closed. Faucet POST → 200 + tx, second → 429 (Redis rate limit OK).
- [x] Operator 2026-10-07: testnet backups NOT wanted (drop B8).
- [ ] Renovate: reproducing the hosted job locally (`renovate --platform=github --dry-run=full`) for DecentralChain + matcher to get the real errors (Mend log needs login).

**2026-10-10 (bypass mode, full ownership):**
- [x] **B6 matcher key FIXED + PROVEN.** SOPS MATCHER_SEED == KeeWeb #5 == host copy → 31VMNV… (10M). infra #184: SOPS `MATCHER_SEED_BASE64` + `DEFAULT_MATCHER`=BEtB5b2k…; push-secrets writes in-mem seed, fails closed, local.conf 640 root:113. Matcher state moved aside (`data.emptykey-20261009`). matcher #33: Dockerfile fixed for sbt 2 (single task; tarball staged at fixed path) + temurin base bump (libssl3t64 CVE-2026-84782). Deployed image `41790d26`, Trivy clean. data-service/scanner/websocket-api/admin recreated with real DEFAULT_MATCHER. **First ExchangeTransaction on this chain: EahWLjQ5… at h49027, signed by 31VMNV**, buyer received 1000 units.
- [x] Matcher repo-level TESTNET_DEPLOY_* recreated (GitHub Free: org secrets don't reach private repos — my deletion broke deploy once).
- [x] **B7 alerts delivered + auto-closed.** #185 (drop never-mounted bearer_token_file; webhook token fallback), #187 (match by title; force-recreate AM/webhook on deploy), #188 (`alert-issues.yml` labels/closes — PAT can open+dispatch but not label/close). Proven: #186 + #189 opened → labelled → auto-closed on resolve. Email: SMTP host unresolvable (no `mail.` DNS at SiteGround) — GitHub issue notifications email watchers meanwhile.
- [ ] **B10 external liveness:** Worker + deploy workflow merged (#190); deploy fails — org CLOUDFLARE_API_TOKEN lacks **Workers Scripts: Edit** (operator: add permission).
- [x] **B4 val-0:** wallet holds 31XTtK… (its seed's address; #153's "no private key" was the deleted external workflow). Funded 20,000,000 DCC from main (8PtkwjHU…) → 4×~20M generators (1-failure tolerance). Close #153 when val-0 appears in /generators/at (~1000 blocks).
- [x] **Crash drill PASSED:** gen-1 pod deleted → Ready 166s, finality continuous (lag 3), 0 InvalidStateHash, restored lastVotedView 600953 and voted (pacemaker fix proven again).
- [x] **Partition drill PASSED** (2026-10-10 02:01–02:12Z, iptables on main blocking the LKE node IP both ways, auto-heal). Per-pod partition impossible: pods are hostNetwork=true (NetworkPolicy no-op), share one node IP, and enable-blacklisting=no makes the blacklist API a no-op. During: main forged alone 49032→49039; gen-0+gen-1 forged their own fork to 49035/49036 (they reach each other on the shared node); val-0 held 49030; **finality frozen at 49027** (no side ≥2/3: no conflicting finality). After heal: all 4 nodes on 49043 within ~60s, fin lag 3; gen-0/gen-1 `rollback to H2EQFTvk… succeeded`; 0 InvalidStateHash, 0 restarts; main's 4 WATCHDOG resets all during the partition; HotStuff resumed (22 commits). Finding: main `quorum=0` + gen-0/gen-1 able to peer each other = a two-sided fork during any main↔cluster split (benign here because neither side can finalize).
- [x] main `interval-after-last-block-then-generation-is-allowed = 30d` KEPT (bootstrap after >15d outage; no effect on a live chain); fix stale "Genesis 2026-06-24" comment in next infra batch.

**2026-10-10 (cont.):**
- [x] matcher #33 merged (sbt-2 Dockerfile + temurin base bump); dev = main.
- [x] Docs #20: chain IDs corrected (! 33 / ? 63 / S 83); sphinx -W passes. link_check stays red only on dead apex/production hosts (DNS/production items).
- [x] Plan versioned at infra/TESTNET-FINAL-PLAN.md (#191); RELAUNCH link fixed; stale genesis comment fixed.
- [x] fail2ban: live + bootstrap.sh use backend = systemd (#192); jail active, banned 2 IPs at once.
- [x] **Deploy SSH key rotated** (new ED25519 SHA256:kib17XTU…): org TESTNET_DEPLOY_SSH_KEY, matcher repo secret, infra env DEPLOY_SSH_KEY (base64 — push-secrets decodes it), TF_VAR_DEPLOY_SSH_PUBLIC_KEY; proven by vps-node-status + push-secrets; old key → "Permission denied". KEEWEB_BACKUP.md no longer holds a private key (operator: attach deploy_key_testnet to KeeWeb #18).
- [x] **All 4 node REST API keys rotated** (#193): new key 200 / old key 403 verified on main, gen-0, gen-1, val-0; Caddy /peers 200; KeeWeb backup #11–14 updated.
- [x] **LKE config changes now reach the pods** (#194): checksum/config annotation per StatefulSet + CI check (a ConfigMap change alone never restarted pods; rotated hashes sat unapplied until a manual restart).
- [x] **Alerts that can fire** (#195): FinalizationStalled lag>20/10m (old >250 unreachable: fallback caps lag ~100), HotStuffCommitNotAdvancing 10m+5m, new CommitteeShrinking, exporter period off-by-one fixed + current committee metric, dead-workflow text removed; promtool tests incl. 4 new. #196: deploy reloads Prometheus (rules were not reloading).
- [x] Redis + exporter brought to repo pins (8.10 / v1.92.1) on the host (no deploy workflow existed); auth enforced, 715 keys kept.
- [x] Admin JWT secret rotated (#197), container recreated, verified.
- [x] drift-detect: "No changes. Your infrastructure matches the configuration." Admin E2E smoke 53/53.
- [x] Old empty-key matcher state removed.
- [ ] Accepted / deferred: BPS exits on node gRPC loss and relies on restart (113 restarts = node deploys; always catches up) — reconnect-in-place is a DecentralChain code improvement; env-file sprawl (every service gets testnet.env) → per-service env files for mainnet (testnet seeds are public by decision); main compose healthcheck not applicable (main runs via docker run, not compose; stall alerts cover it); matcher `database = dcc_testnet` unused (order-history off).
- [ ] Operator: Cloudflare token Workers Scripts:Edit (B10); Mend log for hosted Renovate; Namecheap testnet.decentralscan.com (cert expires 11-05); delete mainnet-node record; SiteGround apex + mail records; equivocation drill decision; KeeWeb sync; OAuth client secret / Sentry token / admin PAT rotation (provider consoles); production decision before 2026-12-30.
- [ ] Deferred by operator: 72h soak report + sign-off tag.

**Should-fix before sign-off:**
- [ ] Revert the main `interval-after-last-block-then-generation-is-allowed = 30d` → 15d (LKE is on 15d). Review main `quorum = 0`: an isolated main forges its own fork. Fix the stale "Genesis 2026-06-24" comment.
- [ ] Main is the only hub: LKE nodes have no LKE↔LKE links, only 3 sockets to main. If main dies, the gens halt.
- [ ] Alert logic: the exporter emits -1 on 404, so `CommitteeGapUpcoming` (`== 0`) misses gaps. Add a rule for committee size ≤ 1. The exporter (healthcheck 5s, `/metrics` 6-9s) is unhealthy. Prometheus has no self-scrape for prometheus/alertmanager/grafana/caddy. Retention must survive container recreation (data only from 15:38). Stale alert text: deleted workflows, "observational".
- [ ] Rotate credentials: REST API keys (7.1; branch `1141c3a` is gone, regenerate), the deploy SSH key (7.2), stale `TF_VAR_ROOT_PASSWORD`. Delete the plaintext admin kubeconfig left in an old session's scratchpad (`…/11f8c55c-…/scratchpad/kubeconfig-testnet`).
- [ ] Least-privilege secrets: every compose service gets the whole `testnet.env`, including `DCC_WALLET_SEED`. `REDIS_PASSWORD` is not in SOPS (live Redis was set by hand, and push-secrets writes the matcher Redis URL without a password). `local.conf` is chmod 644.
- [ ] Host: no host firewall; everything is bound to 0.0.0.0, and only the Linode cloud firewall protects it. fail2ban has been failed since boot. Leftovers: `test-wallets.csv`, `*.bak`. Linode kernel 7.1.9 instead of the distro kernel (decide). Compose drift: node-scala healthcheck (2.6 not rolled out), redis image versions.
- [ ] DB naming: no `dcc_testnet` and no `bps` role. Matcher config + `bootstrap.sh` + `pg-backup.sh` + the BPS runbook (`OWNER bps`) are all wrong. BPS has 52 restarts (start-height race).
- [ ] Matcher blockchain-updates stream: 461× "No data for 1 minute, restarting!".
- [ ] LKE: `ghcr-pull-secret` is missing (works only because the package is public); metrics-server absent; one-off `Wrong BLS signature` QC rejections at 14:17; `Miner can't endorse its own block` (node-side).
- [ ] DNS: delete `mainnet-node` (172.233.108.19). `mainnet-matcher` → a third-party nginx, still linked from the docs. Apex `decentralchain.io`/`decentralscan.com` empty. Admin-dashboard default scanner URL `testnet-scanner.decentralchain.io` doesn't resolve; exchange `origin` is `testnet.decentralchain.io` (no record).
- [ ] Public docs: chain IDs are wrong (`024_Chain-ID.csv`, `09_protocol.rst:115` say T/84, W/87; the real values are `!`/33, `S`/83, `?`/63). No "join the testnet" guide (genesis, peer `50.116.30.244:6868`, chain byte).
- [ ] Stale docs: RELAUNCH:47 (old IP), §5.1 (`b0d559cf`), link to the plan outside the repo; reference doc :50, :109, :390; TOPOLOGY balances; "Newark" naming (it's Dallas now); HotStuff `round-timeout` tuned for Frankfurt→Newark RTT; nodes.yaml "crons kept as safety net".
- [ ] Root repo: commit Task 1.1 Step 1. The only remote is `upstream-waves`, so this plan has no off-machine copy and a stray push goes to Waves. KEEWEB_BACKUP.md: inline private key (119-133), duplicate entry 27, pending deletions, missing entries (new Linode root pw/IP/instance, `DCC_CANARY_SEED`, etc.).
- [ ] CI: drift-detect hasn't run since its exit-code fix (cron 10-05 06:00Z); admin-e2e last ran 09-21 during the outage (#142); matcher #26 failing suite never re-run since the sbt-2 path fix; DecentralChain Renovate stalled since 07-19 (config warnings); matcher Renovate blind to Scala deps; DecentralChain service images predate the 09-30 bump; private-minute headroom 87% in September.
- [ ] Sign-off tag: infra has 0 tags. Tag `testnet-final-YYYYMMDD` in infra on the commit pinning `0346f624` (with a Release listing all digests + genesis + SOAK), and exclude it from `ghcr-cleanup` (keeps 10).
- [ ] gen-2 scaffolding missing everywhere: `lke.tf` ports 6863-6865, `host-endpoints.yaml`, ConfigMap/STS/PDB/secret, exporter list, `LkeGeneratorsDown` hard-codes 3, diagnostics loops. It fits (2062Mi free, needs 1280Mi).
- [ ] Not gating: crypto 2.0.8 release, 5 `CHROME_*` secrets, status page, SBOM/version manifest, production decision before the 2026-12-30 image expiry.

**Verified OK 2026-10-04:** 4 nodes on `0346f624`, v1.8.0, same block id; InvalidStateHash 0 on all 4; features 1–26 ACTIVATED (26 at 12000), none ≥27; reward 20 DCC; live `dcc.conf` = repo, LKE ConfigMaps = mounted; Flux Ready at `b05452e`; startupProbe live; PVCs 2% used; main peers = 3 LKE nodes, none blacklisted/suspended; BPS = chain height; Redis requires auth; sshd hardened (no password, no root); Grafana default login rejected; certs valid; data-service/matcher/node/admin/grafana 200.

## Status update 2026-09-30 (each item re-verified live on this date)

**Scope change, operator 2026-09-30:** node-scala is entirely out of scope ("entirely ignore node scala from now on"). Every step below that edits, commits to, or PRs `$NODE` is marked **OUT OF SCOPE** and must not be acted on. Infra steps that deploy existing node images are unaffected.

| Fact | Evidence (2026-09-30) |
|---|---|
| Linode still offline: Phase 0 blocked | `curl` to testnet-node, mainnet-node, testnet.decentralscan.com and grafana.testnet: no connection on all of them |
| **NEW:** apex DNS missing, separate from Linode | `dig +short A decentralchain.io` (NS SiteGround) and `decentralscan.com` (NS Namecheap) are both empty. Both domains are registered until 2027. `ide.decentralchain.io` has no record at all. DNS is not managed as code. |
| DecentralChain dependency bump landed | PR #112 merged 2026-09-30T11:10Z, then #116 at 16:18Z. main = dev = `b940c744a`. Main CI, CodeQL, RIDE CI and Trivy all green on that commit. `pnpm audit --prod`: no known vulnerabilities. |
| matcher, infra, docs on latest deps | matcher main = dev = `c2f07b47f`; infra main = dev = `835110547`; docs main = dev = `6369444` |
| Docs site deploys again | docs PR #17 + #18 merged; Pages `build_type=workflow`, `https_enforced=true`, cert approved. Deploy Documentation succeeded 2026-09-30T14:41Z; live `last-modified` 2026-09-30 |
| node-go and goleveldb archived | `gh api repos/Decentral-America/{node-go,goleveldb} --jq .archived` both `true` |
| crypto 2.0.8 NOT released | Maven Central `io.decentralchain:crypto` latest = 2.0.7 (declares bcprov 1.84); no `crypto/v*` release or draft. transactions and java-sdk pin bcprov 1.86 as a stopgap |
| `CHROME_PUBLISHER_ID` secret absent | Not present at repo, environment or org level. Required by `deploy-cubensis.yml:198` (chrome-extension-upload v7) |
| Merged 2026-09-30 | DecentralChain #117 (vertx 5.2.0 + tuweni 2.8.0, lifts the last JVM hold); infra #169 (T0/T2 runbook, pycache ignore, linode provider 4.6.0, supersedes Renovate #161). Still open: docs #15, which belongs to another contributor, so leave it. |

### Added 2026-09-30 (not in the original plan)

- [ ] **Restore apex DNS** ⛔ operator: add A records for `decentralchain.io` (SiteGround) and `decentralscan.com` (Namecheap). Add `ide.decentralchain.io` once the RIDE IDE is hosted. The docs now link the IDE there, not the unregistered `decentralchain-ide.com`.
- [x] **Merge DecentralChain #117 and infra #169** (done 2026-09-30 by the operator; dev fast-forwarded: DecentralChain main = dev = `38e405f5f`, infra main = dev = `62cbd74`) ⛔ operator: `gh pr merge 117 -R Decentral-America/DecentralChain --merge --admin`; `gh pr merge 169 -R Decentral-America/infra --merge --admin`. Then fast-forward DecentralChain `dev` to `main`.
- [ ] **Release crypto 2.0.8** ⛔ operator: `gh workflow run prepare-release.yml -R Decentral-America/DecentralChain --ref main -f package=crypto -f version=2.0.8`, then publish the draft in the GitHub UI (that is the Maven Central publish). Then bump `dcc-crypto.version` in transactions and java-sdk to 2.0.8.
- [ ] **Create `CHROME_PUBLISHER_ID`** ⛔ operator: Chrome Web Store dashboard, then the DecentralChain secret. Needed before the next cubensis release.
- [ ] **Renovate check, Monday 2026-10-05:** DecentralChain Dependency Dashboard (#2) has updated, and Renovate opened PRs under the widened `["* * * * 1"]` schedule. Before this, the last Renovate PR was on 2026-07-19.

### Prepared offline 2026-10-01 in infra PR #171 (code only; each needs its ⛔ rollout step after Phase 0)

Validated locally: pyhocon, `tofu validate`, kubeconform, promtool `check rules` / `test rules`, compose config, shellcheck/actionlint, and mock-node runs of the canary script. Per-task evidence is in the PR body.

| Task | Prepared | Rollout left |
|---|---|---|
| 0.2 Steps 1–4 | `booted = true`; `infra-liveness.yml` (folded in from #170) | merge, then dispatch once (Step 5); `provision.yml` apply (Step 6 ⛔) |
| 2.1 Steps 1–3 | `vps-image.env` → `0346f624…`; `scripts/check-digest-parity.sh` in CI; `pin-node-image-digest.yml` bumps vps-image.env too | Step 4 ⛔ `update-node-image.yml` |
| 2.2 Steps 1–3 | `self-commit-to-generation = yes`, `peer-stall-threshold = 900` in `dcc.conf` | Step 4 ⛔ `deploy-node-config.yml` |
| 2.3 | val-0 `quorum = 1`. `git log -S`: the 0 came from `595a899` with no rationale; PR #80 moved only the funded gens | Flux |
| 2.5 | `slashing-enabled = no` on all four | with the next config deploy |
| 2.6 | VPS compose + webhook healthchecks fixed (the image has wget, not curl; the webhook got `/healthz`). **LKE liveness deliberately left as REST**: a height-stall probe would restart every consensus node every ~18 min in a chain-wide halt; the stall alerts cover it | VPS restart, `deploy-monitoring-stack.yml` |
| 3.4 Step 4 | canary-balance guard (exit 3 + `[ALERT] CanaryWalletUnfunded`) | fund the canary (Step 2 ⛔) |
| 4.1 / 4.2 Step 1 | `runbooks/reset-bps-testnet.md`, `runbooks/reset-matcher-testnet.md`, linked from RELAUNCH §10. The plan's draft commands were wrong in four places and missed the manual `./migration up` step | run in Phase 4 |
| 4.4 Step 3 | Grafana admin password through a dedicated `grafana-<network>.env` | ⛔ add SOPS key `GRAFANA_ADMIN_PASSWORD` (absent today), `push-secrets.yml`, then a one-time `grafana cli admin reset-admin-password` |
| 5.1 Step 3 + 7.3-02 | `MainNodeUnreachable`, `LkeGeneratorsDown`, `PostgresDatabaseGrowthHigh`, `HostDiskSpaceLow`, `CapacityExporterDown`; node_exporter + postgres_exporter added (localhost-only) | `deploy-monitoring-stack.yml`, then the Step 4 test-fire |
| 1.2 Steps 2 + 4 | RELAUNCH runbook header and sections; archived-workflows README "2026-09-21 round" | none |

### Findings 2026-10-01 (new, from preparing #171)

- [ ] **SECURITY ⛔ operator: the matcher signs with an empty-seed key.** `push-secrets.yml` extracts `MATCHER_SEED` but never writes it. `local.conf` sets `account-storage.type = in-mem` with no seed, so matcher's default `in-mem.seed-in-base-64 = ""` applies and `AccountStorage.load` builds `KeyPair(ByteStr.empty)`, a key anyone can derive. This has been true since infra `2bf4fec` (2026-07-01). The workflow's warning "matcher will start with a random key" is wrong. It may explain the old 0-balance matcher incident. The fix: write the real seed (or switch to `encrypted-file` with `MATCHER_PASS`), then verify that the derived address equals `DEFAULT_MATCHER`. That needs the KeeWeb seed. Mainnet must not ship with this flow.
- [ ] **DB name mismatch.** `bootstrap.sh` creates `dcc_testnet`, while terraform defaults to `bps_testnet`. The matcher uses `dcc_testnet`; BPS and data-service use `bps_testnet`. Confirm on the VPS after Phase 0.
- [ ] **`REDIS_PASSWORD` still absent from SOPS** (Task 4.4 Step 1).
- [ ] **Stale alert text.** The `CommitteeGapUpcoming` description still tells on-call to run the deleted commit-generator workflows.
- [ ] **Same-box monitoring.** The VPS's own Prometheus can't page about a whole-VPS outage. The off-box `infra-liveness.yml` (Task 0.2) covers that.

## Global Constraints

- **Every node on a chain runs the same binary.** Four digests (VPS pulled imageID + 3 pod imageIDs) must be byte-identical before any chain step is called verified (`RELAUNCH-20260904.md` §5.3, decision D6).
- **Never auto-clear blacklist; suspension only.** `peer-stall-threshold` heals suspensions only (`PeerDatabaseImpl.scala:66-74` rationale).
- **`slashing-enabled` stays `no` fleet-wide** until one node has exercised a live equivocation drill (audit F-1, D4).
- **No re-genesis unless Phase 3 proves the current chain unrecoverable.** PVCs are `Bound` and `linode-block-storage-retain`; the chain is expected to resume.
- **Evidence before assertions.** Every "verified" checkbox names the command and pastes the decisive output line into the Soak Log (§ at end of this file).
- **No `gh run watch`.** Poll with `gh run view <id> --json status,conclusion` at ≥45s intervals (memory: GitHub REST budget).
- **Never touch** the standalone `exchange` repo, `dcc-report`, or (since 2026-09-30) node-scala (memory: never-touch repos).
- **Commit authorship:** sole author jourlez, no AI trailers.
- **Secrets never in chat or plan.** Reference KeeWeb entry names only.

Repo roots used below:
`BC=/Users/jourlez/Documents/Code/Blockchain`, `INFRA=$BC/Ecosystem/infra`, `NODE=$BC/Ecosystem/node-scala`, `MATCHER=$BC/Ecosystem/matcher`, `DCC=$BC/Ecosystem/DecentralChain`, `DOCS=$BC/Ecosystem/docs`.
Main node REST: `MAIN=https://testnet-node.decentralchain.io`. API keys: KeeWeb `MAIN_NODE_REST_API_KEY`, `GEN_0_NODE_REST_API_KEY`, `GEN_1_NODE_REST_API_KEY`, `VAL_0_NODE_REST_API_KEY`.

---

## Phase 0 — Bring the infrastructure back (operator, today)

### Task 0.1: Linode account and power state ⛔

**Files:** none (Linode console). Record results in the Soak Log.

- [ ] **Step 1 ⛔:** Log in to Linode console. Check Billing → any unpaid invoice / suspended state. Pay or escalate. Record the invoice date + amount in the Soak Log (this is the second occurrence; the first was 2026-07-20).
- [ ] **Step 2:** Linodes → instance behind `linode_instance.backend` (`INFRA/terraform/main.tf:107`). Note power state. If `Offline`, Power On. Expected: status `Running` within ~2 min.
- [ ] **Step 3:** Kubernetes → cluster `dcc-peer-testnet`. Node pool: 3 nodes. If nodes show offline, use "Recycle" only if they do not come back within 10 min of the account being unblocked (recycling re-images; PVCs survive because they are block-storage with `retain`).
- [ ] **Step 4:** From workstation:
```bash
ping -c 3 66.228.55.154
curl -s -m 10 $MAIN/node/version
curl -s -m 10 $MAIN/blocks/height
```
Expected: ping replies; version JSON; height ≥ the last height before 2026-09-17 (unknown; must be > 2640 since the chain ran 13 days at ~1 block/min — if it is ≤ 2640 stop and go to Task 3.1 immediately).
- [ ] **Step 5:** Dispatch read-only diagnostics and wait for completion:
```bash
cd $INFRA && gh workflow run cluster-diagnostics.yml -f network=testnet -f roll=false
# then, ≥45s later, repeat until completed:
gh run list -R Decentral-America/infra --workflow cluster-diagnostics.yml --limit 1 --json databaseId,status,conclusion
gh run view <id> -R Decentral-America/infra --log | grep -E "=== (NODES|PODS)|height:|version:" -A0
```
Expected: 3 nodes `Ready`; `dcc-gen-0-0`, `dcc-gen-1-0`, `dcc-val-0-0` `1/1 Running`; three `height:` lines non-empty and within 2 blocks of each other and of `$MAIN/blocks/height`.
- [ ] **Step 6:** Paste the decisive lines into the Soak Log under "Phase 0".

### Task 0.2: Prevent the silent-outage class

**Files:**
- Modify: `INFRA/terraform/main.tf:107-160` (`linode_instance.backend`)
- Create: `INFRA/.github/workflows/infra-liveness.yml`
- Modify: `INFRA/.github/workflows/canary-transaction.yml:5-17` (doc comment) — no logic change

Why: nothing paged anyone for 6 days. The canary was already red for an unrelated reason (0 balance), so its red→red transition on 2026-09-17 carried no signal. Drift-detect ignores power state. Healthchecks only test REST liveness.

- [ ] **Step 1:** Add power-state assertion to tofu so drift-detect flags an Offline instance:
```hcl
# INFRA/terraform/main.tf inside resource "linode_instance" "backend"
  booted = true
```
Run `cd $INFRA/terraform && tofu validate`. Expected: `Success! The configuration is valid.`
- [ ] **Step 2:** Create a scheduled liveness workflow that is independent of wallet balance:
```yaml
# INFRA/.github/workflows/infra-liveness.yml
name: Infra Liveness (Tier 0)
on:
  schedule:
    - cron: '*/30 * * * *'
  workflow_dispatch:
permissions:
  contents: read
  issues: write
jobs:
  probe:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - name: Main node height advances
        id: main
        run: |
          set -euo pipefail
          H1=$(curl -sf -m 15 https://testnet-node.decentralchain.io/blocks/height | jq -r .height)
          sleep 150
          H2=$(curl -sf -m 15 https://testnet-node.decentralchain.io/blocks/height | jq -r .height)
          echo "h1=$H1 h2=$H2"
          test "$H2" -gt "$H1" || { echo "::error::height did not advance ($H1 -> $H2)"; exit 1; }
      - name: LKE nodes Ready
        env:
          LINODE_TOKEN: ${{ secrets.LINODE_TOKEN }}
        run: |
          set -euo pipefail
          CID=$(curl -sf -H "Authorization: Bearer $LINODE_TOKEN" https://api.linode.com/v4/lke/clusters | jq -r '.data[] | select(.label=="dcc-peer-testnet") | .id')
          NOTREADY=$(curl -sf -H "Authorization: Bearer $LINODE_TOKEN" "https://api.linode.com/v4/lke/clusters/$CID/pools" | jq '[.data[].nodes[] | select(.status!="ready")] | length')
          echo "not-ready pool nodes: $NOTREADY"
          test "$NOTREADY" -eq 0
      - name: Open or update alert issue on failure
        if: failure()
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          set -euo pipefail
          TITLE="[ALERT] InfraLiveness: testnet unreachable or not advancing"
          N=$(gh issue list --search "$TITLE in:title" --state open --json number -q '.[0].number')
          BODY="Run: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}"
          if [ -z "$N" ]; then gh issue create --title "$TITLE" --body "$BODY"; else gh issue comment "$N" --body "$BODY"; fi
```
Note the `LINODE_TOKEN` secret already exists (used by `cluster-diagnostics.yml:36`). The `issues: write` permission is required for the alert step.
- [ ] **Step 3:** Validate YAML locally: `cd $INFRA && python3 -c 'import yaml,sys; yaml.safe_load(open(".github/workflows/infra-liveness.yml"))' && echo OK`. Expected: `OK`.
- [ ] **Step 4:** Commit on a branch, open PR, merge after CI green:
```bash
cd $INFRA && git checkout -b feat/infra-liveness-tier0
git add terraform/main.tf .github/workflows/infra-liveness.yml
git commit -m "feat(monitoring): Tier-0 infra liveness probe independent of wallet balance; assert VPS booted in tofu"
git push -u origin feat/infra-liveness-tier0 && gh pr create --fill
```
- [ ] **Step 5:** After merge, dispatch once and confirm green: `gh workflow run infra-liveness.yml` then poll `gh run view`. Expected: `completed success`.
- [ ] **Step 6:** Apply tofu (⛔ operator, because `provision.yml` is a live apply): `gh workflow run provision.yml -f action=apply -f network=testnet` (check the exact input names at `INFRA/.github/workflows/provision.yml` first). Expected plan: the 3 in-place changes already reported by drift-detect (firewall x2, LKE version) plus `booted`. Nothing destroyed. If the plan shows anything `to destroy`, abort.

---

## Phase 1 — Repository hygiene and stale-doc reconciliation (no chain impact)

### Task 1.1: Resolve uncommitted working trees

**Files:** four repos, all currently dirty.

- [ ] **Step 1 ⛔ operator (2026-09-30: the auto-mode classifier blocks the restore/mv/rm for Claude; still uncommitted, `git status` shows the 4 `D` entries):** `$BC` root — four Ecosystem docs deleted uncommitted: `Ecosystem/STATUS.md` (2022 lines, canonical dashboard), `HANDOFF.md`, `INCIDENT-GEN0-PEERS.md`, `DEPLOY.md` (moved to `infra/DEPLOY.md`). Decide: restore `STATUS.md`/`HANDOFF.md`/`INCIDENT-GEN0-PEERS.md` and mark them ARCHIVED (their still-open rows are enumerated in Phase 7/8 of this plan, so nothing is lost), or commit the deletion with a message that names this plan as the successor. Recommended: archive.
```bash
cd $BC && git checkout -- Ecosystem/STATUS.md Ecosystem/HANDOFF.md Ecosystem/INCIDENT-GEN0-PEERS.md
mkdir -p Ecosystem/archive && git mv Ecosystem/STATUS.md Ecosystem/archive/STATUS-2026-08-04.md && git mv Ecosystem/HANDOFF.md Ecosystem/archive/HANDOFF-2026-08-04.md && git mv Ecosystem/INCIDENT-GEN0-PEERS.md Ecosystem/archive/INCIDENT-GEN0-PEERS-2026-08-12.md
git rm -q Ecosystem/DEPLOY.md   # lives at Ecosystem/infra/DEPLOY.md
git add TESTNET-FINAL-PLAN-2026-09-23.md
git commit -m "docs: archive STATUS/HANDOFF/INCIDENT dashboards, drop duplicate DEPLOY.md, add testnet final launch plan"
```
- [ ] **Step 2 — OUT OF SCOPE (node-scala, operator 2026-09-30):** `$NODE` (branch `fix/netty-cve-2026-75595`, already merged as PR #62): commit the staged workflow archive + the two untracked plan docs, then delete the local branch.
```bash
cd $NODE && git checkout main && git pull -q && git checkout -b chore/archive-promote-vps-and-plans
git add .github/archived-workflows/README.md .github/workflows/promote-vps-image.yml .github/archived-workflows/promote-vps-image.yml docs/superpowers/plans/2026-09-12-inprocess-peer-stall-detection.md docs/superpowers/plans/2026-09-12-inprocess-self-commit-generation.md
git commit -m "chore: archive promote-vps-image workflow; commit plans for merged PRs #60/#61"
git push -u origin HEAD && gh pr create --fill
```
- [ ] **Step 3 — OUT OF SCOPE (node-scala, operator 2026-09-30):** `$NODE`: bring `dev` up to `main` (14 commits behind): `git checkout dev && git merge --ff-only origin/main && git push`. Expected: `Fast-forward`.
- [x] **Step 4 (done 2026-09-30 via infra PR #169, merged):** `$INFRA` (branch `chore/archive-oneoff-diagnostics`): commit `RUNBOOK-t0-soak-and-t2-audit.md`, gitignore `monitoring/__pycache__/`. **2026-09-30:** that branch's only commit (`2df0331`) is already on main. Runbook + gitignore are in **infra PR #169**; tick this box once it merges.
```bash
cd $INFRA && echo "monitoring/__pycache__/" >> .gitignore
git add .gitignore RUNBOOK-t0-soak-and-t2-audit.md && git commit -m "docs: commit T0-soak/T2-audit runbook; ignore pycache" && git push -u origin HEAD && gh pr create --fill
```
- [x] **Step 5 (verified 2026-09-30: `publish-maven-package.yml` on DecentralChain main, `publish-protobuf-schemas.yml` gone; local checkout on main, clean):** `$DCC` (branch `chore/archive-unused-workflows`): the staged deletion of `publish-protobuf-schemas.yml` plus untracked `publish-maven-package.yml` is a half-done refactor. Finish or revert; do not leave it. Run `pnpm -w lint` (or the repo's CI command per `README`) and open a PR. Expected: CI green.
- [x] **Step 6 (verified 2026-09-30: matcher and docs on main, 0 dirty, 0 ahead):** `$MATCHER`, `$DOCS`: clean; nothing to do.

### Task 1.2: Correct stale statements (one commit per repo)

**Files:**
- Modify: `$BC/CONSENSUS-BUG-INVESTIGATION-REFERENCE.md:109`, `:390-393`
- Modify: `$INFRA/RELAUNCH-20260904.md:3`, `:321-323`, `:344-346`, `:541-551`, `:642`, `:663`, `:797`
- Modify: `$NODE/docs/hotstuff-audit-readiness.md:9`, `:319`
- Modify: `$INFRA/.github/archived-workflows/README.md` (add the three crons retired in `849148d`)
- Modify: `$NODE/docs/upstream-reports/waves-committee-statehash-timing-bug.md:126-127`

- [ ] **Step 1:** Reference doc: append to §13 "Not yet done" paragraph: `UPDATE 2026-09-23: deployed. Both live images (tag testnet-relaunch-20260904 = sha256:b0d559cf…, and main@2cfdafe860 = sha256:0346f624…) contain 31d4410ba3 (verified with git merge-base --is-ancestor). What is NOT yet done is live observation past height 2640/3325 with zero InvalidStateHash — tracked in TESTNET-FINAL-PLAN-2026-09-23.md Phase 3.` Same one-liner at §8 line 109.
- [ ] **Step 2:** Runbook header line 3: replace `DRAFT / NOT EXECUTED` with `EXECUTED 2026-09-04 through §7 (genesis, config, image, wipe, restart). §8–§14 NOT executed; superseded by ../../TESTNET-FINAL-PLAN-2026-09-23.md Phases 2–6.` Fix §5.1/§5.2 to state the actual two digests and that unification is Task 2.1. Replace every "PR #152 open" with "PR #152 merged 2026-09-04 (c3c44b9)". Replace line 642's "does not exist on main today" with "exists at monitoring/alerts.yml:59".
- [ ] **Step 3 — OUT OF SCOPE (file lives in node-scala, operator 2026-09-30):** Audit-readiness: line 319 → "published 2026-09 (HTTP 200 on Central for 1.6.6 protobuf-src); node-scala resolves it since 17b87fb047". Line 9: bump the baseline SHA to `2cfdafe860` and list the HotStuff-touching commits since `9c49632398` (`git log --oneline 9c49632398..2cfdafe860 -- node/src/main/scala/com/decentralchain/consensus node/src/main/scala/com/decentralchain/state/FinalizationState.scala`).
- [ ] **Step 4:** Archived-workflows README: add a "2026-09-21 round" section listing `auto-commit-generators.yml`, `commit-generators-hotstuff.yml`, `peer-watchdog.yml`, replacement = node-scala PR #60/#61 flags, and the explicit sentence "main node coverage closed by TESTNET-FINAL-PLAN Task 2.2".
- [ ] **Step 5 — OUT OF SCOPE (file lives in node-scala, operator 2026-09-30):** Waves report doc lines 126-127: "Decision 2026-08-30: permanently internal-only (operator declined external reporting)."
- [ ] **Step 6:** Commit each repo: `docs: reconcile stale status claims against 2026-09-23 verified state`.

---

## Phase 2 — Make the four nodes identical and self-healing (config, then rollout)

### Task 2.1: One digest for all four nodes

**Files:**
- Modify: `$INFRA/.github/workflows/update-node-image.yml:43`, `deploy-node-config.yml:61`, `restart-host-network.yml:48` (VPS refs, currently `b0d559cf…`)
- Read: `$INFRA/clusters/testnet/apps/nodes.yaml:526,654,771` (LKE refs, `0346f624…`)

Decision: converge on `sha256:0346f62406518a4e9ecc8414250a03e1cf770bb8f9aeefff294c302274a9a61a` (main@`2cfdafe860`, includes self-commit + peer-stall + netty fix). Nothing newer is on `main`.

- [ ] **Step 1:** Replace the three VPS references:
```bash
cd $INFRA && git checkout -b fix/unify-node-digest-0346f624
sed -i '' 's/b0d559cf4a1ead5a1ae353646176147dc84eb2a3feb6fe2eb13d40c9e0e92098/0346f62406518a4e9ecc8414250a03e1cf770bb8f9aeefff294c302274a9a61a/g' .github/workflows/update-node-image.yml .github/workflows/deploy-node-config.yml .github/workflows/restart-host-network.yml
grep -c 0346f624 .github/workflows/update-node-image.yml .github/workflows/deploy-node-config.yml .github/workflows/restart-host-network.yml clusters/testnet/apps/nodes.yaml
```
Expected: `1 1 1 3` (one per workflow, three in nodes.yaml).
- [ ] **Step 2:** Add a CI guard so the four refs can never diverge again. Create `$INFRA/scripts/check-digest-parity.sh`:
```bash
#!/usr/bin/env bash
# Fails if the node-scala testnet image digest differs between the LKE manifest and the VPS workflows.
set -euo pipefail
cd "$(dirname "$0")/.."
LKE=$(grep -oE 'node-scala@sha256:[0-9a-f]{64}' clusters/testnet/apps/nodes.yaml | sort -u)
VPS=$(grep -ohE 'node-scala@sha256:[0-9a-f]{64}' .github/workflows/update-node-image.yml .github/workflows/deploy-node-config.yml .github/workflows/restart-host-network.yml | sort -u)
echo "LKE: $LKE"; echo "VPS: $VPS"
[ "$(printf '%s\n%s\n' "$LKE" "$VPS" | sort -u | wc -l | tr -d ' ')" = "1" ] || { echo "::error::node-scala digest differs between LKE and VPS"; exit 1; }
```
`chmod +x scripts/check-digest-parity.sh && ./scripts/check-digest-parity.sh`. Expected: two identical lines, exit 0. Add a step invoking it to `.github/workflows/ci.yml`.
- [ ] **Step 3:** Commit + PR: `fix(testnet): unify node-scala digest across VPS workflows and LKE manifest; add parity check`.
- [ ] **Step 4 ⛔ (rollout, main node):** after Task 2.2's config lands, run `gh workflow run update-node-image.yml -f network=testnet` (verify input names in the file). Then:
```bash
ssh -i $BC/deploy_key_testnet deploy@66.228.55.154 'docker inspect node-scala-testnet --format "{{.Image}} {{index .RepoDigests 0}}"'
```
Expected: contains `0346f624…`.

### Task 2.2: Main node gets the in-process self-heal flags

**Files:**
- Modify: `$INFRA/node-config/testnet/dcc.conf` (`miner {}` block near line 146 where `quorum = 0` lives; `network {}` block near line 115-119 where `enable-blacklisting = no` lives)
- Reference: `$NODE/node/src/main/resources/application.conf:167` (`peer-stall-threshold = 900` default semantics), `:253` (`self-commit-to-generation = no`)

Design note (from `2026-09-12-inprocess-peer-stall-detection.md:16`): main has `known-peers = []` and `peers-exchange = no`, so the detector must not log an alarm when there are no candidates; the code gates the log on "something was actually cleared" (`894f99cc5d`). Safe to enable.

- [ ] **Step 1:** Edit `dcc.conf`:
```hocon
  miner {
    # ...existing keys (quorum = 0 etc.)...
    self-commit-to-generation = yes
  }
  network {
    # ...existing keys (enable-blacklisting = no, known-peers = [])...
    peer-stall-threshold = 900
  }
```
- [ ] **Step 2:** Validate HOCON parses and the keys land in the right blocks:
```bash
pip3 install -q pyhocon
python3 - <<'EOF'
from pyhocon import ConfigFactory
c = ConfigFactory.parse_file("node-config/testnet/dcc.conf")
print("self-commit:", c.get("dcc.miner.self-commit-to-generation"))
print("peer-stall :", c.get("dcc.network.peer-stall-threshold"))
EOF
```
Expected: `self-commit: True` and `peer-stall : 900`. (`dcc.` prefix per `application.conf` root key; if the file uses a different root, `pyhocon` raises and the path must be corrected.)
- [ ] **Step 3:** Commit + PR: `config(testnet): enable in-process self-commit and peer-stall self-heal on main node (closes the gap left by retiring the external crons)`.
- [ ] **Step 4 ⛔:** Deploy: `gh workflow run deploy-node-config.yml -f network=testnet`. Then confirm on the VPS:
```bash
ssh -i $BC/deploy_key_testnet deploy@66.228.55.154 'docker logs node-scala-testnet --since 10m 2>&1 | grep -iE "self-commit|peer-stall|stall detector" | head'
```
Expected: at least one startup log line naming the settings (exact text per `MinerImpl`/`NetworkServer` logs added in PR #60/#61).

### Task 2.3: val-0 `quorum` contradicts its own rationale

**Files:** `$INFRA/clusters/testnet/apps/nodes.yaml:426` (`quorum = 0`), rationale at `:139`/`:287` ("Only the bootstrap seed (main VPS) keeps quorum=0").

- [ ] **Step 1:** `git log -S"quorum = 0" --format='%h %cs %s' -- clusters/testnet/apps/nodes.yaml | head` to learn why val-0 got 0. If no deliberate reason, set `quorum = 1` at line 426 to match gen-0/gen-1.
- [ ] **Step 2:** Commit + PR: `config(testnet): val-0 quorum=1, consistent with documented policy (only main keeps 0)`. Flux rolls it; confirm with `kubectl -n dcc rollout status statefulset/dcc-val-0` via cluster-diagnostics or a kubeconfig from `export-kubeconfig.yml`.

### Task 2.4: val-0 wallet lacks its generator key (infra issue #153) ⛔

**Files:** `$INFRA/clusters/testnet/apps/nodes.yaml` val-0 block (wallet seed Secret reference), KeeWeb `VAL_0_NODE_WALLET_SEED`, SOPS secret for val-0.

- [ ] **Step 1:** Derive the address from KeeWeb `VAL_0_NODE_WALLET_SEED` locally (never print the seed): use `dcc-dex-cli`/node's `GenesisBlockGenerator.toFullAddressInfo` per `RELAUNCH-20260904.md` §2.2. Compare with the val-0 generator address in `node/genesis-dcc-testnet-relaunch.conf` and with what the node reports: `curl -s -H "X-API-Key: $VAL0_KEY" http://127.0.0.1:16871/addresses` through the diagnostics port-forward.
- [ ] **Step 2:** If they differ, the Secret mounted into `dcc-val-0-0` holds a different seed than genesis expects. Fix the SOPS value to the genesis seed (⛔ push-secrets.yml), roll the pod, re-run Step 1. Expected: addresses equal.
- [ ] **Step 3:** Confirm self-commit now works: after one generation period, `curl -s $MAIN/generators/at/<nextPeriodStart>` includes val-0's address (period arithmetic in `RELAUNCH-20260904.md` §4.3). Close #153 with the evidence.

### Task 2.5: Add the `slashing-enabled` key explicitly (off) to every config

**Files:** `dcc.conf` hotstuff block (near `authoritative = true` at `:161`), `nodes.yaml:170,315,452`.

Why: `RELAUNCH-20260904.md` §12.4 says "set on exactly one node" but the key appears nowhere, so the drill has no switch. Making the default explicit also documents intent.

- [ ] **Step 1:** Add `slashing-enabled = no` next to `authoritative = true` in all four blocks. `grep -c "slashing-enabled = no" node-config/testnet/dcc.conf clusters/testnet/apps/nodes.yaml` → `1 3`.
- [ ] **Step 2:** Commit + PR: `config(testnet): make slashing-enabled=no explicit on all four nodes ahead of the staged drill`.

### Task 2.6: Healthchecks must detect a stalled chain, not just a live REST

**Files:**
- Modify: `$INFRA/compose/node-scala.yml:81` (main; currently `/node/version`)
- Modify: `$INFRA/clusters/testnet/apps/nodes.yaml:574-588, 700-714, 817+` (readiness/liveness `/node/status`)
- Modify: `$INFRA/compose/prometheus.yml:150` (alert-webhook check ends `|| exit 0`)
- Modify: `$INFRA/compose/blockchain-postgres-sync.yml:36`, `compose/scanner.yml:25`

Design: keep k8s readiness as `/node/status` (readiness must not flap on a temporarily slow chain), but add a **liveness** script that fails if `/blocks/height` has not changed for 15 minutes. For docker-compose, same idea with a state file.

- [ ] **Step 1:** Main node compose healthcheck:
```yaml
    healthcheck:
      test: ["CMD-SHELL", "H=$(curl -sf http://127.0.0.1:6869/blocks/height | sed 's/[^0-9]//g'); P=$(cat /tmp/last_h 2>/dev/null || echo 0); T=$(cat /tmp/last_t 2>/dev/null || echo 0); N=$(date +%s); if [ \"$H\" != \"$P\" ]; then echo $H >/tmp/last_h; echo $N >/tmp/last_t; exit 0; fi; [ $((N-T)) -lt 900 ]"]
      interval: 60s
      timeout: 10s
      retries: 3
      start_period: 120s
```
- [ ] **Step 2:** LKE liveness probe (each of the 3 StatefulSets), leaving readiness as-is:
```yaml
          livenessProbe:
            exec:
              command: ["sh","-c","H=$(wget -qO- http://127.0.0.1:6869/blocks/height | sed 's/[^0-9]//g'); P=$(cat /tmp/last_h 2>/dev/null || echo 0); T=$(cat /tmp/last_t 2>/dev/null || echo 0); N=$(date +%s); if [ \"$H\" != \"$P\" ]; then echo $H >/tmp/last_h; echo $N >/tmp/last_t; exit 0; fi; [ $((N-T)) -lt 900 ]"]
            initialDelaySeconds: 180
            periodSeconds: 60
            failureThreshold: 3
```
(Port differs per node: gen-1 `6870`, val-0 `6871` — check the existing `containerPort` in each block.)
- [ ] **Step 3:** `prometheus.yml:150`: remove `|| exit 0` so the webhook receiver check can fail. `bps.yml:36`: keep `/readiness` but add `&& curl -sf http://127.0.0.1:<bps-port>/metrics | grep -q 'bps_last_indexed_height'` only if that metric exists (check `apps/blockchain-postgres-sync` for exported metric names; otherwise leave and rely on the Prometheus rule in Task 5.1). `scanner.yml:25`: probe `GET /api/faucet` expecting non-503 is wrong when `DCC_FAUCET_SEED` unset by design; leave scanner as-is and alert via Prometheus blackbox in Task 5.1 instead.
- [ ] **Step 4:** Validate: `docker compose -f compose/node-scala.yml config >/dev/null && echo OK`; `kubectl --dry-run=client -f clusters/testnet/apps/nodes.yaml apply >/dev/null 2>&1 || kubeconform clusters/testnet/apps/nodes.yaml`. Expected: no errors.
- [ ] **Step 5:** Commit + PR: `fix(health): liveness fails when block height stalls 15 min; unmask alert-webhook healthcheck`. Roll out via existing deploy workflows (⛔ for the VPS restart).

---

## Phase 3 — Verify the live chain (runbook §8–§9, never executed)

Precondition: Phase 0 green, Tasks 2.1–2.2 rolled out. All commands from the workstation unless noted; LKE via `kubectl port-forward` after `gh workflow run export-kubeconfig.yml` (or the cluster-diagnostics output).

### Task 3.1: Same binary, same chain, advancing

- [ ] **Step 1:** Four `/node/version` strings:
```bash
curl -s $MAIN/node/version
for p in 16869:dcc-gen-0-0:6869 16870:dcc-gen-1-0:6870 16871:dcc-val-0-0:6871; do L=${p%%:*}; R=${p#*:}; POD=${R%%:*}; PORT=${R##*:}; kubectl -n dcc port-forward $POD $L:$PORT >/dev/null 2>&1 & sleep 2; curl -s http://127.0.0.1:$L/node/version; echo; kill %% ; done
```
Expected: 4 identical JSON bodies.
- [ ] **Step 2:** Four image digests byte-identical:
```bash
ssh -i $BC/deploy_key_testnet deploy@66.228.55.154 'docker inspect node-scala-testnet --format "{{index .RepoDigests 0}}"'
kubectl -n dcc get pods -l app=dcc-node -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].imageID}{"\n"}{end}'
```
Expected: all four end in `0346f62406518a4e9ecc8414250a03e1cf770bb8f9aeefff294c302274a9a61a`.
- [ ] **Step 3:** Heights within 2 of each other, and advancing over 30 min:
```bash
for i in 1 2 3; do date -u +%T; curl -s $MAIN/blocks/height; curl -s $MAIN/blocks/height/finalized 2>/dev/null; echo; sleep 600; done
```
Expected: both numbers strictly increase each sample. If `finalized` is pinned while `height` climbs → T0 stall class (memory `t0-stall-20260730`), go to Task 6.3 before anything else.
- [ ] **Step 4:** Zero state-hash rejections on all four since power-on:
```bash
ssh -i $BC/deploy_key_testnet deploy@66.228.55.154 'docker logs node-scala-testnet --since 24h 2>&1 | grep -c InvalidStateHash'
for p in dcc-gen-0-0 dcc-gen-1-0 dcc-val-0-0; do echo -n "$p "; kubectl -n dcc logs $p --since=24h | grep -c InvalidStateHash; done
```
Expected: `0` x4. Any non-zero → stop, capture `docker logs ... | grep -B5 -A5 InvalidStateHash` into `$NODE/.superpowers/sdd/stall-$(date +%F).log`, and open a Task 6.x investigation before continuing.
- [ ] **Step 5:** Confirm the chain is past both historical failure heights and that the 2600–3100 window (where 2640 died: `sponsorshipHeight = 3000` gating) was crossed cleanly:
```bash
H=$(curl -s $MAIN/blocks/height | jq .height); echo $H
curl -s "$MAIN/blocks/headers/seq/2600/2700" | jq -r '.[] | "\(.height) \(.generator) \(.transactionCount)"' | head -5
curl -s "$MAIN/blocks/headers/at/3325" | jq '{height, generator, stateHash}'
```
Expected: `H` well above 3325; headers exist and are non-empty for 2600–2700 and 3325.

### Task 3.2: Activation status exactly as intended (runbook §8.2)

- [ ] **Step 1:**
```bash
curl -s $MAIN/activation/status | jq '{height, features: [.features[] | {id, blockchainStatus, nodeStatus, activationHeight, supportingBlocks}]}'
```
Expected: ids 1–25 `ACTIVATED` at height 0/1; id 26 present with `nodeStatus: IMPLEMENTED`, `blockchainStatus` in `{VOTING, APPROVED, ACTIVATED}` with `supportingBlocks > 0`; no id ≥ 27 activated or approved.
- [ ] **Step 2:** Repeat against gen-0/gen-1/val-0 via port-forward. Expected: identical `features` arrays.
- [ ] **Step 3:** Feature-26 economics check once `ACTIVATED`: `curl -s $MAIN/blockchain/rewards | jq` → `currentReward` equals the AdjustedFullReward (20 DCC-equivalent, per plan Task 2 hunk (c)); before activation it is 6-equivalent. Record both observations with heights in the Soak Log. If 26 stays `VOTING` after ~50h of all-generators-healthy (`RELAUNCH-20260904.md` §12.5), investigate which generator is not voting (`supportingBlocks` vs blocks by generator).

### Task 3.3: Committee for the next period is non-empty (runbook §9)

- [ ] **Step 1:** Compute the next period start (period length from `dcc.conf` hotstuff settings; arithmetic at `RELAUNCH-20260904.md` §4.3) and query:
```bash
curl -s -o /tmp/gen.json -w '%{http_code}\n' "$MAIN/generators/at/<nextPeriodStart>"; jq length /tmp/gen.json; jq -r '.[]' /tmp/gen.json
```
Expected: `200`, length `3`, the three generator addresses (gen-0, gen-1, val-0). If val-0 missing → Task 2.4 not done. If main missing that is expected (main is bootstrap seed, not a committee generator — confirm against `nodes.yaml` rationale at `:139`).
- [ ] **Step 2:** Confirm `dcc_next_period_committee_size` metric > 0 in Prometheus: `curl -s 'http://127.0.0.1:9090/api/v1/query?query=dcc_next_period_committee_size'` over an SSH tunnel to the VPS. Expected: value ≥ 3.

### Task 3.4: Fund the canary wallet and make the canary meaningful (issue #148)

**Files:** `$INFRA/.github/workflows/canary-transaction.yml`; KeeWeb `TREASURY_SEED`; canary address `31LAqgqVTLySNCPuYqgLAYhcgS76wvBaLr9` (per `infra/docs/superpowers/plans/2026-07-24-tier6-canary-monitoring.md:26-36`, re-derive from the seed to be sure).

- [ ] **Step 1:** Balance now: `curl -s $MAIN/addresses/balance/31LAqgqVTLySNCPuYqgLAYhcgS76wvBaLr9 | jq .balance`. Expected today: `0`.
- [ ] **Step 2 ⛔:** Transfer 100 DCC from treasury to the canary address (canary spends 0.002 DCC per run → ~1000 days). Use the admin-dashboard treasury route (`api.treasury.fund.ts`, idempotent) or `dcc-dex-cli`. Re-check balance ≥ `10000000000`.
- [ ] **Step 3:** Dispatch canary: `gh workflow run canary-transaction.yml`; poll; Expected: `success`, log line `Canary tx <id> confirmed at height <h> in <ms>ms`.
- [ ] **Step 4:** Add a canary-balance guard so a future 0-balance is a distinct alert, not a generic failure: in the canary script before broadcast, fetch balance and `console.error('Canary tx failed: CANARY_UNFUNDED balance=' + bal)` if `< 10 * fee`. Commit: `fix(canary): distinguish unfunded wallet from network failure`.
- [ ] **Step 5:** Close #148 with the run URL. Add "re-fund canary" to `RELAUNCH-20260904.md` §10.1 for any future re-genesis.

---

## Phase 4 — Downstream services: write the missing reset procedures, then run them

Runbook §10 is literally `TBD` for three services and silent for four more. These are needed both now (services have been down 6 days and may have stale state vs. the chain) and for any future re-genesis.

### Task 4.1: blockchain-postgres-sync (BPS) reset procedure

**Files:**
- Create: `$INFRA/runbooks/reset-bps-testnet.md`
- Read: `$DCC/apps/blockchain-postgres-sync/README.md:84` (`BPS_STARTING_HEIGHT`), `$INFRA/compose/blockchain-postgres-sync.yml`

- [ ] **Step 1:** Write the procedure (verify container/db names against the compose file first):
```bash
# on the VPS
docker stop blockchain-postgres-sync-testnet
docker exec -i postgres-testnet psql -U postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='bps_testnet';"
docker exec -i postgres-testnet psql -U postgres -c "DROP DATABASE bps_testnet;" -c "CREATE DATABASE bps_testnet OWNER bps;"
# BPS_STARTING_HEIGHT=0 in the env file, then:
docker start blockchain-postgres-sync-testnet
docker logs -f blockchain-postgres-sync-testnet 2>&1 | grep -m1 -E "height [0-9]+ .*(indexed|synced)"
```
- [ ] **Step 2:** For TODAY (no re-genesis): only restart and confirm no "Requested start height exceeds current blockchain height" (memory: BPS stores height; after a node restart it can race). If it appears, `docker restart blockchain-postgres-sync-testnet` once the node height exceeds the stored height.
- [ ] **Step 3:** Verify BPS caught up: `docker exec -i postgres-testnet psql -U postgres -d bps_testnet -tAc "select max(height) from blocks_raw"` ≈ `$MAIN/blocks/height`.
- [ ] **Step 4:** Link the runbook from `RELAUNCH-20260904.md` §10 (replace the TBD). Commit.

### Task 4.2: Matcher state reset procedure (preserve `account.dat`)

**Files:**
- Create: `$INFRA/runbooks/reset-matcher-testnet.md`
- Read: `$MATCHER/dex/src/main/resources/application.conf:6,78,442-452,520` (data-directory, order-db, snapshots, LevelDB event store), `$INFRA/compose/matcher.yml`, `RELAUNCH-20260904.md:609-615`

- [ ] **Step 1:** Write the procedure:
```bash
# on the VPS
docker stop matcher-testnet
ls -la /opt/dcc/data/matcher-testnet          # expect: account.dat, data/ (LevelDB), order-db/, snapshots/, journal/
cp -a /opt/dcc/data/matcher-testnet/account.dat /opt/dcc/backup/matcher-account.dat.$(date +%F)
find /opt/dcc/data/matcher-testnet -mindepth 1 -maxdepth 1 ! -name account.dat -exec rm -rf {} +
docker start matcher-testnet
curl -s http://127.0.0.1:6886/matcher | jq          # matcher public key; must equal the pre-reset key
```
- [ ] **Step 2:** Verify the matcher account still holds funds on the chain: `curl -s $MAIN/addresses/balance/31VMNVAvVh67dPZ41nMnYZvhoZFW7wwPrmq | jq .balance` (genesis matcher address per runbook §2.2). Expected: ~1B units minus fees.
- [ ] **Step 3:** For TODAY: restart only, then place-and-cancel one order through the exchange UI or `dcc-dex-cli` and confirm `GET /matcher/orderbook/<pair>` responds 200.
- [ ] **Step 4:** Add to `RELAUNCH-20260904.md` §10. Commit.

### Task 4.3: data-service, scanner, exchange, admin-dashboard: verify statelessness and URLs

- [ ] **Step 1:** data-service: restart after BPS (`restart-services.yml`); confirm `DEFAULT_MATCHER` set (`RELAUNCH-20260904.md:596`); `curl -s https://testnet-data-service.decentralchain.io/transactions/exchange?limit=1` → 200.
- [ ] **Step 2:** scanner: `grep -rn "createClient\|pg\.\|Pool(" $DCC/apps/scanner/src | head` → confirm it reads only via data-service/BPS and Redis (rate-limit). Record "stateless over BPS + Redis" as verified, or list the tables it owns.
- [ ] **Step 3:** Faucet: `curl -s -o /dev/null -w '%{http_code}\n' https://<scanner>/api/faucet` → not 503. Faucet balance: derive address from KeeWeb `FAUCET_SEED`, `curl -s $MAIN/addresses/balance/<addr>`; if < 100k DCC, ⛔ transfer from treasury (prior relaunches used 1M). Treasury balance = `1000000000000000` minus known outflows.
- [ ] **Step 4:** exchange + admin-dashboard: `grep -n "decentralchain.io" $DCC/apps/exchange/.env.* $DCC/apps/admin-dashboard/.env.* 2>/dev/null` → every URL must be `testnet-node`, `testnet-matcher`, `testnet-data-service`. Fix any `matcher.decentralchain.io` (docs CSV mismatch, Task 8.3).
- [ ] **Step 5:** Admin E2E once, on demand (nightly cron removed deliberately): `gh workflow run admin-e2e.yml -R Decentral-America/infra`. Expected: success; if it fails, triage issue #142 rather than re-enabling the cron.

### Task 4.4: Secrets gaps that will bite on the next `push-secrets`

**Files:** SOPS `secrets/testnet.env` (never print), KeeWeb.

- [ ] **Step 1:** `REDIS_PASSWORD` absent from SOPS while `push-secrets.yml` expects it (memory `testnet-complete-chain:64`). Add the current value (from the running container env or the one-shot `inject-redis-secret.yml`) to SOPS so the next push does not break the faucet rate-limiter.
- [ ] **Step 2:** `DCC_CANARY_SEED` requires two provisioning steps (`canary-transaction.yml:5-17`): SOPS push AND `gh secret set DCC_CANARY_SEED --env testnet`. Confirm the env secret exists: `gh secret list -e testnet -R Decentral-America/infra | grep CANARY`.
- [ ] **Step 3:** Grafana admin password: wire `GF_SECURITY_ADMIN_PASSWORD` from KeeWeb `GRAFANA_ADMIN_PASSWORD` in `compose/grafana.yml` (currently default admin/admin per memory). Alertmanager SMTP: confirm `smtp_auth_password` in the LKE `alertmanager-config` Secret equals KeeWeb `SMTP_PASSWORD`.
- [ ] **Step 4:** KeeWeb backup hygiene (`Ecosystem/KEEWEB_BACKUP.md`): remove the inline OpenSSH private key block (lines 119-130) — reference the KeeWeb entry instead; fix the duplicate entry number 27; execute the 4 pending deletions at lines 254-259; add the four undocumented names (`ADMIN_DASHBOARD_GITHUB_PAT`, `SENTRY_AUTH_TOKEN`, `GRAFANA_URL`, `REDIS_PASSWORD`). Commit: `docs(secrets): remove inline key material, fix numbering, add missing entry names`.

---

## Phase 5 — Alerts armed and proven to page

### Task 5.1: Arm and test-fire (runbook §11)

**Files:** `$INFRA/monitoring/alerts.yml`, `monitoring/alertmanager.yml:20-26`, `clusters/testnet/monitoring/kube-prometheus-stack.yaml:160-199`, `compose/prometheus.yml`.

- [ ] **Step 1:** Deploy monitoring: `gh workflow run deploy-monitoring-stack.yml -f network=testnet`. Expected: success.
- [ ] **Step 2:** Rules loaded: over SSH tunnel `curl -s http://127.0.0.1:9090/api/v1/rules | jq -r '.data.groups[].rules[].name'` → includes `BlockProductionStalled`, `FinalizationStalled`, `FinalizationNotAdvancing`, `HotStuffCommitNotAdvancing`, `HotStuffEquivocationDetected`, `CommitteeGapUpcoming`, `ExporterDown`, `ServiceDown`.
- [ ] **Step 3:** Add two rules that today's outage proves missing (append to `alerts.yml`):
```yaml
  - alert: MainNodeUnreachable
    expr: up{job="node-scala"} == 0
    for: 5m
    labels: {severity: critical}
    annotations: {summary: "main node exporter target down 5m"}
  - alert: LkeGeneratorsDown
    expr: count(up{job=~"dcc-gen.*|dcc-val.*"} == 1) < 3
    for: 10m
    labels: {severity: critical}
    annotations: {summary: "fewer than 3 LKE generators scraped for 10m"}
```
(Adjust `job` labels to the actual scrape config names in `compose/prometheus.yml` and `clusters/testnet/monitoring/`.) `docker run --rm -v $INFRA/monitoring:/m prom/prometheus promtool check rules /m/alerts.yml` → `SUCCESS`.
- [ ] **Step 4:** Test-fire: `curl -XPOST http://127.0.0.1:9093/api/v2/alerts -d '[{"labels":{"alertname":"TestFire","severity":"critical"}}]'` on the VPS tunnel → a GitHub issue appears from the webhook bot within 2 min. Same on the LKE Alertmanager → email arrives at `info@decentralchain.io`. Record both timestamps. Resolve the test issue.
- [ ] **Step 5:** Note in `RUNBOOK-t0-soak-and-t2-audit.md:47,50`: `FinalizationStalled`/`FinalizationNotAdvancing` cover the finalized-height stall requirement; add a Grafana panel for `finalizedHeight` vs `height` (dashboard JSON under `monitoring/grafana/`; confirm panel exists with `jq '.panels[].title' <dashboard>.json`).
- [ ] **Step 6:** Commit: `feat(alerts): infra-down rules; record test-fire evidence`.

---

## Phase 6 — Consensus evidence still owed (testnet-gating subset)

### Task 6.1: Bug 2 ("how far is the chain locked in") — determine whether Task D already closed it

**Files:** `$BC/CONSENSUS-BUG-INVESTIGATION-REFERENCE.md:147-157`; `$NODE/node/src/main/scala/com/decentralchain/state/FinalizationState.scala`; node-scala commits from the 2026-08-30 relaunch (memory `testnet-final-relaunch-20260830:21` — "Task D finalization-rollback bug was real", DeterministicFinality cluster).

- [ ] **Step 1:** `cd $NODE && git log --oneline --since=2026-08-25 -- node/src/main/scala/com/decentralchain/state/FinalizationState.scala node/src/main/scala/com/decentralchain/state/BlockchainUpdaterImpl.scala | head -20`. Read each for "rollback", "microblock discard", "finalized height".
- [ ] **Step 2:** Write a failing test if no rollback coverage exists: in `node/tests/.../FinalizationRollbackSpec.scala`, append a microblock that advances the finalized-height value, discard it (`removeAfter`), assert the finalized height returns to its pre-microblock value and the next key block's state hash equals the appender's recompute. Run `sbt "node-tests/testOnly *FinalizationRollbackSpec"`.
- [ ] **Step 3:** If it fails: implement both halves together per §9 (per-liquid-point finalized tracking with correct rollback; block-builder must not mix discarded-piece data), following TDD; full `sbt "node-tests/test"` zero regressions; PR to main. If it passes: update §9 Bug 2 to "CLOSED by <commit>, covered by FinalizationRollbackSpec" with the commit hash.
- [ ] **Step 4:** Same pass for §8 line 110 (committee-*eligibility* logic vs. stale rollback): `grep -rn "committedGenerators\|nextCommittedGenerators" node/src/main/scala | grep -v Hash` — list every non-hash consumer; for each, state in the doc whether it reads the rolled-back or live list. Close or open accordingly.

### Task 6.2: Live epoch transition + committee rotation evidence (T10)

- [ ] **Step 1:** Identify the next committee-period boundary height. Capture 10 min before and after: `/generators/at/<h>`, `/blocks/height/finalized`, `/debug/hotstuff` (or the actual HotStuff status route in `FinalityApiRoute`), and Kamon counters `hotstuff.stale-target-*` from Prometheus.
- [ ] **Step 2:** Expected: committee set changes or is re-confirmed at the boundary; finalized height continues without a >2-period gap; `stale-target` counters do not grow unboundedly. Paste into the Soak Log and into `hotstuff-audit-readiness.md:108,333` as the T10 live evidence.

### Task 6.3: T0 finality watch (the 2026-07-30 pin was never diagnosed)

- [ ] **Step 1:** Every 6h for 72h: `curl -s $MAIN/blocks/height; curl -s $MAIN/blocks/height/finalized`. Lag must stay bounded (record the max). If lag grows monotonically for >30 min: pull gen-0/gen-1 logs for `endorse|Endorsement|quorum` in that window before any restart, save to `$NODE/.superpowers/sdd/t0-<date>.log`, then diagnose (memory `t0-stall-20260730` deferral reasons no longer apply — kubectl access exists via `export-kubeconfig.yml`).

### Task 6.4: Crash and partition drills (runbook §12.1)

- [ ] **Step 1 (crash):** `kubectl -n dcc delete pod dcc-gen-1-0` during a period in which gen-1 is in the committee. Expected: pod back `Running` < 3 min, height and finalized height keep advancing on main, no `InvalidStateHash`, gen-1 rejoins (`/peers/connected` on main includes gen-1 within 5 min — proves the in-process peer-stall path is not needed for the ordinary case).
- [ ] **Step 2 (partition):** Temporarily add a Calico NetworkPolicy denying egress from `dcc-gen-0-0` to the VPS IP for 20 min, then remove. Expected: main continues with the remaining quorum; after removal, gen-0 reconnects without manual `peers/connect`. Confirm the stall detector log line ("cleared N suspensions") appears at most once and only if suspensions actually existed.
- [ ] **Step 3:** Record both in the Soak Log; mark `hotstuff-audit-readiness.md:97,324`.

### Task 6.5: Equivocation drill with slashing on exactly ONE node ⛔ (runbook §12.4)

- [ ] **Step 1:** Wait until Tasks 6.2–6.4 are recorded and the chain is ≥ 24h past power-on (first-boot lockedQC window, `hotstuff-audit-readiness.md:124-134`).
- [ ] **Step 2 ⛔:** Set `slashing-enabled = yes` on gen-0 only (`nodes.yaml:170` block). Flux rolls it.
- [ ] **Step 3:** Produce an equivocation from a throwaway generator using the node-it harness technique (`FourNodeHotStuffTestSuite` equivocation scenario) against testnet, or by running a second gen-1 instance with the same key for one block (⛔, destructive to gen-1's reputation on the chain; use a funded throwaway generator instead if possible).
- [ ] **Step 4:** Expected: `HotStuffEquivocationDetected` fires; gen-0 emits the evidence tx; `/transactions/info/<id>` shows the `HotStuffEquivocationProof` applied; the offender's generating balance is penalised per the T5 rules. Other three nodes (slashing off) accept the block containing the evidence.
- [ ] **Step 5:** Decide fleet-wide `slashing-enabled` and record the decision in `hotstuff-audit-readiness.md:326` and D4 of the source plan.

### Task 6.6: 72h soak record (closes runbook §12.1, audit-readiness §8 first box)

- [ ] **Step 1:** Start the clock after Task 3.1 passes with all four on `0346f624`. Log every 6h: height, finalized height, `InvalidStateHash` count (all four), committee size, canary success rate (`gh run list --workflow canary-transaction.yml --limit 24`), any alert fired.
- [ ] **Step 2:** Pass criteria: zero `InvalidStateHash`; finalized-height lag max recorded and < 2 periods; canary ≥ 95% success; all drills (6.2, 6.4) inside the window; no pod restarts other than deliberate.
- [ ] **Step 3:** Write `$INFRA/SOAK-2026-XX-XX.md` from the Soak Log; link from `RUNBOOK-t0-soak-and-t2-audit.md` and set its T0-soak start timestamp (the 60-day mainnet clock starts here too).

---

## Phase 7 — Security hygiene

### Task 7.1: Rotate the REST API keys (staged since June, never rolled out)

**Files:** infra branch `security/rotate-api-keys` (commit `1141c3a`, unpushed per `HANDOFF.md:281/342`); KeeWeb entries `*_NODE_REST_API_KEY`; `verify-api-keys.yml`.

- [ ] **Step 1:** `cd $INFRA && git branch -a | grep rotate` — if the branch exists locally, rebase onto main; else regenerate 4 keys + hashes (`node/src/main/scala/.../ApiKeyHash` procedure documented in `RUNBOOK-mainnet-edge-and-key-rotation.md`).
- [ ] **Step 2 ⛔:** Push new hashes via `push-secrets.yml`, roll all four nodes (Flux + `deploy-node-config.yml`), update KeeWeb, then `gh workflow run verify-api-keys.yml`. Expected: 4x `200` with new keys, 4x `403` with old keys.
- [ ] **Step 3:** Update GitHub env secrets that hold the keys (`GEN0_KEY`, `GEN1_KEY`, `VAL0_KEY` used by `cluster-diagnostics.yml`).

### Task 7.2: Rotate the deploy SSH key (pasted into a chat session 2026-09-02)

- [ ] **Step 1:** `ssh-keygen -t ed25519 -f $BC/deploy_key_testnet.new -C deploy@testnet`; add pubkey to VPS `deploy` user via existing session; `TF_VAR_DEPLOY_SSH_PUBLIC_KEY` in KeeWeb and GitHub; `DEPLOY_SSH_KEY` secret; remove old pubkey from `~/.ssh/authorized_keys`; test `ssh -i deploy_key_testnet.new deploy@66.228.55.154 uptime`.
- [ ] **Step 2:** `git rm --cached` nothing (keys are untracked at `$BC/deploy_key_testnet*`; confirm with `git ls-files | grep deploy_key` → empty). Delete the old private key file.

### Task 7.3: Remaining audit-report items with no status tag

- [ ] 01 pruning (mainnet 60-node scale) — the node-scala tracking issue is OUT OF SCOPE (operator 2026-09-30): defer; open a tracking issue in node-scala with the report text; not testnet-gating.
- [ ] 02 exchange-indexer Postgres growth: add a Prometheus rule on `pg_database_size_bytes{datname="bps_testnet"}` growth > X/day and disk-free < 20%; commit with Task 5.1.
- [ ] 04 over-provisioned compute: revisit after the soak; cost only.
- [ ] 0c exchange WCAG (2 axe-core checks): DecentralChain issue; not testnet-gating.
- [ ] 5a faucet rate-limit Redis wiring: covered by Task 4.4 Step 1 (`REDIS_PASSWORD`) — verify `REDIS_URL` set in scanner env, then mark FIXED.

---

## Phase 8 — Ecosystem debt that shows up as red on dashboards

### Task 8.1: matcher nightly Network/Chaos tests (matcher #26, failing since 2026-09-10)

- [ ] **Step 1:** `gh run view 34455102525 -R Decentral-America/matcher --log-failed | grep -E "FAILED|\*\*\* |All attempts" | head` → identify the suite. If "All attempts are out"/GC-bound → runner starvation (memory `matcher-dexit-flakiness`): move `@NetworkTests` to a larger runner (`runs-on: ubuntu-latest-8-cores` or self-hosted) in `nightly-network-tests.yml`; do not loosen timeouts. Otherwise treat as a real bug and open a systematic-debugging task.
- [ ] **Step 2:** One green nightly, then close #26. **2026-09-30:** `nightly-network-tests.yml` now triggers on `v*` tags + `workflow_dispatch` only (no cron), so there is no nightly to go green. #26 is still OPEN and the failing suite was never diagnosed. Do Step 1 on a manual dispatch, then close #26 with that run.

### Task 8.2: Test-debt branches never merged (`docs/test-debt-inventory.md`)

- [ ] **node-scala part OUT OF SCOPE (operator 2026-09-30). matcher part resolved (verified 2026-09-30): no `ignore-triage` branch exists locally or on the remote, `d91766a5f` is not in matcher history, and the `ignore{}` triage landed via matcher PR #21 (`587820f28`, 2026-08-03). The inventory never referenced that branch.** Original: node-scala `test/fix-class-a-ignores` (`d963e5f22d`) and matcher `test/matcher-ignore-triage` (`d91766a5f`): `git branch -a | grep -E "fix-class-a|ignore-triage"`; if present, rebase and PR; if gone, update the inventory to say so.
- [ ] DEX-982 deprecation window and DEX-1402 WS test: leave as documented; not testnet-gating.

### Task 8.3: Public docs point at the right testnet

**Files:** `$DOCS/docs/_static/02_decentralchain/tables/025_*.csv`, `026_*.csv`, `028_*.csv` (`matcher.decentralchain.io` → `testnet-matcher.decentralchain.io`), `029_*.csv`, `030_Faucet-Obtaining-Tokens.csv` (TBA → scanner faucet URL), `docs/04_building-apps/03_how-to-guides.md:35,63,79`, `04_wallet-integration.md:17` (`nodes.decentralchain.io` does not resolve → `testnet-node.decentralchain.io`).

- [ ] **Step 1 (2026-10-01: edits DONE in docs PR #19, merged, docs main = dev = `491a264`. data-service, exchange (`testnet.decentral.exchange`, returns 200), matcher, explorer, faucet and the dead `nodes.*` samples are fixed. REMAINING: the 200-check for the data-service, matcher, explorer and faucet hosts, which resolve to the offline Linode VPS. Tick after Phase 0):** Edit; `curl -s -o /dev/null -w '%{http_code}\n' <each URL>` → 200 for every URL in those tables. Commit: `docs: publish live testnet endpoints; fix matcher host and dead nodes.* host`.

---

## Phase 9 — Sign-off: definition of "final testnet"

All boxes below must be true, each with a Soak Log line (command + output + date):

- [ ] Four nodes on `sha256:0346f624…` (or a newer single digest), byte-identical `/node/version`.
- [ ] Main node has `self-commit-to-generation = yes` and `peer-stall-threshold = 900`; all four have explicit `slashing-enabled`.
- [ ] `InvalidStateHash` = 0 on all four across the 72h soak; chain height > 3325 and past 2600–3100 cleanly.
- [ ] Features 1–25 activated, 26 `ACTIVATED` with reward = 20-equivalent observed, none ≥ 27.
- [ ] `/generators/at/<next>` = 3 addresses every period for 72h; val-0 present (#153 closed).
- [ ] Canary ≥ 95% green over 72h (#148 closed); Tier-0 liveness workflow green.
- [ ] Alerts: rules loaded, both receivers test-fired with evidence; `MainNodeUnreachable`/`LkeGeneratorsDown` present.
- [ ] Downstream: BPS max height ≈ chain height; matcher order round-trip OK; data-service 200; faucet claim OK; treasury/faucet balances recorded; exchange/admin URLs correct; admin-e2e green once.
- [ ] Drills recorded: pod crash, partition, live epoch transition, equivocation with slashing on one node + fleet decision.
- [ ] Bug 2 status resolved to CLOSED-with-commit or FIXED (Task 6.1); §8 line 110 resolved.
- [ ] Security: API keys rotated and verified, SSH key rotated, KeeWeb backup cleaned, `REDIS_PASSWORD` in SOPS, canary env secret present.
- [ ] Docs: reference doc, relaunch runbook, audit-readiness, archived-workflows README reconciled; public docs endpoints 200.
- [ ] Working trees clean in all in-scope repos (DecentralChain, matcher, infra, docs). The node-scala `dev == main` clause is OUT OF SCOPE (operator 2026-09-30).

Tag on sign-off: `cd $NODE && git tag -a testnet-final-$(date +%Y%m%d) -m "Testnet final: soak passed, see infra/SOAK-*.md" <digest commit> && git push --tags`; pin the same digest as the Release image.

---

## Explicitly deferred to stagenet/mainnet (not testnet-gating; listed so nobody re-derives them)

- Reference §7 Phase 2/3: legacy node build (untouched since 2024), stagenet legacy→modern handoff at 10k blocks, storage compatibility, Phase 3 mainnet migration.
- `hotstuff.authoritative` advisory vs enforcing decision (F-1); external consensus audit; 60-day T0 soak (clock starts at Task 6.6); mainnet LKE HA (`lke_ha=true`, dedicated CPU, ≥2 pool); gen nodes on separate LKE nodes.
- HotStuff design item "view = height under Waves-NG" (memory `hotstuff-t2-step5:129`), C1 single-active-view pacemaker, P3 100MB frame cap, E1/P5 defaults.
- Consensus rule changes SC-575 / SC-580 / SC-695 (network governance via a new feature id).
- Audit item 01 (pruning), `committedGeneratorsHash` None-acceptance hardening, `maxCommittedGenerators` cap.
- Waves upstream reporting: permanently internal-only (operator decision).
- Prometheus federation Newark→LKE; matcher first versioned release; `AGE_SECRET_KEY` for stagenet/mainnet envs; `SENTRY_AUTH_TOKEN` mainnet.
- `Ecosystem/AUDIT-T2-FINALITY.md` is lost; its ledger is partially reconstructed in memory `hotstuff-t2-step5:276`. Re-create only if the external audit needs it.

---

## Soak Log (append-only; one line per verified checkbox)

| Date (UTC) | Task | Command | Decisive output | Who |
|---|---|---|---|---|
| 2026-09-23 | 0 (pre) | `gh run view 35867921158` | 3 LKE workers NotReady; dcc-gen-0/gen-1/val-0 Pending 6d1h | Claude (read-only) |
| 2026-09-23 | 0 (pre) | `curl $MAIN/blocks/height` | timeout; VPS no ping | Claude |
| 2026-09-23 | Ground truth | `git merge-base --is-ancestor 31d4410ba3 testnet-relaunch-20260904` | true (carry-fee fix in both live images) | Claude |
| 2026-09-30 | Status | `curl` testnet-node / mainnet-node / grafana.testnet | no connection (Linode still offline) | Claude |
| 2026-09-30 | Status (new) | `dig +short A decentralchain.io decentralscan.com @1.1.1.1` | empty for both (apex DNS missing); whois: registered to 2027 | Claude |
| 2026-09-30 | Status | `gh run list -R Decentral-America/DecentralChain -b main` @ `b940c744a` | CI, CodeQL, RIDE CI, Trivy: success | Claude |
| 2026-09-30 | Status | `pnpm audit --audit-level=moderate --prod` on DecentralChain main | No known vulnerabilities found | Claude |
| 2026-09-30 | Status | `gh api repos/Decentral-America/docs/pages` + `curl -sI docs.decentralchain.io/en/main/` | build_type=workflow, https_enforced=true; 200, last-modified 2026-09-30 | Claude |
| 2026-09-30 | 1.1 Step 5 | `git ls-tree origin/main .github/workflows/` (DecentralChain) | publish-maven-package.yml present; publish-protobuf-schemas.yml absent | Claude |
| 2026-09-30 | 1.1 Step 6 | `git status` / `rev-list origin/main..HEAD` (matcher, docs) | 0 dirty, 0 ahead | Claude |
| 2026-09-30 | 8.2 (matcher) | `git branch -a \| grep ignore-triage` (matcher) | no branch; triage in PR #21 `587820f28` | Claude |
| 2026-09-30 | 1.1 Step 4 + merges | `gh pr view 117/169`; `git rev-parse origin/main origin/dev` | both MERGED; DecentralChain dev=main `38e405f5f`, infra dev=main `62cbd74` | operator + Claude |
| 2026-10-01 | 8.3 (edits) | `gh pr view 19 -R Decentral-America/docs`; `curl -o /dev/null -w %{http_code} https://testnet.decentral.exchange/` | MERGED; exchange 200; other testnet hosts resolve to 66.228.55.154 (offline) | Claude |
| 2026-10-01 | Offline prep | `gh pr view 171 -R Decentral-America/infra` | 13 commits; digest-parity OK; tofu validate OK; LKE liveness kept REST (restart-storm risk) | Claude |
| 2026-10-01 | Security | `git show origin/main:.github/workflows/push-secrets.yml` + matcher `AccountStorage.load` | MATCHER_SEED never written; in-mem seed "" → KeyPair(empty) | Claude |
| 2026-10-04 | Recovery | heights via REST / kubectl exec | main 33482 (fin 33382), gen-0 22894, gen-1 9927, val-0 8958, all syncing; liveness green | Claude |
| 2026-10-04 | 3.1 Step 4 | `grep -c InvalidStateHash` (main docker logs 12h; gen-0/gen-1/val-0 kubectl logs 12h) | 0 / 0 / 0 / 0 | Claude |
| 2026-10-04 | 3.1 Steps 1-2 | `/node/version` x4; main image `0346f6240651`, LKE pods `sha256:0346f624…` | all `DecentralChain v1.8.0`, one digest | Claude |
| 2026-10-04 | 3.2 | `curl $MAIN/activation/status` | 26 features ACTIVATED (1–26), none ≥ 27, height 34239 | Claude |
| 2026-10-04 | 2.2 / 2.5 | `grep` on the live `/opt/dcc/config/node-testnet/dcc.conf` | `self-commit-to-generation = yes`, `peer-stall-threshold = 900`, `slashing-enabled = no` | Claude |
| 2026-10-04 | 4.1 Step 3 | `select max(height) from blocks_microblocks` (bps_testnet) vs `$MAIN/blocks/height` | 34239 = 34239 (BPS caught up) | Claude |
| 2026-10-04 | 6.x observation | main `docker logs` HotStuff | T2 stalled 15:12→15:42 UTC at 33997; WATCHDOG reset, then committed 34102 and stayed steady (111 commits / 2 resets in 90 min). Follows today's restarts; watch during the soak | Claude |
