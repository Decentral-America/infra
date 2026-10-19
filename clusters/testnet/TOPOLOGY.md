# Testnet Topology & Deploy Paths (READ BEFORE ANY NODE CHANGE)

Regenerated 2026-10-18 from live chain data at height 74869 (period starting at 74801).
Balances drift with fees and transfers; re-run the generator in the infra wave-4 plan to refresh.

**What DCC is:** a sovereign Layer-1 with its own token (DCC), consensus and genesis. Testnet chain ID `!`
(byte 33), ~30s average block time (min 5s), FairPoS V2 + LPoS, finality via T0 DeterministicFinality
(feature 25) with T2 HotStuff **authoritative on testnet** (`hotstuff.authoritative = true`, see `RUNBOOK.md`
Scenario E).

## Nodes

| Node | Address | Substrate | Role | Deploy path |
|------|---------|-----------|------|-------------|
| **main** | `31RPEKcz71a3hdxt8z7qLhTpRMuRV2kUyr6` | VPS `50.116.30.244` (Linode Dallas), docker compose, host network | generator + public API (`testnet-node.decentralchain.io`) + co-located matcher, BPS, data-service, websocket, scanner, admin, redis, postgres, monitoring | `update-node-image.yml` / `deploy-node-config.yml` → `scripts/node-up.sh` → `compose/node-scala.yml`, digest from `node-config/testnet/vps-image.env` |
| **gen-0** | `31PmKNdHAU5sZbtg8TrzKh8WfE7E8xBc9WD` | LKE 663401 `dcc-peer-testnet` (Frankfurt), StatefulSet `dcc-gen-0`, P2P 6863 | generator | Flux GitOps — `clusters/testnet/apps/nodes.yaml` |
| **gen-1** | `31dLhqhGoGVhtkf5msWFmgZn1ErrVR6b9qV` | LKE, StatefulSet `dcc-gen-1`, P2P 6864, REST 6870 | generator | Flux GitOps — `nodes.yaml` |
| **val-0** | `31XTtK5S8b1DigEB4LCkgrCHHcU7qXPpSbV` | LKE, StatefulSet `dcc-val-0`, P2P 6865 | generator (funded 2026-10-10; it forges and self-commits like the others) | Flux GitOps — `nodes.yaml` |

All four commit themselves to each generation period in-process (`self-commit-to-generation = yes`).
The LKE nodes share the single worker's public IP (hardcoded in `nodes.yaml` and main's `dcc.conf`; after a
worker recycle run `scripts/set-lke-node-ip.sh`, `RUNBOOK.md` Scenario A). Main has `known-peers = []` and
peer exchange off; the LKE nodes dial main.

## Stake and fault tolerance

Finality needs endorsements from at least 2/3 of the committee's generating balance. The stake rebalance of
2026-10-18 (AUD-182) is complete: gen-0, gen-1 and val-0 each transferred part of their stake to main
(val-0's transfer `qTJTcdoGqQoS8Ftr91phCoZKXbNzmmKUhYVvMXwHaWG` at height 74593). Generating balances mature 1000 blocks after a transfer, so the committee's generating share reaches the effective share from height 75593 (current generating share of main: 68.4%, already above 2/3).

| Node | Address | Generating balance, period 74801 (DCC) | Share | Effective balance, post-rebalance (DCC) | Share |
|------|---------|-----|-----|-----|-----|
| **main** | `31RPEKcz71a3hdxt8z7qLhTpRMuRV2kUyr6` | 46,737,428 | 68.4% | 59,748,369 | 73.4% |
| **gen-0** | `31PmKNdHAU5sZbtg8TrzKh8WfE7E8xBc9WD` | 7,286,316 | 10.7% | 7,288,995 | 9.0% |
| **gen-1** | `31dLhqhGoGVhtkf5msWFmgZn1ErrVR6b9qV` | 7,220,729 | 10.6% | 7,223,109 | 8.9% |
| **val-0** | `31XTtK5S8b1DigEB4LCkgrCHHcU7qXPpSbV` | 7,121,030 | 10.4% | 7,121,650 | 8.8% |
| **total** | | 68,365,504 | 100% | 81,382,123 | 100% |

- main holds **73.4%** of the committee stake after the rebalance, about 59,748,369 DCC (≥ 2/3: main alone can finalize); gen-0, gen-1 and val-0 about 7,288,995, 7,223,109 and 7,121,650 DCC.
- gen-0 + gen-1 + val-0 together hold **26.6%** (< 2/3: the three LKE nodes together cannot finalize without main).
- **Losing main halts finality by design** (operator decision, stake rebalance of 2026-10-18, register AUD-182).
  Blocks keep coming only while main is up, too: the LKE miners run `quorum = 1` and their only peer is main.
  The cluster is a k8s testbed; main is the authoritative node.

## Other funded accounts

| Account | Address | Balance (DCC) |
|---------|---------|---------------|
| Faucet (scanner `/api/faucet`) | `31XRiENNF6qbyHBQssRNP4GwTR4KTAokYGC` | 999,980 |
| Treasury (admin-dashboard Load Test) | `31cs1eQss3CWFuYrDHpgct3FwMAFkWzSe3T` | 50,000 |
| Matcher account (pubkey `BEtB5b2kX8Yge4sb5RRbTUqd5Va8Ah8PhphowcW31z6Y`) | `31VMNVAvVh67dPZ41nMnYZvhoZFW7wwPrmq` | 10,000,000 |

## The rule: image changes go through ONE flow

1. `pin-node-image-digest.yml` resolves the node-scala ref to a digest, tags it `testnet-pinned-<rev>` (GHCR
   cleanup never deletes those) and opens a PR pinning `nodes.yaml` ×3 + `vps-image.env`.
2. Roll that PR with `runbooks/staggered-node-rollout.md`: suspend Flux (parent first), main via
   `update-node-image.yml --ref <pin-branch>`, then each LKE node via `scripts/roll-testnet-node.sh`, **merge last**,
   resume Flux.

CI (`scripts/check-digest-parity.sh`) fails if the VPS and LKE pins differ (rule D6). There is no tag-based path:
`deploy-specific-sha.yml` and `deploy-testnet-release.yml` were removed, `deploy-container.yml` refuses `node-scala`,
and `compose/node-scala.yml` accepts only a digest.

**Never use `restart-host-network.yml`** unless you mean to wipe main's chain data.

## Public endpoints

| Service | URL |
|---------|-----|
| Node REST API | `https://testnet-node.decentralchain.io` |
| Block explorer + faucet | `https://testnet.decentralscan.com` (faucet: `/faucet`) |
| Data service | `https://testnet-data-service.decentralchain.io` |
| DEX matcher | `https://testnet-matcher.decentralchain.io` |
| WebSocket | `wss://testnet-ws.decentralchain.io/ws` |
| Exchange | `https://testnet.decentral.exchange` (not `decentral.exchange`, which is mainnet) |
| Admin dashboard | `https://testnet-admin.decentralchain.io` |
| Grafana | `https://grafana.testnet.decentralchain.io` |

## Verifying a release

- Main: `ssh deploy@50.116.30.244 'docker inspect -f "{{.Config.Image}}" node-scala-testnet'` equals `vps-image.env`.
- LKE: `kubectl -n dcc get pods -o jsonpath='{range .items[*]}{.metadata.name} {.status.containerStatuses[0].imageID}{"\n"}{end}'`.
- Health: Prometheus/Grafana (`dcc_finality_lag`, `dcc_hotstuff_lag`, `dcc_block_height` per node); do not poll REST in a loop.
