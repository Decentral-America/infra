# DCC Testnet LKE Cluster — Disaster Recovery Runbook

## Prerequisites

```bash
# kubeconfig for LKE cluster 663401 (dcc-peer-testnet, Frankfurt), fetched from the Linode API:
CID=$(curl -fsS -H "Authorization: Bearer $LINODE_TOKEN" https://api.linode.com/v4/lke/clusters \
  | jq -r '.data[] | select(.label=="dcc-peer-testnet") | .id')
curl -fsS -H "Authorization: Bearer $LINODE_TOKEN" "https://api.linode.com/v4/lke/clusters/$CID/kubeconfig" \
  | jq -r .kubeconfig | base64 -d > ~/.kube/dcc-testnet.yaml
chmod 600 ~/.kube/dcc-testnet.yaml
export KUBECONFIG=~/.kube/dcc-testnet.yaml
```

---

## Scenario A — LKE Worker Node Terminates or Is Recycled

**Symptom:** `kubectl get nodes` shows the worker `NotReady` or gone; pods `Pending`; `LkeGeneratorsDown` fires.

**Why "recycle and wait" is not enough:** the pool has ONE worker (`lke_node_count = 1`) running gen-0, gen-1
and val-0 with `hostNetwork: true`. A recycled worker gets a **new Linode ID and a new public IP**, and:

- the IP is hardcoded in `clusters/testnet/apps/nodes.yaml` (`declared-address` ×3, `blacklist-exempt` ×3) and in
  main's `node-config/testnet/dcc.conf` (`blacklist-exempt`); `scripts/set-lke-node-ip.sh` rewrites all of them;
- the LKE Cloud Firewall attaches **by Linode ID** (`terraform/lke.tf` `linode_firewall.lke_nodes`): until
  `provision.yml apply` the new worker runs with NO cloud firewall (kubelet 10250 and NodePorts public);
- the VPS egress rule `allow-lke-exporter-out` (`terraform/main.tf`) and the Prometheus `lke-chain` target
  (`deploy-monitoring-stack.yml` → `file_sd/lke-chain.json`) still point at the old IP.

**Volumes:** chain-data PVCs use `linode-block-storage-retain`. Retain protects against a pod/PVC delete, NOT an
account-level action: on 2026-10-01 Linode's deletion removed the volumes too. A node that lost its volume
re-syncs from main over P2P (IR-5).

**Recovery steps (in order):**

1. **Confirm and record the new IP.**
   ```bash
   kubectl get nodes -o wide          # STATUS Ready; note EXTERNAL-IP = NEW_IP
   kubectl get pvc -n dcc             # Bound (or Pending if the volumes are gone)
   ```
   If the worker is gone and nothing replaced it: Linode Cloud Manager → Kubernetes → dcc-peer-testnet → Node
   Pools → **Recycle**, then wait for `Ready` (3–5 min).
2. **Close the firewall gap first.**
   `gh workflow run provision.yml -f action=plan -f network=testnet`. The plan must change only
   `linode_firewall.lke_nodes` (`linodes` = the new ID) and the VPS rule `allow-lke-exporter-out`. Then run the same
   command with `-f action=apply`. Verify:
   `curl -fsS -H "Authorization: Bearer $LINODE_TOKEN" https://api.linode.com/v4/networking/firewalls?page_size=100 | jq '.data[] | select(.label|test("lke")) | .entities'`
   lists the new Linode ID.
3. **Point the configs at the new IP (PR).**
   `scripts/set-lke-node-ip.sh <NEW_IP>`. It rewrites nodes.yaml + main's dcc.conf and refreshes the
   `checksum/config` annotations. Open the PR, then roll it with `runbooks/staggered-node-rollout.md` (main via
   `deploy-node-config.yml --ref <branch>` because dcc.conf changed, then the three pods one at a time), merge last.
4. **Monitoring.** `gh workflow run deploy-monitoring-stack.yml`, then on the VPS check
   `curl -s 127.0.0.1:9091/api/v1/query?query=up%7Bjob%3D%22lke-chain%22%7D` → value `1`.
