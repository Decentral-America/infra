# Reset blockchain-postgres-sync (BPS), testnet

**Purpose:** drop the BPS index and rebuild it from block 1 after a **re-genesis**,
when the database still describes a dead chain. For a plain outage or node restart
(no re-genesis) do **not** drop anything. Use [Restart only](#restart-only-no-re-genesis).

**Status:** written 2026-10-01 (TESTNET-FINAL-PLAN Task 4.1). Not executed yet. Each
destructive command is marked ⛔ and needs a fresh operator go-ahead at the moment it runs.

**Linked from:** `RELAUNCH-20260904.md` section 10.

## What was verified (and where the plan draft was wrong)

The commands in the plan's draft were checked against this repo. Four of them would
have failed or done the wrong thing:

| Plan draft said | Actual | Source |
|---|---|---|
| `docker exec -i postgres-testnet psql ...` | No Postgres container exists. Postgres 18 is a **system** package on the VPS. Use `sudo -u postgres psql`. | `terraform/scripts/bootstrap.sh:63-81`, `restart-services.yml:76`, `vps-node-status.yml:35` |
| `CREATE DATABASE bps_testnet OWNER bps` | There is no `bps` role. The application role is **`dcc`** (`POSTGRES__USER`). | `bootstrap.sh:376`, `bootstrap.sh:305` |
| `BPS_STARTING_HEIGHT=0` in the env file | The compose file pins **`BPS_STARTING_HEIGHT: "1"`** under `environment:`, which overrides `env_file`. The BlockchainUpdates gRPC server **rejects 0** ("must be > 0"). Leave it at 1. | `compose/blockchain-postgres-sync.yml:20-24` |
| `select max(height) from blocks_raw` | No `blocks_raw` table. Blocks live in **`blocks_microblocks`**. | BPS migration `2022-04-27-111623_initial/up.sql:12` |

Also verified:

- **Container:** `blockchain-postgres-sync-testnet`, compose project
  `blockchain-postgres-sync-testnet`, file `/opt/dcc/compose/blockchain-postgres-sync.yml`
  (`compose/blockchain-postgres-sync.yml:13`, `restart-services.yml:94-96`).
- **Database name:** the BPS container reads it from `POSTGRES__DATABASE` in
  `/opt/dcc/secrets/testnet.env`. Terraform defaults it to **`bps_testnet`**
  (`terraform/main.tf:141`), and every workflow that queries it uses `bps_testnet`.
  Read it from the env file rather than assuming (step 1).
  - Careful: `bootstrap.sh:383-387` creates a different database, `dcc_testnet`. The matcher
    uses that one for Postgres (`push-secrets.yml:295-302`). Do not drop `dcc_testnet`.
- **Schema:** the consumer does **not** migrate on start. Migrations are a separate binary,
  `/app/migration up`, in the same image (BPS `Dockerfile:55-56`, `src/bin/migration.rs`).
  No infra or DecentralChain workflow runs it, so after a drop you must run it by hand
  (step 5).
- **Other readers of the same DB:** `data-service-testnet` (PG* vars from the same env
  file). Stop it first, or it will hold connections and serve errors mid-reset.
- **Health / progress signals:** `GET 127.0.0.1:9090/readiness` (DB pool) and
  `GET 127.0.0.1:9090/metrics` → `bps_last_synced_height`. The consumer also logs
  `Start fetching updates from height N` at start (`src/lib/consumer/mod.rs`).

## Preconditions

- [ ] The node on the VPS (`node-scala-testnet`) is on the **new** chain and advancing:
      `curl -s http://127.0.0.1:6869/blocks/height` returns a height that goes up.
      BPS streams from the node's BlockchainUpdates gRPC on `:6881`.
- [ ] You are on the VPS as `deploy` (sudo). Never print the env file. The commands below
      read only the non-secret `POSTGRES__DATABASE` / `POSTGRES__USER` keys.

## Full reset (after a re-genesis)

```bash
# on the VPS
# 1. Resolve names from the live env file (non-secret keys only)
DB=$(sudo grep '^POSTGRES__DATABASE=' /opt/dcc/secrets/testnet.env | cut -d= -f2-)
OWNER=$(sudo grep '^POSTGRES__USER=' /opt/dcc/secrets/testnet.env | cut -d= -f2-)
echo "DB=$DB OWNER=$OWNER"            # expect: DB=bps_testnet OWNER=dcc -- STOP if anything else
IMG=$(docker inspect -f '{{.Config.Image}}' blockchain-postgres-sync-testnet)
echo "BPS image: $IMG"

# 2. Stop the writer and the reader
docker stop blockchain-postgres-sync-testnet data-service-testnet

# 3. (optional) keep a dump of the old chain's index, for forensics
sudo install -d -o deploy -g deploy /opt/dcc/backup
sudo -u postgres pg_dump -Fc "$DB" > "/opt/dcc/backup/${DB}.$(date +%F).dump"

# 4. ⛔ Drop and recreate (PG 18: WITH (FORCE) terminates leftover sessions)
sudo -u postgres psql -v ON_ERROR_STOP=1 \
  -c "DROP DATABASE IF EXISTS \"$DB\" WITH (FORCE);" \
  -c "CREATE DATABASE \"$DB\" OWNER \"$OWNER\";"

# 5. Apply the schema (the consumer does not migrate on its own)
docker run --rm --network host --env-file /opt/dcc/secrets/testnet.env \
  "$IMG" ./migration up
# expect: "Applied migration: ..." lines, ending with 2026-06-28-000000_add_txs_19_commit_to_generation

# 6. Start BPS (BPS_STARTING_HEIGHT stays 1 from the compose file)
docker start blockchain-postgres-sync-testnet
docker logs blockchain-postgres-sync-testnet 2>&1 | grep -m1 "Start fetching updates from height"
# expect: "Start fetching updates from height 1"
```

The fresh migration already creates `txs_19.block_uid` with `ON DELETE CASCADE`, so the
`txs_19_block_uid_fkey` fix in `restart-services.yml:75-76` reports
"already CASCADE" and does nothing. Running it is harmless.

### Verify caught up

```bash
# on the VPS
sudo -u postgres psql -d "$DB" -tAc "select max(height) from blocks_microblocks"
curl -s http://127.0.0.1:6869/blocks/height
curl -s http://127.0.0.1:9090/metrics | grep '^bps_last_synced_height'
```

Pass: all three numbers are within a few blocks of each other, and the first and third keep
rising between two samples taken a minute apart.

### Bring the reader back

```bash
docker start data-service-testnet
# or, so data-service re-reads its env_file: gh workflow run restart-services.yml (⛔ operator)
curl -s -o /dev/null -w '%{http_code}\n' https://testnet-data-service.decentralchain.io/transactions/exchange?limit=1
# expect: 200
```

## Restart only (no re-genesis)

This is the procedure for an outage or a node restart on the **same** chain, such as the
2026-09-17 Linode outage. BPS keeps its height in Postgres and resumes from there. On start
it rolls back `BPS_START_ROLLBACK_DEPTH` (default 1) blocks.

```bash
# on the VPS, once node-scala-testnet is up and advancing
docker restart blockchain-postgres-sync-testnet
docker logs --since 5m blockchain-postgres-sync-testnet 2>&1 | grep -E "Start fetching updates from height|exceeds|error" | head
```

If BPS reports a start height above the node's current height, the node is not caught up
yet. This happens when BPS restarts while the node is still syncing. Wait until
`curl -s http://127.0.0.1:6869/blocks/height` is past the height BPS asked for, then
`docker restart blockchain-postgres-sync-testnet` once more. **Do not drop the database
to fix this.** Then run [Verify caught up](#verify-caught-up).

## Not covered / open

- Redis: BPS publishes updates to Redis (`REDIS_URL`), and websocket-api consumes them.
  It has not been verified whether any Redis keys from the old chain need flushing after a
  re-genesis. Check websocket-api for persisted keys before the next re-genesis.
- The `bootstrap.sh` (`dcc_testnet`) and terraform (`bps_testnet`) database names differ.
  A freshly provisioned VPS may therefore have no `bps_testnet` database until someone
  creates it. Step 4's `CREATE DATABASE` covers that case too.
