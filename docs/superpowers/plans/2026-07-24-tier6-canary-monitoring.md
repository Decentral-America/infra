# Tier 6 — Live Synthetic/Canary Monitoring — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close Tier 6 of the [E2E testing strategy](../specs/2026-07-24-e2e-testing-strategy-design.md) — the design spec flags this tier as lower-confidence (general practice, not research-verified). A dedicated, low-value canary wallet submits a real transfer against the live testnet on a schedule; failure surfaces through the exact same alerting channel every other testnet alert already uses (Alertmanager → `alert-webhook.py` → GitHub Issues) — reused directly rather than inventing a parallel notification path.

**Architecture:** A new scheduled GitHub Actions workflow, modeled on the proven retry-loop shape of `auto-commit-generators.yml`, but signing client-side with the already-published `@decentralchain/transactions` npm package (the same one `e2e-blockchain`'s specs already use) rather than a node's server-side `/transactions/sign` wallet endpoint — the existing `/transactions/sign` pattern only works because the signing node already holds that specific account's key in its own wallet (confirmed: `auto-commit-generators.yml`'s generator commits each go through the matching generator's own node); a canary account has no such node-side wallet entry, so client-side signing against the public REST API is the correct, simpler fit here, with no SSH/kubectl dependency at all.

**Tech Stack:** GitHub Actions, Node.js + `@decentralchain/transactions` (npm), SOPS-encrypted secrets (matching the existing `DCC_FAUCET_SEED` pattern).

## Global Constraints

- The canary account must be its own dedicated wallet, funded minimally, never reused for the faucet or load-test sender accounts already documented in project memory.
- Reuse the exact GitHub Issue title/label convention `alert-webhook.py` already uses (`[ALERT] {name}: {summary}`, labels `['alert', f'severity:{sev}']`) so canary failures land in the same place, in the same format, as every other testnet alert — do not invent a different issue format.
- Do not add a Prometheus Pushgateway or modify `exporter.py`'s no-dependency, pure-stdlib design in this plan — a Grafana-visible latency trend for the canary is legitimate future work, flagged explicitly at the end of this plan, not built here.
- This tier's confidence is explicitly lower than Tiers 1-4 in the design spec — say so plainly in any follow-up communication about this work, don't overstate certainty.

---

### Task 1: Provision a dedicated canary wallet secret

**Files:**
- Modify: `infra/secrets/testnet.env` (SOPS-encrypted — edit via `sops`, do not hand-edit ciphertext)
- Modify: `infra/.github/workflows/push-secrets.yml`

- [ ] **Step 1: Generate a new canary seed phrase (offline, not committed in plaintext anywhere)**

Run (locally, not in CI): `node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"` or use the project's existing account-generation convention if one exists (check `DecentralChain/packages/e2e-blockchain/src/helpers/accounts.ts`'s `randomTestAccount` for the exact seed-generation approach already trusted elsewhere in this project, and mirror it, rather than inventing a different method).

- [ ] **Step 2: Add the secret to the SOPS-encrypted testnet secrets file**

