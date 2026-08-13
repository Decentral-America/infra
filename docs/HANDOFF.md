# DecentralChain (DCC) — Testnet Engineering Handoff

**Date:** 2026-06-30 (body content) — reconciled 2026-08-02, 2026-08-04, then again 2026-08-13 (see "Reconciled 2026-08-13" section at the bottom, supersedes earlier ones where they conflict)
**Status:** Chain live and advancing (height 132,000+ as of 2026-08-13, all three generators — main/gen-0/gen-1 — forging in a healthy split after a connectivity bug fix; see "Reconciled 2026-08-13"). `DecentralChain v1.7.0`. The "9733+ / v1.6.3" and "107,779 / 107,697" figures in the table/T2 section below are older point-in-time snapshots, left as-is per reconciliation policy. **T2 HotStuff is AUTHORITATIVE on testnet** and its `finalizedHeight` is genuinely advancing again post-fix (see T2 HotStuff Summary below and "Reconciled 2026-08-13"). BPS type-19 deployed.
**Audience:** DCC engineering team

> Single source of truth for testnet infrastructure state. For detailed runbook procedures, see `node-scala/docs/testnet-bootstrap-runbook.md`.

---

## What DCC Is

DecentralChain is a sovereign Layer-1 blockchain with its own token (DCC), consensus, genesis, and network. It is not connected to any external blockchain network.

- **Chain ID:** `!` (byte 33)
- **Total supply:** 100,000,000 DCC
- **Block time:** ~30s average (min 5s), testnet genesis-configured
- **Consensus:** FairPoS V2 + LPoS (Leased Proof of Stake)
- **Finality:** T0 DeterministicFinality (feature 25) active + T2 HotStuff active
- **P2P port:** 6868 (Newark) / 6863–6865 (Frankfurt LKE)
- **REST API:** port 6869 per node (gen-1: port 6870)

---

## Current Testnet State (2026-06-30)

> **2026-08-02 note:** this table is the original 2026-06-30 snapshot and has not been re-walked
> field-by-field. The only two facts independently re-verified live during the 2026-08-02
> reconciliation are chain height (`102,268`, up from `9733+`) and node version
> (`DecentralChain v1.7.0`, up from `v1.6.3`) via `curl https://testnet-node.decentralchain.io/{blocks/height,node/version}`.
> Everything else below (peer/mining status, T2 "soak PASSED", CurGens/NextGens counts) is unverified
> as of today and should be treated as historical, not current-state fact.

| Item | Status |
|------|--------|
| Chain height | 9733+, advancing ~30-60s/block |
| Main node (Newark 66.228.55.154) | Healthy — v1.6.3-be2dcfc0 |
| gen-0 (LKE 172.105.64.89:6863) | Mining |
| gen-1 (LKE 172.105.64.89:6864) | Mining |
| val-0 (LKE 172.105.64.89:6865) | Synced |
| T0 DeterministicFinality | Active |
| T2 HotStuff | Active — lag=0, round-timeout=1200ms, soak PASSED |
| CurGens | 3 — main + gen-0 + gen-1 |
| NextGens | 3 — all committed |
| BPS (blockchain-postgres-sync) | Healthy, type-19 enabled (fbece975a) |
| Matcher | Healthy (port 6886) |
| Prometheus alerts | 5 production alerts deployed |

---

## Network Topology

```
Newark (66.228.55.154)               Frankfurt LKE (172.105.64.89)
┌──────────────────────┐             ┌────────────────────────────────┐
│  node-scala-testnet  │◄───────────►│  dcc-gen-0  (P2P :6863)       │
│  + BPS               │◄───────────►│  dcc-gen-1  (P2P :6864)       │
│  + data-service      │             │  dcc-val-0  (P2P :6865)       │
│  + matcher           │             │  Kubernetes / Flux GitOps      │
│  + scanner           │             └────────────────────────────────┘
│  + Caddy             │
│  + exchange          │
└──────────────────────┘
```

### Newark — Main Node

| Item | Value |
|------|-------|
| Host | `66.228.55.154` |
| P2P port | `6868` |
| REST API | `http://66.228.55.154:6869` (via Caddy: `https://testnet-node.decentralchain.io`) |
| Balance | ~26.7M DCC |
| Node image | `ghcr.io/decentral-america/node-scala:node-scala-testnet-latest` |
| SSH | `ssh -i deploy_key_testnet deploy@66.228.55.154` |
| Config | `/opt/dcc/config/node-testnet/dcc.conf` |
| Compose | `/opt/dcc/compose/node-scala.yml` |

### Frankfurt LKE — Gen / Validator Nodes

| Node | P2P Port | REST Port | Role | Balance |
|------|----------|-----------|------|---------|
| dcc-gen-0 | 6863 | 6869 | Generator (mining) | ~26.7M DCC |
| dcc-gen-1 | 6864 | **6870** | Generator (mining) | ~26.7M DCC |
| dcc-val-0 | 6865 | 6869 | Validator (relay) | 0 DCC |

**LKE cluster:** ID 615553, region eu-central (Frankfurt), k8s 1.35  
**Config:** `infra/clusters/testnet/apps/nodes.yaml` via Flux GitOps  
**Key config flags:** `enable-blacklisting = no`, `suspension-residence-time = 300s`, `hotstuff { enabled = true; round-timeout-ms = 1200 }`