5. **Verify the mesh.**
   ```bash
   curl -s -H "X-API-Key: <main key>" http://127.0.0.1:6869/peers/connected   # on the VPS: 3 peers at NEW_IP:6863-6865
   for p in dcc-gen-0-0 dcc-gen-1-0 dcc-val-0-0; do kubectl -n dcc exec $p -c node -- wget -qO- localhost:6869/blocks/height; done
   ```
   Every pod's height is within 2 of main's, and `LkeGeneratorsDown` resolves.

**Expected downtime:** 15–30 minutes. The LKE generators cannot peer until step 3. Main holds over 2/3 of the
committee stake (AUD-182), so finality continues on main's commits meanwhile.

---

## Scenario B — StatefulSet Rolling Update Deadlocks

**Symptom:** `kubectl rollout status statefulset/dcc-gen-0 -n dcc` hangs. Pod is stuck in `Pending`, `CrashLoopBackoff`, or `Init` state and the rollout does not advance.

**Cause:** Kubernetes StatefulSet `OrderedReady` policy requires the terminating pod to become `Ready` before the next one proceeds. If the new image fails its readiness probe, the rollout stalls permanently. (This is a known upstream issue, GitHub #67250, not fixed.)

**Note:** `dcc-gen-0` and `dcc-gen-1` use `podManagementPolicy: Parallel`, so they are not affected. Only `dcc-val-0` uses `OrderedReady` and could hit this.

**Recovery steps:**

1. Identify the stuck pod:
   ```bash
   kubectl get pods -n dcc
   kubectl describe pod dcc-val-0-0 -n dcc
   # Look for: readiness probe failures, image pull errors, OOMKilled
   ```

2. If the new image is bad, roll back the image in the manifest:
   ```bash
   # Edit clusters/testnet/apps/nodes.yaml
   # Change dcc-val-0 image tag back to the previous known-good tag
   git commit -am "revert: roll back dcc-val-0 to previous image"
   git push
   # Flux applies the rollback within 5 minutes
   ```

3. If the image is fine but the pod is stuck in a bad state, delete the pod manually to unblock the rollout:
   ```bash
   kubectl delete pod dcc-val-0-0 -n dcc
   # StatefulSet controller recreates the pod; rollout resumes
   ```

4. Confirm rollout completes:
   ```bash
   kubectl rollout status statefulset/dcc-val-0 -n dcc
   ```

**Prevention:** Always test image upgrades on a local node or staging environment before pushing to testnet. Canary: update `dcc-val-0` first (non-mining), verify block relay works, then update generators.

---

## Scenario C — SOPS Age Key Rotation

**When needed:** Age private key is suspected compromised, or routine key rotation policy.

**Impact:** Zero downtime. The key is only used at deploy time by Flux — running pods are not affected.

**Steps:**

1. Generate a new age key pair:
   ```bash
   age-keygen -o new-testnet.key
   # Output: public key printed to stdout, private key in new-testnet.key
   NEW_PUBLIC_KEY="age1..."  # copy from output
   ```

2. Save the new private key in KeeWeb as "DCC Testnet SOPS Age Key (new)" before proceeding.

3. Re-encrypt all SOPS-managed files with both old and new keys (transition period):
   ```bash
   # Add new public key to .sops.yaml alongside the old one, then:
   cd Ecosystem/infra
   SOPS_AGE_KEY="<old-private-key>" sops updatekeys secrets/testnet.env
   SOPS_AGE_KEY="<old-private-key>" sops updatekeys clusters/testnet/apps/gen0-wallet.secret.yaml
   SOPS_AGE_KEY="<old-private-key>" sops updatekeys clusters/testnet/apps/gen1-wallet.secret.yaml
   ```

4. Update the `sops-age` secret on the cluster:
   ```bash
   NEW_AGE_KEY=$(cat new-testnet.key)
   kubectl create secret generic sops-age \
     --namespace=flux-system \
     --from-literal=age.agekey="$NEW_AGE_KEY" \
     --dry-run=client -o yaml | kubectl apply -f -
   ```

5. Remove the old public key from `.sops.yaml`. Commit and push.

6. Flux reconciles with the new key. Verify:
   ```bash
   flux get kustomizations
   # apps and monitoring should show Ready=True
   ```

7. Delete the old private key from KeeWeb and shred the local file:
   ```bash
   shred -u new-testnet.key  # rename once confirmed working
   ```

---

## Scenario E — T2 HotStuff Soak

**Prerequisite: DONE (2026-07-13).** T2 HotStuff is deployed to all testnet nodes (image `dev-hotstuff`
= `sha256:ea5da215`, `dcc.hotstuff.enabled=true`, `round-timeout=1200ms`, `settled-depth=3` — present in
`apps/nodes.yaml` ×3) and is **committing across all nodes**: `hotStuffFinalizedHeight` advances in
lockstep at tip−settled-depth on VPS + gen-0 + gen-1. (This closed the step-5 QC blocker — a vote-message
`blockHeight` mismatch; see node-scala `docs/hotstuff-step5-findings-and-rework.md`. Any earlier
"Status: PASSED 2026-06-30" was fiction — this section is now real.)

**How to run the fault soak:** `gh workflow run t2-soak.yml --repo Decentral-America/infra` (45-min
harness; pulls the LKE kubeconfig via the Linode API — no local kubectl needed). It scales gen
StatefulSets down/up and records, per phase, `height / finalized / lag / hotStuffFinalized` from the VPS
main node. **feature-25 finalized height is the pass/fail authority; `hotStuffFinalized` is observed.**

**Soak scenarios** (record real results here after each run):
| Phase | Action | Expected (feature-25) | Expected (observational HotStuff) |
|-------|--------|-----------------------|-----------------------------------|
| A | gen-0 down | finality continues (main+gen-1 ≥ 2/3) | `hotStuffFinalized` keeps advancing |
| B | gen-1 down | finality continues (main+gen-0 ≥ 2/3) | keeps advancing |
| C | both gen down | FairPoS keeps producing; finality pauses (1-of-3 < 2/3) — no halt | pauses (no quorum) |
| D | both restored | finality resumes + catches up | resumes + catches up |

_Latest run: **PASS — 2026-07-13, run 29284578037** (all 18 steps success; gen nodes scaled down/up
and restored cleanly). Evidence from independent VPS `/node/status` sampling every 60s across the window:_
- _**Chain (FairPoS):** never halted — tip advanced continuously 47140 → 47231 throughout all phases._
- _**HotStuff (observational):** paused briefly during each generator outage (hotStuffFinalized froze in
  ~3 episodes — 47137/47146/47154 — hsLag rising to 6–8), **resumed after every restore**, and returned
  to steady hsLag = 3 (= settled-depth) from ~21:15 onward. Post-soak healthy (47228 @ hsLag 3, 21:50)._
- _**feature-25 (authoritative):** held at 47127 during the soak (within one generation-period; lag grew
  13 → 100 as expected), then finalized the next period normally at 21:48 (47128 → 47131, lag settled to
  the expected 100). No halt, no stall beyond normal per-period cadence._
- _Net: matches the expected table — finality degrades gracefully under quorum loss and fully recovers;
  the chain never halts. Remaining before mainnet enable: external consensus audit + the §5 A/B decision._

**Check finality health** (feature-25 = authoritative; HotStuff commit = observational, now on `/node/status`):
```bash
TIP=$(curl -s http://localhost:6869/blocks/height | jq .height)
FIN=$(curl -s http://localhost:6869/blocks/height/finalized | jq .height)          # authoritative
HSF=$(curl -s http://localhost:6869/node/status | jq .hotStuffFinalizedHeight)     # observational
echo "tip=$TIP finalized=$FIN lag=$((TIP-FIN)) hotStuffFinalized=$HSF"
# Healthy: FIN advancing; HSF ≈ TIP − settled-depth(3) and advancing.
```

**Prometheus alerts active** (deployed via `deploy-monitoring-stack.yml`; source `monitoring/alerts.yml`
— verified against the actual alert names in that file 2026-08-13, all 7 present):
- `BlockProductionStalled` — no block in 5 min (CRITICAL)
- `FinalizationStalled` — `dcc_finality_lag > 250` for 15 min (HIGH, authoritative feature-25)
- `FinalizationNotAdvancing` — `dcc_finalized_height` static 30 min (HIGH)
- `HotStuffCommitNotAdvancing` — `dcc_hotstuff_finalized_height` static 30 min while chain advances
  (WARNING only — observational; feature-25 unaffected)
- `ExporterScrapeError` / `ExporterDown` — the chain metrics exporter itself is failing/unreachable
- `ServiceDown` — a monitored service (node/BPS/matcher) is down

**T2 HotStuff rollout history** (kept here per this scenario's own "record real results" convention):
by 2026-08-03/04, `dcc.hotstuff.authoritative = true` went live on all 4 testnet nodes — HotStuff commits
now genuinely raise the authoritative `finalizedHeight` (feature-25), not just an observational value.
A cross-committee-epoch fork hazard (T10: two committees each honestly forming a QC for a different block
at the same view/height) was found and fixed the same window (`committeeEpoch` bound into vote/QC bytes,
protobuf-schemas 1.6.5). On 2026-08-13, a separate connectivity bug (`NetworkServer.scala` suspending
peers on benign graceful closes) had stalled
`hotStuffFinalizedHeight` for hours by starving gen-0/gen-1 of a stable connection to main; fixed
(node-scala PR #58) and recovered via the since-archived `migrate-state-snapshot.yml`. Full audit-scope detail, threat
model, and the mainnet enable-gate checklist live in `node-scala/docs/hotstuff-audit-readiness.md` — not
duplicated here.

---

## Scenario F — Generator Commitment (CommitToGenerationTransaction)

**How it works now:** every generator (main, gen-0, gen-1, val-0) commits itself in-process
(`dcc.miner.self-commit-to-generation = yes`, node-scala PR #60). The external commit workflows
(`auto-commit-generators.yml`, `commit-generators-hotstuff.yml`, `peer-check.yml`) were retired; see
`.github/archived-workflows/README.md`. A generation period is 100 blocks (~50 min).

**Check commitment:** the exporter publishes `dcc_current_period_committee_size` and
`dcc_next_period_committee_size` (alerts `CommitteeShrinking`, `CommitteeGapUpcoming`). By hand:
```bash
H=$(curl -s https://testnet-node.decentralchain.io/blocks/height | jq .height)
START=$(( ((H-1)/100)*100 + 1 ))
curl -s https://testnet-node.decentralchain.io/generators/at/$START | jq 'length'          # current committee (4)
curl -s https://testnet-node.decentralchain.io/generators/at/$((START+100)) | jq 'length'  # next (404 "[]" until the first commit lands)
```

**Manual commit (only if a node's self-commit is rejected repeatedly; its log says `Self-commit ... rejected`):**
sign a type-19 transaction on THAT node's loopback with its own API key, then broadcast it. Public
`/transactions/sign` is blocked by Caddy. Read the key from SOPS through an env var; never type it.
```bash
# main (on the VPS):
curl -s -X POST -H "X-API-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"type":19,"sender":"31RPEKcz71a3hdxt8z7qLhTpRMuRV2kUyr6"}' http://127.0.0.1:6869/transactions/sign > /tmp/ctg.json
curl -s -X POST -H 'Content-Type: application/json' -d @/tmp/ctg.json http://127.0.0.1:6869/transactions/broadcast; rm -f /tmp/ctg.json
# LKE node: kubectl port-forward -n dcc dcc-gen-0-0 16869:6869 (gen-1 serves REST on 6870), then the same two calls.
```

**Quorum math:** finality needs endorsements from ≥ 2/3 of the committee's generating balance. Since the
2026-10-18 rebalance (AUD-182) main alone holds more than 2/3 (see `TOPOLOGY.md` "Stake and fault
tolerance"): main can finalize alone, and **losing main halts finality by design**.

---

## Quick Reference

| Situation | Command |
|-----------|---------|
| Check pod status | `kubectl get pods -n dcc` |
| Tail node logs | `kubectl logs -n dcc dcc-gen-0-0 -f` |
| Force Flux reconcile | `flux reconcile kustomization apps` |
| Check Flux health | `flux get all` |
| List PVCs | `kubectl get pvc -n dcc` |
| Describe stuck pod | `kubectl describe pod <name> -n dcc` |
| Unblock stuck rollout | `kubectl delete pod <name> -n dcc` |
| Check block height | `kubectl exec -n dcc dcc-gen-0-0 -- curl -s http://127.0.0.1:6869/blocks/height` |
| Check peer count | `kubectl exec -n dcc dcc-gen-0-0 -- curl -s http://127.0.0.1:6869/peers/connected` |

---

## Scenario D — Pods Running but Chain Not Advancing / No Peers (P2P peering)

**Symptom:** `kubectl get pods -n dcc` shows generators `1/1 Running`, REST API healthy
(`/blocks/height` responds), but height is stuck (e.g. at genesis height 1 on the
LKE nodes) and `/peers/connected` shows 0. No block production.

**Topology (must hold):**

| Node | Host | P2P bind | declared-address | known-peers |
|------|------|----------|------------------|-------------|
| main (VPS, Dallas, host network) | 50.116.30.244 | `dcc.network.port = 6868` | `50.116.30.244:6868` | none (`known-peers = []`; the LKE nodes dial main) |
| dcc-gen-0 (LKE)  | 139.162.144.243 | 6863 | `139.162.144.243:6863` | Dallas:6868 + gen-1 + val-0 |
| dcc-gen-1 (LKE)  | 139.162.144.243 | 6864 | `139.162.144.243:6864` | Dallas:6868 + gen-0 + val-0 |
| dcc-val-0 (LKE)  | 139.162.144.243 | 6865 | `139.162.144.243:6865` | Dallas:6868 + gen-0 + gen-1 |

**Layered checklist (work top-down — each layer must pass before the next matters):**

1. **Main P2P reachable.** Main runs with host networking (`compose/node-scala.yml`), so
   `dcc.network.port = 6868` is the listening port; the Linode firewall and the host firewall
   (`host/nftables/dcc-host.nft`) both allow inbound 6868. Verify from outside:
   `nc -zv 50.116.30.244 6868` → succeeds.
2. **Firewall egress.** Main's Cloud Firewall `outbound_policy = DROP` must allow
   the Frankfurt P2P ports. `terraform/main.tf` `allow-p2p-out` is `6863-6868`. Test
   from main: `python3 -c "import socket;socket.create_connection(('139.162.144.243',6863),5)"`
   → OPEN, not TimeoutError. A **timeout** (vs connection-refused) means a firewall is
   dropping packets; **refused** means the port simply isn't listening.
3. **Frankfurt inbound.** LKE Cloud Firewall (`linode_firewall.lke_nodes`) must allow
   inbound 6863-6865. Test from anywhere: `nc -zv 139.162.144.243 6863` → succeed.
4. **Pod config sanity** (`kubectl exec -n dcc dcc-gen-0-0 -- sed -n '/network {/,/}/p' /etc/dcc/dcc.conf`):
   `bind-address = "0.0.0.0"`, correct `port`, `declared-address`, and `known-peers`.
5. **Outbound dial actually happening.** Set `DCC_LOG_LEVEL=DEBUG` on a node, roll it,
   wait 2-3 min, then `kubectl logs -n dcc dcc-gen-0-0 | grep -iE "Connecting|Connected|handshake|Channel closed"`.
   Healthy nodes log `Connecting to /<ip>:<port>` then `Connected to ...`.

**History:** the 2026-06-10 "no outbound connection attempt" issue recorded here was resolved on
2026-07-08 (handshake-timeout and dedup fixes, IR-6 causes 1-4); peering has worked since.

**val-0 specific:** exits 61 `CANNOT GET CONSOLE TO ASK WALLET PASSWORD` if it lacks
either a seed (`DCC_WALLET_SEED`) or `wallet.password = ""`. Both are now set; if it
still crashloops, check the seed Secret decrypted (`kubectl get secret dcc-val0-wallet -n dcc`).

---

## Incident Response (consensus & security)

> Complements the infra scenarios above. Each incident: **detect → triage → mitigate → recover**.
> Golden signals live in Prometheus/Grafana; alerts route via Alertmanager. Node facts come from
> `GET /node/status`, `/blocks/height`, `/blocks/height/finalized`, `/peers/connected`. Never call
> `/debug/*` publicly — use the node's own API key over the loopback/SSH path.

### IR-1 — Chain halt (no new blocks)
- **Detect:** `BlockProductionStalled` (no block > 5 min); `dcc_blockchain_height_age_seconds` high; explorer/height frozen.
- **Triage:** is the node process up (`ServiceDown`/`ExporterDown`)? `peers/connected` ≥ 1? Is any generator actually mining (logs "generating balance")? FairPoS needs ≥ 1 generator with generating balance and a connected mesh.
- **Mitigate:** restart the affected node (`cluster-diagnostics.yml -f roll=true` for k8s gens; SSH `docker restart` for the VPS main). If a P2P partition, see infra Scenario D (peering) — verify `declared-address` and reachability. If all generators are down, bring at least one back.
- **Recover:** confirm height advances again on all nodes; watch for a fork on rejoin (IR-4).

### IR-2 — Finality stall (blocks produced but not finalizing)
- **Detect:** `FinalizationStalled` (`dcc_finality_lag > 20` for 10 min; normal ~3) or `FinalizationNotAdvancing` (30 min static). Chain keeps producing; finality is what's behind. `HotStuffCommitNotAdvancing` fires when T2 commits stop while blocks continue.
- **Triage:** finality needs ≥ 2/3 of the committee's generating balance endorsing. Main alone holds more than 2/3 (AUD-182), so first check main: up, synced, has its LKE peers, and logs no `[HotStuff] WATCHDOG` loop. Then the committee for the period (Scenario F).
- **Mitigate:** restart a wedged node (`update-node-image.yml` for main, `scripts/roll-testnet-node.sh` for an LKE node). Commit a missing generator by hand only as in Scenario F.
- **Recover:** `dcc_finalized_height` advances again and the lag returns to ~3. Not chain-fatal, but fix promptly: a sustained stall means no economic finality.
- **HotStuff is authoritative on testnet** (`hotstuff.authoritative = true` since 2026-08-03): a T2 stall caps the finality lag near 100 (the `height - max-rollback` fallback), which is exactly what `FinalizationStalled` catches.

### IR-3 — Key compromise (generator/main seed, API key, SOPS age, or SSH key)
- **Detect:** unexpected transactions from a node/generator address; a leaked secret; anomalous admin/API access.
- **Immediate blast-radius note:** today the full stake sits on the hot generating account (see MAINNET-READINESS.md item #1 — lease instead). Until then, a seed leak = potential total-stake loss.
- **Mitigate by secret type:**
  - **Node/generator wallet seed:** generate a NEW account, transfer funds out immediately to a fresh cold account, then rotate the node's seed (update `secrets/<net>.env` via `sops`, re-run push-secrets, redeploy). Post-leasing: cancel leases and re-point to a new generator.
  - **Node REST API key:** rotate `MAIN_NODE_REST_API_KEY` in SOPS → push-secrets → redeploy; Caddy re-injects the new key.
  - **SOPS age key:** follow Scenario C (age key rotation) — re-encrypt all `secrets/*.env`, rotate the in-cluster `sops-age` secret.
  - **SSH deploy key:** rotate `DEPLOY_SSH_KEY` (GH secret) + the server's `authorized_keys`; prefer moving to Tailscale ephemeral access (MAINNET-READINESS item #2) so there is no long-lived public SSH key.
- **Recover:** confirm no residual attacker access; audit recent transactions/logins; document the timeline.
- **Note:** Waves FairPoS has **no slashing**, so the primary risk is fund theft / attacker block-signing, not stake burning.

### IR-4 — Fork / reorg
- **Detect:** nodes disagree on the block at a height (different block IDs/signatures); a node reports a lower cumulative score; explorer shows a reorg.
- **Triage:** identify the canonical chain = highest cumulative score **and** highest `finalized` height. **Feature-25-finalized blocks must never be reverted** — if a *finalized* block forked, that is a critical consensus bug: halt and escalate (do not auto-heal).
- **Mitigate (non-finalized divergence, normal):** FairPoS resolves by score automatically once the mesh reconnects. For a node stuck on a minority branch, roll it back below the divergence via the node's own API (`POST /debug/rollback`, loopback + API key only) and let it resync. If that fails, use the IR-5 recovery.
- **Recover:** all nodes converge on one chain; `finalized` height monotonic across nodes; no double-spends in the reorged range.

### IR-5 — Gen node can't sync / `InvalidStateHash` (build or state-hash divergence)
- **Detect:** an LKE node is stuck far below main's tip and cycling; its log shows `InvalidStateHash(Some(expected),Some(computed))` then a rollback; `LkeGeneratorsDown` fires or its height in `cluster-diagnostics.yml` is frozen while main advances.
- **First check the build:** all four nodes must run the same digest (rule D6: `node-config/testnet/vps-image.env` = the three pins in `nodes.yaml`; `scripts/check-digest-parity.sh`). A different build is the usual cause (2026-07-16 incident).
- **Recover — P2P resync (default):** scale the StatefulSet to 0, delete that node's PVC, scale back to 1; the node syncs from genesis over P2P. Set `miner.enable = no` for that node during the catch-up (with `quorum = 1` a lagging node must not forge its own branch), and re-enable it at the tip. Proven on the current (2026-09-04 relaunch) chain on 2026-10-04, when all three LKE nodes resynced from genesis to ~34k. A full replay past height 56354 (equivocation proof) and 60000 (deposit forfeiture) has not been exercised by a fresh node (AUD-035, node-scala plan).
- **Recover — state transplant (fallback):** if the resync itself stops with `InvalidStateHash`, transplant main's RocksDB `data/` into the PVC with a loader pod. The procedure is the archived `.github/archived-workflows/migrate-state-snapshot.yml` (read it; restore it to `.github/workflows/` only for that run).
- **Verify:** all nodes at the same height with `restarts=0`; finality lag back to ~3; the node's address appears in the block-generator distribution again.

### IR-6 — Peer connectivity loops / "0 connected peers" / stuck at 1 active generator
- **Detect:** admin-dashboard "Active Generators" stuck at 1 (it counts distinct generators over the
  last `min(500,height)` blocks); `/peers/connected` shows 0 on a gen node; it briefly appears then
  vanishes with no error logged; `cluster-diagnostics.yml` shows a repeating connect→handshake-ok→close
  cycle on a fixed period (often exactly `suspension-residence-time`).
- **This has had at least five distinct root causes over time** — check each rather than assuming the
  last one recurred:
  1. **Handshake-timeout misconfiguration** (node-scala PR #16, 2026-07-08) — outbound handshake
     timeout accidentally 1s instead of the configured 30s specifically when reconnecting after
     losing all peers; self-reinforcing loop under cross-region latency.
  2. **Chain fork** — main diverged from the gen mesh, allowed to persist by `quorum=0`; reconciled by
     transplanting main's canonical RocksDB state onto the gen pods (same mechanism as IR-5's
     `migrate-state-snapshot.yml`, different original cause).
  3. **Stale-entry dedup race in `HandshakeHandler`** (node-scala PR #11) — the dedup closed the *new*
     channel whenever an entry already existed for `(address, nonce)`, even if that entry was a dead
     channel whose cleanup listener hadn't run yet. Logged only at `debug`, hence invisible. Fixed:
     evict inactive previous entries instead of closing the new one.
  4. **Peer-exchange gossip** (`enable-peers-exchange`) recreating the same collision via a path
     `known-peers=[]` didn't cover — fixed by disabling peer-exchange on main (infra PR #38).
  5. **Suspend-on-any-close bug** (node-scala PR #58, 2026-08-13) — `NetworkServer.scala` suspended the
     remote peer on *any* outgoing channel close, including a completely benign graceful one, not just
     genuine failures. Since gen-0/gen-1's only known-peer is main, every ordinary reconnect (most
     likely triggered by `HandshakeHandler`'s own duplicate-connection dedup, which keys on
     `(host, nonce)` not direction) became a 30s penalty box — see the T2 HotStuff rollout history note
     in Scenario E above for the fix + recovery detail; not repeated here.
- **Mitigate/Recover (generic):** if a node has fallen far enough behind that connectivity alone
  won't let it catch up in reasonable time, use the IR-5 recovery (P2P resync, then state transplant).
- **Verify:** stable connections with zero suspend-loop recurrence across multiple
  `cluster-diagnostics.yml` runs; heights converge; over time all generator addresses (not just main)
  appear in the block-generator distribution again.
- History: this incident class was first closed 2026-07-08 (causes 1-4 above), had an unconfirmed
  2026-08-12 recurrence (symptoms logged but self-quieted before root-causing), then a real recurrence
  2026-08-13 (cause 5) confirmed and fixed. If this signature reappears again, causes 1-5 are all worth
  re-checking before assuming a sixth new cause.

### Escalation & contacts
- Secrets/keys: SOPS (`secrets/testnet.env`, decrypt with the testnet age key) and the operator's KeeWeb vault.
- Deploy substrates & release flow: `clusters/testnet/TOPOLOGY.md`. Node image changes: `pin-node-image-digest.yml` PR + `runbooks/staggered-node-rollout.md`.

---

## Known CI Non-Issues (investigated, deliberately not "fixed")

> Forcing these would be reckless, not thorough. Recorded so nobody re-investigates the same dead end.

- **matcher's kanela NPE storm** under full-suite unit-test load (thousands of log lines, 0 actual test
  failures) — root cause understood (sbt2 worker-JVM reuse causes non-deterministic partial
  Kamon/Pekko instrumentation retransformation), but kanela is deliberately attached to the test JVM
  and the existing `KanelaWorkerClasspathFix` workaround is already fragile, battle-tested reflection
  code. A real fix needs dedicated design work, not a blind patch.
- **node-scala Check-PR's occasional timing-test flakes** — reproduced under 4 escalating
  CPU-starvation techniques (up to 246 competing processes) and could NOT be reproduced; no fix was
  invented for a failure that didn't recur locally.
- **Org-wide dead-code sweep** only covers node-scala (proven zero dead code by construction,
  `-Wunused:all` + `-Werror` already gates every merge) and matcher's known removals (a real dev-branch
  cleanup already landed). Matcher's own `-Wunused` retrofit and a DecentralChain Nx/TS monorepo sweep
  are real, separate initiatives, not attempted as part of this.
- **matcher billing**: was ~97% one thing — the 8-shard `dex-it` integration suite running on every push
  to `main`. Fixed by moving it to nightly + release tags only (~$105/mo saved, same 148-suite coverage,
  shards unchanged). matcher is the only private/billed repo of the 4; the rest are public (free Actions).

---

## Gotchas — What NOT to Do

- `restart-host-network.yml` **WIPES the main node's chain data**. Use `update-node-image.yml` / `deploy-node-config.yml` instead.
- Never start the main node by hand with `docker run`: `scripts/node-up.sh` (via those workflows) is the only path, and it runs the digest from `vps-image.env`.
- Do not use Docker bridge mode for the main node; it causes TCP failures reaching it from LKE.
- Do not write the matcher's `local.conf` to `/opt/dcc/data/matcher-testnet/config/`, which is silently ignored. It lives at `/opt/dcc/config/matcher-testnet/local.conf` and only `push-secrets.yml` writes it (`scripts/render-matcher-local-conf.sh`).
- blockchain-postgres-sync (BPS) exits when the node's gRPC stream drops and restarts on its own (restart policy). If it does not, `docker start blockchain-postgres-sync-testnet` on the VPS.
- Do not use `gh run watch`: it burns the GitHub REST rate limit (1200/hr for the whole org). Use GraphQL polling plus artifact download instead.
- Do not recall credentials from memory: read them from SOPS or the operator's vault.
