# Archived workflows

These were one-off incident-response/diagnostic workflows, moved out of `.github/workflows/`
(GitHub Actions only scans that directory directly, not subdirectories, so these no longer
run or appear in the Actions tab — content and history are preserved, not deleted).

Archived 2026-08-13 after the audit triage confirmed each had no runs in 4+ weeks and its
associated incident is documented as resolved:

| Workflow | Last run before archiving | Associated incident |
|---|---|---|
| `wipe-chain.yml` | 2026-07-07 | Genesis reset tooling, testnet bring-up |
| `fix-extension-height.yml` | 2026-06-30 | Height-extension divergence fix |
| `resync-gen-nodes.yml` | 2026-07-16 | RC#2 peer-cycling fix |
| `t2-soak.yml` | 2026-07-13 | HotStuff T2 soak-test tooling |
| `check-val0-address.yml` | 2026-06-30 (failure, never re-run) | val-0 address verification, one-off |
| `tune-hotstuff-round-timeout.yml` | never run | Built, never actually needed |

**Not archived, deliberately** — still actively used, confirmed via real run history at
triage time: `debug-state-hash.yml` (ran 2026-08-12), `live-statehash-divergence.yml` (ran
2026-08-13) — both tied to the still-open height-3325 statehash divergence. `deep-finality-diag.yml`
(ran 2026-08-04) — recent enough to keep for now.

If any of these are needed again, move the file back to `.github/workflows/` — nothing else
to restore.
