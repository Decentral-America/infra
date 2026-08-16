# Testnet Topology & Deploy Paths (READ BEFORE ANY NODE CHANGE)

**What DCC is:** a sovereign Layer-1 with its own token (DCC), consensus, and genesis — not connected
to any external chain. Testnet chain ID `!` (byte 33), total supply 100,000,000 DCC, ~30s average block
time (min 5s), FairPoS V2 + LPoS consensus, finality via T0 DeterministicFinality (feature 25,
authoritative) + T2 HotStuff (authoritative on testnet only, see `RUNBOOK.md` Scenario E). P2P port 6868
(Newark) / 6863-6865 (Frankfurt LKE); REST API port 6869 per node (gen-1 uses 6870).

The testnet is **not** a single substrate. Treating "the 3 nodes in `nodes.yaml`" as the whole network is
the exact mistake that causes half-deploys and mixed protocol versions. Full inventory:

| Node | Address | Substrate | Role | Deploy path |
|------|---------|-----------|------|-------------|
| **Main** | `31RPEKcz71a3hdxt8z7qLhTpRMuRV2kUyr6` | **VPS** (SSH, `docker run --network host`) | generator (~26% blocks) **+ public API** (`testnet-node.decentralchain.io`) + co-located matcher / BPS / redis / postgres | SSH + `docker run`; config at `/opt/dcc/config/node-testnet/dcc.conf` |
| **gen-0** | `31PmKNdHAU5sZbtg8TrzKh8WfE7E8xBc9WD` | **LKE k8s** | generator (~37%) | Flux GitOps — `apps/nodes.yaml` |
| **gen-1** | `31dLhqhGoGVhtkf5msWFmgZn1ErrVR6b9qV` | **LKE k8s** | generator (~36%) | Flux GitOps — `apps/nodes.yaml` |
| **val-0** | (non-mining) | **LKE k8s** | validator / sync | Flux GitOps — `apps/nodes.yaml` |

> The **Main node is a committed generator** — its stake counts toward the 2/3 finality/HotStuff quorum.
> Any consensus change (e.g. enabling HotStuff) that skips it will fail to reach quorum network-wide.

**Plugin JARs** (`/opt/dcc/plugins/testnet/`, built from source at `Ecosystem/matcher`): `ext.jar`
(registers BlockchainUpdates + DEXExtension) and `grpc.jar` (`DccBlockchainApiGrpc` stubs + DEX gRPC +
14-field `Block$Header`).

**Main node specifics:** host `66.228.55.154`, P2P port `6868`, REST via Caddy at
`https://testnet-node.decentralchain.io`. SSH: `ssh -i <deploy_key> deploy@66.228.55.154`
(verified 2026-08-13 — login user is `deploy`, not `root`). Config: `/opt/dcc/config/node-testnet/dcc.conf`.
Compose: `/opt/dcc/compose/node-scala.yml`. Newark is **not** GitOps — use `deploy-node-config.yml` for
config changes, never hand-edit on the host. **Never use `restart-host-network.yml`** — it wipes chain
data; use `update-node-image.yml` (or `deploy-testnet-release.yml`, see below) instead.

**Public endpoints:**

| Service | URL |
|---------|-----|
| Node REST API | `https://testnet-node.decentralchain.io` |
| Block explorer | `https://testnet.decentralscan.com` |
| Data service | `https://testnet-data-service.decentralchain.io` |
| DEX Matcher | `https://testnet-matcher.decentralchain.io` |
| Exchange | `https://testnet.decentral.exchange` (not `decentral.exchange` — that's mainnet) |
| Admin dashboard | `https://testnet-admin.decentralchain.io` |
| Faucet | `https://testnet.decentralscan.com/faucet` |
| Grafana | `https://grafana.testnet.decentralchain.io` |
| WebSocket | `wss://testnet-ws.decentralchain.io/ws` |

**Token distribution (generators + faucet):**

| Address | Label | Balance (approx., drifts with fees/txs) |
|---------|-------|------|
| `31RPEKcz71a3hdxt8z7qLhTpRMuRV2kUyr6` | Main node (Newark) | ~26.7M DCC |
| `31PmKNdHAU5sZbtg8TrzKh8WfE7E8xBc9WD` | gen-0 (Frankfurt) | ~26.7M DCC |
| `31dLhqhGoGVhtkf5msWFmgZn1ErrVR6b9qV` | gen-1 (Frankfurt) | ~26.7M DCC |
| `31XRiENNF6qbyHBQssRNP4GwTR4KTAokYGC` | Faucet (Newark) | ~1M DCC |
| `31cs1eQss3CWFuYrDHpgct3FwMAFkWzSe3T` | Treasury (admin-dashboard Load Test, created 2026-08-13) | 50,000 DCC |

## The rule: image changes go through ONE workflow
**`deploy-testnet-release.yml`** is a thin orchestrator that **calls the existing battle-tested
workflows** (it does not reimplement them) with the same image ref, so both substrates move together:
`deploy-specific-sha.yml` (VPS main node, SSH) + `pin-node-image-digest.yml` (k8s swarm — resolves the
ref to an immutable digest and PRs `nodes.yaml` → Flux on merge). One dispatch, one image ref, all nodes.

- ✅ **Do:** `Actions → Deploy Testnet Release → image_ref=<tag|digest>`. One digest, all nodes.
- ❌ **Don't** hand-edit `nodes.yaml`, or run `update-node-image.yml` / `deploy-specific-sha.yml` /
  `pin-node-image-digest.yml` in isolation for an image change — each touches only one substrate and
  reintroduces drift. (They remain for single-node emergency/repair use only.)

## Why two mechanisms exist
Organic growth: the Main node + matcher/DEX stack started on one VPS (stateful, co-located services,
host networking); the generator fleet was later added on managed LKE k8s. Two substrates, two deploy
paths, historically no shared source of truth for the image → drift.

## North star (recommended consolidation)
Fold the VPS Main node + matcher stack into the k8s cluster (StatefulSet + PVC for chain state, matcher
as its own Deployment, ingress for the public API). Then the whole testnet is one GitOps substrate,
`deploy-testnet-release.yml`'s SSH step disappears, and everything is digest-pinned in git. Until that
migration lands, `deploy-testnet-release.yml` is the guardrail that keeps the two substrates in lockstep.

## Verifying a release
- VPS (public): `curl -s https://testnet-node.decentralchain.io/node/status` — `hotStuffFinalizedHeight`
  appears here once HotStuff is enabled and committing.
- k8s gen nodes: `kubectl -n dcc logs deploy/dcc-gen-0 | grep "T2 HotStuff coordinator ENABLED"`, or the
  Prometheus/Grafana stack (`dcc_finalized_height`, `dcc_hotstuff_finalized_height`) — do **not** poll
  REST in a loop; the exporter already scrapes once per interval.
