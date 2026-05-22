# DecentralChain Infrastructure

> **Public repo:** `Decentral-America/infra`
>
> **Why public?** GitHub Free plan only allows reusable workflows to be called
> across repos when the called workflow's repo is public. No secrets are in the
> code — all sensitive values are in GitHub Secrets or on-server
> `/opt/dcc/secrets/<network>.env` files. Public infra repos are standard practice.

## Contents

```
infra/
├── .github/
│   └── workflows/
│       ├── deploy-container.yml   — Reusable: SSH pull+up for any Docker service
│       └── provision.yml          — OpenTofu: provision/update Linode servers
├── terraform/
│   ├── main.tf                    — OpenTofu root config (Linode provider, state backend)
│   ├── variables.tf               — Input variables
│   ├── outputs.tf                 — Outputs (IPs, hostnames)
│   └── scripts/
│       └── bootstrap.sh           — Server bootstrap: Docker, deploy user, DB, .env
└── compose/
    ├── scanner.yml                — docker-compose for scanner service
    ├── data-service.yml           — docker-compose for data-service
    └── blockchain-postgres-sync.yml — docker-compose for BPS
```

## How caller repos use this

```yaml
# In DecentralChain/.github/workflows/deploy-scanner.yml
jobs:
  deploy:
    uses: Decentral-America/infra/.github/workflows/deploy-container.yml@main
    with:
      network:  mainnet
      service:  scanner
      image:    ghcr.io/decentral-america/scanner:${{ github.sha }}
    secrets: inherit
```

The `deploy-container.yml` job declares `environment: ${{ inputs.network }}` — GHA
reads `DEPLOY_HOST/USER/SSH_KEY/HOST_FINGERPRINT` from **this repo's** environments,
not the caller's. Caller repos have zero environments, zero environment secrets.

## One-time setup checklist

### 1 — GitHub repo

Create `Decentral-America/infra` as a **public** repo. Push these files to `main`.

### 2 — GitHub Environments (in this repo's Settings → Environments)

Create 3 environments: `mainnet`, `stagenet`, `testnet`.

Add 4 secrets to **each** environment (12 secrets total):

| Secret | Description |
|--------|-------------|
| `DEPLOY_HOST` | Linode server IP (from OpenTofu output) |
| `DEPLOY_USER` | SSH user — set to `deploy` |
| `DEPLOY_SSH_KEY` | Ed25519 private key, base64-encoded |
| `DEPLOY_HOST_FINGERPRINT` | Ed25519 host fingerprint |

### 3 — Repo-level secrets (Settings → Secrets → Actions)

| Secret | Description |
|--------|-------------|
| `LINODE_TOKEN` | Linode API token (read/write) |
| `LINODE_OBJ_ACCESS_KEY` | Linode Object Storage access key (OpenTofu state) |
| `LINODE_OBJ_SECRET_KEY` | Linode Object Storage secret key (OpenTofu state) |

### 4 — Org-level secrets (or add to each app repo if on GitHub Free)

| Secret | Used by |
|--------|---------|
| `GHCR_TOKEN` | All image push jobs (push to ghcr.io) |
| `CLOUDFLARE_API_TOKEN` | Exchange deploy (CF Pages) |
| `CLOUDFLARE_ACCOUNT_ID` | Exchange deploy (CF Pages) |

### 5 — Cloudflare Pages projects (one-time CLI, run once per network)

```bash
npx wrangler@4.93.1 pages project create dcc-exchange-mainnet --production-branch main
npx wrangler@4.93.1 pages project create dcc-exchange-stagenet --production-branch main
npx wrangler@4.93.1 pages project create dcc-exchange-testnet --production-branch main
```

### 6 — Generate deploy SSH keypair (once per network/server)

```bash
ssh-keygen -t ed25519 -C "github-actions-deploy" -f deploy_key
cat deploy_key | base64 -w0         # → DEPLOY_SSH_KEY secret
ssh-keyscan <host> | grep ed25519   # → DEPLOY_HOST_FINGERPRINT secret
# Add deploy_key.pub to the server's deploy user after OpenTofu provisions it
```

### 7 — Linode Object Storage state bucket (once)

```bash
linode-cli obj mb dcc-tofu-state --cluster us-east-1
```

### 8 — Provision servers via OpenTofu

Trigger the `provision.yml` workflow manually: action=`apply`, network=`mainnet`.
Repeat for `stagenet` and `testnet` as needed.

---

## Secret summary — total across entire ecosystem

| Location | Secrets | Count |
|----------|---------|-------|
| Org (or per-app-repo) | `GHCR_TOKEN`, `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` | 3 |
| infra `mainnet` env | `DEPLOY_HOST/USER/SSH_KEY/HOST_FINGERPRINT` | 4 |
| infra `stagenet` env | same names | 4 |
| infra `testnet` env | same names | 4 |
| infra repo-level | `LINODE_TOKEN`, `LINODE_OBJ_ACCESS_KEY`, `LINODE_OBJ_SECRET_KEY` | 3 |
| Server `/opt/dcc/secrets/*.env` | DB passwords (never in GitHub) | written by bootstrap |
| `DecentralChain` repo | **0** | **0** |
| `blockchain-postgres-sync` repo | **0** | **0** |