Run: `cd infra && sops secrets/testnet.env` (opens decrypted in `$EDITOR`), add:
```
DCC_CANARY_SEED=<the generated seed phrase>
```
mirroring the exact comment style already used for the faucet seed (`push-secrets.yml:191-198`, quoted in the code audit backing this plan): explain what breaks without it (canary workflow fails to sign) and why it must be in SOPS (so a re-provision restores it, avoiding the faucet's prior on-server-only drift incident).

- [ ] **Step 3: Add provisioning to `push-secrets.yml`**

In `infra/.github/workflows/push-secrets.yml`, add a block adjacent to the faucet-seed provisioning:
```
# Canary transactions — Tier 6 synthetic monitoring signs+broadcasts a real,
# low-value transfer on a schedule using this dedicated seed. Kept in SOPS so a
# re-provision restores it, same reasoning as DCC_FAUCET_SEED above.
if [[ -n "${CANARY_SEED:-}" ]]; then
  printf 'DCC_CANARY_SEED=%s\n' "${CANARY_SEED}"
fi
```
Confirm the exact surrounding shell-variable-sourcing convention (how `FAUCET_SEED` becomes available as a shell variable in that script — likely sourced from the decrypted SOPS file earlier in the same job) before adding this block, and match it exactly rather than guessing the variable-loading mechanism.

- [ ] **Step 4: Fund the canary account with a small amount from the existing faucet or main wallet**

Run (manually, one-time): use the existing faucet (`https://testnet.decentralscan.com/api/faucet`) or an existing funded test account to send a small amount (e.g. 100 DCC — enough for thousands of minimal canary transfers at typical fee levels) to the canary account's address. Record the address in this plan's own follow-up notes (not in the secret file) for operational reference.

- [ ] **Step 5: Commit**

```bash
cd /Users/jourlez/Documents/Code/Blockchain/Ecosystem/infra
git add .github/workflows/push-secrets.yml
git commit -m "ci: provision a dedicated canary wallet secret for Tier 6 synthetic monitoring"
```
Note: `secrets/testnet.env` is SOPS-encrypted ciphertext — committing it is safe and expected (that's the point of SOPS), but confirm `git diff --stat` shows only the expected encrypted-file change, not an accidental plaintext leak, before pushing.

---

### Task 2: Scheduled canary-transaction workflow

**Files:**
- Create: `infra/.github/workflows/canary-transaction.yml`

**Interfaces:**
- Consumes: `@decentralchain/transactions`'s `transfer`, `broadcast`, `waitForTx` (the exact same functions `e2e-blockchain`'s `alias.spec.ts` already uses: `transfer({...}, seed)`, `broadcast(tx, apiBase)`, `waitForTx(txId, {apiBase, timeout})`).

- [ ] **Step 1: Write the workflow**

```yaml
name: Canary Transaction (Tier 6 synthetic monitoring)
# Submits a real, minimal-value transfer against the live testnet on a schedule, using a
# dedicated canary wallet. Failure (broadcast rejected, or not confirmed within the timeout)
# opens a GitHub Issue using the exact same title/label convention alert-webhook.py already
# uses for every other testnet alert, so this failure mode surfaces in the same place.
on:
  schedule:
    - cron: '*/15 * * * *'  # every 15 min
  workflow_dispatch: {}

permissions:
  contents: read
  issues: write

jobs:
  canary:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    environment: testnet
    steps:
      - name: Set up Node.js
        uses: actions/setup-node@a0853c24544c31adeaf4085cba310b7c1c78a5e9  # v5.0.0 — confirm current pinned SHA before merging
        with:
          node-version: '22'

      - name: Install signing/broadcast dependency
        run: npm install --no-save @decentralchain/transactions@latest

      - name: Sign, broadcast, and confirm a minimal canary transfer
        id: canary
        env:
          DCC_CANARY_SEED: ${{ secrets.DCC_CANARY_SEED }}
        run: |
          cat <<'EOF' > /tmp/canary.mjs
          import { transfer, broadcast, waitForTx } from '@decentralchain/transactions';

          const API_BASE = 'https://testnet-node.decentralchain.io/';
          const CHAIN_ID = '!'; // matches DCC_TEST_CHAIN_ID used elsewhere in this project's E2E config
          const SEED = process.env.DCC_CANARY_SEED;

          const start = Date.now();
          const tx = transfer({ amount: 100_000, chainId: CHAIN_ID, recipient: /* canary's own address: self-transfer avoids needing a second funded account */ undefined }, SEED);

          try {
            await broadcast(tx, API_BASE);
            const confirmed = await waitForTx(tx.id, { apiBase: API_BASE, timeout: 120_000 });
            const latencyMs = Date.now() - start;
            console.log(`Canary tx ${tx.id} confirmed at height ${confirmed.height} in ${latencyMs}ms`);
            process.exit(0);
          } catch (err) {
            console.error(`Canary tx failed: ${err?.message ?? err}`);
            process.exit(1);
          }
          EOF
          node /tmp/canary.mjs

      - name: Open a GitHub Issue on failure (matches alert-webhook.py's issue format)
        if: failure()
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          PREFIX="[ALERT] CanaryTransactionFailed"
          EXISTING=$(gh issue list --repo "${{ github.repository }}" --label alert --state open --json title,number \
            --jq ".[] | select(.title | startswith(\"$PREFIX\")) | .number" | head -1)
          if [ -z "$EXISTING" ]; then
            gh issue create --repo "${{ github.repository }}" \
              --title "$PREFIX: canary transaction did not confirm against testnet" \
              --label alert --label severity:high \
              --body "## HIGH — canary transaction did not confirm against testnet

          **Network:** testnet
          **Alert:** \`CanaryTransactionFailed\`
          **Severity:** high
          **Run:** ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}

          > Auto-opened by the canary-transaction workflow (Tier 6 synthetic monitoring). Close when resolved."
          fi
```

Note: the `transfer(...)` call above needs a real recipient — a self-transfer (recipient = the canary account's own address) is the simplest, safest choice (no second account to fund/manage), but the `recipient` field is left as `undefined` in this draft because deriving the canary account's own address from its seed requires an extra `address(SEED, CHAIN_ID)` call (from `@decentralchain/ts-lib-crypto`, used identically in `alias.spec.ts`) — add that import and compute `const recipient = address(SEED, CHAIN_ID)` before finalizing; do not leave `recipient: undefined` in the merged workflow, it will fail validation.

- [ ] **Step 2: Fix the self-transfer recipient, matching `alias.spec.ts`'s exact pattern**

```js
import { address } from '@decentralchain/ts-lib-crypto';
import { transfer, broadcast, waitForTx } from '@decentralchain/transactions';
// ...
const recipient = address(SEED, CHAIN_ID);
const tx = transfer({ amount: 100_000, chainId: CHAIN_ID, recipient }, SEED);
```
Update the `npm install` step to also install `@decentralchain/ts-lib-crypto@latest`, and update the inline script accordingly.

- [ ] **Step 3: Validate YAML syntax locally**

Run: `python3 -c "import yaml; yaml.safe_load(open('infra/.github/workflows/canary-transaction.yml'))" && echo OK`
Expected: `OK`.

- [ ] **Step 4: Dispatch it once manually and confirm a real successful run**

Run: `gh workflow run canary-transaction.yml -R Decentral-America/infra` (confirm the exact owner/repo slug with `git -C infra remote -v` first)
Expected: the run completes with a confirmed canary transaction and no issue opened. This is the only real proof the signing/broadcast/confirmation path works end-to-end — do not claim this task complete without observing one real green run.

- [ ] **Step 5: Verify the failure path once, deliberately (e.g. temporarily point `API_BASE` at an unreachable URL via `workflow_dispatch`, or simulate by reverting the recipient computation) and confirm an issue is opened correctly, then revert**

This proves the alerting path (not just the happy path) actually works before relying on it. Revert the deliberate-failure change immediately after confirming.

- [ ] **Step 6: Commit**

```bash
cd /Users/jourlez/Documents/Code/Blockchain/Ecosystem/infra
git add .github/workflows/canary-transaction.yml
git commit -m "ci: add scheduled canary-transaction workflow (Tier 6 synthetic monitoring), alerts via GitHub Issues"
```

---

## What this plan does not cover

- Grafana-visible latency-trend charts for the canary (would require a Prometheus Pushgateway or a change to `exporter.py`'s dependency-free design) — deliberately out of scope here; the binary success/failure signal via GitHub Issues is what this plan delivers. Flag this as a candidate follow-up if latency-trend visibility becomes a real need, rather than building it speculatively now.
- Extending the canary to cover DEX settlement (matcher order round-trip) or other transaction types beyond a simple transfer — start with the simplest, most reliable signal first; broadening the canary's tx-type coverage is natural, bounded follow-up work once the basic transfer canary has run reliably for a while.
