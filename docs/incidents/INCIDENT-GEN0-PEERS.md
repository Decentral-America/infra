# INCIDENT (ARCHIVED): Testnet "0 Connected Peers" / gen-0 Unable to Broadcast

**Status: RESOLVED 2026-07-08 12:42 UTC.** Verified stable across ~14.5 hours of independent check-ins with a
genuinely decentralized, growing generator distribution across three addresses.

This incident is closed. The full blow-by-blow live-investigation narrative (~53KB, including two premature
"resolved" declarations before the real fix, a chain-fork bisection, and several dead-end debugging attempts) has
been removed from this file since the incident is closed — this is now a compact archival summary kept only
because `HANDOFF.md` and `infra/.github/workflows/wipe-chain.yml` reference it as historical context.

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

## Follow-up — 2026-08-13, real root cause of the underlying connectivity pattern found and fixed

The 2026-08-12 recurrence note above logged symptoms (`0 connected peers`, single fresh 30s suspend entry,
consistent with normal cycling) without a root cause. The next day, the admin-dashboard's "Active Generators"
count was reported stuck at 1, and a fresh live diagnostic (`cluster-diagnostics.yml`) caught the actual
mechanism in progress: gen-0/gen-1 were cycling **connect → handshake accepted → suspended + closed** on a
~30-second period (exactly `suspension-residence-time`), every single time, with no error/blacklist/score-mismatch
ever logged in between — just a graceful ("expected") channel close immediately followed by a 30s suspension.

**Root cause:** `NetworkServer.scala`'s `handleOutgoingChannelClosed` suspended the remote peer on *any* outgoing
channel close, including a completely benign, graceful one (`closeFuture.isSuccess`) — not just genuine failures.
Since gen-0/gen-1's only known-peer is main, and a graceful close (most likely triggered by `HandshakeHandler`'s
own duplicate-connection dedup on either side — it keys on `(host, nonce)`, not direction) is a normal, expected
event in a bidirectional-dial topology, this turned every ordinary reconnect into a 30-second penalty box. Over
hours, that compounds into exactly the "700-1100 blocks behind" state this incident already knew about — this is
the missing piece connecting the 2026-08-12 recurrence note to a real, permanent fix, not a config workaround.

**Fix:** node-scala PR #58 — only suspend on the genuine-failure branch (the one that already logs a real close
cause), leave the "(expected)" graceful-close branch alone. Built, deployed to gen-0/gen-1/val-0 *and* main (the
compose-based VPS was still on an older build — fixed for fleet consistency even though main rarely dials out).

**Verification:** post-fix, gen-0/gen-1 held stable connections with zero suspend-loop recurrence across multiple
follow-up `cluster-diagnostics.yml` runs. They had fallen far enough behind (700-1100 blocks) that connectivity
alone wasn't enough to catch up in reasonable time — recovered via `migrate-state-snapshot.yml` (briefly stops
main for a consistent RocksDB snapshot, loads it into each gen's PVC). All three nodes converged to identical
height within minutes and are now forging in a healthy, roughly even split (36/36/28 over a 100-block sample).
The E2E finality test that depends on this (`finality.spec.ts` → "if present, hotStuffFinalizedHeight is
advancing too") now passes cleanly — confirmed via a fresh `admin-e2e.yml` dispatch (31/31 test files passed).

**Still open:** this fix addresses the graceful-close suspend path specifically. The broader "why does a benign
duplicate-connection close happen at all" (i.e. why does gen-0's own outgoing dial keep racing against an
existing channel in the first place) was not fully traced to its root in the netty/HandshakeHandler layer — it's
apparently common enough on this topology to matter, but is no longer *punished* the way it used to be. If the
30s-suspend-loop signature reappears despite this fix, that deeper question is the next place to look.
