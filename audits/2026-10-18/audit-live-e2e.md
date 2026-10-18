# DCC Testnet Live E2E Feature Audit, 2026-10-18

Scope: real transactions on testnet (chain `!`), node `DecentralChain v1.8.0`, matcher `0.0.0-20261010T014227`. The run covered heights 73261 to ~73315.
Accounts: four fresh throwaway accounts (A `31daBZ6v4E4RcwkrSVetg1UiCamFegQgbBh`, B `31LfyMt9PfLjzCaMi68Exiu7THjoBvahts9`, C `31JHA1sEv9d5bAsUBzgNdAgWtBtACYysTsG`, D `31UsypkhE9UXKDFZ9t92BVtC2CP571gDx79`), plus two more created during the run (E and an Ethereum key).
Funding: **one** faucet request, POST `https://testnet.decentralscan.com/api/faucet`, which returned 10 DCC in tx `C7MZBij4f1orXNa42sLktWaLKco1YLnXgKt6uMwvGhkc` and confirmed at h73262. Total spend was about 3.07 DCC, mostly the issue and set-asset-script fees of 1 DCC each.
No generator, matcher or faucet keys were used. No service config was touched.

Why the e2e suite was not run: `admin-e2e.yml` funds it from `secrets.GEN_0_SEED_PHRASE`, a generator account, which is out of bounds. Every flow was hand-written with the repo SDK instead (`@decentralchain/transactions` dist, `ts-lib-crypto`, `node-api`). Scripts and raw JSONL results are in `scratchpad/live/` (`p1..p5.mjs`, `results.jsonl`).

Measurement method:
- **confirm**: time from broadcast to `/transactions/info` returning a height. This is liquid (microblock) state.
- **finalize**: time from broadcast until tx height <= `/blocks/height/finalized`.
- **DS**: the tx is visible at `/v0/transactions/<type>/<id>` (time measured from broadcast).
- **Explorer**: SSR page `/transaction?id=` returns 200 and contains the id.

## Results table

