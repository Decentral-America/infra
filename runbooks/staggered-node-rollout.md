# Staggered node-scala rollout (testnet)

Use this to put a new node-scala image, a node config change, or both on the 4 testnet nodes **one node at a time**.

Never let all four restart together. On 2026-10-07 a whole-committee restart wedged HotStuff, and on 2026-10-15 it happened again by accident (see "Why Flux must be suspended at the parent" below).

## The rule: merge last

A pin PR (digest in `clusters/testnet/apps/nodes.yaml` ×3 plus `node-config/testnet/vps-image.env`, and any config with refreshed `checksum/config` annotations) **must not reach Flux before every node already runs it**.

Roll every node from the PR branch first. Merge after that, so Flux's apply of the merged files changes nothing.

## Steps

0. **Open the PR, don't merge.** If the PR changes node config, run `python3 scripts/config-checksums.py --fix`, then `./scripts/check-digest-parity.sh`. Check out the PR branch locally. Record the baseline: height, finalized height, `/generators/at/<h>` length, and each pod's `startTime`.

1. **Suspend Flux at the parent, then the child:**
   ```
   kubectl -n flux-system patch kustomization flux-system --type merge -p '{"spec":{"suspend":true}}'
   kubectl -n flux-system patch kustomization apps        --type merge -p '{"spec":{"suspend":true}}'
   ```
   Do **both**, parent first. Suspending only `apps` does not hold; see below.

2. **Main (VPS):**
   - If `node-config/testnet/dcc.conf` changed, `scp` it to `/tmp/dcc.conf.new`, then `sudo cp` it over `/opt/dcc/config/node-testnet/dcc.conf` and `chown root:root`. Keep a backup and `diff` it; the diff must be exactly the intended lines. This does not restart anything.
   - Run `gh workflow run update-node-image.yml --ref <pin-branch>`. The `testnet` environment has no branch policy, so a branch ref works. The workflow reads `vps-image.env` from that ref, runs the plugin-shadowing check, restarts the node, and fails on class-linkage errors.
   - Wait until main is advancing with finality lag ≤ 5 and has peers.

3. **LKE, one node at a time:** run `scripts/roll-testnet-node.sh dcc-gen-0`, then `dcc-gen-1`, then `dcc-val-0` (cwd = infra, on the PR branch). The script:
   - applies that node's ConfigMap and StatefulSet with Flux's field manager;
   - waits for the rollout;
   - waits for the node to reach main's height with main's lag ≤ 5;
   - prints the new image, restarts, InvalidStateHash count, class-linkage count, and the pod `startTime` before and after. **A start time that didn't change means nothing rolled.**

   Before starting the next node, confirm the committee is still the full set.

4. **Merge the PR** while Flux is still suspended.

5. **Resume:** first `apps`, then `flux-system` (`"suspend":false`). Confirm `lastAppliedRevision` equals the merge commit and **no pod `startTime` changed**.

6. **Verify:**
   - all 4 nodes on the digest (`docker inspect` on the VPS; `imageID` for the pods);
   - the same block id at a common height on all 4;
   - 0 `InvalidStateHash` since the start;
   - `max_over_time(dcc_finality_lag[30m])` and `dcc_hotstuff_lag` normal (Prometheus on the VPS, `127.0.0.1:9091` inside `prometheus-testnet`);
   - committee size unchanged.

## Why Flux must be suspended at the parent

`clusters/testnet/apps.yaml` defines the `apps` Kustomization, and the self-managing `flux-system` Kustomization (path `./clusters/testnet`) applies it.

kustomize-controller (v1.9.6 here) removes fields owned by kubectl field managers when it applies an object. So the next `flux-system` reconcile silently deletes a `kubectl patch`-ed `suspend: true` on `apps`. That reconcile happens on every new git revision, and the merge itself is a new revision.

On 2026-10-15 (infra #213):
1. Only `apps` was suspended, and the PR was merged before the nodes were rolled.
2. At 15:52:47Z `flux-system` re-applied `apps.yaml`, and the suspend was gone (the `apps` managedFields show no `kubectl-patch` manager afterwards).
3. `apps` then applied the merge commit, and all three StatefulSets rolled within 4 seconds (15:52:56–15:53:00Z), while main restarted about 30s later.

The chain survived that time: 0 InvalidStateHash, max finality lag 4, HotStuff lag 3. That was luck, not design.

Older rollouts (#199–#205) avoided it only because each node's image was set before the pin merged, so the unsuspended apply happened to be a no-op.
