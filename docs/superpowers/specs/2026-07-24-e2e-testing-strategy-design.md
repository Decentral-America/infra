# Enterprise E2E Testing Strategy — DecentralChain Ecosystem

Date: 2026-07-24
Scope: DecentralChain, node-scala, matcher, infra (dcc-report excluded)
Status: Approved design, pending implementation plan

## 1. Problem

Three of four repos already carry real E2E test suites, but coverage is fragmented and one major suite is dead weight:

- **DecentralChain** `packages/e2e-blockchain` (Vitest) covers 19 of 20 node transaction types (`TransactionType.scala`, Ethereum EIP-155 already included among the 20) against local docker or live testnet. Missing: `CommitToGeneration` (HotStuff).
- **node-scala** `node-it` (sbt/Scala, Docker, 187 files) covers consensus/finality/RIDE/tx types extensively, including a 4-node HotStuff cluster suite. Runs only on manual `workflow_dispatch` — never gates a merge.
- **matcher** `dex-it` + `dex-integration-it` (sbt/Scala, Docker, 125+ files) cover the full DEX/settlement surface. CI only runs `quickCheck` (unit tests); `fullCheck` (the actual E2E) is dispatched manually only — **the real E2E suite is not a CI gate at all**.
- **infra** orchestrates test runs (`admin-e2e.yml`) but only drives DecentralChain's Vitest suite — it never exercises matcher.
- No suite anywhere tests the full pipeline: transfer to node, order to matcher, exchange settles, verify balances on-chain, live end to end.
- Known unresolved bugs in project history (Finality Stall Recurrence, Committed-Generators StateHash Finding, Matcher Unfunded Account's 4 stacked bugs, empty-committee stall) are exactly the failure classes that deterministic simulation, chaos/nemesis, and property fuzzing are built to catch — none of those techniques exist in this stack today.

## 2. Research grounding

Deep-research pass (22 primary sources, 25 claims adversarially verified 3-vote, 23 confirmed / 2 refuted) found strong, multi-source backing for three techniques and left three as general-practice (flagged accordingly below):

- **High confidence** (TigerBeetle ARCHITECTURE.md + Vörtex blog, Antithesis docs, arXiv 2108.08441 chaos-engineering-for-consensus paper, Jepsen CockroachDB analysis, CockroachDB joint-consensus blog, Cosmos SDK simulation docs, Trail of Bits Echidna/Medusa posts): Deterministic Simulation Testing, chaos/nemesis testing of consensus and cross-service transaction boundaries, property-based Operation fuzzing.
- **Lower confidence, general industry practice, no primary source cleared verification** (excluded vendor-content areas): contract/schema conformance testing, live synthetic/canary monitoring, CI cadence conventions for Docker-Compose integration suites. Recommendations here are architecturally sound but not citation-backed — flagged per tier below.

Full findings: see workflow run `wf_010a17fe-4c5` (deep-research), journal retained in session transcript dir.

## 3. Architecture — 7-tier pyramid

| Tier | Technique | Repo(s) | New or extend | Cadence |
|---|---|---|---|---|
| 0 | Unit tests | all | existing | every push |
| 1 | Deterministic Simulation Testing (DST) | node-scala | **done** | every push |
| 2 | Docker-based integration/E2E | node-scala `node-it`, matcher `dex-it`/`dex-integration-it`, DecentralChain `e2e-blockchain` | extend + wire into CI | PR to main |
| 3 | Chaos/nemesis on real containers | node-scala + matcher (shared harness) | **new**, extends node-it/dex-it | nightly + manual |
| 4 | Property/Operation fuzzing | node-scala tx pipeline, matcher fixed-point math | **new** | nightly |
| 5 | Contract/schema conformance | matcher + node API vs TS SDK | **new** | every push touching API |
| 6 | Live synthetic/canary monitoring | testnet, driven from infra | **new** | scheduled (hourly) |
| 7 | CI orchestration / flake management | all repos | reorganize existing workflows | — |

### Tier 1 — DST for node-scala finality [high confidence]

Pattern (TigerBeetle/FoundationDB): abstract IO, clock, and RNG behind one interface inside the finality/consensus module. Run full HotStuff round logic in-process against a simulated network + clock + storage, seeded by a single `Long`. A failing seed replays byte-for-byte, deterministically, converting "flaky once per 10k CI runs" into "always reproducible with seed X."

- Directly targets the failure class behind the **Finality Stall Recurrence** and **Committed-Generators StateHash Finding** memory entries — both are ordering/timing bugs, DST's exact target.
- Any existing or future TLA+ spec of the finality protocol remains a design-debug tool only (verifies the model, not the Scala implementation) — DST is what verifies the binary.
- **Concrete implementation task**: audit whether committee-membership change (generator add/remove) is atomic/joint-consensus-style or sequential. CockroachDB's etcd/raft work showed sequential reconfiguration creates a transient unsafe-majority window — this matches the shape of the prior **empty-committee stall** bug and should be checked at the code level before or during DST harness construction.
- Scope of first harness: happy-path round, crashed-generator recovery, network-partition reconvergence, committee-membership change — mirrors what `FourNodeHotStuffTestSuite` already covers in `node-it`, but at in-process simulation speed (milliseconds, not Docker-boot seconds) so it can run on every push and explore many more seeds per CI minute.

### Tier 2 — Integration/E2E: wire existing suites into CI, close the cross-repo gap

- **Wire matcher's `fullCheck` into CI.** Today `ci.yml`'s integration job runs `quickCheck` only (unit tests); `dex-it`/`dex-integration-it` — real E2E suites — never gate a merge. Code audit found the actual blocker: `dex-ext/build.sbt`'s base image reference (`decentralchain/dccnode:${version}`) points at a name nothing in the workspace ever publishes — node-scala's real release image is `ghcr.io/decentral-america/node-scala`. Fix the image reference, then move `fullCheck` into CI.
- **New cross-repo settlement E2E coverage**: largely already exists — `DecentralChain/packages/e2e-blockchain/src/transactions/exchange.spec.ts` already funds two accounts, places crossing orders directly against the matcher REST API, and verifies on-chain settlement via balance polling. The actual gap: `admin-e2e.yml`'s `smoke` suite doesn't include it (matcher coverage today only runs under `full` or explicit `custom` dispatch) — add it to the smoke list rather than writing a new spec from scratch.
- **`CommitToGeneration` (Type 19) correction**: this transaction type is NOT untested — `e2e-blockchain/src/transactions/advanced-types.spec.ts` already scans blocks for CTG transactions and verifies a malformed submission is rejected. The real, narrower gap: that test hand-rolls a raw JSON body via `fetch`, and never once calls the SDK's own `commitToGeneration()` builder function (`packages/sdk/transactions/src/transactions/commit-to-generation.ts`) — that function has zero test coverage of its own (proof/BLS-signing/id-computation logic untested).

### Tier 3 — Chaos/nemesis on real containers [high confidence]

DST is in-process and never touches the real JVM GC, real Docker network, or real TS SDK client bindings. TigerBeetle's answer (Vörtex) is a separate real-binary layer: run unmodified release containers, inject partition/latency/corruption via a TCP-proxy fault injector (toxiproxy or equivalent), kill/restart processes mid-round. Build as an extension of the existing `node-it`/`dex-it` Docker-Compose harness — do not rebuild the harness, add fault injection to it.

- Reuse the arXiv 2108.08441 methodology: continuous throughput/latency/success-rate telemetry during fault injection, scraped via the existing Grafana/Loki stack (already deployed per infra), not just pass/fail.
- **Priority target: matcher↔node settlement boundary.** The **Matcher Unfunded Account** memory entry (4 stacked bugs masking DEX settlement) is exactly the failure class Jepsen-style nemesis testing catches. Inject clock skew, network partition, matcher/node process pause or kill during concurrent order-settlement sequences. Check invariants — no double-spend, no lost settlement, monotonic balance reconciliation — not just service up/down.

### Tier 4 — Property/Operation fuzzing [high confidence]

- **node-scala**: Cosmos SDK simulation pattern. Build an "Operation" generator producing randomized-but-valid transactions (transfer, order, lease, alias, data, sponsorship, etc.), weighted by realistic frequency, seeded PRNG, run through the real transaction-processing pipeline. Four verification modes: (a) invariant checks after each block — supply conservation, no negative balances, order-book consistency; (b) state export/import round-trip; (c) upgrade/hard-fork replay (pre-fork state through post-fork logic); (d) **cross-node determinism — same operation sequence through 2+ independent node instances must produce identical state hash.** Mode (d) directly targets the open **Committed-Generators StateHash Finding** — this is very likely where that bug's root cause will surface.
- **matcher**: Trail of Bits Echidna/Medusa-style reusable invariant patterns (commutativity, associativity, rounding-direction, no-value-created-from-nothing) applied to matcher's price/fee/rounding fixed-point arithmetic — the exact class of bug that hides in DEX settlement math.

### Tier 5 — Contract/schema conformance [general practice, not source-verified]

Generate matcher's OpenAPI/gRPC schema, node's gRPC/REST schema, and the TS SDK's client types from one source of truth where not already the case. Diff schemas in CI on any PR touching the API layer; fail the build on a breaking change without an explicit version bump. Flagged lower-confidence: the deep-research pass found no primary source clearing verification for this area (only vendor blog content, explicitly excluded) — treat as sound but not citation-backed, revisit with a targeted follow-up research pass if higher assurance is wanted before investing heavily.

### Tier 6 — Live synthetic/canary monitoring [general practice, not source-verified]

Dedicated canary wallet, separate from existing faucet/load-test wallets. Scheduled workflow (hourly) submits one of each major transaction type plus one full DEX round-trip against live testnet, low-value, alerting via existing Grafana on failure or latency drift. Same confidence caveat as Tier 5.

### Tier 7 — CI cadence and orchestration

- **Push**: unit tests (Tier 0) + DST (Tier 1) — both fast, both run everywhere.
- **PR to main**: `node-it`, `dex-it`/`dex-integration-it` (`fullCheck`), cross-repo settlement E2E on local docker-compose (Tier 2) — container-boot cost acceptable per-PR, not per-push.
- **Nightly/scheduled**: DST multi-seed sweep (many more seeds than fit in a PR budget), chaos/nemesis (Tier 3), Operation fuzzing (Tier 4), live-testnet smoke E2E.
- **Manual dispatch**: full chaos suite on demand, full live-testnet suite on demand.
- Flake management: track flake rate per suite (no specific tool prescribed here — general practice, not source-verified); a suite crossing a flake-rate threshold gets quarantined from the merge-gate cadence and moved to nightly-only until fixed, rather than blocking merges on known-flaky tests.

## 4. Success criteria

- 100% of node-scala's 20 transaction types (`TransactionType.scala`, Ethereum EIP-155 included) covered at the SDK/E2E layer.
- Every consensus-bug class has a dedicated technique: ordering/timing (DST), network/crash (chaos), cross-service settlement (nemesis), state-divergence (cross-node determinism fuzz).
- matcher's existing `dex-it`/`dex-integration-it` suites are a CI gate, not manual-only.
- Cross-repo settlement pipeline (transfer, order, exchange, on-chain verification) has one dedicated E2E spec, runnable both locally and against live testnet.
- API contract drift between matcher/node and the TS SDK fails CI before merge.

## 5. Open questions carried into implementation

1. ~~Is node-scala's committee-membership change atomic (joint-consensus-style) or sequential?~~ **Answered by Tier 1's code audit: sequential, not atomic.** `HotStuffCoordinator.Enabled.refreshCommittee()` re-reads the committee independently on every single event callback (onProposal/onVote/onQC/onLeaderTurn) with no requirement that all three phases of one view agree on one snapshot — structurally the same class of bug CockroachDB found and fixed via joint consensus in etcd/raft. Tier 1's Task 7 built an exploratory DST scenario specifically to probe this (committee stake change injected between PREPARE and PRE_COMMIT, timing empirically calibrated so ~45% of a 200-seed sweep genuinely lands after a PREPARE QC has already formed under the old committee). **Result: clean at 200 seeds — no `SafetyInvariants` violation found.** Per the harness's own honest framing, this does NOT prove the gap is safe, only that it wasn't hit at this sample size/fault intensity. Recommended follow-up: a larger nightly-tier sweep (Tier 3/7) with more seeds and richer fault injection before concluding this is a non-issue; if HotStuff is heading toward mainnet enablement, adding an actual atomic/joint-consensus-style committee transition to `HotStuffCoordinator` should be considered regardless of whether DST ever catches a live counterexample, since the structural gap is confirmed real even though no failure was observed yet.
2. Why was matcher's `fullCheck` never wired into CI — was the "no release artifacts/live node in CI" blocker in the existing `ci.yml` comment ever revisited? Needs a decision before Tier 2 CI wiring.
3. Contract testing and canary-monitoring conventions at comparable production blockchain/DEX systems were not found by the research pass — a targeted follow-up research pass is worth running before finalizing Tier 5/6 tooling choices, if higher assurance is wanted.

## 6. Out of scope

- dcc-report repo (explicitly excluded by request).
- Formal verification (TLA+ or similar) of the finality protocol itself — referenced only as a complementary, non-substitute technique for Tier 1.