| # | Feature | Result | Tx id(s) | Height | Confirm | Finalize | DS | Explorer | Notes |
|---|---|---|---|---|---|---|---|---|---|
| 1 | Faucet | PASS | C7MZBij4f1orXNa42sLktWaLKco1YLnXgKt6uMwvGhkc | 73262 | - | - | yes | - | 10 DCC. **No CAPTCHA enforced**: the request had no token and was accepted (see L1) |
| 2 | Transfer | PASS | 8ENRXzV4DJnQB8Hv2vhjRduEoRwdLcddisq32tRM8ENL | 73263 | 1.7s | 85.8s | yes | yes | |
| 3 | Chained spend: child broadcast while the parent is only in the UTX | REJECTED (by design) | parent 8ENRX…, child FnTDn2mmgb44jTP8QMyyHBYo7VH6LufH5y9SjUHo3Wf7 | - | - | - | - | - | 400 "negative dcc balance … current balance equals 0". The UTX validates against liquid state, not against other UTX txs (Waves semantics). See L2 |
| 4 | Chained spend: child broadcast right after the parent reached a microblock | PASS | parent 7u1AKFn9LqYnA7GfsAsp41R2iNpvobysCJLZPtKiALhb (h73307), child GxVywq5JvrqMQ9qoM78uTtFb2HGj325KFAvrNDp7r5Hj | 73308 | 1.4s | 107.5s | - | - | Accepted immediately. Not evicted, not delayed |
| 5 | Mass transfer (2 recipients) | PASS | ENYZwiT4CGzRNXdrt35eKLvV9Cxe3Fbetgbm3fRNBDh | 73266 | 3.0s | 91.9s | 3.3s | yes | Balances exact |
| 6 | Issue asset (AUDT, 2 decimals) | PASS | 9P2QmU7sGFLKTpECnBkfaZgXp6pGJ6hQvLvQ8fBRb6LF | 73270 | 1.4s | 112.2s | 1.8s | yes (asset page too) | Fee 1 DCC |
| 7 | Reissue (+500000) | PASS | BGRVrggenUwpmVtE58t65cUGPxnBCALy8QkkwzAsSm7t | 73273 | 1.4s | 68.7s | 1.7s | yes | |
| 8 | Burn (-100000) | PASS | aXKyqAVx9EDCZceT77YA9q15JQNVyrnegkCPkGvZcSm | 73276 | 2.0s | 42.2s | 2.1s | yes | Final quantity 140000000 matches expected exactly |
| 9 | Sponsorship (minSponsoredAssetFee=1) | PASS | A1RMPYgGxm6cbfNTfVT8f2LHuGgWBHdnatrVpbWhYp1S | 73279 | 2.0s | 174.1s | 2.3s | yes | DS shows minSponsoredFee=1 |
| 10 | Transfer with fee paid in the sponsored asset (B to C) | PASS | A6w8gpVQYKD4Vg1baRCqCHXTpx4oN22Lcp5xedx1JYd7 (asset funding 6ub1aErojXqUUD4Y7mES8Lt9fj4f7xoEm9pm38CrsYgc) | 73285 | 2.0s | 60.0s | 2.3s | yes | Accounting exact: B DCC delta 0, sponsor A DCC delta -100000, A asset delta +1 |
| 11 | Update asset info (rename AUDT to AUDT2) | PASS | 8jDhK2HG1y5XTveEqAFByxrAocG2NKo3455PHfssqkpz | 73297 | <2s | - | yes (DS name=AUDT2) | yes (asset page shows AUDT2) | Allowed only ~27 blocks after issue, so testnet min-update interval is small. See I2 |
| 12 | Issue smart asset (script `true`) | PASS | GVsjXbQfxCLmGAShxKnEXYWyVX6qcSznSFGAE4tBVzZp | 73288 | 22.3s | 111.0s | 22.6s | yes | 22s confirm was one slow block (64s gap), same as rows 15 and 16 |
| 13 | Set asset script (transfer amount <= 1000) | PASS | 6D18vi8zT6YHNCw61FDVqTFkqeRqHnjda19vsqzrsbW7 | 73291 | 1.4s | 80.1s | 1.8s | yes | Allowed transfer G7C9vPPCK5yK6Yo1G4yGXcxCHKYo8ACffgCf3PnrfFxT (h73294) went through. A 5000 transfer was rejected with "Transaction is not allowed by token-script" (error 308), as intended |
| 14 | Lease (0.2 DCC D to B) | PASS | 983XrCtY33WEn5VGcspBWAibMyVKjbyYasvTFErCmvuF | 73270 | 1.7s | 112.2s | 2.0s | yes | B effective balance +20000000. `/leasing/active` count 1 |
| 15 | Lease cancel | PASS | DXKmEXjFZSLPaHtHSeer7tJJ1L3isqxuBjs1ZLuSVDAY | 73273 | 1.4s | 69.0s | 1.7s | yes | `/leasing/info` status=canceled, cancelHeight 73273 |
| 16 | Create alias (`auditmve058l1`) | PASS | BUqunNer6sXJAmSHg7WrAtmEnYZ8Dx9kzDdqod7t7LMw | 73270 | 1.4s | 112.1s | 1.8s | yes | Node `/alias/by-alias` and DS `/v0/aliases/<alias>` both resolve to A |
| 17 | Transfer to alias (C to `alias:!:auditmve058l1`) | PASS | 8WaZXEUoCj4gaDA6cFL8ApXxDxhqArVxqcrrLt78ywXE | 73273 | 1.4s | 68.7s | 1.7s | yes | A credited |
| 18 | Data tx (int/bool/string/binary) | PASS | BUUaFvpfvStaBz96ts95eEXeAdAY9bzCMRpb4PHmApf8, update FXGKbYqs3edWxUjAHfbj9SFCTKMVPWgymMh9uVydgz91 | 73270 / 73303 | 1.4s / 3.8s | 112s / 169s | 1.8s / 4.1s | yes | All 4 types read back exactly from `/addresses/data` |
| 19 | Set account script (verifier: transfers <= 0.01 DCC plus sigVerify) | PASS | 6KRzfLkK1DJU7Fg8T2soN2kzRQ4BvcQx5aNs66utB3YN | 73288 | 22.3s | 110.9s | 22.6s | yes | Complexity 184, extraFee 0 |
| 20 | Scripted-account tx | PASS | allowed JXYnGUsQFEeNxtu1ES64y6tih2kGs3pBS8s4LprDB48 (h73291), also DHtwCCa4e2yTNQKdAhGRyTxJ7dz1qYPEyEw9EQPe11a5 at fee 0.001 | 73291 | 1.5s | 80.3s | 1.8s | yes | A 0.02 DCC transfer was rejected with "Transaction is not allowed by account-script" (error 307), as intended. A minimum-fee (0.001) tx from the scripted account was accepted, because RideV5+ adds no extra fee for verifier complexity <= 200 (I1) |
| 21 | Set dApp script | PASS | 9wTXYGMA26Ug4nTE5WQqbcd4jgovYZXfWxaoDNkd59Mm | 73288 | 22.3s | 110.9s | 22.6s | yes | |
| 22 | Invoke script with payment (deposit 0.1 DCC) | PASS | DuJqzmHDnE5YVECxtC6t6tcdo5qc9e6L23B1LUm8qvDK | 73291 | 1.6s | 80.2s | 1.9s | yes | dApp state key = 10000000. B -10500000 (payment plus fee), dApp +10000000 |
| 23 | Invoke with ScriptTransfer (withdraw 0.04) | PASS | CQqLwjTU6RkWXBTW5NC9ddK5Ug6zh5kXq7nDaTArwoUy | 73294 | 0.8s | 77.9s | 1.4s | yes | stateChanges show transfer 4000000 to B and data 6000000. Over-withdraw throw was rejected with "Error while executing dApp: insufficient deposit" (error 306) |
| 24 | DEX: place unfilled limit order, then cancel | PASS | order 9uzPKDgn599qgFeMUWeigLoLRz9T5xuNCden2SznfSdL | - | - | - | - | - | OrderAccepted, visible in orderbook asks. Cancel returned OrderCanceled; status became `Cancelled` |
| 25 | DEX: crossing sell (A) and buy (B), AUDT/DCC 10 @ 0.01 | PASS | sell 9Ak6GPKHRpfUuon35JKpSTBTKFe2hkWHJkA16WHePce, buy 53pPEbC2yu7Kaz79aooSXDgQUiNVtNjkjUnFsjgVREcm | - | fill 257ms | - | - | - | Both `Filled` (filledAmount 1000, filledFee 300000). `/matcher/orderbook/.../status` lastPrice correct |
| 26 | ExchangeTransaction settles on chain | PASS | 5DRBqSnwkQhNxrz6XMMdZg1x1PGkBbM2i8D3yJAk92Gz | 73300 | 1.8s | 61.4s | yes* | yes | Deltas exact: A asset -1000, B asset +1000, A DCC +9700000 (0.1 minus 0.003 fee), B DCC -10300000. *DS was checked only after finality, so its true lag was not measured (other txs show about 2s) |
| 27 | DS candles for the trade | PARTIAL / FAIL | - | - | - | - | - | - | Without `matcher=` the candle for 16:06 is empty (txsCount 0). With `matcher=31VMNVAvVh67dPZ41nMnYZvhoZFW7wwPrmq` the candle is correct (o/h/l/c 0.01, volume 10). See M2 |
| 28 | DS pairs | FAIL | - | - | - | - | - | - | `/v0/pairs/<asset>/DCC` returns **HTTP 500**. `/v0/pairs?limit=3` returns an empty list. `/v0/pairs?pairs=` returns `data:null`. See M1 |
| 29 | Matcher websocket (`/ws/v0`) | PASS | - | - | - | - | - | - | `obs` subscription returned an orderbook snapshot that includes the last trade (0.01, 10, buy) |
| 30 | websocket-api (`wss://testnet-ws.decentralchain.io/ws`) | **FAIL** | - | - | - | - | - | - | Connects, pings, and returns "Invalid topic" for a bad topic. **Zero `subscribed`/`update` frames** for 7 valid topics across two sessions (~4 min total) while about 10 matching txs confirmed. See H1 |
| 31 | Ethereum EIP-155 transfer (type 18) | PASS | eth 0x88f436c3e67f9bb44097c3b60f5c331c06c18af9c9020e0bdfd1385ff306062a / DCC ADcRzegEFDz6PKD4kq14Szr9zLaH3e6jDcivcCVb3NPB | 73311 | 2.0s | 76.4s | yes (`/v0/transactions/ethereum-like/<id>`, `/all/<id>`) | yes | Recipient +100000. Sender charged 100000 fee exactly. `eth_getTransactionReceipt` returns the receipt |
| 32 | Explorer address page | PARTIAL | - | - | - | - | - | - | `/address?addr=` returns 200 with the address. The alias and tx list are not in the SSR HTML (they load client-side), and the client side was not verified |

