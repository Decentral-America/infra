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

**Not archived from this round** — `deep-finality-diag.yml` (ran 2026-08-04) — recent enough
to keep for now; re-check next triage.

Archived 2026-09-21 after a full 89-workflow audit across all 5 repos, following the
2026-09-04 testnet relaunch (fresh genesis, `31d4410ba3` fix included) which obsoleted several
pre-relaunch diagnostic/recovery tools:

| Workflow | Last run before archiving | Why |
|---|---|---|
| `debug-state-hash.yml` | 2026-08-12 | Hardcoded to heights (3323-3325) on the pre-relaunch chain, which no longer exists |
| `live-statehash-divergence.yml` | 2026-08-13 | Diagnosed the height-3325 divergence, root-caused and fixed in `31d4410ba3`, chain since re-genesised |
| `migrate-state-snapshot.yml` | 2026-08-13 | One-off recovery for pre-fix (`be2dcfc0`) chain state; fleet is now uniformly on the fixed, digest-pinned relaunch image |
| `deploy-redis.yml` | 2026-07-04 | Stale one-shot ops tool, no docs references, trivially reconstructible if needed |
| `restart-admin.yml` | 2026-06-30 | Same — stale, undocumented, reconstructible |
| `inject-redis-secret.yml` | never run | One-shot task already completed by other means before this tool was ever used |
| `set-redis-policy.yml` | never run | Dead on arrival, zero doc references |
| `tag-release.yml` | never run | Superseded by node-scala's own release-tagging path |
| `fund-load-test-senders.yml` | 2026-06-30 | Single-session load-test episode, superseded by the admin dashboard's stress-test integration |
| `rebalance-validators.yml` | 2026-06-28 | Single-session use, superseded by later committee/generator work in node-scala |

**Important correction to the 2026-08-13 note above:** the height-3325 statehash divergence
is now **closed** (fixed in `31d4410ba3`, live on the relaunched chain since 2026-09-04) — it
is not "still-open" as previously stated here.

**Not archived, deliberately kept despite low/no run counts** (verified 2026-09-21 as still
load-bearing): `verify-api-keys.yml` (key-rotation runbook step), `bootstrap-flux.yml` and
`label-hostendpoint-nodes.yml` (cluster-rebuild/scale-up tools, low cost to keep, high cost if
missing), `stress-test.yml` (live admin-dashboard "Run Stress Test" button — do NOT archive,
confirmed wired via `correlation_id` in `admin-dashboard/src/routes/api.load-test.stream.ts`),
`prune-released-chain-volumes.yml` (actively scheduled, prevents real recurring billing).

If any of these are needed again, move the file back to `.github/workflows/` — nothing else
to restore.
