# DCC Testnet LKE Cluster — Disaster Recovery Runbook

## Prerequisites

```bash
# All commands require a working kubeconfig for the Frankfurt LKE cluster.
# Download from Linode Cloud Manager → Kubernetes → dcc-peer-testnet → Download kubeconfig
export KUBECONFIG=~/.kube/dcc-testnet.yaml
```

---

## Scenario A — LKE Worker Node Terminates Unexpectedly

**Symptom:** Pod enters `Pending` state, `kubectl get pods -n dcc` shows nodes as `NotReady`.

**What survives automatically:** Block Storage PVCs use `linode-block-storage-retain` with `ReclaimPolicy: Retain`. The 3 chain-data volumes are **not deleted** when the node is lost.

**Recovery steps:**

1. Confirm the node is gone and PVCs still exist:
   ```bash
   kubectl get nodes
   kubectl get pvc -n dcc
   # All 3 PVCs should still show Bound or Released, not Deleted
   ```

2. In Linode Cloud Manager, go to **Kubernetes → dcc-peer-testnet → Node Pools** and click **Recycle** on the node pool. This provisions a new node with the same plan/region.

3. Wait for the new node to reach `Ready` (typically 3–5 minutes):
   ```bash
   kubectl get nodes -w
   ```

4. Once the node is `Ready`, Flux reconciles automatically within 5 minutes. Pods reschedule and the CSI driver re-attaches the Block Storage volumes.

5. Verify recovery:
   ```bash
   kubectl get pods -n dcc
   kubectl logs -n dcc dcc-gen-0-0 --tail=20
   # Expect: "Node started" and block height resuming
   ```

**Expected downtime:** 5–10 minutes (node recycle + CSI re-attach + JVM warm-up).

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
   # dcc-apps and dcc-monitoring should show Ready=True
   ```

7. Delete the old private key from KeeWeb and shred the local file:
   ```bash
   shred -u new-testnet.key  # rename once confirmed working
   ```

---

## Scenario E — T2 HotStuff Soak Results (2026-06-30)

**Status: PASSED.** All 4 failure scenarios verified at `round-timeout-ms = 1200` (tuned from 5000ms; p99 ~1000ms + 20% margin).

| Scenario | Result |
|----------|--------|
| gen-0 down | T2 maintained lag=0 (main + gen-1 quorum) |
| gen-1 down | T2 maintained lag=0 (main + gen-0 quorum) |
| both gen nodes down | FairPoS continued (+3 blocks), T2 paused (no quorum) — no halt |
| both gen nodes restored | T2 self-healed to lag=0 within 3 min |

**Deployed config** (main node and all gen nodes via Flux):
```hocon
hotstuff {
  enabled = true
  round-timeout-ms = 1200
}
```

**Check T2 health:**
```bash
curl http://localhost:6869/blockchain/finality
# Healthy: hotStuffFinalizedHeight lag < 10 blocks
# Alert:   hotStuffFinalizedHeight lag > 50 blocks for 10 min → check generators committed
```

**Prometheus alerts active** (deployed via `deploy-monitoring.yml`):
- `T2FinalizationStalled` — lag >50 blocks for 10 min (HIGH)
- `T2GeneratorsNotCommitted` — NextGens <2 for 15 min (HIGH)
- `BlockProductionStalled` — no block in 5 min (CRITICAL)

---

## Scenario F — Generator Commitment (CommitToGenerationTransaction)

**Auto-commit:** `auto-commit-generators.yml` runs on dual cron schedule (every 35 min) to keep all 3 generators committed for the next generation period. Each generation period is 100 blocks ≈ 50 min. **T2 HotStuff stops after the current period ends if NextGens < 2.**

**Check commitment status:**
```bash
gh workflow run peer-check.yml --repo Decentral-America/infra
# Look for: CurGens >= 2 AND NextGens >= 2
```

**Manual emergency commit:**
```bash
gh workflow run auto-commit-generators.yml --repo Decentral-America/infra
# OR the manual workflow:
gh workflow run commit-generators-hotstuff.yml --repo Decentral-America/infra
```

**CommitToGeneration via node REST API (manual):**
```bash
# Each node signs for itself — BLS auto-derived, period start auto-filled
# gen-0:
kubectl port-forward dcc-gen-0-0 -n dcc 16869:6869
curl -X POST http://localhost:16869/transactions/sign \
  -H "X-API-Key: KEY" -H "Content-Type: application/json" \
  -d '{"type":19,"sender":"ADDRESS"}'
# Then broadcast: curl -X POST http://localhost:16869/transactions/broadcast -d '<signed_tx>'