Latency summary:
- Confirmation to liquid state: 0.8-3.8s in 26 of 29 measured txs. The rest took 22s, all in one slow block.
- Time to finalize: 42-174s, median about 85s.
- Block intervals sampled at h73290-73300: 17, 51, 6, 25, 7, 9, 64, 37, 14, 56s, a mean of about 29s with very high variance. The finalized height trails the tip by 0-3 blocks.
- DS indexing: about 1.4-4.1s after broadcast, effectively real time.

## Findings

### H1, HIGH: websocket-api emits no updates. It is effectively dead on testnet.
Evidence:
- Topics subscribed: `topic://transactions?type=all&address=<A>`, `…?type=all&address=<B>`, `…?type=exchange&address=<A>`, `…?type=transfer&address=<B>`, `topic://state/<C>/int`, `topic://state/<C>/str`.
- Matching txs confirmed while subscribed (DEX trade, a data update of `int`, 3 transfers involving A and B) produced 0 frames other than `ping`.
- A bad topic returns `{"type":"error","message":"Invalid topic"}`, so the server is up and parsing frames.
- The exchange wallet's `useTransactionStream` and `useStateSubscription` therefore never receive live data.

Probable root cause (from code; not verified on the server because there is no host access):
- BPS loads its whole config with `envy::prefixed("BPS_")` (`DecentralChain/apps/blockchain-postgres-sync/src/lib/config/consumer.rs:80`). The Redis field is `redis_url`, so the expected env var is **`BPS_REDIS_URL`**, which is also what the BPS README documents (line 103).
- Infra writes **`REDIS_URL`**: `infra/.github/workflows/push-secrets.yml:190` and `infra/scripts/push-secrets-local.sh:165`. Its comment says "BPS reads REDIS_URL", which is wrong.
- `infra/compose/blockchain-postgres-sync.yml` does not map it either.
- The result is that BPS logs "REDIS_URL not set — Redis publishing disabled" (`src/bin/consumer.rs:50`) and never PUBLISHes. The websocket-api only learns values from those PUBLISHes (`updater.rs` psubscribe `topic://*`), so new subscriptions wait forever for a first value.

