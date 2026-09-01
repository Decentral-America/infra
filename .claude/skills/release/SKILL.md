---
name: release
description: Use when deploying a DecentralChain app (exchange/dex, data-service, scanner, websocket-api, admin-dashboard, bps) to a network (testnet, stagenet, mainnet) — dispatches the Deploy workflow, polls to completion through the approval gate, and verifies the site actually changed.
argument-hint: "[network] [app] — e.g. testnet dex"
disable-model-invocation: true
allowed-tools: Bash(gh run list:*), Bash(gh run view:*), Bash(gh api:*), Bash(gh workflow list:*), Bash(git log:*), Bash(git rev-list:*), Bash(git fetch:*), Bash(git branch:*), Bash(curl:*)
---

# release

Deploy a DecentralChain app to a network. Arguments are order-independent: `/release testnet dex` and `/release dex testnet` are the same.

ARGUMENTS: $ARGUMENTS

All workflows live in `Decentral-America/DecentralChain`. Always pass `--repo Decentral-America/DecentralChain`.

## Quick reference

| App (aliases) | Workflow | Networks | Env gate? |
|---|---|---|---|
| `exchange`, `dex` | `Deploy Exchange` | mainnet, stagenet, testnet | **Yes** |
| `data-service`, `data` | `Deploy Data Service` | mainnet, stagenet, testnet | No |
| `scanner`, `explorer` | `Deploy Scanner` | mainnet, stagenet, testnet | No |
| `websocket-api`, `ws`, `websocket` | `Deploy WebSocket API` | stagenet, testnet | No |
| `admin-dashboard`, `admin`, `dashboard` | `Deploy Admin Dashboard` | testnet, mainnet | No |
| `bps` | `Deploy BPS` | stagenet, testnet | No |

If the network isn't in that app's list, stop and say so — `workflow_dispatch` rejects a `choice` value outside its options.

## The four traps

These are why this skill exists. Each one has produced a wrong result in this repo before.

1. **`gh workflow run` ignores your current branch.** With no `--ref` it dispatches against the repo default (`main`) and reports success. Every historical run of Deploy Exchange built `main`. **Always pass `--ref` explicitly**, then confirm the run's `headBranch` matches what you intended.

2. **The exchange has an environment gate; nothing else does.** Only `deploy-exchange.yml` declares `environment:`, so only the exchange is branch-gated. A rejected dispatch runs **zero steps** and reports a plain "failure" with nothing in the log to explain it — run `33532256007` failed exactly this way, dispatched from `dev` when `testnet` still required protected branches. The two environments are gated *differently*, so check rather than assume:

   | Env | Policy | Allowed refs |
   |---|---|---|
   | `testnet` | `custom_branch_policies` | allowlist: `main`, `dev` |
   | `mainnet` | `protected_branches` | protected branches only (`main`; **not** `dev`) |

   The other five apps have no environment and can deploy from any ref.

3. **The exchange also requires a human approval.** `testnet` and `mainnet` carry a `required_reviewers` rule for the `release-approvers` team. The run parks in status `waiting` after the `resolve` job and does nothing until approved — in run `31916561060` that pause was 17 minutes. `prevent_self_review` is `false`, so the dispatcher may approve their own run. **A poll that only watches for `completed` will look hung.** Watch for `waiting` and surface it.

4. **A skipped deploy still finishes green.** If `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` are unset, the deploy step logs a notice, is skipped, and the run concludes `success` with the site unchanged. **Never report "live" from the run conclusion alone** — verify per step 5.

Also: `concurrency` queues per network and never cancels, so a second dispatch waits behind the first rather than replacing it.

## Procedure

**1 — Resolve.** Parse network and app from ARGUMENTS against the table. If either is missing or ambiguous, ask; do not guess.

**2 — Preflight.** Pick the ref. Default to `main`.

For the **exchange only**, verify the ref clears that network's gate *before* dispatching. Read the live policy rather than trusting the table — it has changed before:

```bash
REF=<ref>; NET=<network>; R=Decentral-America/DecentralChain
POL=$(gh api repos/$R/environments/$NET --jq '.deployment_branch_policy')
echo "policy: $POL"
if [ "$(echo "$POL" | jq -r .custom_branch_policies)" = "true" ]; then
  gh api repos/$R/environments/$NET/deployment-branch-policies --jq '.branch_policies[].name' \
    | grep -qx "$REF" && echo "OK: $REF is allowlisted" || echo "BLOCKED: $REF not in allowlist"
else
  [ "$(gh api repos/$R/branches/$REF --jq .protected)" = "true" ] \
    && echo "OK: $REF is protected" || echo "BLOCKED: $REF is not a protected branch"
fi
```