# gen-1 (uses port 6870 internally):
kubectl port-forward dcc-gen-1-0 -n dcc 16870:6870
curl -X POST http://localhost:16870/transactions/sign ...
```

**Quorum math:** Main ~26.7M DCC, gen-0 ~26.7M DCC, gen-1 ~26.7M DCC (total ~80M). Any 2-of-3 = ~53.4M > 53.3M threshold. T2 requires any majority of committed generators.

---

## Quick Reference

| Situation | Command |
|-----------|---------|
| Check pod status | `kubectl get pods -n dcc` |
| Tail node logs | `kubectl logs -n dcc dcc-gen-0-0 -f` |
| Force Flux reconcile | `flux reconcile kustomization dcc-apps` |
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
Frankfurt nodes / 2412 on Newark) and `/peers/connected` shows 0. No block production.

**Topology (must hold):**

| Node | Host | P2P bind | declared-address | known-peers |
|------|------|----------|------------------|-------------|
| Newark (compose) | 66.228.55.154 | `dcc.network.port = 6868` | `66.228.55.154:6868` | the 3 Frankfurt nodes |
| dcc-gen-0 (LKE)  | 172.105.64.89 | 6863 | `172.105.64.89:6863` | Newark:6868 + gen-1 + val-0 |
| dcc-gen-1 (LKE)  | 172.105.64.89 | 6864 | `172.105.64.89:6864` | Newark:6868 + gen-0 + val-0 |
| dcc-val-0 (LKE)  | 172.105.64.89 | 6865 | `172.105.64.89:6865` | Newark:6868 + gen-0 + gen-1 |

**Layered checklist (work top-down — each layer must pass before the next matters):**

1. **Newark P2P bind == published port.** `dcc.network.port` MUST equal the compose
   publish (`6868:6868`) and the Linode firewall inbound rule (6868). A mismatch
   (historically `port = 6863` vs publish 6868) makes Newark unreachable even though
   docker-proxy shows `0.0.0.0:6868 LISTEN`. Verify: `nc -zv 66.228.55.154 6868` from
   outside → must succeed.
2. **Firewall egress.** Newark's Cloud Firewall `outbound_policy = DROP` must allow
   the Frankfurt P2P ports. `terraform/main.tf` `allow-p2p-out` is `6863-6868`. Test
   from Newark: `python3 -c "import socket;socket.create_connection(('172.105.64.89',6863),5)"`
   → OPEN, not TimeoutError. A **timeout** (vs connection-refused) means a firewall is
   dropping packets; **refused** means the port simply isn't listening.
3. **Frankfurt inbound.** LKE Cloud Firewall (`linode_firewall.lke_nodes`) must allow
   inbound 6863-6865. Test from anywhere: `nc -zv 172.105.64.89 6863` → succeed.
4. **Pod config sanity** (`kubectl exec -n dcc dcc-gen-0-0 -- sed -n '/network {/,/}/p' /etc/dcc/dcc.conf`):
   `bind-address = "0.0.0.0"`, correct `port`, `declared-address`, and `known-peers`.
5. **Outbound dial actually happening.** Set `DCC_LOG_LEVEL=DEBUG` on a node, roll it,
   wait 2-3 min, then `kubectl logs -n dcc dcc-gen-0-0 | grep -iE "Connecting|Connected|handshake|Channel closed"`.
   Healthy nodes log `Connecting to /<ip>:<port>` then `Connected to ...`.

**KNOWN OPEN ISSUE (as of 2026-06-10):** Layers 1-4 verified GREEN (Newark binds 6868
and is externally reachable; egress widened to 6863-6868 and applied; Frankfurt P2P
6863/6864 reachable from both Newark and the public internet; pod config correct with
known-peers present). However layer 5 fails: the node emits **no outbound connection
attempt at all** — not even at DEBUG — over multiple minutes, despite
`max-outbound-connections = 100` (default), correct `known-peers`, and
`NetworkServerL1.apply` constructing the server + scheduling the connect task
unconditionally. Newark (long-running, single node) shows the same: it has never had a
peer. Next diagnostic requires **interactive cluster access** (not 8-min CI cycles):
  - `kubectl exec` into a generator and confirm the effective logback level for
    `com.decentralchain.network` (the `-Dlogback.stdout.level` may not lower the
    network logger; a logback `<logger name="com.decentralchain.network" level="TRACE"/>`
    override may be required to see `doConnect`).
  - Confirm `scheduleConnectTask` fires and what `peerDatabase.nextCandidate` returns
    (it should resolve `settings.knownPeers`); check whether the candidates are being
    added to `excludedAddresses` (self/declared-address collision) or silently dropped.
  - Verify the handshake `applicationName` (`Constants.ApplicationName + "!"`) matches
    between Newark and Frankfurt by capturing a handshake frame.
  - **Recommended:** pull a kubeconfig locally (`linode-cli lke kubeconfig-view <id>`)
    for sub-second iteration instead of CI round-trips.

**val-0 specific:** exits 61 `CANNOT GET CONSOLE TO ASK WALLET PASSWORD` if it lacks
either a seed (`DCC_WALLET_SEED`) or `wallet.password = ""`. Both are now set; if it
still crashloops, check the seed Secret decrypted (`kubectl get secret dcc-val0-wallet -n dcc`).