---

## Token Distribution

| Address | Label | Balance |
|---------|-------|---------|
| `31RPEKcz71a3hdxt8z7qLhTpRMuRV2kUyr6` | Main node (Newark) | ~26.7M DCC |
| `31PmKNdHAU5sZbtg8TrzKh8WfE7E8xBc9WD` | gen-0 (Frankfurt) | ~26.7M DCC |
| `31dLhqhGoGVhtkf5msWFmgZn1ErrVR6b9qV` | gen-1 (Frankfurt) | ~26.7M DCC |
| `31XRiENNF6qbyHBQssRNP4GwTR4KTAokYGC` | Faucet (Newark) | 5M DCC |

---

## Public Endpoints

| Service | URL | Status |
|---------|-----|--------|
| Node REST API | `https://testnet-node.decentralchain.io` | Live |
| Block explorer | `https://testnet.decentralscan.com` | Live |
| Data service | `https://testnet-data-service.decentralchain.io` | Live |
| DEX Matcher | `https://testnet-matcher.decentralchain.io` | Live |

---

## Repos

| Repo | Purpose |
|------|---------|
| `Decentral-America/infra` | OpenTofu, Flux manifests, node configs, CI/CD workflows |
| `Decentral-America/node-scala` | L1 blockchain node |
| `Decentral-America/DecentralChain` | Frontend monorepo (scanner, exchange, wallet, BPS) |
| `Decentral-America/matcher` | DEX order matching engine |

---

## Services

### blockchain-postgres-sync (BPS)

- **Image:** `ghcr.io/decentral-america/blockchain-postgres-sync:fbece975a0074868d20dc476324a0fa0587f2e70`
- **Database:** `bps_testnet` on VPS postgres
- **Type-19 fix deployed:** `txs_19` table, dedup upsert fix, `Loader.scala` gRPC root-cause fix
- BPS crashes after node restart — restart with `docker start blockchain-postgres-sync-testnet`

### Matcher

- **Config:** `/opt/dcc/config/matcher-testnet/local.conf`
- CRITICAL: do NOT write `local.conf` to the data dir — that path is shadowed by the config mount

### Plugin JARs (`/opt/dcc/plugins/testnet/`)

| File | Purpose |
|------|---------|
| `ext.jar` (184KB) | Registers BlockchainUpdates + DEXExtension |
| `grpc.jar` (4.6MB) | DccBlockchainApiGrpc stubs + DEX gRPC + 14-field `Block$Header` |

Both JARs built from source at `Ecosystem/matcher` @ `0767d246`.

---

## T2 HotStuff Summary

