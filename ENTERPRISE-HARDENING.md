# DCC Testnet — Enterprise Hardening Roadmap

Status as of 2026-07-17. Owns the four workstreams agreed after the committee-recovery
incident. The urgent finality caveat is **already fixed** (see §0); the rest are staged
enterprise changes with clear go-points, runbooks, and rollbacks.

---

## §0 — DONE: finality caveat resolved (committee model)

**Problem:** finality was chunky/stalling. Deep diagnosis (node source + live logs) proved it
is a **consensus-aggregation** limit, not P2P: feature-25 finality is *miner-aggregated* with
*fire-once* endorsements. With all 3 nodes forging, the aggregator rotates every block and the
endorsement target changes before any block reaches 2/3 → stall. Connections were stable and all
3 endorsed throughout — it was never a NAT flap.

**Fix (infra PR #98, live):** block-producer + validator-committee model — **main is the sole
producer/aggregator; gen-0/gen-1 are committed endorsers** (`miner.enable=no`). Finality still
requires their 2/3 stake (main alone ≈29% < 2/3) → **decentralized + safety-critical**, and it is
**continuous** (single stable aggregator; verified lag=100 constant, advancing every block — the
protocol's one-period cadence). To get *fully decentralized block production* back **with** tight
finality, ship §3 (endorsement rebroadcast).

Fleet is **digest-pinned** to the canonical build `be2dcfc0` (`sha256:9d7d4f31…`) everywhere
(k8s `nodes.yaml` + the 3 VPS deploy workflows). Recover a gen node only via
`migrate-state-snapshot.yml` — the chain is un-resyncable from genesis (RUNBOOK IR-5).

---

## Recommended execution order

1. **§1 Committee HA** — remove the single-node SPOF + give finality 1-fault tolerance. *(cost decision)*
2. **§2 WireGuard mesh** — stable per-node P2P identity; mainnet-grade eclipse/DoS hardening. *(live rollout, phased)*
3. **§3 Endorsement rebroadcast** — re-enable all generators forging WITH tight finality. *(consensus rebuild + coordinated fleet re-pin)*
4. **§4 Custody + SSH** — stake off the hot key; harden remote access. *(key rotation)*

§1 first (cheap resilience). §2 before §3 so multi-producer finality is tested on a stable mesh.
§3 is the only one that changes consensus code — highest blast radius, do last among 1–3.

---

## §1 — Committee HA (node spread + stake rebalance)  →  MAINNET-LAUNCH ITEM (no testnet action)

**DECISION 2026-07-17:** leave the testnet LKE pool exactly as-is (1× g6-standard-4). Node type/sizing
is already deployed and fine — the only lever is node *count*, and paying for extra nodes purely for
committee redundancy is not warranted on testnet. **This is a mainnet-launch requirement, where HA is
non-negotiable.** No testnet change. (Everything below applies at mainnet launch.)

**Problem:** all 3 LKE pods run on ONE node (`192.168.168.125`) = single point of failure for the
whole finality committee. Worse, with current stake (main 2.18e15, gen-0/gen-1 2.68e15 each; 2/3 =
5.03e15) **only gen-0+gen-1 together clear 2/3** — losing *either* gen halts finality regardless of
node placement. So true fault-tolerance needs BOTH node spread AND stake rebalance.

**Design:**
- **Node spread:** `terraform/testnet.tfvars` `lke_node_count 1 → 3` (keep `g6-standard-4`, or 3×
  `g6-standard-2` to save cost). Soft anti-affinity (`role: generator`, already in `nodes.yaml`)
  then spreads gen-0/gen-1 to distinct nodes; optionally make it `required` with 3 nodes present.
  Apply via **`provision.yml`** (uses GH-secret Linode+R2 creds — no local creds needed). Pods
  reschedule; PVCs (Linode block volumes) reattach → data intact; expect a brief finality dip +
  re-commit (run `auto-commit-generators.yml` after).
- **Stake rebalance for 1-fault tolerance:** equalize stake across main+gen-0+gen-1 so ANY 2-of-3
  = 2/3 (tolerate one validator/node down). Transfer DCC (treasury/faucet) to top up main to ~match
  the gens (~2.51e15 each). Then losing any one validator keeps finality live.
- **Mainnet:** add a 4th validator for real BFT headroom.

**GO-POINT / DECISION:** recurring cost. 1×g6-standard-4 ($48/mo) → 3×g6-standard-4 (~$144/mo) or
3×g6-standard-2 (~$72/mo). **Needs cost sign-off before `provision.yml` apply.**

**Rollback:** `lke_node_count` back to 1 + `provision.yml`; stake transfer is one-way (testnet funds).

---

## §2 — WireGuard mesh (P2P hardening)  →  artifacts in `infra/wireguard/`

**Problem:** the committee P2P rides shared-egress NAT (Waves `max-single-host-connections` cap +
NAT/idle teardown). Not the finality cause (that's §0/§3), but the underlying fragility behind the
whole incident and a hard blocker for mainnet (no eclipse/DoS resistance, can't safely enable
blacklisting).

**Design (self-hosted WireGuard — NOT Tailscale):** private subnet `10.66.0.0/24` (main `.1`,
gen-0/1/val-0 `.11/.12/.13`), P2P over WG IPs, `PersistentKeepalive=25` (kills NAT/idle teardown).
Two critical findings from the design pass:
- The 3 gens share one node + `hostNetwork:true` → WG must be **per-pod (own netns)**, which means
  **dropping `hostNetwork`** on the gens (side effects flagged in `nodes-wg-patch.yaml`: probes,
  NetworkPolicies go live, metrics-exporter, native-sidecar k8s version).
- Shared NAT ⇒ WG transport is **hub-and-spoke** (main = hub/router with `ip_forward`+FORWARD),
  not gen↔gen direct. Keep the proven **concentrator P2P** (`known-peers` spokes→main only, main
  `known-peers=[]`, `enable-peers-exchange=no`). Full symmetric `known-peers` mesh is the exact
  simultaneous-initiation config that destabilized finality before — documented but opt-in only.

**Artifacts (drafts, nothing applied — Flux does not watch `wireguard/`):**
`peers.txt` (address/key plan + SOPS storage), `wg0-main.conf`, `wg0-spoke.conf.template`,
`gen-0-wg.secret.yaml` (SOPS skeleton), `nodes-wg-patch.yaml` (StatefulSet init/sidecar + hostNetwork
removal), `deploy-wireguard-vps.yml` (VPS workflow), `main.tf.firewall-patch` (Linode inbound+outbound
UDP 51820), `dcc.conf.network-patch`.

**Phased rollout (chain is LIVE — bring tunnels up first, switch P2P last, main last):**
0. Keys → SOPS + `push-secrets`. 1. Firewall (`tofu apply`). 2. Stand up tunnels only, verify
`wg show` handshakes + `ping` over WG while P2P still on public IPs (roll val-0 first). 3. Cut P2P
to WG one node at a time (val-0 → gen-0 → gen-1 → **main last**), verifying `/peers/connected` shows
WG addrs + finality keeps advancing, one finality window between each. 4. (Later) close public P2P ports.

**GO-POINT:** live-chain networking change + drops `hostNetwork`. Phased with per-node rollback
(a bad switch isolates one node, one-deploy revert; tunnels-first ordering prevents a committee-wide stall).

---

## §3 — Endorsement rebroadcast (re-decentralize block production)  →  ✅ DONE + LIVE (2026-07-17)

**DONE:** the endorsement-rebroadcast patch is built, validated on testnet, and LIVE. All 3 generators
forge AND finality is tight+continuous (lag 100, verified 28/30 advances over a 26-min hands-off window;
forgers main/gen-0/gen-1 balanced). Build: node-scala branch `feat/endorsement-rebroadcast` @ 84d1d98
(= be2dcfc0 + patch) → image `node-scala-testnet-be2dcfc0-endorse` (`sha256:db44d52f`), pinned fleet-wide.
Build fix: `publish-node-scala.yml` gained a `monorepo-ref` input; dispatch with the FULL 40-char SHA
`2c886b76999e658bf4fa058a290eacb40b83c1d3` (protobuf-schemas 1.6.3 era). Rollback = re-pin `be2dcfc0`
(`9d7d4f31`) + gens `enable=no`. **Ops lesson: judge finality on the SETTLED state after ~20min hands-off,
never on post-roll churn — an initial post-deploy stall self-heals (this is why the first attempt was
wrongly rolled back).** Follow-ups (non-blocking): merge the branch for provenance; fix the `v0.0.0`
version label (tag the branch v*); add `NNodesRotatingFinalizationTestSuite` (node-it) as a regression guard.

**Goal (achieved):** re-enable ALL generators forging WITH tight finality by fixing the fire-once-endorsement gap.

**Design (Option A, implemented on the branch):** bounded, idempotent periodic rebroadcast of a
node's OWN current-height endorsement, so a rotated aggregator still receives it in-window.
`BlockEndorser.rebroadcast()` re-emits already-signed bytes while the voting is live; self-terminates
on height advance; `Application` calls it every 3s. **Consensus-safe:** never re-signs (no
equivocation), aggregator `EndorsementStorage` dedups (idempotent), bounded by the height guard.
~15 lines across `BlockEndorser.scala` + `Application.scala`.

**Remaining before deploy (STAGED — branch not merged):**
1. **Build** off `be2dcfc0` with **`protobuf-schemas` pinned to 1.6.3** (DecentralChain monorepo
   commit `2c886b7699`) — this is the exact dep that failed the earlier rebuild. Add a `monorepo-ref`
   input to `publish-node-scala.yml` ON this branch (dispatch uses the dispatched ref's workflow copy).
2. **Test:** new `NNodesRotatingFinalizationTestSuite` (node-it) proving `height-finalizedHeight`
   stays bounded with all gens forging — A/B: interval-disabled (stalls, reproduces bug) vs enabled
   (bounded). Run on a resourced CI runner (node-it is memory-sensitive).
3. **Deploy:** consensus change → **coordinated whole-committee re-pin** to the new digest (all nodes
   together; then set gen-0/gen-1 `miner.enable=yes` again). Verify tight finality live.

**Rollback:** redeploy the `be2dcfc0` image (`sha256:9d7d4f31…`) — the change is image-scoped.

**GO-POINT:** consensus-code build + coordinated live redeploy. Highest blast radius; do after §2.

---

## §4 — Custody + SSH hardening (pre-existing mainnet-readiness)

- **Signing-key custody:** full stake currently sits on the hot generating key (seed in SOPS + node
  env). Design leasing/custody so the node holds only a minimal generating balance while the bulk is
  in cold custody (see `LEASING-CUSTODY-DESIGN.md`). Mainnet-critical (no slashing, so theft is the
  risk).
- **SSH access:** long-lived `TESTNET_DEPLOY_SSH_KEY` in GH secrets. Move to short-lived access
  (SSH-CA short-lived certs, or a bastion, or GitHub OIDC→broker) so no long-lived key exists. See
  `MAINNET-READINESS.md` item #2 (SSH accept-with-mitigations was chosen interim).

**GO-POINT:** key rotation + custody changes touch signing/deploy identity — coordinate + verify no lockout.

---

## Cross-cutting guardrails
- Fleet stays **digest-pinned**; intentional image changes go through `pin-node-image-digest.yml`
  (k8s) + the 3 VPS deploy workflows, never the mutable `node-scala-testnet-latest` tag.
- Gen-node recovery = `migrate-state-snapshot.yml`, never `resync-gen-nodes.yml` (RUNBOOK IR-5).
- Every phase above has an explicit rollback; never switch the aggregator (main) or deploy consensus
  code without a verified prior step.
