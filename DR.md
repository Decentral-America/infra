# Backup and disaster recovery

One design for every network. `<network>` is `testnet`, `stagenet` or `mainnet`; the same scripts,
units and runbook steps are promoted with the stack (ECO-85). Testnet is where the design is proven.

**Status (2026-10-31):** code merged-pending (this file, `scripts/pg-backup.sh`,
`scripts/chain-snapshot.sh`, `host/systemd/dcc-pg-backup@.{service,timer}`, `bootstrap.sh`).
Nothing below is live until the steps in [Rollout](#rollout-pending-live-steps) are done and the
restore drill is recorded.

**Decision history.** 2026-10-07: operator declined testnet backups (plan B8, "peers re-sync").
**Superseded 2026-10-24** by the mainnet-grade standard (testnet is promoted to stagenet and
mainnet with the same artifacts and runbooks). The 2026-10-01 account-level loss deleted every peer
at once, so "peers re-sync" is not a recovery path when all peers live in one Linode account.

## 1. Targets — PROPOSED, pending Operator approval (ECO-85)

| | testnet | stagenet | mainnet |
|---|---|---|---|
| RPO, Postgres (`bps_<network>`, `admin_<network>`) | 24 h | 24 h | 24 h |
| RPO, chain state | 24 h (daily snapshot); re-sync from any surviving peer is 0 | same | same |
| RPO, config (compose, Caddy, node config, secrets) | 0 (in git; secrets SOPS-encrypted in git) | same | same |
| RTO, full VPS rebuild on a fresh Linode | 4 h | 4 h | 4 h |

Why these numbers: every input is either in git (0 loss) or reproducible from the chain except the
admin dashboard's own rows (`admin_<network>`, low churn), so a daily dump is enough. `bps_<network>`
can always be rebuilt by re-indexing from the node; the dump only saves the re-index time. The 4 h
RTO is the sum of the steps in section 5 with margin (tofu + bootstrap ~20 min, secrets push and
deploys ~30 min, Postgres restore and chain restore depend on size and are measured by the drill).
The drill result (section 6) decides whether 4 h holds; if it does not, the Operator either accepts
the measured number or funds a faster path (warm standby).

Operator approval: `PENDING — Owner` (name, date).

## 2. What is backed up

| Item | Source | Method | Frequency / retention | Destination |
|---|---|---|---|---|
| BPS chain index `bps_<network>` | VPS system Postgres | `scripts/pg-backup.sh`: `pg_dump -Fc` as the `postgres` OS user (peer auth), verified with `pg_restore --list`, sha256 sidecar | daily 03:15 UTC (`dcc-pg-backup@<network>.timer`), keep 7 | `s3://dcc-<network>-backups/pg/bps_<network>/<UTC>.dump` |
| Admin dashboard DB `admin_<network>` | VPS system Postgres | same | same | `.../pg/admin_<network>/<UTC>.dump` |
| Chain state (RocksDB) | ONE LKE node, default `dcc-val-0` (PVC `chain-data-dcc-val-0-0`, `/var/lib/dcc/data`) | `scripts/chain-snapshot.sh` (section 3) | daily **once the Operator approves the stop** (section 3), keep 7 | `.../chain/dcc-val-0/<UTC>-h<height>.tar.gz` + `.sha256` |
| Grafana dashboards | git: `monitoring/dashboards/` (provisioned) | none needed | — | git |
| Grafana state (public-dashboard share, users) | volume `grafana-data-<network>` | not backed up: `deploy-monitoring.sh` re-creates the public dashboard with its fixed token; anonymous access is off and logins use the admin password from SOPS | — | re-created by deploy |
| Compose files, node config, alert rules, Caddy template | git: `compose/`, `node-config/`, `monitoring/`, `scripts/render-caddyfile.sh` + `terraform/<network>.tfvars` | none needed | — | git |
| Rendered Caddyfile `/opt/dcc/caddy/Caddyfile` | rendered by `update-caddy.yml` from the repo + `MAIN_NODE_REST_API_KEY` (SOPS) + `E2E_RATE_LIMIT_BYPASS_KEY` (GitHub secret) + the host IP | re-render, never copied (it holds a key) | — | — |
| Secrets | `secrets/<network>.env` (SOPS/age, in git) | none needed; the age private key custody is in SECURITY.md | — | git + key custody |
| Linode recovery images | Linode private images | one-off export (section 7) | until superseded | `s3://dcc-recovery-images/` |
| OpenTofu state | R2 `dcc-tofu-state` (already off-account, encrypted) | existing | — | R2 |

The main node's own volume `node-state-<network>` is not snapshotted: a restored main re-syncs from
the LKE nodes, or is seeded from the chain snapshot (section 5) if they are gone too.

**Failure detection.** `pg-backup.sh` writes
`dcc_backup_last_success_timestamp_seconds{kind="pg",target="<db>"}` and
`dcc_backup_last_size_bytes` to node-exporter's textfile directory; a failed database keeps its old
timestamp. Alerts (monitoring/alerts.yml, promtool-tested): `BackupStale` (no success for 26h) and
`BackupNeverSucceeded` (no series for 26h). The script exits non-zero on any failure, so
`systemctl status dcc-pg-backup@<network>` and the journal show it too. Log: `/var/log/dcc/pg-backup.log`.

## 3. Chain snapshot design (Operator decision required)

**Evidence.** node-scala has no online checkpoint or export endpoint (`DebugApiRoute` has none), and
the offline `Exporter` opens the database with `RDB.open`, which takes the RocksDB LOCK, so it also
needs the node stopped. A copy of a running RocksDB is not consistent. No volume-snapshot path is
used: the repo defines no VolumeSnapshotClass for the `linode-block-storage-retain` PVCs, and a
block-level clone of an attached, mounted volume would be crash-consistent at best.
The only consistent method is the one already used in the 2026-08 recovery
(`.github/archived-workflows/migrate-state-snapshot.yml`): stop the node, tar `data/`, start it.

**Chosen design.** `scripts/chain-snapshot.sh <network> [sts]`:
preflight (all three LKE nodes Ready, main finality lag <= 20) -> suspend Flux at the parent then
`apps` (runbooks/staggered-node-rollout.md) -> scale `dcc-val-0` to 0 -> read-only loader pod on its
PVC streams `tar czf - data` -> scale back to 1 immediately -> upload with sha256 -> wait until the
node is back within 20 blocks of main -> resume Flux -> keep 7. A trap always scales the node back up
and restores Flux, also on failure.

**Why val-0 and why this needs a decision.** Every LKE node is a committee generator. With val-0
stopped the committee runs on 3 of 4 (HotStuff and T0 still have quorum; the crash drill of
2026-10-10 deleted gen-1 with finality continuous), but there is no fault tolerance for the few
minutes of the copy. Committee weight on 2026-10-31 (`/generators/at/<current period start>`, field `balance`): main
~60.2M DCC (73.4%), gen-0, gen-1 and val-0 ~7.2-7.3M each (~8.8% each; ECO-412 tracks the
concentration), so stopping any one LKE node costs the same ~9% and leaves > 2/3 online. main (the P2P hub and the largest stake) is never used. The script refuses to run without
`CONFIRM=STOP-<sts>`, and **no schedule is enabled** until the Operator decides:

- [ ] **⛔ Operator decision (ECO-85), one of:**
  (a) approve a daily stop of val-0 (scheduler: run `chain-snapshot.sh` daily from a host that holds
  the kubeconfig and R2 key, outside any soak freeze), or
  (b) add a dedicated non-generating follower node whose daily stop has no consensus impact
  (recommended for mainnet; needs ~1.3 GiB on the LKE worker, re-check capacity), or
  (c) weekly instead of daily (RPO 7 days for the chain; peers remain the first restore source).
  Decision: `PENDING — Owner`, date: `PENDING`.

## 4. Destination and credentials

- Bucket per network: `dcc-<network>-backups` (Cloudflare R2, same account as `dcc-tofu-state`,
  outside Linode). Image exports: `dcc-recovery-images`. **Both buckets: PENDING creation.**
- API token: an R2 token scoped to Object Read & Write on that one bucket (not the tofu-state token).
- On the VPS: `/opt/dcc/secrets/backup-<network>.env`, mode 600 root, with
  `R2_BACKUP_ACCESS_KEY_ID`, `R2_BACKUP_SECRET_ACCESS_KEY`, `R2_BACKUP_ENDPOINT`
  (`https://<account id>.r2.cloudflarestorage.com`). Source of truth: the same three keys in SOPS
  `secrets/<network>.env`, **PENDING** (and the secrets push must write this file; not wired yet).
- Retention is enforced by the scripts (keep 7). An R2 lifecycle rule deleting objects older than
  30 days is a recommended backstop if a script ever stops pruning.

## 5. Restore procedure (fresh Linode, account-independent inputs only)

1. `provision.yml` (tofu apply) for `<network>` -> new VPS; bootstrap installs Postgres, Docker,
   firewall, fail2ban, backup timer. Pin the new host key (`ssh/known_hosts`).
2. `push-secrets.yml` (SOPS) -> master env, per-service env files, matcher config, Postgres password.
3. Postgres: download the newest dumps and verify sha256, then
   `pg_restore --clean --if-exists --no-owner --role=dcc -d bps_<network> <dump>` and the same for
   `admin_<network>` (as the `postgres` OS user). `bps_<network>` may instead be re-indexed from the
   node (runbooks/reset-bps-testnet.md) if the dump is older than the RPO.
4. Main node: `deploy-node-config.yml` / `update-node-image.yml`. If no LKE peer survives, seed
   `node-state-<network>` from the newest chain snapshot (untar `data/` into the volume while the node
   is stopped, owner uid 999) before starting it.
5. `update-caddy.yml`, `deploy-monitoring-stack.yml`, then each service's `deploy-container.yml`.
6. LKE (if lost): `provision.yml` recreates the cluster, `bootstrap-flux.yml`; nodes re-sync from
   main, or are seeded from the snapshot as in step 4.
7. Verify: main height advancing and equal to the network tip, finality lag normal, data-service
   `/v0` 200, BPS height = chain height, explorer and admin 200.

## 6. Restore drill record (ECO-85) — PENDING

Acceptance: restore onto a fresh Linode from tofu + backups only, reach the current height,
data-service returns 200, elapsed time recorded against the RTO.

| Field | Value |
|---|---|
| Date / operator | PENDING |
| Backups used (object keys + sha256) | PENDING |
| Start (UTC) / end (UTC) / elapsed | PENDING |
| Height reached vs network tip | PENDING |
| data-service `/v0` status | PENDING |
| Within RTO? | PENDING |
| 7 consecutive daily objects in R2 (pg + chain), listing | PENDING |
| `pg-backup.sh` exit 0 on the VPS; `crontab -l` shows no legacy backup job | PENDING |
| Temporary Linode deleted (`linode-cli linodes list`) | PENDING |

## 7. Linode private images (ECO-81)

Listed by the lead with `linode-cli images list --is_public false` on 2026-10-31. All created
2026-10-01 (when non-payment deleted the account's Linodes), all **expire 2026-12-30**.

| Image | Label / content | Size | Decision (2026-10-31) |
|---|---|---|---|
| `private/41601991` | dcc-backend-testnet, Debian 12 | 22091 MB | **KEEP**: the testnet VPS was restored from it on 2026-10-04; export off-account |
| `private/41601994` | LKE boot disk | ~10 GB | **DROP**: LKE recreates worker nodes from its own image |
| `private/41601999` | LKE boot disk | ~10 GB | **DROP**: same |
| `private/41601995` | econode-1 | 18840 MB | **PENDING — owner of that project** (not a DCC image) |
| `private/41602001` | turbo-team | 21111 MB | **PENDING — owner of that project** (not a DCC image) |
| `private/41602005` | crypto-core | 18864 MB | **PENDING — owner of that project** (not a DCC image) |

Owner sign-off of the decisions above (must be dated before 2026-12-15): `PENDING — Owner`.

**Export procedure (per kept image).** Boot a temporary Linode from the image in rescue mode (or
with the image disk attached as a secondary, unmounted disk), then stream the raw disk, compressed,
straight to R2 and hash the same stream:

```
dd if=/dev/sdX bs=4M status=progress | zstd -T0 -19 \
  | tee >(sha256sum > /root/image.zst.sha256) \
  | aws --endpoint-url "$R2_BACKUP_ENDPOINT" s3 cp - s3://dcc-recovery-images/<image-id>-<label>.img.zst --expected-size <bytes>
```

Re-download the object on a different host, recompute sha256, and compare. Restore test: create a
Linode from the export (upload as a custom image, `linode-cli image-upload`), boot it, keep the boot
log, delete the test Linode. Delete every temporary Linode and record `linode-cli linodes list`.

| Image | R2 object key | SHA-256 (at export) | SHA-256 (re-download) | Restore-test boot log | Temp Linodes deleted |
|---|---|---|---|---|---|
| `private/41601991` | PENDING | PENDING | PENDING | PENDING | PENDING |

## 8. Account continuity (ECO-83)

Non-payment has deleted DCC infrastructure twice: 2026-07-20 (VPS unreachable; services
self-healed on power-on) and 2026-10-01 (every Linode, the LKE cluster and its volumes deleted).
This section records who keeps each account paid. **No card or bank data goes in git**; the
payment-method screenshots live in the team drive.

| Linode account | Payment-method owner | Backup contact | Payment methods (2 required; screenshot in team drive) | Billing email (shared ops address + both contacts) | Prepaid credit (>= 2 months) and date | Monthly balance review (owner, day) |
|---|---|---|---|---|---|---|
| DCC testnet account (VPS + LKE) | PENDING — Owner | PENDING — Owner | PENDING | PENDING | PENDING | PENDING |
| Account behind 173.255.238.171 | PENDING — Owner | PENDING — Owner | PENDING | PENDING | PENDING | PENDING |
| Account behind 172.237.135.228 | PENDING — Owner | PENDING — Owner | PENDING | PENDING | PENDING | PENDING |

| IP / resource | What it serves | Linode account |
|---|---|---|
| 50.116.30.244 | testnet VPS (Linode 107373605, Dallas) | DCC testnet account |
| LKE `dcc-peer-testnet` | testnet gen-0, gen-1, val-0 | DCC testnet account |
| 173.255.238.171 | legacy mainnet node v1.3.5 (`mainnet-node.decentralchain.io`) | unknown — PENDING — Owner |
| 172.237.135.228 | production web (`decentralscan.com`) | unknown — PENDING — Owner |

Evidence still owed (ECO-83): an invoice or test notification received at the ops address (date),
the prepaid amount, and the owner names above.