> **2026-08-04 update (supersedes the 2026-08-02 caveat below — kept for history):** The pacemaker/
> single-active-view rework that `docs/hotstuff-step5-findings-and-rework.md` said was needed (the
> `view=block-height` shell model failing on an NG chain) is **complete and merged** to node-scala `main`
> (`9c49632398`). T2 is not just "enabled" on testnet anymore — by explicit human decision, ahead of the
> external consensus audit and scoped to testnet only, a new `dcc.hotstuff.authoritative` opt-in flag is
> **live on all 4 testnet nodes** (`infra/node-config/testnet/dcc.conf`,
> `infra/clusters/testnet/apps/nodes.yaml`). With it on, a genuine HotStuff commit now **raises the
> authoritative feature-25 `finalizedHeight`** (monotonic max()-merge — never injects a block outside a
> node's own canonical chain). This is verified working, not just deployed: `curl
> https://testnet-node.decentralchain.io/blocks/height/finalized` → `107697` against `blocks/height` →
> `107779` (2026-08-04), advancing continuously. Since the authoritative switch, node-scala `main` also
> picked up **T10**: a cross-committee-epoch fork hazard (two disjoint committed-generator committees each
> forming an honest 2/3-stake QC for a *different* block at the identical view/height) found and fixed
> 2026-08-03 (wire-format `committeeEpoch` binding, schema 1.6.5, + a transition-gating rule), plus a
> distinct liveness gap in that same fix's own wiring found and fixed 2026-08-04. Both are merged and live
> on testnet via image `sha-9c49632`. See `node-scala/docs/hotstuff-audit-readiness.md` (T10 entry) and
> `node-scala/docs/consensus-upgrade-plan.md` for full detail — narrowed, not fully closed (no live
> multi-node Docker evidence of an actual committee-epoch *transition* yet, only unit/DST simulation).
> **Mainnet is completely unaffected** — `dcc.hotstuff.authoritative` stays `false` there, still gated
> behind the external audit, a formal multi-day soak record for this reworked model (not yet documented
> despite the live deployment), and equivocation→slashing wiring. This was an explicit, fully-informed
> human decision scoped to testnet only, made ahead of Task 9 (external audit) of
> `docs/superpowers/plans/2026-08-02-launch-readiness.md`.
>
> <details><summary>2026-08-02 caveat (superseded, kept for history)</summary>
>
> T2 is enabled on testnet (`nodes.yaml` sets `hotstuff.enabled = true` on the LKE gen/val nodes) and
> running, but per `Application.scala:317` and `docs/hotstuff-audit-readiness.md` §1 it is **observational
> only** — `NodeHotStuffEffects.onCommit` records `hotStuffFinalizedHeight` on `/node/status` but does NOT
> mutate the authoritative finalized height; feature-25 DeterministicFinality (T0) remains the sole
> finality source. A HotStuff bug today cannot fork/halt/rollback the chain. Separately,
> `docs/hotstuff-step5-findings-and-rework.md` records that the first live multi-node run (step 5, after
> this "soak PASSED" note was written) found the `view=block-height` shell model fails on an NG chain and
> needs a rework before it can go to external audit or ever become authoritative.
> </details>

- **Status:** Authoritative on testnet (2026-08-03/04) — the pacemaker/single-active-view rework is
  complete and `dcc.hotstuff.authoritative = true` is live and confirmed advancing `finalizedHeight`.
  Soak PASSED note below is the historical 2026-06-30 result under the pre-rework observational engine.
- **round-timeout-ms:** 1200 (tuned from 5000ms — p99 ~1000ms + 20% margin)
- **Quorum:** 2/3 of ~80M total committed balance. Any 2-of-3 generators = quorum.
- **Generation period:** 100 blocks ≈ 50 min
- **Auto-commit:** dual cron — every 35 min + :17 hourly

Soak results (2026-06-30, pre-rework observational engine — no formal soak record yet exists for the
reworked/authoritative model; do not infer one):
- gen-0 down: T2 maintained lag=0 (main + gen-1 quorum)
- gen-1 down: T2 maintained lag=0 (main + gen-0 quorum)
- both down: FairPoS continued (+3 blocks), T2 paused (no quorum)
- both restored: T2 self-healed to lag=0 within 3 min

Check T2 health:
```bash
curl https://testnet-node.decentralchain.io/blocks/height/finalized
curl https://testnet-node.decentralchain.io/blocks/height
# finalized lag < 10 → healthy
# finalized lag > 50 for 10 min → ALERT: T2 stalled
```

---

## Monitoring

5 Prometheus alerts deployed via `monitoring/alerts.yml`:

| Alert | Condition | Severity |
|-------|-----------|----------|
| BlockProductionStalled | No block in 5 min | CRITICAL |
| T2FinalizationStalled | T2 lag >50 blocks for 10 min | HIGH |
| T2GeneratorsNotCommitted | NextGens <2 for 15 min | HIGH |
| NodePeersLow | <1 peer for 5 min | HIGH |
| T0FinalizationStalled | T0 lag >200 blocks for 30 min | MEDIUM |

Deploy via: `gh workflow run deploy-monitoring.yml --repo Decentral-America/infra`

---

## GitOps — How to Make Changes

Frankfurt LKE is managed via Flux. Never run `kubectl apply` directly — always push to `infra/main`.

```
git push to infra/main → Flux reconciles within 5 min
```

Newark is NOT GitOps — use `deploy-node-image.yml` for image updates and `deploy-node-config.yml` for config changes. Never use `restart-host-network.yml` (wipes chain data).

---

## Key Operations

```bash
# Deploy new node image (NO chain wipe)
gh workflow run update-node-image.yml --repo Decentral-America/infra

# Deploy updated dcc.conf (NO chain wipe)
gh workflow run deploy-node-config.yml --repo Decentral-America/infra

# Commit generators for next period
gh workflow run auto-commit-generators.yml --repo Decentral-America/infra

# Check chain height
curl https://testnet-node.decentralchain.io/blocks/height

# SSH into Newark
ssh -i /path/to/deploy_key_testnet deploy@66.228.55.154
docker logs node-scala-testnet --tail=50

# Check Frankfurt pods
export KUBECONFIG=kubeconfig.yaml
kubectl get pods -n dcc
```

---

## What NOT to Do

- `restart-host-network.yml` WIPES chain data — use `update-node-image.yml` instead
- `peer-watchdog.yml` SIGKILLs the node — emergency tool only, causes BPS crash + chain reset
- Do NOT use bridge mode for main node — causes TCP failure from LKE
- Do NOT write matcher `local.conf` to `/opt/dcc/data/matcher-testnet/config/` — silently ignored
- Do NOT use `gh run watch` — burns GitHub REST rate limit (1200/hr)
- Do NOT check credentials from memory — always read KEEWEB_BACKUP.md first

---

## Security Notes

**API keys in git history:** Node REST API keys were in git history (infra repo, commits Jun 25-27). **2026-08-02: new keys generated + staged, NOT yet rolled out.** Fresh keys for all 4 nodes (main/Newark, gen-0, gen-1, val-0) generated via CSPRNG (`openssl rand -base64 32`), hashed offline with the correct method (`secureHash = Keccak256(Blake2b256(key))`, Base58-encoded — verified byte-for-byte against the live node's hash algorithm), and staged on infra branch `security/rotate-api-keys` (unpushed): `secrets/testnet.env` (SOPS-encrypted raw keys), `clusters/testnet/apps/nodes.yaml` (gen-0/gen-1/val-0 `api-key-hash`), `node-config/testnet/dcc.conf` (main node `api-key-hash`). Raw keys are NOT yet in GitHub Actions secrets and the old keys are still live/accepted — rollout (push branch, Flux reconcile, update GH Actions secrets, run `verify-api-keys.yml`) is a deliberate human-triggered deploy step, not done as part of this staging pass. Because git history retains the old keys forever, rotation (not history-rewrite) remains the only real fix, and the old keys become permanently dead only once rollout completes.

**CVE-2026-44249 (CVSS 8.1):** Netty IPv6 Subnet Filter Bypass — patched. Upgraded to `netty41=4.1.135.Final` and `nettyCodec=4.2.15.Final`.

| Layer | What's in place |
|-------|----------------|
| Secrets at rest | SOPS AES256-GCM, age keys in KeeWeb, never in git |
| Secrets in cluster | Kubernetes Secrets (base64 in etcd — acceptable for testnet) |
| Image integrity | Images pinned by SHA digest |
| Network — Newark | Linode Cloud Firewall: only 6868/80/443/22 inbound |
| Network — LKE | Cloud Firewall: P2P 6863-6865 open, SSH restricted |
| CI/CD | GitHub Actions with environment protection gates |
| Supply chain | Trivy HIGH/CRITICAL scan gate on every image build |

---

## CI Health (2026-08-02)

Only `matcher` is a private/billed repo; node-scala, DecentralChain, infra, docs are public
(Actions is free there). matcher's spend was ~97% one thing: the 8-shard dex-it integration
running on every push to main. Fixed — it now runs nightly + on release tags only (~$105/mo
saved, same 148-suite coverage, shards unchanged). All 5 repos: zero open PRs, dev==main.

**node-scala node-it nightly** — was red every night since the schedule was added (07-25);
root-caused to two distinct races (a TwoNodes commit-vs-period-rollover race, and an unrelated
already-fixed FourNode/DegradedLink stall). Fixed and merged; first real-runner confirmation
run succeeded. Needs one more consecutive green night to fully close.

**matcher nightly chaos** — bisected against pre-merge main; confirmed pre-existing
nemesis-timing flakiness, not a regression. Given a retry-once policy (mirrors the existing
dex-it shard pattern) so a single flaky run doesn't red the whole nightly.

**Alerting** — all 5 repos now file/update a GitHub issue (label `ci`) when a scheduled
workflow fails, so a red nightly can't sit unnoticed for days again.

**Known, investigated, deliberately not "fixed"** (forcing these would be reckless, not
thorough — see `docs/superpowers/plans/2026-08-02-absolute-green.md` for full evidence):
- matcher's kanela NPE storm under full-suite unit-test load (thousands of log lines, 0 actual
  test failures) — root cause understood (sbt2 worker-JVM reuse causes non-deterministic
  partial Kamon/Pekko instrumentation retransformation), but kanela is deliberately attached to
  the test JVM and the existing `KanelaWorkerClasspathFix` workaround is already fragile,
  battle-tested reflection code. A real fix needs dedicated design work, not a blind patch.
- node-scala Check-PR's occasional timing-test flakes — reproduced under 4 escalating
  CPU-starvation techniques (up to 246 competing processes) and could NOT be reproduced; no fix
  was invented for a failure that didn't recur locally.
- SC-695 (RIDE InvokeScriptTransaction version-gating + an `extraFeePerStep` fee mechanism) — **UPDATE
  2026-08-04: this line is now stale, kept for history.** After the spec was written
  (`node-scala/docs/features/feature-30-sc695-spec.md`), SC-695 *was* subsequently implemented and merged
  to node-scala `main` behind a new `BlockchainFeature` id 30, **dormant until governance activation** —
  zero live effect on testnet or mainnet today, no different from any other unactivated feature. The
  previously-ignored `InvokeScriptTransactionRideV5Suite` tests are resolved as part of that work. Not a
  chain-safety concern — same dormant-until-activated pattern as feature 25/27/29.
- Org-wide dead-code sweep only covers node-scala (proven zero dead code by construction,
  `-Wunused:all` + `-Werror` already gates every merge) and matcher's known removals (a real
  dev-branch cleanup already landed). Matcher's own `-Wunused` retrofit and the DecentralChain
  Nx/TS monorepo sweep are real, separate initiatives — not attempted here.

