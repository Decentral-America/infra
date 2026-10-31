# Security Policy

## Supported Versions

This repository contains infrastructure code for the DecentralChain (DCC) ecosystem.
All versions of the `main` branch are considered current.

## Reporting a Vulnerability

If you discover a security vulnerability in this repository, **do not open a public GitHub issue**.

Please report it privately via one of the following channels:

- **GitHub Private Security Advisory**: Use the [Security Advisory](../../security/advisories/new) feature in this repository.
- **Email**: josue.rojas@sdbullion.com
- **Secondary email**: info@decentralchain.io

### What to include

- A description of the vulnerability and its potential impact.
- Steps to reproduce (if applicable).
- Any suggested remediation if you have one.

### What to expect

- We will acknowledge receipt within **48 hours**.
- We aim to triage and respond with a preliminary assessment within **5 business days**.
- We will notify you when the vulnerability has been remediated.
- We will credit you in the fix (unless you prefer to remain anonymous).

## Security Architecture

This infra repo manages Linode server provisioning via OpenTofu and Docker-based deployments.

Key security boundaries:

- **Secrets are never stored in code** — all sensitive values are in GitHub Secrets (Tier 2)
  or on-server `/opt/dcc/secrets/<network>.env` files (Tier 3).
- **The infra repo is public** (required for cross-org reusable workflows on GitHub Free plan).
  No secrets are in the code.
- **Environments have required reviewers** for `infra-<network>-provision` environments —
  apply/destroy require human approval.
- **GHCR authentication** is performed per-deploy using a scoped PAT passed securely via
  SSH action environment variables.

## Known Issues — Action Required Before Mainnet

### API keys in git history

Node REST API keys are present in git history of this repository (commits Jun 25–27, 2026).
**All API keys must be rotated before mainnet launch.**

**Status (2026-10-10): ROTATED and rolled out** (infra #193). All four node REST API keys (main, gen-0,
gen-1, val-0) were replaced; `verify-api-keys.yml` showed HTTP 200 with each new key and 403 with each
old key on every node, and the GitHub Actions secrets were updated (TESTNET-FINAL-PLAN.md History,
2026-10-10 entry). The old keys in git history are dead. The remaining credential rotations (OAuth
client secret, Sentry token, admin PAT, `TF_VAR_ROOT_PASSWORD`) are tracked in ECO-76.

Rotation procedure:

1. Generate new API keys (random alphanumeric, 32+ chars).
2. Hash each key using `secureHash = Keccak256(Blake2b256(key))`, then base58-encode.
   **CRITICAL: NOT SHA-256.** Use the node's own utility:
   ```bash
   curl -s -X POST http://localhost:6869/utils/hash/secure \
     -H "Content-Type: application/json" -d '{"message":"YOUR_NEW_KEY"}' \
     | python3 -c "import json,sys; print(json.load(sys.stdin)['hash'])"
   ```
3. Update `api-key-hash` in `dcc.conf` for each node:
   - Main: `infra/node-config/testnet/dcc.conf` → deploy via `deploy-node-config.yml`
   - Gen/val: `infra/clusters/testnet/apps/nodes.yaml` → Flux auto-applies within 10 min
4. Update GitHub Actions secrets: `MAIN_NODE_REST_API_KEY`, `GEN_0_NODE_REST_API_KEY`,
   `GEN_1_NODE_REST_API_KEY`, `VAL_0_NODE_REST_API_KEY`.
5. Verify each node: `curl -H "X-API-Key: NEW_KEY" http://localhost:6869/peers/connected` → expect 200.

## Per-service secrets (key → service)

Each VPS container reads only `/opt/dcc/secrets/<service>-<network>.env` (compose `env_file:`), written
by `scripts/render-service-env.sh` from the master `/opt/dcc/secrets/<network>.env` that
`push-secrets.yml` assembles from SOPS. No container mounts the master file. This table is checked
against the renderer by `scripts/tests/security-key-table.test.sh` (CI "Unit tests"): a key added to
or removed from a service there must be changed here too.

