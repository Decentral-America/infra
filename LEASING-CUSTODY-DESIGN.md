# Generator Stake Custody via Leasing — Design

> **Goal:** shrink the blast radius of a generator-node compromise. Today each generator's hot key
> (on the node) controls its **full ~22–27M DCC** stake. With leasing, the bulk of the stake lives on
> a **cold treasury** account whose seed is never on a node; only a small operating balance is hot.
> A node compromise then costs the small hot balance + attacker block-signing — **not the stake.**
>
> Addresses MAINNET-READINESS.md item #1 (highest-leverage custody win). Native Waves/DCC mechanism —
> no code changes. Rehearse on testnet first.

## Threat model — what this does / doesn't protect
- **Protects:** the ~22–27M stake. Leased funds can be moved/cancelled **only by the lessor** (cold treasury); the generator (hot key) cannot spend or steal them. A compromised node cannot drain the stake.
- **Does NOT protect:** the block-**signing** ability. In FairPoS the account seed both owns funds and signs blocks, so the signing key is inherently hot — an attacker with the node's seed can sign blocks (equivocate) and spend the small hot operating balance. That residual is inherent to any online validator; mitigate via key rotation + the IR-3 runbook. (Note: DCC/Waves FairPoS has **no slashing**, so there is no stake-burn penalty — the harm from signing abuse is liveness/forks, handled by finality + IR-4, not fund loss.)

