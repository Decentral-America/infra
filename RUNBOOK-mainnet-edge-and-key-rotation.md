# Runbook — Mainnet Edge Provisioning (R3) & REST API-Key Rotation (R5)

From the T2 finality audit (`Ecosystem/AUDIT-T2-FINALITY.md`). These two items require infrastructure/cluster access that does not exist yet (no mainnet), so they are **operator runbooks**, not code changes. The node/edge *code* hardening (R1 denylist, R4 rate-limit) is already merged; this covers the launch-time steps that can only run against real mainnet infra.

---

## R3 — Bring the hardened edge config to mainnet

The `Update Caddy` workflow (`.github/workflows/update-caddy.yml`) is deliberately testnet-only today (`options: [testnet]`, reads `terraform/testnet.tfvars`, uses `secrets.AGE_KEY_TESTNET`, `environment: testnet`). It already carries the R1 denylist + R4 `/utils` rate-limit. It is **not** parameterized for mainnet on purpose — none of the mainnet inputs below exist, so wiring a `mainnet` choice now would only create a path that fails at runtime. Do these first, then flip it on.

**Provisioning checklist (all are prerequisites, none exist yet):**
1. `terraform/mainnet.tfvars` — mainnet domains (`node_domain`, `matcher_domain`, `scanner_domain`, `data_service_domain`, `websocket_domain`, `admin_domain`, `grafana_domain`, `acme_email`) + backup/TLS settings, mirroring `testnet.tfvars`.
2. A `mainnet` GitHub **environment** (protection rules / required reviewers for a production edge).
3. Secrets in that environment: `AGE_KEY_MAINNET` (SOPS/age), `E2E_RATE_LIMIT_BYPASS_KEY` (or omit the bypass for mainnet), and the mainnet node REST key path in SOPS.
4. `secrets/mainnet.env` (SOPS-encrypted) containing `MAIN_NODE_REST_API_KEY` (see R5).
5. The custom `caddy-ratelimit` image digest pinned in the mainnet `compose/caddy.yml` (the `rate_limit` directives require it — stock Caddy will fail to start otherwise).

**Then parameterize the workflow (safe once the above exist):**
- Add `mainnet` to `inputs.network.options`.
- Replace hardcoded `terraform/testnet.tfvars` with `terraform/${NETWORK}.tfvars`.
- Select the age key per network, e.g. `SOPS_AGE_KEY: ${{ secrets[format('AGE_KEY_{0}', ... uppercased network)] }}`.
- Keep `environment: ${{ inputs.network }}` (already parameterized).

**Verify after first mainnet run:** `caddy reload` validates atomically (a bad Caddyfile fails the step but leaves the running config untouched — zero downtime). Then from an external host confirm the denylist: `curl -so /dev/null -w '%{http_code}' https://<node_domain>/debug/state` → **404**; `.../wallet/seed` → **404**; a normal read (`/blocks/height`) → **200**.

---

## R5 — Rotate the REST API key (and verify the old one is dead)

**Why:** node REST API keys were exposed in infra git history (commits Jun 25–27). History was rewritten and secrets are now SOPS-encrypted, but **scrubbing history does not invalidate a leaked key** — only changing the deployed `api-key-hash` does. A previously-exposed key remains valid until the hash on the node changes. Rotate before mainnet, and confirm the old key no longer authenticates.

Hash scheme (must match the node): `secureHash = base58( Keccak256( Blake2b256( key ) ) )`.

**Steps (per network, all nodes):**
1. **Generate** a new random key (≥ 32 bytes), e.g. `openssl rand -base64 32`.
2. **Hash** it. Easiest is the node's own endpoint against a *local* node: `curl -s -X POST <local-node>/utils/hash/secure -d '<newkey>'` → returns the base58 secure hash. (Cross-check offline: `Keccak256(Blake2b256(key))` base58-encoded.)
3. **Update config** — set `dcc.rest-api.api-key-hash = <newhash>` in every node config: k8s `clusters/<net>/apps/nodes.yaml` (gen/val nodes) and the VPS `node-config/<net>/dcc.conf`. The hash is safe to commit (it is not the key).
4. **Update the raw key** in SOPS: `secrets/<net>.env` `*_REST_API_KEY=<newkey>` (re-encrypt with `sops`), and update any GitHub Actions/environment secret that carries the key (e.g. the value `update-caddy.yml` injects as `X-API-Key`).
5. **Deploy** to all nodes (Flux reconcile for k8s; the VPS deploy workflow for the main node). Confirm each node reloaded the new hash.
6. **Verify rotation succeeded:**
   - New key works: `curl -s -H 'X-Api-Key: <newkey>' https://<node_domain>/peers/all` → 200 (through the edge, which injects its own key) *and* directly on a node → 200.
   - **Old key is dead:** `curl -s -o /dev/null -w '%{http_code}' -H 'X-Api-Key: <OLDKEY>' http://<node-local>:6869/debug/configInfo` → **403**. This is the step that actually closes the exposure; do it on every node.
7. Run `verify-api-keys.yml` (if present) to confirm all nodes agree on the new hash.

**Rollback:** if a node rejects the new key, revert its `api-key-hash` to the previous value in config and redeploy that node only; the edge will keep working for read routes it doesn't key.
