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
   # Edit clusters/testnet/apps/dcc-nodes.yaml
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
