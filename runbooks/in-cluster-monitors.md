# In-cluster monitors (canary, matcher canary, infra liveness)

Why: every GitHub Actions minute in any repo of the org counts against the shared free pool. The
testnet health checks used to be dispatched as `workflow_dispatch` runs by an LKE CronJob
(`liveness-trigger`) plus `schedule:` backups: about 170 to 200 runs a day, roughly 130 min/day for
`infra-liveness` alone. The checks now run directly in the cluster and use no Actions minutes.

## What runs where

| Check | Where | Cadence | On failure |
|---|---|---|---|
| `canary-transaction` (real self-transfer confirms on testnet) | LKE CronJob `canary-transaction` | `*/15` | issue `[ALERT] CanaryTransactionFailed` or `CanaryWalletUnfunded` |
| `matcher-canary` (crossing orders match and settle on chain) | LKE CronJob `matcher-canary` | `7 * * * *` | `[ALERT] MatcherSettlementCanaryFailed` or `MatcherCanaryUnfunded` |
| `infra-liveness` (height advances, every node Ready, Flux Ready) | LKE CronJob `infra-liveness` | `20,50 * * * *` | `[ALERT] InfraLiveness` |
| Off-box deadman: block freshness, Linode pool, Alertmanager `Watchdog` + alert-webhook, Flux, **and that the three CronJobs above still run** | `.github/workflows/infra-liveness.yml` | every 3 h | `[ALERT] InfraLiveness` |
| Prometheus alert rules (`monitoring/alerts.yml`) | VPS Prometheus / Alertmanager / alert-webhook | continuous | unchanged |

Everything lives in `clusters/testnet/apps/monitors/` (Flux `apps` Kustomization, `prune: true`).
The scripts are generated into the ConfigMap `monitor-scripts-<hash>`, so a script change takes effect
on the next run of each CronJob. `canary-transaction.yml` and `matcher-canary.yml` remain as
`workflow_dispatch` only and execute the same scripts.

## Alerting path

The CronJob opens one issue through the GitHub API, in the format `monitoring/alert-webhook.py` uses
(title `[ALERT] <Name>: <summary>`, `**Severity:**` in the body). `alert-issues.yml` then labels it
(`alert`, `severity:*`), because the token can create issues but not label or comment on them. An
already open issue whose title starts with `[ALERT] <Name>` suppresses a duplicate. Resolution is
manual (close the issue), exactly as before. The issue body carries the last 20 log lines.

If a monitor fails for a reason that is not a testnet fault (npm registry down while installing the
SDK: exit 4) it files no issue. The off-box deadman catches a monitor that has not succeeded within
its limit and has no matching open alert issue (`scripts/check-monitor-cronjobs.py`: canary 75 min,
liveness 2 h, matcher canary 4 h; "not scheduled" limits 35 min, 75 min, 2 h).

What is deliberately NOT in the cluster: the Alertmanager deadman (`Watchdog` held by Alertmanager,
alert-webhook `/healthz`). Both listen on the VPS loopback and only an off-box observer proves the VPS
alerting plane is alive, so that check moved from every 30 min to every 3 h inside `infra-liveness.yml`.
Whole-VPS or whole-cluster death is still caught by the Prometheus rules (`MainNodeUnreachable`,
`LkeGeneratorsDown`) and the 3 h deadman.

## Secrets

Secret `monitors` in namespace `dcc` (`monitors.secret.yaml`, SOPS, the same age key as the other
cluster secrets):

- `github-token`: the fine-grained token the former `liveness-trigger` used. It can create issues on
  this repo (and dispatch workflows); it cannot comment or label. Rotate it here and in the
  `ADMIN_DASHBOARD_GITHUB_PAT` entry of `secrets/testnet.env` together if they share a token.
- `dcc-canary-seed`: the canary account seed, the same value as `DCC_CANARY_SEED` in
  `secrets/testnet.env` and the `testnet` environment secret.

Edit: `sops clusters/testnet/apps/monitors/monitors.secret.yaml` (or `sops -d` / `sops -e
--filename-override`), commit, let Flux apply. A changed Secret is read by the next CronJob run (env
from `secretKeyRef` is resolved when each Job's pod starts). Never paste a value into a manifest.

## Operate

```bash
export KUBECONFIG=~/.kube/dcc-testnet.yaml          # see clusters/testnet/RUNBOOK.md
kubectl -n dcc get cronjobs,jobs -l app.kubernetes.io/part-of=monitors
kubectl -n dcc logs job/<job-name>                    # last 2 successful and 3 failed Jobs are kept
kubectl -n dcc create job --from=cronjob/canary-transaction canary-manual-$(date +%s)   # run now
kubectl -n dcc patch cronjob matcher-canary -p '{"spec":{"suspend":true}}'              # pause (Flux reverts it)
```

For a lasting pause (for example while the matcher is being reset) suspend the parent first, as in
`runbooks/staggered-node-rollout.md`, or set `spec.suspend: true` in `cronjobs.yaml` through a PR. The
deadman only warns about a suspended CronJob.

The monitors run as ordinary (non-hostNetwork) pods, so the `monitors-egress` NetworkPolicy is
enforced: DNS and HTTPS only. `infra-liveness` is the only one with a ServiceAccount token (read-only
RBAC on nodes, and Flux Kustomizations and pods in `flux-system`).

## Failure modes

| Symptom | Meaning |
|---|---|
| Alert issue opened, Job `Failed` | the testnet check failed; see the issue body and `kubectl logs` |
| Job `Failed`, no issue, deadman red | monitor infrastructure: image pull, npm registry, bad token (`alert delivery failed` in the log) |
| Deadman: "last scheduled N min ago" | CronJob controller or the LKE node is down; check `kubectl get nodes` and Flux |
| `CanaryWalletUnfunded` | re-fund the canary wallet from the treasury (TESTNET-FINAL-PLAN Task 3.4 Step 2) |

## Cost

Replaces about 170 to 200 dispatched runs a day (canary 96, liveness 48, matcher canary 24, plus
backups). The remaining GitHub schedule is `infra-liveness.yml` 8 runs a day at about 1 billed
minute each. The old CronJob `liveness-trigger`, its token Secret and NetworkPolicy were removed.