---

## Remaining Blockers Before Mainnet

- [ ] Rotate REST API keys (all 4 nodes) — **STAGED, NOT ROLLED OUT.** Exposed in infra git history (commits Jun 25-27). New keys generated + hashed (`secureHash = Keccak256(Blake2b256(key))`, Base58-encoded) and staged on infra branch `security/rotate-api-keys` (unpushed, commit `1141c3a`) — `secrets/testnet.env`, `clusters/testnet/apps/nodes.yaml`, `node-config/testnet/dcc.conf` updated. Old keys are still live and accepted; rollout (push branch, update GH Actions secrets, Flux reconcile, run `verify-api-keys.yml` to confirm every node accepts the new key and rejects the old) is a deliberate human-triggered deploy step, intentionally not done automatically. Because git history retains the old keys forever, rotation (not history-rewrite) is the only real fix, and the old keys become permanently dead only once rollout completes. See Security Notes above
- [ ] T0 60-day stabilization — **STILL OPEN.** T0 DeterministicFinality must run stably ≥60 days before T0 mainnet activation; soak clock not yet started/completed
- [ ] T0 mainnet activation — **STILL OPEN.** 8-week advance notice to ~50 node operators. Node version to upgrade to should be re-confirmed at activation time (live testnet is now `v1.7.0`, not the `v1.6.3` this line originally cited) + vote feature 25
- [ ] T2 HotStuff mainnet external audit — **STILL OPEN, but the rework itself is DONE.** The shell rework (`docs/hotstuff-step5-findings-and-rework.md`'s "view=block-height fails on an NG chain" finding) is complete and merged to node-scala `main` (`9c49632398`); `HotStuffVotePool` is bounded; a cross-committee-epoch fork hazard (T10) found 2026-08-03 was fixed the same day, and a liveness gap in that fix's own wiring was found and fixed 2026-08-04. By explicit human decision, `dcc.hotstuff.authoritative = true` is now live on all 4 **testnet** nodes (confirmed via `/blocks/height/finalized` genuinely advancing) — this was a deliberate, informed testnet-only decision made ahead of the external audit, not an accidental gap. What remains **before mainnet**: (1) a formal multi-day soak record (crash/partition/equivocation) for the reworked/authoritative model — not yet documented despite the live testnet deployment; (2) equivocation → `conflictGenerators` slashing wiring; (3) an external consensus audit sign-off (not yet engaged — vendor/procurement action); (4) live multi-node Docker evidence of an actual T10 committee-epoch transition (unit/DST-simulation only so far). Do NOT enable `hotstuff.authoritative = true` on **mainnet** `dcc.conf` until all four close. Tracked as Phase 3 (Tasks 8-10) of `docs/superpowers/plans/2026-08-02-launch-readiness.md`; see `node-scala/docs/hotstuff-audit-readiness.md` §8 for the full enable-gate checklist. This is testnet-only today and does not affect mainnet chain safety.
- [ ] Stagenet validation run — **STILL OPEN.** Legacy → modern node handoff at 10k blocks, verify no chain splits
- [ ] Set proper git version tag on node-scala — **PARTIALLY DONE / correct the target.** node-scala has cut a real versioned release, `v1.7.0` (2026-07-25) — the "v1.0.0 or similar" framing is stale, a release process now exists. matcher, however, has never cut a versioned release (see Task 6 of the launch-readiness plan — cutting matcher's first tag is also what unblocks genuine cross-version backward-compat testing). Remaining open item: cut matcher's first tagged release.
- [ ] Mainnet LKE: `lke_ha = true` + dedicated CPU nodes + ≥2 node pool size — **STILL OPEN.** Currently `lke_ha=false`, shared CPU, single node (confirmed in `terraform/{lke.tf,testnet.tfvars,variables.tf}`, `terraform/lke.tf:11-12`). Pod anti-affinity (`preferredDuringSchedulingIgnoredDuringExecution`) is already present in `infra/clusters/testnet/apps/nodes.yaml` but only takes effect with ≥2 nodes.
- [x] `GHCR_TOKEN` PAT scope — **CONFIRMED GOOD (2026-08-02).** GitHub's API never exposes stored-secret scopes directly, so this was verified behaviorally instead: the org secret `GHCR_TOKEN` exists (`visibility: all`, confirmed via `gh api orgs/Decentral-America/actions/secrets`), and the latest scheduled `ghcr-cleanup.yml` run on `infra` (run 30733948843, 2026-08-02) actually deleted 20 real images from the `node-scala` package (`total images deleted = 20`, `multi architecture images deleted = 7`) with zero 403/permission errors in the logs — a real delete only succeeds with `delete:packages` scope, so the PAT is correctly scoped. Other matrix packages (scanner, matcher, blockchain-postgres-sync, data-service, caddy-ratelimit) reported `total images deleted = 0` in that run simply because they had nothing past the retention window, not because of a permission failure.

**Resolved since 2026-06-30 (verified 2026-08-02 — see "Reconciled 2026-08-02" section):**
- ~~Seccomp profile on val-0~~ — **DONE.** `RuntimeDefault` seccomp confirmed present on gen-0, gen-1, AND val-0 (`infra/clusters/testnet/apps/nodes.yaml:410,541,667`). The old "val-0 pending" framing was stale.

## Mainnet Prep (non-blocking)

- [ ] Add `SENTRY_AUTH_TOKEN` to SOPS `secrets/mainnet.env` once mainnet is provisioned — **STILL OPEN** (can't be done pre-provision)

**Resolved since 2026-06-30:**
- ~~Add alertmanager config to Prometheus — alert rules fire but there is no notification target~~ — **DONE.** `infra/monitoring/alertmanager.yml` exists with a `github-issues` webhook receiver and a critical-severity route. The "no notification target" framing was stale.
- ~~Add Grafana dashboard panels for: T2 lag, T0 lag, generator counts, peers~~ — **STATUS UNCLEAR, re-verify.** Not directly re-audited this pass; alertmanager routing and the underlying Prometheus alert rules (`monitoring/alerts.yml`) exist, but whether Grafana *dashboard panels* specifically were added was not confirmed. Left open until someone checks the Grafana dashboard JSON directly.

## Known Operational Items

- **BPS metrics scrape** — **DONE.** `infra/monitoring/prometheus.yml` scrapes both `:9101` (chain exporter) and `:9090` (BPS, added — see comment at prometheus.yml:19,28 crediting `blockchain-postgres-sync/src/bin/consumer.rs`). The old "not yet in prometheus.yml" framing was stale.
- **`commit-to-generation.yml`** — **CORRECTED (not merely "deprecated" — verified deleted).** Checked `infra/.github/workflows/` directly on 2026-08-02: no `commit-to-generation.yml` file exists in the repo at all. Only `auto-commit-generators.yml` and `commit-generators-hotstuff.yml` remain. The old wording ("is deprecated ... use auto-commit-generators.yml instead") implied a present-but-discouraged file; that's stronger than reality — it isn't there to accidentally run.
- **LKE gen-0/gen-1/val-0** all run on a single LKE node (testnet) — **STILL OPEN**, unchanged. Acceptable for testnet; mainnet requires separate nodes (see HA blocker above).
- **Monitoring gap** — **PARTIALLY STALE, corrected.** In-cluster monitoring for the LKE gen/val nodes DOES exist: `infra/clusters/testnet/monitoring/kube-prometheus-stack.yaml` (kube-prometheus-stack) and `infra/clusters/testnet/monitoring/metrics-exporter.yaml` (chain-specific exporter on `:9200`, confirmed at metrics-exporter.yaml:18,27,114) are both present and deployed via Flux. So the LKE nodes are *not* literally invisible to monitoring the way the old line claimed. The real remaining gap, confirmed by checking `infra/monitoring/prometheus.yml` for any `federate`/`remote_write` config (none found): there is no cross-site federation from the Newark Prometheus (the instance on-call actually watches in Grafana) to the LKE cluster's in-cluster stack/`:9200` exporter. That federation gap is the still-open item — tracked as Task 13 (Phase 5) of the launch-readiness plan. See `INCIDENT-GEN0-PEERS.md` for the incident that originally surfaced this.

---

## Reconciled 2026-08-02

This HANDOFF was reconciled against the "Evidence Base" table in
`docs/superpowers/plans/2026-08-02-launch-readiness.md` (Task 1, Phase 1). Every item in "Remaining
Blockers Before Mainnet", "Mainnet Prep (non-blocking)", and "Known Operational Items" above was
individually re-checked against a live file/endpoint (not transcribed from the plan blindly) and marked
DONE, STILL-OPEN, PARTIALLY STALE, or CORRECTED with the verifying citation inline. Concretely re-verified
during this pass (not just trusted from the plan):

- `infra/clusters/testnet/apps/nodes.yaml` — seccomp `RuntimeDefault` at all 3 node blocks, confirmed at
  exactly lines 410, 541, 667 — matches the plan's citation precisely.
- `infra/monitoring/alertmanager.yml` — `github-issues` receiver + critical-severity route, present.
- `infra/monitoring/prometheus.yml` — both `dcc-chain` (`:9101`) and `bps` (`:9090`) scrape jobs present.
- `infra/.github/workflows/` directory listing — `verify-api-keys.yml` exists; `commit-to-generation.yml`
  does not exist (only `auto-commit-generators.yml` + `commit-generators-hotstuff.yml`).
- `infra/clusters/testnet/monitoring/{kube-prometheus-stack.yaml,metrics-exporter.yaml}` — both exist;
  exporter confirmed listening on `:9200`. No federation config found in `infra/monitoring/prometheus.yml`
  (no `federate` job, no `remote_write` block) — cross-site federation into Newark Grafana genuinely does
  not exist yet.
- `infra/.github/workflows/ghcr-cleanup.yml` — the `delete:packages` PAT requirement is now CONFIRMED
  correctly scoped: the 2026-08-02 scheduled run (30733948843) actually deleted 20 images from
  `node-scala` with no permission errors (see "Remaining Blockers" GHCR_TOKEN entry above for full
  evidence). Trivy HIGH/CRITICAL gate also re-verified this pass: `severity: HIGH,CRITICAL` +
  `exit-code: '1'` present on matcher/ci.yml, DecentralChain/security.yml, and infra/deploy-container.yml
  (real build-failing gates on release images); node-scala/ci.yml runs Trivy as an `fs` scan uploaded to
  the Security tab (SARIF) with no `exit-code`, so it's advisory there, not a hard gate — worth tightening
  but not a supply-chain hole today since node-scala's image build path isn't the one missing coverage.
  `.trivyignore` exists on DecentralChain and infra, but every entry is a dated, justified risk-acceptance
  (specific CVE/GHSA IDs with rationale + upstream-fix tracking links), not a blanket suppression — no
  hidden HIGH/CRITICAL findings. Renovate (not Dependabot) confirmed as the sole active mechanism on all
  4 code repos (`renovate.json` present, no `dependabot.yml` anywhere) — PR backlog is 0 open across
  node-scala/matcher/DecentralChain/infra/Ecosystem. node-scala and matcher show 0 renovate PRs merged
  historically (unlike DecentralChain/infra, which have merged security-update PRs), but this matches the
  already-known baseBranchPatterns fix landed 2026-07-24 (see `project_renovate_basebranch_orgwide`):
  both repos' Dependency Dashboards (issue #3 and #15 respectively) are live and updating as of
  2026-08-02, with real detected updates queued under "Awaiting Schedule"/"Rate-Limited" sections —
  Renovate is active, just schedule-gated (Monday 4am) with nothing merged yet since the fix, not stuck.
- Live chain state: `curl https://testnet-node.decentralchain.io/blocks/height` → `102268`;
  `curl https://testnet-node.decentralchain.io/node/version` → `DecentralChain v1.7.0`.

**Discrepancy found between the plan's Evidence Base and current reality:** the plan's Evidence Base
table states T2 HotStuff is "`enabled=false` by default and OBSERVATIONAL." That's true of the code
default, but on live testnet `infra/clusters/testnet/apps/nodes.yaml` explicitly sets `hotstuff.enabled =
true` for the LKE gen/val nodes — so T2 is actually running on testnet today, just still observational
(does not mutate authoritative finality; see the T2 HotStuff Summary caveat added above). This is a
nuance, not a contradiction, but it's worth stating explicitly rather than silently collapsing "disabled
by default in code" into "disabled on testnet," which would be wrong.

Not marked done (kept STILL-OPEN per the task instructions, even though some are discussed favorably in
the plan): API-key rotation, T0 60-day soak, T2 rework + external audit, LKE HA flip (`lke_ha=false`
confirmed current), stagenet validation run, cross-site monitoring federation, SC-695 and other real test
debt (tracked separately in Phase 2 of the plan, not part of this HANDOFF's blocker list), and the
mainnet operator notice. GHCR PAT scope is now CONFIRMED GOOD (2026-08-02, see "Remaining Blockers"
above) and marked done — it's the one item in this list resolved this pass.

The "CI Health (2026-08-02)" section above was added in an earlier step this session and is left as-is
(not duplicated here).

---

## Reconciled 2026-08-04

Supersedes the 2026-08-02 reconciliation above where the two conflict; that section is left intact for
history. A large amount of real HotStuff work landed across node-scala, infra, and this repo between
2026-08-02 and 2026-08-04 that the earlier pass could not have known about. Re-verified directly (not
transcribed from any prior doc):

- **T2 HotStuff is no longer merely "enabled=observational" on testnet — it is AUTHORITATIVE.** The
  2026-08-02 "Discrepancy found" note above (T2 "actually running... just still observational") is now
  itself stale. By explicit human decision, ahead of the external audit and scoped to testnet only, node-scala
  main (`9c49632398`) shipped the pacemaker/single-active-view rework plus a `dcc.hotstuff.authoritative`
  opt-in flag, deployed live to all 4 testnet nodes (infra PR #131, 2026-08-03). Verified directly today:
  `curl https://testnet-node.decentralchain.io/blocks/height` → `107779`; `curl
  https://testnet-node.decentralchain.io/blocks/height/finalized` → `107697` — genuinely advancing via the
  HotStuff commit path, not just a config flag flipped with no observable effect.
- **T10 cross-committee-epoch-fork fix, found and closed 2026-08-03/04.** Adversarial review of the
  authoritative-finality work found a real hazard: two disjoint committed-generator committees (e.g.
  across a full validator-set rotation) could each independently form an honest 2/3-stake QC for a
  *different* block at the identical view/height. Fixed via a `committeeEpoch` field bound into the
  signed vote/QC bytes (`protobuf-schemas` 1.6.5, verified published to Maven Central 2026-08-04 — `curl
  -o /dev/null -w '%{http_code}' https://repo1.maven.org/maven2/io/decentralchain/protobuf-schemas/1.6.5/`
  → `200`) plus a transition-gating rule. A follow-up adversarial review the next day found the fix's OWN
  wiring introduced a distinct liveness gap (committee epoch derived from the signer's live tip instead of
  the vote's target height, causing honest replicas to disagree on epoch across a rotation boundary and
  permanently stall); fixed the same day. Both merged to node-scala `main` @ `9c49632398` (PR #47). See
  `node-scala/docs/hotstuff-audit-readiness.md` T10 entry for full detail. **Narrowed, not fully closed:**
  no live multi-node Docker evidence of an actual committee-epoch transition exists yet, only unit/DST
  simulation — real remaining work, not chain-safety-blocking on testnet today.
- **SC-695 was implemented** (node-scala PR #46, feature id 30, dormant until governance activation) —
  this HANDOFF's "Known, investigated, deliberately not fixed" section above still said "explicitly NOT
  scaffolded"; corrected inline above. Zero live effect either network — same dormant-feature pattern as
  25/27/29, not confused with anything currently active.
- **Live testnet image bumped to `sha-9c49632`** (digest
  `sha256:8a1c9d17e03a305ca763b0c53c1e2c080e891c64d8cd6946abd75507c8c1f69d`) on both Newark and the LKE
  gen-0/gen-1/val-0 nodes (infra PR #135, merged 2026-08-04) — includes the T10 fix and SC-695. Confirmed
  by reading `infra/clusters/testnet/apps/nodes.yaml:458,586,703` directly (all three LKE pods pin this
  exact digest) and `curl https://testnet-node.decentralchain.io/node/version` → `{"version":"DecentralChain
  v1.7.0"}` (version string unchanged from 2026-08-02 — only the underlying image digest moved; `v1.7.0`
  is the git tag, not a 1:1 proxy for "which commit is deployed", so the digest is the real source of
  truth here).
- **infra `dev` == `main`, re-verified 2026-08-04**, both at `5ac53efc435c3ddd582b30e0b5c314a89408ef9a`
  (fast-forwarded during this pass — `dev` had drifted one merge-commit behind after PR #135). node-scala
  `dev` == `main` at `9c49632398dcb860ff42ee5fb010f702ef37c133`, no drift found. Zero open PRs on
  node-scala/infra/matcher/DecentralChain (docs repo has one open Renovate security PR, unrelated to this
  reconciliation).
- Everything in "Not marked done" above from the 2026-08-02 pass remains accurately STILL-OPEN today
  *for mainnet*: API-key rotation, T0 60-day soak, T2 **mainnet** audit + soak record + slashing wiring
  (testnet-only authoritative deployment does not close this), LKE HA flip, stagenet validation run,
  cross-site monitoring federation, mainnet operator notice. SC-695 is no longer "not scaffolded" (see
  above) but remains dormant/non-blocking either way.

*For full operational procedures, credential locations, and bug history, see `node-scala/docs/testnet-bootstrap-runbook.md`. For the resolved gen-0 P2P/chain-fork post-mortem, see `INCIDENT-GEN0-PEERS.md`.*

---

## Reconciled 2026-08-13

Re-verified live, not transcribed from any prior doc. Supersedes the 2026-08-04 reconciliation above where they conflict.

- **New gen-0/gen-1 connectivity bug found and fixed — same family as `INCIDENT-GEN0-PEERS.md`'s 2026-08-12 recurrence note, now root-caused.** `NetworkServer.scala`'s `handleOutgoingChannelClosed` was suspending the remote peer on *any* outgoing channel close, including a completely benign, graceful one (`closeFuture.isSuccess`) — not just genuine failures. Since gen-0/gen-1's only known-peer is main, this created a self-sustaining ~30s connect → handshake-ok → suspend → retry loop (exactly `suspension-residence-time`) that never let them hold a connection long enough to catch up. Fixed in node-scala PR #58 (only suspend on the genuine-failure branch now), built, and deployed to gen-0/gen-1/val-0 *and* main (fleet consistency — main's own compose-based VPS was still on an older build).
- **gen-0/gen-1 had fallen 700-1100 blocks behind the canonical chain** as a direct result of the above (confirmed via `cluster-diagnostics.yml`) — this is what the admin-dashboard's "Active Generators: 1" was actually measuring (it counts distinct generators over the last `min(500, height)` blocks; gen-0/gen-1 genuinely weren't forging). Recovered via `migrate-state-snapshot.yml` (briefly stops main for a consistent RocksDB snapshot, loads it into each gen's PVC) — all three nodes converged to the same height within minutes. Since then all three are forging in a healthy, roughly even split (confirmed: 36/36/28 over a 100-block sample). **This is the same connectivity bug class the RC#2/quorum=1 fixes were guarding against — the graceful-close-suspend path was simply never covered by those earlier fixes.**
- **T2 HotStuff's `hotStuffFinalizedHeight` was stalled** as a direct consequence (needs a QC from main+gen-0+gen-1; with two of three unable to hold a connection, no quorum). The exact E2E test that was failing (`finality.spec.ts` → "if present, hotStuffFinalizedHeight is advancing too") now passes cleanly post-fix — confirmed via a fresh dispatch of `admin-e2e.yml` (31 test files passed, 0 failing).
- **admin-dashboard Maven Central panel fixed** — two independent bugs, not related to the above: (1) the UI hardcoded the wrong groupId (`io.github.decentral-america`; the real, verified namespace is `io.decentralchain`, confirmed live against `repo1.maven.org` — all 14 packages present), and (2) the backend queried `search.maven.org`'s legacy Solr index, which has zero entries for this namespace despite the packages being live (a known gap between Sonatype Central Portal publishing and that legacy mirror) — switched to `central.sonatype.com`'s own solrsearch mirror, which has the real data.
- **Dependabot alert sweep** — clarified that "Dependabot" on this org means alert-scanning only; `dependabot_security_updates` (auto-PR) is disabled everywhere, so alerts sit until manually fixed. Fixed 5 in DecentralChain (nx Zip-Slip, 4× undici CVEs) and 2 in matcher (`httpcore5`, `jsoup` — both genuinely unpatched in the resolved dependency tree, unlike the other 16 matcher alerts which turned out to already be fixed as of a 12-day-old commit; Dependabot just hadn't rescanned). `extract-zip` (DecentralChain) has no upstream fix yet — dev-only e2e tooling, left as a documented exception.
- **New dedicated treasury wallet created and wired up.** The old genesis-era "treasury" wallet was drained and its stored KeeWeb value was never a real seed (literally the text `dcc-testnet-treasury`). Generated a fresh wallet (`31cs1eQss3CWFuYrDHpgct3FwMAFkWzSe3T`), funded it with 50,000 DCC from the faucet, added `TREASURY_SEED` to `infra/secrets/testnet.env` (SOPS), and wired the admin-dashboard's Load Test auto-fund/auto-sweep to fall back to it server-side when the UI field is left blank. See `KEEWEB_BACKUP.md` entry #27.
- **KeeWeb vault spot-checked against live infra** — all wallet seeds, REST API keys, matcher credentials, the AGE key, admin-dashboard OAuth/PAT, and the deploy SSH key (login user is `deploy`, not `root` — corrected in `KEEWEB_BACKUP.md`) verified current. Grafana admin password confirmed via a live authenticated API call.