Verify: `docker logs blockchain-postgres-sync-testnet | grep -i redis`.
Fix: emit `BPS_REDIS_URL` in both push-secrets paths. The scanner faucet's `REDIS_URL` should stay as it is.

Secondary issue: multitopic subscriptions (`topic://state?address__in[]=…`) need a Redis key that lists the subtopics. Nothing in BPS writes that key; it only publishes. So multitopic subscriptions can never resolve even after the fix above.

### M1, MEDIUM: Data-service pairs are broken. Single-pair lookups return 500 and the pairs list is empty.
- `/v0/pairs/9P2Qm…/DCC` returns 500 "Internal Server Error", with and without `matcher=`. The reverse order also returns 500.
- `/v0/pairs?limit=3` returns `data: []`, even though exchange txs exist (DS `/v0/transactions/exchange` lists 5DRBq…).
- The pairs table is fed by the pairs daemon (`DecentralChain/apps/data-service/src/daemons/pairs`). `infra/compose/data-service.yml` defines no pairs-daemon service, so it appears never to be deployed.
- The 500 itself is a bug: a missing pair should return 404 or `null`.
- Impact: DEX market lists and pair stats that rely on DS pairs are empty.

### M2, MEDIUM: DS candles are empty unless `matcher=` is passed. DEFAULT_MATCHER appears wrong on testnet.
- `/v0/candles/<asset>/DCC?interval=1m&timeStart=…` returns txsCount 0 for the trade minute.
- The same query with `&matcher=31VMNVAvVh67dPZ41nMnYZvhoZFW7wwPrmq` (the live matcher's address, derived from `BEtB5b2k…`) returns the correct candle.
- The candles are computed correctly; it is the default matcher filter that misses them. `variables.env.example` uses `3MNXvMCn9FxPPjc4oe9oRGUSMDBXoQvUAdr`.
- The exchange's `useMarketStats24h` (`apps/exchange/src/api/services/matcherService.ts:643`) calls candles **without** `matcher`, so testnet 24h stats will always show empty.
- Fix: set the testnet DS `DEFAULT_MATCHER=31VMNVAvVh67dPZ41nMnYZvhoZFW7wwPrmq`, which must match the matcher key rotated 2026-10-09.

### L1, LOW: The testnet faucet does not enforce CAPTCHA.
- POST `/api/faucet` with only `{address}` succeeded.
- `DCC_RECAPTCHA_SECRET` is unset, so the check is skipped, and the rate limit is per address only.
- Anyone can drain 10 DCC per freshly generated address, without limit. That is acceptable for testnet, but note it for mainnet-like environments.

### L2, LOW / informational: A dependent tx is rejected while its parent is only in the UTX.
- If the child is broadcast before the parent reaches a microblock, the node returns 400 "negative balance".
- Once the parent is in liquid state, the child is accepted immediately and mined in the next block (row 4). The earlier eviction and long-delay problem (node-scala #68-#73) did **not** reproduce.
- Clients and SDK users must wait for parent confirmation, not just a 200 broadcast. The SDK helpers do this; document it for integrators.

### L3, LOW: Block interval variance is high and finality is slow.
- Block gaps ranged 6-64s and time to finalize was 42-174s.
- When a tx lands just before a long gap, user-perceived confirmation spikes. One microblock took 22s (rows 12, 19, 21).
- Not a failure, but worth knowing for "fast finality" claims.

### I1, INFO: Smart-account txs need no extra fee at verifier complexity <= 200.
This is RideV5+ semantics and is expected. A 0.001 DCC transfer from a scripted account was accepted.

### I2, INFO: UpdateAssetInfo was accepted about 27 blocks after issue.
The testnet `min-asset-info-update-interval` must be small. Confirm that this is intended and differs from the mainnet setting.

### I3, INFO: The DS route for type 18 is `/v0/transactions/ethereum-like/<id>`.
`/ethereum/<id>` returns 404. Ethereum txs are not in `/v0/transactions/transfer?recipient=` results, so a wallet history built from typed DS lists will miss incoming Ethereum transfers.

## PASS list
Faucet, transfer, chained spend after liquid confirm, mass transfer, issue, reissue, burn, sponsorship plus a sponsored-fee transfer, update asset info, smart asset issue, set asset script (with its rejection path), lease, lease cancel, alias plus transfer to alias, data tx, set account script plus scripted-account tx (with its rejection path), dApp set script, invoke with payment, invoke with ScriptTransfer (with throw rejection), DEX place/cancel, DEX match to Filled, on-chain Exchange settlement, matcher WS, Ethereum EIP-155 transfer plus eth RPC receipt. DS and explorer reflected every tx within seconds.
