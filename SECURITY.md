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

_Last reviewed: 2026-06-30_