<!-- key-table:begin -->
| Service (env file `<service>-<network>.env`) | Keys |
|---|---|
| node-scala | DCC_WALLET_SEED, DCC_WALLET_PASSWORD |
| scanner | DCC_NODE_URL, DCC_MATCHER_URL, DCC_DATA_SERVICE_URL, DCC_CHAIN_ID, DCC_FAUCET_SEED, REDIS_URL; optional DCC_FAUCET_AMOUNT, DCC_FAUCET_RATE_HOURS, DCC_RECAPTCHA_SECRET, IPINFO_TOKEN |
| data-service | PGHOST, PGPORT, PGDATABASE, DEFAULT_MATCHER, RATE_PAIR_ACCEPTANCE_VOLUME_THRESHOLD, RATE_THRESHOLD_ASSET_ID, PGUSER (= dcc_ro), PGPASSWORD (from DCC_RO_PASSWORD); optional MATCHER_SETTINGS_URL, RATE_BASE_ASSET_ID, LOG_LEVEL |
| data-service-pairs | PGHOST, PGPORT, PGDATABASE, PGUSER (= dcc_pairs), PGPASSWORD (from DCC_PAIRS_PASSWORD); optional LOG_LEVEL |
| blockchain-postgres-sync | BPS_BLOCKCHAIN_UPDATES_URL, BPS_CHAIN_ID, BPS_REDIS_URL, POSTGRES__HOST, POSTGRES__PORT, POSTGRES__USER, POSTGRES__PASSWORD, POSTGRES__DATABASE |
| websocket-api | REPO__PASSWORD |
| admin-dashboard | ADMIN_DASHBOARD_GITHUB_OAUTH_CLIENT_ID, ADMIN_DASHBOARD_GITHUB_OAUTH_CLIENT_SECRET, ADMIN_DASHBOARD_JWT_SECRET, ADMIN_DASHBOARD_GITHUB_PAT, ADMIN_DASHBOARD_PG_DATABASE, PGHOST, PGPORT, PGUSER, PGPASSWORD, DCC_NODE_URL, GRAFANA_URL, SENTRY_AUTH_TOKEN; optional TREASURY_SEED |
| postgres-exporter | PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE |
| alert-webhook | ADMIN_DASHBOARD_GITHUB_PAT |
| alertmanager | ALERTMANAGER_SMTP_USERNAME, ALERTMANAGER_SMTP_PASSWORD |
<!-- key-table:end -->

Not rendered by `render-service-env.sh`, written directly by `push-secrets.yml`:

| File | Keys | Reader |
|---|---|---|
| `grafana-<network>.env` (640 root:deploy) | GF_SECURITY_ADMIN_PASSWORD (SOPS `GRAFANA_ADMIN_PASSWORD`) | grafana container |
| `backup-<network>.env` (600 root:root) | R2_BACKUP_ACCESS_KEY_ID, R2_BACKUP_SECRET_ACCESS_KEY, R2_BACKUP_ENDPOINT | `scripts/pg-backup.sh` (systemd, root); no container |
| `/opt/dcc/config/matcher-<network>/local.conf` (640 root:113) | matcher seed (SOPS `MATCHER_SEED_BASE64`), API key hashes | matcher container (uid 113), read-only mount |

The matcher has no `env_file`. The main node's API key hash is in `node-config/<network>/dcc.conf`
(a hash, not a secret). Live check (ECO-76): `docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' <container> | cut -d= -f1`
must list only that row's keys plus the compose `environment:` constants.

## SOPS age key custody

Each network's `secrets/<network>.env` and `clusters/<network>/*.secret.yaml` are encrypted to one age
recipient per network (`.sops.yaml`). Whoever holds a network's private key can decrypt every secret of
that network, so each private key is held separately. Values are never written here.

| Network | Public recipient (`.sops.yaml`) | GitHub copy (names checked 2026-10-31, `gh secret list -e <env>`) | Holder (role) | Offline storage |
|---|---|---|---|---|
| testnet | `age1gpe6clrw…sd97vzs` | env `testnet`: `AGE_SECRET_KEY`; repo: `AGE_KEY_TESTNET` (Flux `sops-age`) | Owner (Operator) | Operator's encrypted KDBX vault (ECO-73); PENDING Owner confirmation of the entry |
| stagenet | `age13ecynhep…xrvrxflfsqkd6q2q` | none: env `stagenet` exists and has 0 secrets | Owner (Operator) — PENDING confirmation | PENDING Owner: record the vault entry name; add `AGE_SECRET_KEY` to env `stagenet` only when stagenet is provisioned |
| mainnet | `age1kapnwpu7…4vqncgfgh` | none: env `mainnet` exists and has 0 secrets | Owner (Operator) — PENDING confirmation | PENDING Owner: vault entry plus a second, offline copy (sealed backup) held by the backup contact named in DR.md "Account continuity"; never in the same place as the testnet key |

Rules: a private key is never committed, pasted into chat or issues, or stored on the VPS (the host
receives only decrypted per-service files). Rotation (a new recipient, then `sops updatekeys`) follows
`clusters/testnet/RUNBOOK.md` Scenario C.

## Runtime Hardening

All containers deployed by this repo run with:

- `no-new-privileges: true` — privilege escalation blocked at kernel level.
- All Linux capabilities dropped (`cap_drop: ALL`); none re-added.

Kubernetes pods (LKE — gen/val nodes, not public-facing) additionally have:

- `fsGroup` set for filesystem ownership restriction.
- `allowPrivilegeEscalation: false` in security context.

## Known Patched Vulnerabilities

| CVE | Component | Status |
|-----|-----------|--------|
| CVE-2026-44249 | node-scala Docker image | ✅ Patched — current image deployed |

## Responsible Disclosure

We follow coordinated disclosure. We ask that you give us reasonable time to fix
issues before public disclosure.

---

_Last reviewed: 2026-10-31_