On `BLOCKED`, **stop — do not dispatch.** Report which gate rejected it and offer the choices: deploy an allowed ref, merge into one, or amend the environment policy. If suggesting `main` as the fallback, say what that would actually ship instead:

```bash
git -C ~/Documents/Repos/DecentralChain fetch origin -q
git -C ~/Documents/Repos/DecentralChain log --oneline origin/main..origin/<ref> -- apps/exchange
```

**3 — Dispatch.** Confirm with the user first — this ships. Then:

```bash
gh workflow run "<Workflow Name>" --repo Decentral-America/DecentralChain \
  --ref <ref> -f network=<network>
```

Capture the run id (the dispatch itself returns nothing useful):

```bash
sleep 5
gh run list --repo Decentral-America/DecentralChain --workflow "<Workflow Name>" \
  --limit 1 --json databaseId,headBranch,status,url
```

Verify `headBranch` is the ref you asked for. If it isn't, the dispatch went to the wrong branch — stop and report.

**4 — Poll.** Loop until the run leaves `in_progress`/`queued`/`waiting`, reporting each state change:

```bash
for i in $(seq 1 120); do
  S=$(gh run view <id> --repo Decentral-America/DecentralChain --json status,conclusion \
      --jq '.status + " " + (.conclusion // "-")')
  echo "$(date +%H:%M:%S) $S"
  case "$S" in completed*) break;; esac
  sleep 30
done
```

If status is `waiting`, the run is blocked on approval, not building. Surface it immediately with the pending environment and the approval link — don't sit silently:

```bash
gh api repos/Decentral-America/DecentralChain/actions/runs/<id>/pending_deployments \
  --jq '.[] | {env:.environment.name, can_approve:.current_user_can_approve}'
```

Tell the user to approve in the run's web UI, then keep polling. Approving is the user's action, not yours.

**5 — Verify, then report.** A `success` conclusion is necessary, not sufficient (trap 4). Confirm the deploy step actually ran:

```bash
gh run view <id> --repo Decentral-America/DecentralChain --json jobs \
  --jq '.jobs[].steps[] | select(.name | test("Deploy|Cloudflare")) | {name, conclusion}'
```

A `skipped` there means **nothing shipped** — say so plainly rather than reporting a green run as live.

For the exchange, check the live URL (`testnet` → `https://testnet.decentral.exchange`, `stagenet` → `https://stagenet.decentral.exchange`, `mainnet` → `https://decentral.exchange`). Cache-bust, and check a referenced asset too — Pages can serve stale HTML pointing at a garbage-collected bundle, which is a 200 on a blank page:

```bash
U=https://testnet.decentral.exchange
curl -so /dev/null -w "html %{http_code}\n" -H 'Cache-Control: no-cache' "$U/?cb=$(date +%s)"
A=$(curl -s -H 'Cache-Control: no-cache' "$U/?cb=$(date +%s)" | grep -oE '/assets/[A-Za-z0-9_.-]+\.(js|css)' | head -1)
curl -s "$U$A" -o /tmp/asset.check -w "asset $A %{http_code} %{content_type}\n"
head -c 15 /tmp/asset.check | grep -qi '<!doctype\|<html' \
  && echo "FAIL: served the SPA fallback, not the asset" || echo "OK: real asset"
```

**A 200 on an asset URL proves nothing on its own.** Cloudflare Pages answers unknown paths with the SPA fallback — `index.html`, HTTP 200, `text/html`. A missing bundle therefore looks identical to a present one unless you check the body isn't HTML. Related: locally-built chunk hashes do **not** match CI's, because CI sets `SENTRY_RELEASE` and changes the content — so never verify a deployed asset by a filename from your own `dist/`. Read the name out of the live HTML, or out of the live entry chunk for a lazy route:

```bash
curl -s "$U/assets/<live-index-chunk>.js" | grep -oE '<ChunkName>-[A-Za-z0-9_-]+\.js' | sort -u
```

Then report: app, network, ref, **deployed commit SHA**, run URL, and the verified live URL. If any check failed, lead with that.

## Red flags

- Dispatching without `--ref` → you are deploying `main` regardless of intent.
- Reporting "deployed" from a green conclusion without checking the deploy step ran.
- Treating a `waiting` run as in-progress and polling silently for 17 minutes.
- Assuming a branch gate from memory or from this file instead of reading the live policy.
- Accepting a 200 on an asset URL as proof the asset exists — the SPA fallback returns 200 HTML.
- Checking a deployed asset by a filename from your local `dist/` — CI's hashes differ.
- Inventing a network for an app whose workflow doesn't offer it.
