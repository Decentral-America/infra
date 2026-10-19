# INCIDENT (ARCHIVED): Testnet "0 Connected Peers" / gen-0 Unable to Broadcast

**Status: RESOLVED 2026-07-08 12:42 UTC.** Verified stable across ~14.5 hours of independent check-ins with a
genuinely decentralized, growing generator distribution across three addresses.

This incident is closed. The full blow-by-blow live-investigation narrative (~53KB, including two premature
"resolved" declarations before the real fix, a chain-fork bisection, and several dead-end debugging attempts) has
been removed from this file since the incident is closed — this is now a compact archival summary kept only
because node-scala code comments and `clusters/testnet/RUNBOOK.md` reference it as historical context. (Moved into the infra repo on 2026-10-18 from an untracked workspace file; `HANDOFF.md` no longer exists and `wipe-chain.yml` is archived under `.github/archived-workflows/`.)

## What happened

Testnet dashboard showed **Active Generators: 1, Connected Peers: 0** — only the main node was forging. gen-0's
`CommitToGeneration` broadcasts failed with "not enough connections with peers (0)". gen-0 would briefly appear in
`/peers/connected`, then silently vanish with zero errors/close reasons logged on either side.

## Root causes (two compounding issues)

1. **Handshake-timeout bug (node-scala PR #16).** `NetworkServer.scala`'s outbound handshake timeout was
   accidentally set to 1s (instead of configured 30s) specifically when reconnecting after losing all peers — a
   self-reinforcing connect/suspend loop under cross-region latency (LKE Frankfurt ↔ Newark).
2. **Chain fork.** main diverged from the gen-0/gen-1/val-0 mesh at or before height 28500 (originating in an
   earlier chain-state transplant + subsequent restart chaos, allowed to persist by `quorum = 0`). Reconciled by
   transplanting main's canonical RocksDB state onto all three gen pods.

## Key findings (root-cause chain, in discovery order)

- `known-peers` bidirectional-initiation race → fixed (infra PR #27, `known-peers = []` on main).
- `max-rollback = 2000` exceeded the wire-protocol's 200-ID/13KB `GetBlockIds` limit, causing Netty to reject
  messages as malformed and kill peer connections → fixed (reduced to 100, infra PR #28). Primary cause for
  main + gen-1.
- **The actual gen-0 root cause:** a stale-entry dedup race in `HandshakeHandler` (`node-scala PR #11`) — the
  dedup always closed the *new* channel when an entry already existed for `(address, nonce)`, even if the
  existing entry was a dead channel whose cleanup listener hadn't run yet. Logged only at `debug`, hence
  invisible. Fixed: evict inactive previous entries instead of closing the new channel.
- Peer-exchange gossip (`enable-peers-exchange`) recreated the same collision via a path `known-peers=[]` didn't
  cover → fixed (infra PR #38, disabled peer-exchange on main).
- A follow-on, self-inflicted chain-wipe during investigation surfaced what was believed at the time to be a
  separate structural bug: replaying the chain from genesis under the current feature-activation config produced
  `InvalidStateHash` around height ~1800 — a new node couldn't bootstrap from genesis. **This original theory
  (config drift from commit `00658a1`) was investigated further on 2026-08-06 and found to be WRONG:** the
  testnet's current genesis (2026-06-24, post-dating that config commit) had run under one consistent feature
  config its entire life, so a fresh replay was never actually broken by *that*. The real cause was two genuine
  node-scala consensus bugs — a lost committed-generators-hash state-hash fix that existed only on orphaned,
  unmerged git tags, and a CommitToGenerationTransaction fee incorrectly carrying over via the standard NG 60/40
  split. Both fixed and deployed live 2026-08-12 (node-scala PRs #52/#53). A fresh genesis replay now gets from
  genesis cleanly through roughly height 3300 (previously: a permanent hard stop at 1798) — but a third, still-
  unsolved `InvalidStateHash` divergence exists at height 3325, so full genesis replay is **still not possible
  end-to-end**. Tracked as a standalone follow-up in node-scala's project history; see `wipe-chain.yml` for the
  current operational workaround (copy state from a live peer instead of replaying).

## Fix verification

Reconciled all gen pods to main's canonical chain state, then confirmed lockstep height and a genuinely
decentralized generator distribution (three distinct addresses producing blocks) held stable across ~14.5 hours
of independent re-checks, with zero recurrence of the suspend/close signature.

*Full investigation history (git blame this file at commit before 2026-08-04 if ever needed — note: this file
was lost from disk between 2026-08-06 and 2026-08-12 since it was never git-tracked, and was reconstructed from
session record on 2026-08-12; the original pre-2026-08-04 detailed history is not recoverable via git blame.)*

## Recurrence note — 2026-08-12, not reopened

Around 09:34-09:39 UTC today, gen-0/gen-1's logs show 5 repeated `Error appending extension ... InvalidStateHash`
entries while trying to sync a batch of blocks from main (chain tip was ~height 130240s at the time — nowhere
near the still-open height-3325 genesis-replay divergence). By the time this was noticed (~22:44-22:48 UTC, during
unrelated CI-flakiness triage), the error was no longer reproducing in the last 3000 log lines on either pod, main
was advancing normally (130328 → 130337 in under a minute), and val-0 was connected to main. gen-0/gen-1 showed 0
connected peers at spot-check time, `suspended` listed only a single fresh 30s entry (not blacklisted), consistent
with normal suspend/reconnect cycling rather than a persistent divergence.

**Not root-caused** — the burst self-quieted before a live block-level diff could be pulled, so there's no
evidence beyond the log lines that a real state divergence occurred (as opposed to e.g. a single competing block
that lost the fork race and rolled back normally, which also logs as "Can't process fork" + one InvalidStateHash
per rejected attempt). Logged here so a *recurrence* of this exact signature is recognized quickly rather than
re-investigated from scratch — if it happens again and stays live long enough to catch, pull the full block
signatures via `infra/.github/workflows/live-statehash-divergence.yml` (added today for exactly this) before it
clears.

## Finding #11 (2026-07-07): peer-lifecycle events were invisible at every log level

node-scala code cites this finding. Connection resets (`FatalErrorHandler`), outbound channel closes
(`NetworkServer.handleOutgoingChannelClosed`) and peer suspensions (`PeerDatabaseImpl.suspend`) were logged at
trace/debug and did not show up even with targeted TRACE overrides, so repeated gen-0/gen-1/val-0 disconnects
from main could not be diagnosed without a rebuild. All three were raised to `info`. The new logging immediately
caught a connection that was established, then suspended and closed 1.5 s later with no handshake in between.
That led to the 1 s reconnect handshake-timeout bug (root cause 1 above): `NetworkServer` now always uses the
configured `handshake-timeout`.

## Follow-up (2026-08-13): suspension on graceful closes

A separate connectivity bug had `NetworkServer` suspending peers on benign, graceful outgoing channel closes. That
starved gen-0/gen-1 of a stable connection to main and stalled `hotStuffFinalizedHeight` for hours. Fixed in
node-scala PR #58 ("don't suspend a peer on a graceful outgoing channel close", merged 2026-08-13).

## Status update (2026-10-18)

- The height-3325 `InvalidStateHash` divergence mentioned above was later root-caused and fixed; it only
  affected the history of the pre-relaunch chain. The Testnet was relaunched from a new genesis on 2026-09-04.
- `live-statehash-divergence.yml` and `wipe-chain.yml` are retired (see `.github/archived-workflows/README.md`).
- Main's `known-peers = []` and `enable-peers-exchange = no` from this incident are still in force
  (`node-config/testnet/dcc.conf`).