## Verified DCC mechanics (from node-scala)
- **Leasing supported:** `LeaseTransaction` (type 8) / `LeaseCancelTransaction` (type 9). Leased funds stay in the lessor's account (unspendable while leased) and count toward the **recipient's generating balance** after the generating-balance depth.
- **Generating balance includes leased-in:** `CommitToGenerationTransactionDiff` checks `generatingBalance(sender)` (which includes leased-in) ≥ min — so **leased stake counts for both FairPoS mining AND feature-25 finality commit.** ✅ (verified in code)
- **Min generating balance:** `MinimalEffectiveBalanceForGenerator2 = 1,000 DCC` (feature `SmallerMinimalGeneratingBalance` = #1, active on testnet; otherwise 10,000 DCC). A generator below this can't mine or commit.
- **CommitToGeneration deposit:** `DepositInDcclets = 100 DCC` per commit; `generatingBalanceAfterDeposit` must stay ≥ 1,000 DCC.
- **Generating-balance depth:** `BlockchainSettings.generatingBalanceDepth(height)` (Waves default 1000 blocks ≈ ~83 min at 5s blocks). ⚠️ **Verify DCC's exact value before executing** — it sets the window during which a fresh lease does NOT yet count.

## Account layout (recommended)
- **Per-generator cold treasury** (`treasury-main`, `treasury-gen0`, `treasury-gen1`) — one cold account per generator for blast-radius isolation (a single shared treasury is simpler but one key then controls all leases). Cold seeds generated **offline**, stored **only in KeePassium**, **never** loaded into a running node.
- Each hot generator retains a small **own** operating balance; the rest is leased in from its treasury.

## Balance plan (per generator)
| Bucket | Amount | Rationale |
|--------|--------|-----------|
| Hot **own** balance (on node) | **~5,000 DCC** | must cover: min-generating floor (1,000) + repeated 100-DCC commit deposits + tx fees + buffer, and keep the generator minable even with zero leased-in mid-transition |
| **Leased-in** from cold treasury | rest (~21.8M / 26.8M / 26.8M − 5k) | counts toward generating balance after depth → mining + finality weight preserved |
| Net generating balance | ≈ unchanged | consensus + finality committee weights stay ~as today |

## Migration sequence — ⚠️ the ordering hazard
A fresh lease does **not** count toward generating balance until `generatingBalanceDepth` blocks pass, but moving own funds **out** drops generating balance **immediately**. So there is a window where the migrating generator's weight = only its retained ~5,000 DCC.

**Safe rule: migrate ONE generator at a time; fully complete + verify before the next.** With 3 roughly-equal generators, dropping one to ~5k for the depth window leaves the other two holding ≈2/3 of committed generating balance, so **feature-25 finality still holds** — but only if just one is mid-migration.

Per generator G with cold treasury T:
1. **Transfer** the bulk from G → T (leave ~5,000 DCC own on G). G stays ≥ 1,000-DCC min so it keeps mining + committing at low weight.
2. **Lease** from T → G for (bulk − small margin). Sign with T's **offline** cold key; broadcast the pre-signed tx via any node's public `/transactions/broadcast` (broadcasting a signed tx needs no API key).
3. **Wait** `generatingBalanceDepth` blocks, then verify `GET /addresses/balance/details/G` shows `generating` restored to ≈ pre-migration and `available`≈5,000.
4. **Verify finality stayed healthy** the whole window (`/blocks/height/finalized` advancing, lag ~100). Only then migrate the next generator.

_Optional staged variant (never dips): transfer out in two halves, leasing+maturing the first half before moving the second. More steps; unnecessary if one-at-a-time keeps 2/3._

## Cold-key custody
- Treasury seeds: generate offline, store in KeePassium (like the existing wallet entries), **never** in SOPS-on-a-node or loaded by a node process.
- Sign treasury transfers/leases **offline** (SDK or Waves util offline-signing), broadcast the signed tx from any node. The cold seed never touches an online host.

## Compromise response (ties to IR-3)
If a generator node/hot-key is compromised: the leased stake is safe. Cold treasury issues `LeaseCancelTransaction`, re-leases to a **new clean generator**, and the compromised generator's seed is rotated + node redeployed. Blast radius = the ~5,000-DCC hot balance + temporary signing, not the stake.

## Testnet rehearsal (do this first)
Run the full sequence on testnet (test funds) for one generator, confirm: generating balance restores after depth, the generator keeps mining + committing, finality lag stays ~100 throughout, and a `LeaseCancel` cleanly returns the funds. Then apply to all three, then bake into the mainnet-launch runbook.

## Open items to verify before mainnet
1. Exact `generatingBalanceDepth` value for DCC (sets the transition window).
2. Whether the 100-DCC commit deposit locks from **available (own)** balance each period (if so, size the hot retainer to cover N periods of deposits) or is returned/rolling.
3. `LeaseCancel` of a large lease has no adverse finality-committee side effect (should be fine — generating balance drops only after depth, symmetric to lease-in).
4. Faucet account (`31XRi…`) is unaffected (separate account; not a generator) — no change.

## Testnet rehearsal — RESULTS (2026-07-16) ✅ validated
Ran the full sequence on the **main** generator with a 1,000,000-DCC test slice (of ~21.8M), fully reversed:
- **Transfer** 1,000,000 main→treasury — confirmed (h54535). ✓
- **Lease** 900,000 treasury→main — confirmed (h54536); `/leasing/active/main` showed the 900k lease and the treasury's `available` dropped to 100k, i.e. **the leased funds are locked on the lessor and the generator cannot spend/steal them** (the whole point). ✓
- **LeaseCancel** — confirmed; treasury `available` restored to 1,000,000. **Fully reversible.** ✓
- **Restore** — transferred the slice back; main `available` returned to baseline (minus ~0.005 DCC fees). ✓
- **Finality** stayed healthy the entire time (lag ≈ 2; never stalled). ✓
- **Observed the depth hazard live:** immediately post-restore, main `available` = 21.8M but `generating` = 20.8M — generating balance lags by the ~1000-block depth and self-restores after. Confirms the "one generator at a time" migration rule.

**Mechanics are proven.** For the real migration: use a **cold/offline** treasury seed (the rehearsal used a node-wallet address `31LQnV…`, now empty — harmless), migrate one generator at a time, and wait out the depth before the next. Remaining pre-mainnet verifications are the four "Open items" above.
