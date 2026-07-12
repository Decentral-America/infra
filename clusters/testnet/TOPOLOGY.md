# Testnet Topology & Deploy Paths (READ BEFORE ANY NODE CHANGE)

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
