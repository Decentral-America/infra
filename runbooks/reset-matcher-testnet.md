# Reset the DEX matcher state, testnet (keep the matcher identity)

**Purpose:** clear the matcher's order books, event queue and snapshots after a
**re-genesis**. Those reference asset IDs, addresses and orders from the dead chain. The
matcher's signing identity must stay exactly the same. For a plain outage on the **same**
chain, do **not** delete anything. Use [Restart only](#restart-only-no-re-genesis).

**Status:** written 2026-10-01 (TESTNET-FINAL-PLAN Task 4.2). The empty-key matcher state was removed
on 2026-10-10; a full re-genesis reset has not been needed since. Each destructive command is marked ⛔
and needs a fresh operator go-ahead at the moment it runs.

**Linked from:** `RELAUNCH-20260904.md` section 10.

## What was verified

- **Container:** `matcher-testnet`, host network, REST on `127.0.0.1:6886`
  (`compose/matcher.yml:22,44-49`; `dex/src/main/container/dex.conf` in the matcher repo).
- **Host paths** (`compose/matcher.yml:50-54`):
  - `/opt/dcc/data/matcher-testnet` is mounted as `/var/lib/decentralchain-dex`, the matcher
    `root-directory` (entrypoint passes `-Ddcc.dex.root-directory`).
  - `/opt/dcc/config/matcher-testnet` is mounted read-only at `.../config` and holds
    `local.conf`, written only by `push-secrets.yml` (`scripts/render-matcher-local-conf.sh`). **Never delete it.**
- **What the state is:** `data-directory = <root>/data` (matcher `application.conf:6`) holds
  the order DB, the local events queue (`events-queue.type = local`) and order-book
  snapshots. The plan draft named `order-db/`, `snapshots/` and `journal/` as top-level dirs.
  That is not confirmed. List the directory and delete by the rule "everything except
  `account.dat` and `config`" (step 4).
- **Not state:** order history in Postgres is off by default (`order-history.enable = no`),
  and the Redis client is off by default (`redis-internal-client-handler-actor.enabled =
  false`). `push-secrets.yml` sets neither, so there is nothing to clear in Postgres or Redis.
  Step 1 checks this on the live `local.conf`.

## Which key is the matcher using? Check BEFORE any reset

Resolved on 2026-10-09 (infra #184). `local.conf` carries `account-storage.type = in-mem` with
`in-mem.seed-in-base-64` from SOPS `MATCHER_SEED_BASE64`. The matcher public key is `BEtB5b2kX8Yge4sb5RRbTUqd5Va8Ah8PhphowcW31z6Y`
(address `31VMNVAvVh67dPZ41nMnYZvhoZFW7wwPrmq`). `account.dat` is not read.
`curl -s http://127.0.0.1:6886/matcher` must return that public key before and after any reset; if it does
not, stop: the matcher is not running on its real key.

## Preconditions

- [ ] `node-scala-testnet` is on the new chain and advancing (the matcher reads it over gRPC
      `:6887` and BlockchainUpdates `:6881`).
- [ ] You are on the VPS as `deploy` (sudo). Never print `local.conf` in full: it contains the
      matcher seed and the API key hash.

## Full reset (after a re-genesis)

```bash
# on the VPS
# 1. Record identity and storage mode (no secret values printed)
PRE_PK=$(curl -s http://127.0.0.1:6886/matcher | tr -d '"'); echo "pre-reset matcher public key: $PRE_PK"
sudo grep -nE 'account-storage|^[[:space:]]*type[[:space:]]*=' /opt/dcc/config/matcher-testnet/local.conf
sudo grep -c 'seed-in-base-64' /opt/dcc/config/matcher-testnet/local.conf    # count only
sudo grep -nE 'order-history|redis-internal-client-handler-actor' /opt/dcc/config/matcher-testnet/local.conf || echo "order-history/redis-actor not overridden (both off)"
# STOP if: type is in-mem AND the seed count is 0 (see the warning above)

# 2. Stop
docker stop matcher-testnet

# 3. Full backup of the data dir (includes account.dat if present)
sudo install -d -m 700 /opt/dcc/backup
sudo tar -C /opt/dcc/data -czf "/opt/dcc/backup/matcher-testnet.$(date +%F-%H%M).tgz" matcher-testnet
sudo ls -la /opt/dcc/data/matcher-testnet          # record what is there

# 4. ⛔ Delete all state except account.dat and the config mountpoint
sudo find /opt/dcc/data/matcher-testnet -mindepth 1 -maxdepth 1 \
  ! -name account.dat ! -name config -exec rm -rf {} +
sudo ls -la /opt/dcc/data/matcher-testnet          # expect: account.dat (if it existed) + config only

# 5. Start and verify the identity did not change
docker start matcher-testnet
sleep 120   # start_period in compose/matcher.yml is 120s
POST_PK=$(curl -s http://127.0.0.1:6886/matcher | tr -d '"'); echo "post-reset matcher public key: $POST_PK"
[ "$PRE_PK" = "$POST_PK" ] && echo "IDENTITY OK" || echo "IDENTITY CHANGED -- STOP, restore the backup"
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:6886/matcher/orderbook   # expect 200
```

### Verify the matcher account is funded on the new chain

```bash
# from anywhere
MAIN=https://testnet-node.decentralchain.io
curl -s "$MAIN/addresses/publicKey/$POST_PK" | jq -r .address     # the matcher's address
curl -s "$MAIN/addresses/balance/31VMNVAvVh67dPZ41nMnYZvhoZFW7wwPrmq" | jq .balance
```

Pass: the address derived from `POST_PK` **is** `31VMNVAvVh67dPZ41nMnYZvhoZFW7wwPrmq` (the
genesis matcher account, 1B DCC at genesis), and its balance is about `1000000000000000`
minus fees. If the address differs, the matcher signs settlement with an unfunded key
(the 2026-07 "matcher unfunded account" class). Fix the account storage before taking
orders.

### Prove it settles

Place and cancel one small order through the exchange UI or `dcc-dex-cli`. Then
`curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:6886/matcher/orderbook/<amountAsset>/<priceAsset>`
should print `200`.

## Restart only (no re-genesis)

This is for an outage on the **same** chain, such as 2026-09-17. On start the matcher
replays its local event queue and snapshots.

```bash
# on the VPS, once node-scala-testnet is up and advancing
docker restart matcher-testnet
sleep 120
curl -s http://127.0.0.1:6886/matcher                                   # public key, same as before the outage
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:6886/matcher/orderbook   # 200
```

Then run [Verify the matcher account is funded](#verify-the-matcher-account-is-funded-on-the-new-chain)
and [Prove it settles](#prove-it-settles).

## Restore (if the identity changed)

```bash
docker stop matcher-testnet
sudo rm -rf /opt/dcc/data/matcher-testnet
sudo tar -C /opt/dcc/data -xzf /opt/dcc/backup/matcher-testnet.<stamp>.tgz
docker start matcher-testnet
```
