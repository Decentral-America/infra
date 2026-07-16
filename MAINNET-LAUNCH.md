# DCC Mainnet-Launch Runbook (ordered execution)

> The sequenced execution plan for the remaining mainnet-readiness items, in **optimal order**
> (risk-ascending, dependency-aware). Companion to `MAINNET-READINESS.md` (the *what/why* + status)
> and `LEASING-CUSTODY-DESIGN.md` / `clusters/testnet/RUNBOOK.md` (the *how* for individual pieces).
> This doc is the *order of operations* for a real mainnet bring-up.
>
> **Why these aren't executed on the live testnet now:** a leasing migration is pointless without a
> **cold** treasury seed held off the node (a node-wallet treasury gives no blast-radius benefit);
> re-enabling P2P blacklisting risks re-triggering the RC#2 peer loop and must follow a root-cause fix;
> sentry topology + governance activation are genesis-time by nature. All are gated on cold keys,
> a careful test window, or the genesis itself — so they belong to the launch sequence below.

## Optimal order (and the rationale)
1. **Design & prerequisites** (zero risk) — finalize params, genesis, cold-key custody. Do first; nothing downstream is safe without it.
2. **Genesis + chain params + governance activation config** — the chain can't exist before this; everything else runs *on* it.
3. **Validator onboarding + cold-treasury leasing** — needs a live chain + finality healthy; must precede exposing the network widely.
4. **Sentry topology** — wrap the (now-funded) generators before the network is public-facing.
5. **P2P hardening (blacklisting + known-peers)** — last of the network changes; riskiest live-behavior change, and only safe once RC#2 is resolved and a curated peer set exists.
6. **Monitoring / IR / soak carry-over** — validate the whole thing end-to-end before opening it up.

> Rationale: put the **irreversible/foundational** work first (genesis), the **finality-dependent** work while finality is healthy (leasing), and the **live-peering-risk** work last (blacklisting) so a peering hiccup can't jeopardize the migration or genesis.

---

## Phase 1 — Genesis, chain params, governance activation
- **Genesis block:** define timestamp, initial base-target, block-delay, and the **initial token distribution** (treasury/foundation/validators/community) — publish it. Genesis addresses use the mainnet address-scheme byte (`?` per node-scala `BlockchainSettings`), distinct from testnet `!`.
- **Chain params:** decide + document `min-block-time`, `generation-period-length`, and the activation cadence (`feature-check-blocks-period` / `blocks-for-feature-activation`). Testnet uses `3000 / 2700` (90%); Waves mainnet default is `10000 / 9000` (80%) with a further +10k-block activation delay. **Pick deliberately** — longer periods give a small validator set more time to upgrade.
- **Governance activation (CFG-1):** pre-activate only a **small stable core** at genesis; gate all post-launch protocol changes — **including the BLS finality feature #25** — through on-chain **height/voting** activation. This is the biggest divergence from today's testnet (which pre-activates `{1–25,28}` from height 0) and is what makes governance real. `auto-shutdown-on-unsupported-feature` should stay on.
- **Rehearse on a fresh testnet/localnet** before the real genesis: bring up with only the core pre-activated, then vote #25 in at a height, confirm the activation delay + upgrade window behave.

## Phase 2 — Validator onboarding + cold-treasury leasing
- **Per generator:** generate a **cold/offline treasury seed** (never loaded on a node; custody in KeePassium / air-gapped), fund it from the genesis distribution, then **lease** the stake to the generator's hot account, keeping ~5,000 DCC hot. Full mechanics + the depth ordering hazard are in `LEASING-CUSTODY-DESIGN.md` (rehearsal ✅ validated on testnet 2026-07-16).
- **Sequence:** one generator at a time; wait `generatingBalanceDepth` before the next so ≥2/3 committed stake (finality) holds throughout. Sign treasury txs **offline**; broadcast the signed tx from any node.
- **Onboarding:** each generator broadcasts `CommitToGeneration` (tx 19, 100-DCC deposit) per generation period; wire `auto-commit-generators.yml` equivalent for mainnet + finality-headroom monitoring.
- **Decentralization:** onboard independent validators (not all operator-run) before/at launch so no single party holds >1/3 (finality-halt) or >1/2 (liveness) of generating stake.

## Phase 3 — Sentry-node topology
- Run each **generator with no public IP** (or a non-gossiped `declared-address`), reachable only by a small fleet of public **sentry/relay** nodes that mark the generator as a **private peer** (don't gossip its address). Primary purpose: DDoS/eclipse protection for the block producers.
- Maps onto node-scala's `known-peers` / `declared-address` settings: sentries list each other + public seeds; generators list only their sentries; sentries list generators as private.
- Add sentry uptime to the `dcc_service_up` monitoring set.

## Phase 4 — P2P hardening (blacklisting + known-peers)
- **Resolve RC#2 first.** `enable-blacklisting=no` + `known-peers=[]` today weaken eclipse resistance; they were set to stop the RC#2 gen-0/gen-1 60s suspension loop (see `[[project_dcc_rc2_fix]]`). Re-enabling blacklisting **without** fixing the root cause re-triggers the loop.
  - Root-cause options to investigate: peer-exchange gossip re-adding self/declared-address (dedup), suspension-vs-blacklist timing, or a curated `known-peers` set removing the churn source.
- **Then:** set `enable-blacklisting=yes` and a **curated `known-peers`** list spanning multiple regions/ASNs (seeds + sentries), and keep the defaults (`max-single-host-connections=3`, in/out caps 100).
- **Validate on testnet** in a watched window: flip it, monitor `dcc_peers_connected` + finality lag; **revert immediately** if the RC#2 loop returns.

## Phase 5 — End-to-end validation before opening up
- Run the fault **soak** (RUNBOOK Scenario E) on the mainnet-config chain: generator down / partition / restore, confirming finality degrades gracefully and recovers.
- Confirm all `ServiceDown` / finality / block-production alerts fire correctly; dashboards populated.
- Walk the **incident-response runbooks** (RUNBOOK §Incident Response) as tabletop: chain halt, finality stall, key compromise, fork.
- External consensus/security audit sign-off (esp. if HotStuff is ever made authoritative — today it's observational).

## Launch gate checklist
- [ ] Genesis + distribution published; mainnet chain-id (`?`) + params locked.
- [ ] Only a stable core pre-activated; #25 + others gated through governance voting.
- [ ] Cold treasuries funded; stake **leased** to generators; ~5k DCC hot each; finality healthy.
- [ ] ≥ enough independent validators that no party holds >1/3 generating stake.
- [ ] Sentry topology live; generators not publicly reachable.
- [ ] RC#2 resolved; blacklisting on; curated known-peers.
- [ ] Soak passed on mainnet config; alerts + dashboards + IR runbooks validated.
- [ ] Secrets: all cold/hot keys in KeePassium + SOPS as appropriate; age keys for all networks custodied.
- [ ] External audit sign-off.

---
_Status of the pieces (2026-07-16): security/monitoring hardening + IR runbooks + leasing design & rehearsal
are DONE on testnet. The items above are the launch-time execution, gated on cold keys, the RC#2 fix, and the
mainnet genesis. See `MAINNET-READINESS.md` for the full findings + citations._
