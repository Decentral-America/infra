# DecentralChain Infrastructure

> **Public repo:** `Decentral-America/infra`
>
> **Why public?** GitHub Free plan only allows reusable workflows to be called
> across repos when the called workflow's repo is public. No secrets are in the
> code — all sensitive values live in GitHub Secrets or on-server
> `/opt/dcc/secrets/<network>.env` files. Public infra repos are standard practice
> in the industry (HashiCorp, Cloudflare, etc. all follow this pattern).

---

## Table of Contents

- [Repository structure](#repository-structure)
- [Secret architecture](#secret-architecture--three-tiers)
- [Master secrets inventory](#master-secrets-inventory)
- [GitHub Environments reference](#github-environments-reference)
- [Per-secret reference (every secret explained)](#per-secret-reference)
- [Server `.env` file reference](#server-env-file-reference)
- [OpenTofu variables reference](#opentofu-variables-reference)
- [One-time setup checklist](#one-time-setup-checklist)
- [Activation](#activation)

---

## Repository structure

```
infra/
├── .github/
│   └── workflows/
│       ├── deploy-container.yml     Reusable: SSH docker pull + compose up for any service
│       └── provision.yml            OpenTofu: provision / update Linode servers
├── terraform/
│   ├── main.tf                      OpenTofu root (Linode provider, S3 state backend, firewall)
│   ├── variables.tf                 All input variables with descriptions
│   ├── outputs.tf                   Outputs: server IP, IPv6, chain ID
│   └── scripts/
│       └── bootstrap.sh             First-boot StackScript: Docker, PostgreSQL 17,
│                                    deploy user, /opt/dcc/secrets/<network>.env
└── compose/
    ├── scanner.yml                  docker-compose for the scanner service (port 3000)
    ├── data-service.yml             docker-compose for the data service (port 8080)
    └── blockchain-postgres-sync.yml docker-compose for BPS (host network, PostgreSQL)
```

---

## Secret architecture — three tiers

Secrets are split across three tiers by sensitivity and scope. **Nothing sensitive is
in this repo's files.** Each tier exists for a distinct reason.

```
┌─────────────────────────────────────────────────────────────────────┐
│ Tier 1 — GitHub Secrets (org or repo level)                         │
│                                                                     │
│  Lives in: GitHub org (Decentral-America) or a specific repo        │
│  Accessible to: GHA workflow runners                                │
│  Examples: GHCR_TOKEN, CLOUDFLARE_API_TOKEN, LINODE_TOKEN           │
│                                                                     │
│  These never touch the server. They only run inside GitHub Actions  │
│  runners or are forwarded to the server for a single operation      │
│  (e.g. GHCR_TOKEN is used once for docker login, then discarded).   │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
┌────────────────────────────────▼────────────────────────────────────┐
│ Tier 2 — GitHub Environment Secrets (infra repo only)               │
│                                                                     │
│  Lives in: this repo's Settings → Environments                      │
│  Scoped to: one network (mainnet / stagenet / testnet)              │
│  Examples: DEPLOY_HOST, DEPLOY_USER, DEPLOY_SSH_KEY                 │
│                                                                     │
│  The deploy-container.yml job declares environment: <network>.      │
│  GHA reads these secrets from THIS repo's environment, not from     │
│  the calling repo. This is the key isolation: callers pass          │
│  `secrets: inherit` but the SSH credentials only ever live here.    │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
┌────────────────────────────────▼────────────────────────────────────┐
│ Tier 3 — On-Server Secrets (/opt/dcc/secrets/<network>.env)         │
│                                                                     │
│  Written once by bootstrap.sh at instance creation time.            │
│  Never stored in GitHub. Not passed through environment variables   │
│  in compose files (compose uses env_file: to source them).          │
│  Examples: POSTGRES_PASSWORD, DCC_NODE_URL, DEFAULT_MATCHER         │
│                                                                     │
│  These stay on the server forever. No rotation mechanism needed     │
│  unless the database password or matcher address changes.           │
└─────────────────────────────────────────────────────────────────────┘
```

**Key architectural rule:** environment secrets in `deploy-container.yml` come from
the **infra repo's** environments, NOT from the calling repo. `secrets: inherit`
in callers (DecentralChain repo) forwards that repo's secrets — but the SSH
credentials (`DEPLOY_*`) are infra-scoped and the deploy job's
`environment: ${{ inputs.network }}` declaration makes GHA read from here.

---

## Master secrets inventory

Complete count across the entire ecosystem. No secrets live in the `DecentralChain`
or `blockchain-postgres-sync` repo.

| Location | Secret(s) | Count | Status |
|----------|-----------|------:|--------|
| **Org** (`Decentral-America`) | `NX_CLOUD_ACCESS_TOKEN` | 1 | ✅ set |
| **Org** | `NPM_TOKEN` | 1 | ✅ set |
| **Org** | `MAVEN_GPG_PRIVATE_KEY` | 1 | ✅ set |
| **Org** | `MAVEN_GPG_PASSPHRASE` | 1 | ✅ set |
| **Org** | `CENTRAL_USERNAME` | 1 | ✅ set (⚠ name mismatch — see below) |
| **Org** | `CENTRAL_PASSWORD` | 1 | ✅ set (⚠ name mismatch — see below) |
| **Org** | `CODECOV_TOKEN` | 1 | ✅ set |
| **Org** | `DOCKERHUB_TOKEN` | 1 | ✅ set |
| **Org** | `GHCR_TOKEN` | 1 | ❌ missing |
| **Org** | `CLOUDFLARE_API_TOKEN` | 1 | ❌ missing |
| **Org** | `CLOUDFLARE_ACCOUNT_ID` | 1 | ❌ missing |
| **Org** | `MAVEN_CENTRAL_USERNAME` | 1 | ❌ missing (see ⚠ below) |
| **Org** | `MAVEN_CENTRAL_PASSWORD` | 1 | ❌ missing (see ⚠ below) |
| **Org** | `MAVEN_GPG_KEY_ID` | 1 | ❌ missing |
| **Org** | `NVD_API_KEY` | 1 | ❌ missing |
| **Org** | `CHROME_EXTENSION_ID` | 1 | ❌ missing |
| **Org** | `CHROME_CLIENT_ID` | 1 | ❌ missing |
| **Org** | `CHROME_CLIENT_SECRET` | 1 | ❌ missing |
| **Org** | `CHROME_REFRESH_TOKEN` | 1 | ❌ missing |
| **Org** | `FIREFOX_ADDON_GUID` | 1 | ❌ missing |
| **Org** | `FIREFOX_JWT_ISSUER` | 1 | ❌ missing |
| **Org** | `FIREFOX_JWT_SECRET` | 1 | ❌ missing |
| **Org** | `EDGE_PRODUCT_ID` | 1 | ❌ missing |
| **Org** | `EDGE_CLIENT_ID` | 1 | ❌ missing |
| **Org** | `EDGE_API_KEY` | 1 | ❌ missing |
| **infra repo** (`mainnet` env) | `DEPLOY_HOST` | 1 | ❌ missing |
| **infra repo** (`mainnet` env) | `DEPLOY_USER` | 1 | ❌ missing |
| **infra repo** (`mainnet` env) | `DEPLOY_SSH_KEY` | 1 | ❌ missing |
| **infra repo** (`mainnet` env) | `DEPLOY_HOST_FINGERPRINT` | 1 | ❌ missing |
| **infra repo** (`stagenet` env) | same 4 DEPLOY_* secrets | 4 | ❌ missing |
| **infra repo** (`testnet` env) | same 4 DEPLOY_* secrets | 4 | ❌ missing |
| **infra repo** (repo-level) | `LINODE_TOKEN` | 1 | ❌ missing |
| **infra repo** (repo-level) | `LINODE_OBJ_ACCESS_KEY` | 1 | ❌ missing |
| **infra repo** (repo-level) | `LINODE_OBJ_SECRET_KEY` | 1 | ❌ missing |
| **Server** `/opt/dcc/secrets/*.env` | written by bootstrap (see §[Server .env](#server-env-file-reference)) | — | written at provision time |
| **DecentralChain repo** | — | **0** | nothing needed |

> **⚠ MAVEN_CENTRAL naming mismatch.** The org currently has `CENTRAL_USERNAME` and
> `CENTRAL_PASSWORD`. The `publish-protobuf-serialization.yml` workflow uses those names.
> However, `publish-blst.yml`, `publish-curve25519.yml`, `publish-groth16.yml`,
> `publish-java-sdk.yml`, `publish-ride.yml`, and `publish-transactions.yml` all
> reference `MAVEN_CENTRAL_USERNAME` / `MAVEN_CENTRAL_PASSWORD` — different names.
> **Fix:** either rename the existing org secrets to `MAVEN_CENTRAL_USERNAME` /
> `MAVEN_CENTRAL_PASSWORD` (and update `publish-protobuf-serialization.yml` to match),
> or add `MAVEN_CENTRAL_*` as aliases pointing at the same values. Publish workflows
> only fire on version tags so this is not blocking CI today.

---

## GitHub Environments reference

This repo requires **six** GitHub Environments (Settings → Environments):

| Environment | Purpose | Secrets it holds |
|-------------|---------|-----------------|
| `mainnet` | Live deploy target for deploy-container.yml | `DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_SSH_KEY`, `DEPLOY_HOST_FINGERPRINT` |
| `stagenet` | Staging deploy target | same 4 secrets |
| `testnet` | Testnet deploy target | same 4 secrets |
| `infra-mainnet-provision` | Human-approval gate for OpenTofu apply/destroy on mainnet | no secrets — acts as approval gate only |
| `infra-stagenet-provision` | Human-approval gate for OpenTofu stagenet | no secrets |
| `infra-testnet-provision` | Human-approval gate for OpenTofu testnet | no secrets |

**Why separate provision environments?** The `provision.yml` workflow uses
`infra-<network>-provision` (not the plain `mainnet`/`stagenet`/`testnet` environments).
This lets you configure required reviewers on provisioning (destructive infra changes)
independently of deploy (routine service restarts). The deploy environments have no
required reviewers — CI deploys must be fast and automated.

---

## Per-secret reference

### Tier 1 — GitHub org secrets

---

#### `GHCR_TOKEN`

**Where:** Org level (`Decentral-America`) or infra repo level.
**Used by:** `deploy-container.yml` — passed via SSH to the server for `docker login ghcr.io`.
**Status:** ❌ missing.

The server must authenticate to GHCR before pulling private images. The deploy
workflow forwards this token into the SSH session via `appleboy/ssh-action`'s
`envs:` parameter. After the SSH session ends the token is discarded — it never
persists on the server.

**How to create:**
1. Go to GitHub → your personal account → Settings → Developer settings →
   Personal access tokens → Fine-grained tokens (or classic tokens).
2. **Required scope:** `read:packages` — that is the only scope needed.
3. If using a classic PAT: `read:packages` only. Do NOT give `write:packages`,
   `repo`, or any other scope.
4. If using a fine-grained PAT: set resource owner to `Decentral-America`,
   repository access to all org repos, permissions → packages: read.
5. Store the token value as org secret `GHCR_TOKEN`.

**Alternative (no long-lived PAT):** Create a dedicated machine-user GitHub account,
add it to the org with read-only member access, and use a PAT from that account.
This reduces blast radius if the token is ever compromised.

---

#### `CLOUDFLARE_API_TOKEN`

**Where:** Org level.
**Used by:** `deploy-exchange.yml` — passed to `cloudflare/wrangler-action`.
**Status:** ❌ missing.

Controls uploads to Cloudflare Pages for the exchange SPA. Three separate CF Pages
projects are used (one per network: `dcc-exchange-mainnet`, `dcc-exchange-stagenet`,
`dcc-exchange-testnet`). The token must have permission to deploy to all three.

**How to create:**
1. Log in to Cloudflare Dashboard → Account → My Profile → API Tokens.
2. Click **Create Token** → **Use a template** → **Edit Cloudflare Pages**.
3. Scope to your account. This creates a token with `account:cloudflare_pages:edit`.
   That is the minimum — do not use a global API key.
4. The token is shown once. Copy it immediately.
5. Store as org secret `CLOUDFLARE_API_TOKEN`.

> Note: the Pages projects themselves must be pre-created (see [setup step 5](#5--create-cloudflare-pages-projects-one-time)).
> The token only works after the projects exist.

---

#### `CLOUDFLARE_ACCOUNT_ID`

**Where:** Org level.
**Used by:** `deploy-exchange.yml` alongside `CLOUDFLARE_API_TOKEN`.
**Status:** ❌ missing.

The account ID scopes the API token to the correct Cloudflare account.

**How to find:**
1. Log in to Cloudflare Dashboard.
2. Select your account from the sidebar.
3. The URL shows `https://dash.cloudflare.com/<ACCOUNT_ID>`. That 32-character hex
   string is the account ID.
4. Alternatively: Account → Overview — the account ID is listed in the right sidebar.
5. This is **not** a secret in the cryptographic sense (it appears in URLs), but
   GitHub treats it as one for configuration cleanliness.

---

#### `NX_CLOUD_ACCESS_TOKEN`

**Where:** Org level ✅ already set.
**Used by:** `ci.yml`, `cubensis-nightly-e2e.yml`.

Enables distributed computation caching and remote task execution on Nx Cloud. When
set, CI builds share their task output cache across runs. When not set, every run
re-computes everything. The token is read-only for cache hits; it does not grant
access to repository code.

**How to find/rotate:** Log in to cloud.nx.app → your workspace → Settings →
Access Tokens.

---

#### `NPM_TOKEN`

**Where:** Org level ✅ already set.
**Used by:** `release.yml` (publishes workspace packages to npm), `publish-ride.yml`.

Authenticates to npm for `npm publish`. Required for publishing `@decentralchain/*`
packages. The token must have `publish` permission on the `@decentralchain` npm org.

**How to create:**
1. Log in to npmjs.com → profile → Access Tokens → Generate New Token → Automation.
2. The token needs to be scoped to the `@decentralchain` npm org.
3. Store as `NPM_TOKEN`.

---

#### `MAVEN_GPG_PRIVATE_KEY`

**Where:** Org level ✅ already set.
**Used by:** All `publish-*.yml` workflows (Scala/JVM packages).

The ASCII-armored GPG private key used to sign Maven artifacts before upload to
Maven Central. Maven Central requires all artifacts to be signed.

**Format:** Full ASCII-armored export including header/footer lines:
```
-----BEGIN PGP PRIVATE KEY BLOCK-----
<base64 content>
-----END PGP PRIVATE KEY BLOCK-----
```

**How to export:**
```bash
gpg --armor --export-secret-keys <KEY_ID> | pbcopy
```

---

#### `MAVEN_GPG_PASSPHRASE`

**Where:** Org level ✅ already set.
**Used by:** All `publish-*.yml` workflows.

The passphrase protecting `MAVEN_GPG_PRIVATE_KEY`. The sbt build calls
`gpg --batch --passphrase <value>` when signing artifacts.

---

#### `MAVEN_GPG_KEY_ID`

**Where:** Org level — ❌ missing.
**Used by:** `publish-blst.yml`, `publish-curve25519.yml`, `publish-groth16.yml`,
`publish-java-sdk.yml`, `publish-ride.yml`, `publish-transactions.yml`.

The 8-character short key ID (or full 40-character fingerprint) of the GPG key.
Used to tell sbt which key to sign with when the keyring has multiple keys.

**How to find:**
```bash
gpg --list-secret-keys --keyid-format=short
# Output: sec   ed25519/ABCD1234 2025-01-01
#                        ^^^^^^^^ — this is the short key ID
```

---

#### `MAVEN_CENTRAL_USERNAME` / `MAVEN_CENTRAL_PASSWORD`

**Where:** Org level — ❌ missing (org has `CENTRAL_USERNAME`/`CENTRAL_PASSWORD`
which serve `publish-protobuf-serialization.yml` only; the other 6 publish workflows
need `MAVEN_CENTRAL_*` names).
**Used by:** `publish-blst.yml`, `publish-curve25519.yml`, `publish-groth16.yml`,
`publish-java-sdk.yml`, `publish-ride.yml`, `publish-transactions.yml`.

Credentials for the Maven Central Portal (central.sonatype.com). These are the
Portal Token credentials, **not** your Sonatype Jira credentials (the legacy OSSRH
portal used Jira login; the new Central Portal uses separate API tokens).

**How to obtain Portal Tokens:**
1. Log in to central.sonatype.com with your Sonatype account.
2. Click your profile → Generate User Token.
3. The username token and password token displayed are
   `MAVEN_CENTRAL_USERNAME` and `MAVEN_CENTRAL_PASSWORD` respectively.
4. These tokens expire unless you extend them — note the expiry date.

**Resolution options:**
- **Option A (recommended):** Add `MAVEN_CENTRAL_USERNAME` and
  `MAVEN_CENTRAL_PASSWORD` as org secrets (same values as `CENTRAL_USERNAME`/
  `CENTRAL_PASSWORD` if they are the same account), then update
  `publish-protobuf-serialization.yml` to use the `MAVEN_CENTRAL_*` names.
- **Option B:** Keep both name pairs in the org. Two secrets with different names,
  same values. No workflow changes needed.

---

#### `CENTRAL_USERNAME` / `CENTRAL_PASSWORD`

**Where:** Org level ✅ already set.
**Used by:** `publish-protobuf-serialization.yml` only.

Same type of Maven Central Portal Token as above. See `MAVEN_CENTRAL_USERNAME`
for how to obtain. The naming inconsistency is documented — see ⚠ in the
[master inventory](#master-secrets-inventory).

---

#### `NVD_API_KEY`

**Where:** Org level — ❌ missing.
**Used by:** `publish-blst.yml`, `publish-curve25519.yml`, `publish-groth16.yml`,
`publish-java-sdk.yml`, `publish-transactions.yml`.

API key for the NIST National Vulnerability Database. Used by the
`dependency-check-maven` plugin to query CVE data during publish CI without hitting
unauthenticated rate limits (300 req/day without a key vs. 2,000/day with).

**How to obtain:**
1. Visit https://nvd.nist.gov/developers/request-an-api-key.
2. Enter your email. The key is emailed immediately — no approval required.
3. The key is a 128-bit UUID (e.g. `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`).
4. Store as `NVD_API_KEY`.

---

#### `CODECOV_TOKEN`

**Where:** Org level ✅ already set.
**Used by:** CI workflows that upload coverage reports to codecov.io.

The repository upload token from codecov.io. Found in the Codecov dashboard under
your repo's settings → Upload Token.

---

#### `DOCKERHUB_TOKEN`

**Where:** Org level ✅ already set.
**Used by:** Workflows that push Docker images to Docker Hub (if any).

An access token from hub.docker.com → Account Settings → Security → New Access Token.
Minimum required permission: `Read & Write`.

---

#### Browser Extension Store Secrets (`CHROME_*`, `FIREFOX_*`, `EDGE_*`)

**Where:** Org level — ❌ all 10 missing.
**Used by:** `deploy-cubensis.yml` — triggered only by `cubensis/v*.*.*` tags.

These are only needed when publishing the Cubensis Connect browser extension.
Not on the critical path for backend deployment.

| Secret | What it is | How to obtain |
|--------|-----------|---------------|
| `CHROME_EXTENSION_ID` | Chrome Web Store extension ID (32-char string) | Chrome Web Store Developer Dashboard → your extension → top of the page |
| `CHROME_CLIENT_ID` | Google OAuth 2.0 client ID | Google Cloud Console → APIs & Services → Credentials → OAuth 2.0 Client IDs |
| `CHROME_CLIENT_SECRET` | Google OAuth 2.0 client secret | Same credentials page as above |
| `CHROME_REFRESH_TOKEN` | Long-lived OAuth refresh token | Run the OAuth2 flow once using `chrome-webstore-upload-cli` (see below) |
| `FIREFOX_ADDON_GUID` | Mozilla AMO addon GUID, format: `{xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}` | AMO Developer Hub → your extension → Technical Details → UUID |
| `FIREFOX_JWT_ISSUER` | AMO API key issuer | addons.mozilla.org → User → Developer Tools → Manage API Keys → JWT issuer |
| `FIREFOX_JWT_SECRET` | AMO API key secret | Same page as issuer |
| `EDGE_PRODUCT_ID` | Microsoft Edge Addons product ID | Microsoft Partner Center → your extension → product ID in URL |
| `EDGE_CLIENT_ID` | Microsoft Edge Addons API client ID | Partner Center → Settings → API access → Create API credentials |
| `EDGE_API_KEY` | Microsoft Edge Addons API key | Same credentials page |

**How to obtain Chrome OAuth refresh token:**
```bash
npx chrome-webstore-upload-cli@3 --action login \
  --client-id <CHROME_CLIENT_ID> \
  --client-secret <CHROME_CLIENT_SECRET>
# Follow the browser OAuth flow — you get a refresh token at the end.
```

---

### Tier 2 — infra repo environment secrets

These are read by `deploy-container.yml` from this repo's environments. They are
never visible to caller repos. All four secrets are required in each environment
before setting `INFRA_DEPLOY_ENABLED=true`.

---

#### `DEPLOY_HOST`

**Environment:** `mainnet`, `stagenet`, `testnet` (one value per env).
**Format:** IPv4 address string, e.g. `198.51.100.42`.
**Status:** ❌ missing everywhere.

The public IP of the Linode backend server for that network. This IP is the output
of `tofu apply` (the `backend_ip` output). After provisioning, set this secret
before enabling deploys.

**Value source:** after running `provision.yml` with `action=apply`:
```bash
cd terraform/
tofu workspace select mainnet
tofu output backend_ip
```
Or read it directly from the Linode Cloud Manager → Linodes → the instance labeled
`dcc-backend-mainnet`.

---

#### `DEPLOY_USER`

**Environment:** `mainnet`, `stagenet`, `testnet` (same value in all three: `deploy`).
**Format:** Plain string.
**Status:** ❌ missing everywhere.

The SSH username on the server. The bootstrap script creates a user named `deploy`
with Docker group membership and no sudo. Set this to the string `deploy`.

---

#### `DEPLOY_SSH_KEY`

**Environment:** `mainnet`, `stagenet`, `testnet` (different key per environment recommended).
**Format:** Ed25519 private key, base64-encoded as a **single line** (no line breaks).
**Status:** ❌ missing everywhere.

The private half of the deploy SSH keypair. The public half is passed to OpenTofu
via `var.deploy_ssh_public_key`, which the bootstrap script writes to
`/home/deploy/.ssh/authorized_keys`.

**How to generate (once per network):**
```bash
# Generate a dedicated key — do NOT reuse your personal SSH key
ssh-keygen -t ed25519 -C "github-actions-deploy-mainnet" -f deploy_key_mainnet -N ""

# The public key goes into OpenTofu (see variables section)
cat deploy_key_mainnet.pub   # → var.deploy_ssh_public_key in tofu apply

# The private key is base64-encoded for the GitHub secret
# macOS:
cat deploy_key_mainnet | base64 | tr -d '\n'
# Linux:
cat deploy_key_mainnet | base64 -w0
# → DEPLOY_SSH_KEY secret value

# Delete the key files after storing the secret safely
rm deploy_key_mainnet deploy_key_mainnet.pub
```

> **Security note:** Use a separate keypair per network. If a mainnet key is ever
> compromised, stagenet/testnet are unaffected.

---

#### `DEPLOY_HOST_FINGERPRINT`

**Environment:** `mainnet`, `stagenet`, `testnet`.
**Format:** `SHA256:<base64>` (the fingerprint line from `ssh-keyscan`).
**Status:** ❌ missing everywhere.

The server's Ed25519 host key fingerprint. `appleboy/ssh-action` uses this to verify
the server's identity on every deploy, preventing man-in-the-middle attacks on the
deploy connection.

**How to obtain (after the server is provisioned):**
```bash
# Replace <HOST> with the server's public IP
ssh-keyscan -t ed25519 <HOST> 2>/dev/null | awk '{print $2, $3}' | ssh-keygen -lf - | awk '{print $2}'
# Output: SHA256:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

Or more directly — connect once and accept the key, then read it:
```bash
ssh-keyscan -t ed25519 <HOST> 2>/dev/null
# Output line: <IP> ssh-ed25519 AAAA...
# The fingerprint shown by the ssh client on first connect is the SHA256 of that key.
```

The value stored in the secret must be the full fingerprint string including the
`SHA256:` prefix, e.g. `SHA256:nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8`.

---

### Tier 2 — infra repo-level secrets (provision only)

These are used exclusively by `provision.yml` (OpenTofu) and are never needed by
any caller repo.

---

#### `LINODE_TOKEN`

**Where:** infra repo → Settings → Secrets → Actions (repo-level, not env-scoped).
**Used by:** `provision.yml` — passed as `LINODE_TOKEN` env var to `tofu` commands.
**Status:** ❌ missing.

A Linode Personal Access Token with read/write access to Linodes, StackScripts,
Firewalls, and Object Storage.

**How to create:**
1. Log in to cloud.linode.com → Profile → API Tokens → Create a Personal Access Token.
2. Label it `github-actions-opentofu`.
3. Expiry: set an appropriate duration (1 year recommended — calendar a rotation reminder).
4. Permissions: select **Read/Write** for:
   - Linodes
   - StackScripts
   - Firewalls
   - Object Storage (for state backend + bucket operations)
5. The token is shown once. Copy it immediately.
6. Store as infra repo secret `LINODE_TOKEN`.

---

#### `LINODE_OBJ_ACCESS_KEY`

**Where:** infra repo → Settings → Secrets → Actions.
**Used by:** `provision.yml` → `tofu init -backend-config="access_key=..."`.
**Status:** ❌ missing.

The S3-compatible access key for Linode Object Storage. OpenTofu uses this to
read and write the Terraform state file stored in the `dcc-tofu-state` bucket.
The state bucket must exist before `provision.yml` can run.

**How to create:**
1. Log in to cloud.linode.com → Object Storage → Access Keys.
2. Click **Create an Access Key**.
3. Label it `opentofu-state`. Scope it to the `dcc-tofu-state` bucket if the
   Linode UI offers bucket-scoped keys (not always available — in that case,
   use account-scoped keys with the narrowest available scope).
4. The access key is shown once alongside the secret key. Copy both immediately.
5. Store access key as `LINODE_OBJ_ACCESS_KEY`.

---

#### `LINODE_OBJ_SECRET_KEY`

**Where:** infra repo → Settings → Secrets → Actions.
**Used by:** `provision.yml` → `tofu init -backend-config="secret_key=..."`.
**Status:** ❌ missing.

The secret key paired with `LINODE_OBJ_ACCESS_KEY`. Treat like a password — rotate
on a schedule and whenever an operator with access leaves the team.

---

## Server `.env` file reference

`/opt/dcc/secrets/<network>.env` is written once by `bootstrap.sh` at instance
creation time (passed through Linode StackScript UDF variables from OpenTofu).
It is never stored in GitHub. All three containers source it via Docker Compose
`env_file:`.

| Variable | Example (mainnet) | Source | Description |
|----------|-------------------|--------|-------------|
| `NETWORK` | `mainnet` | OpenTofu UDF | Network name |
| `CHAIN_ID` | `63` | OpenTofu UDF | DCC chain byte (`?`=63, `S`=83, `!`=33) |
| `POSTGRES_PASSWORD` | `<random>` | OpenTofu `var.postgres_password` | PostgreSQL password for `dcc` role |
| `POSTGRES_USER` | `dcc` | hardcoded | PostgreSQL username |
| `POSTGRES_DB` | `dcc_mainnet` | derived | Database name |
| `PGHOST` | `localhost` | hardcoded | For `psql` CLI on the server |
| `PGPORT` | `5432` | hardcoded | |
| `PGDATABASE` | `dcc_mainnet` | derived | |
| `PGUSER` | `dcc` | hardcoded | |
| `PGPASSWORD` | `<same as POSTGRES_PASSWORD>` | OpenTofu | For CLI clients |
| `DCC_NODE_URL` | `https://mainnet-node.decentralchain.io` | bootstrap logic | Node REST API base URL |
| `DCC_MATCHER_URL` | `https://mainnet-matcher.decentralchain.io/matcher` | bootstrap logic | Matcher REST API URL |
| `DCC_DATA_SERVICE_URL` | `https://data-service.decentralchain.io/v0` | bootstrap logic | Data service URL consumed by scanner |
| `BLOCKCHAIN_UPDATES_URL` | `grpc://mainnet-node.decentralchain.io:6881` | OpenTofu UDF | gRPC endpoint for blockchain-postgres-sync |
| `DEFAULT_MATCHER` | `<DCC blockchain address>` | OpenTofu UDF | Matcher account address (data-service config) |
| `RATE_PAIR_ACCEPTANCE_VOLUME_THRESHOLD` | `0` | OpenTofu UDF | Minimum volume for rate pair display |
| `RATE_THRESHOLD_ASSET_ID` | `DCC` | OpenTofu UDF | Asset ID for rate threshold |

> **These values are never passed through GitHub Actions.** They are written at
> instance creation and read by Docker Compose at container start. If you need to
> update them after the fact, SSH to the server and edit the file directly, then
> restart the affected containers.

---

## OpenTofu variables reference

These are inputs to `terraform/variables.tf` and are passed at `tofu apply` time
(either as `-var` flags, a `terraform.tfvars` file, or environment variables
prefixed `TF_VAR_`). They flow into the server's `.env` file via the bootstrap
StackScript UDF mechanism.

| Variable | Sensitive | Required | Default | Description |
|----------|-----------|----------|---------|-------------|
| `linode_region` | no | no | `us-central` | Linode datacenter slug. Options: `us-central` (Dallas), `us-east` (Newark), `us-southeast` (Atlanta), `eu-west` (London), etc. Choose closest to your users. |
| `linode_type` | no | no | `g6-standard-2` | Linode plan (2 vCPU / 4 GB). For mainnet with full PostgreSQL history consider `g6-standard-4` (4 vCPU / 8 GB). Check `linode-cli linodes types` for current plans. |
| `root_password` | **yes** | yes | — | Root password for the Linode instance. Use a random 32+ character string. Store in a password manager. This is only used once at instance creation — you never SSH as root. |
| `deploy_ssh_public_key` | no | yes | — | Ed25519 public key for the `deploy` user (the `.pub` file output of `ssh-keygen`). This corresponds to `DEPLOY_SSH_KEY` private key stored in the GitHub environment. |
| `postgres_password` | **yes** | yes | — | PostgreSQL password for the `dcc` database role. Use a random 32+ character string. Written to `/opt/dcc/secrets/<network>.env` as `POSTGRES_PASSWORD`. Never stored in GitHub. |
| `default_matcher` | no | yes | — | The DCC blockchain address of the matcher contract for this network. Used by the data-service to identify exchange transactions. Mainnet and stagenet have different addresses. |
| `rate_pair_acceptance_volume_threshold` | no | no | `0` | Minimum 24h trade volume (in base units) for a rate pair to be included in data-service output. `0` = show all pairs regardless of volume. |
| `rate_threshold_asset_id` | no | no | `DCC` | The asset ID to use as the volume denominator for rate pair thresholds. |
| `blockchain_updates_url` | no | yes | — | gRPC URL for the DCC node's Blockchain Updates API. Format: `grpc://mainnet-node.decentralchain.io:6881`. Used by blockchain-postgres-sync to subscribe to new blocks. |

---

## One-time setup checklist

Follow these steps in order. Each step is a hard prerequisite for the next.

### 1 — Create the infra GitHub repo

Create `Decentral-America/infra` as a **public** repo. Push these files to `main`.
A public repo is required on GitHub Free for cross-repo reusable workflow calls.

### 2 — Create GitHub Environments (in this repo's Settings → Environments)

Create all **six** environments:

**Deploy environments** (4 secrets each, 12 secrets total):

```
mainnet    → DEPLOY_HOST, DEPLOY_USER, DEPLOY_SSH_KEY, DEPLOY_HOST_FINGERPRINT
stagenet   → (same 4 secrets, different values)
testnet    → (same 4 secrets, different values)
```

**Provision environments** (no secrets, just approval gates):

```
infra-mainnet-provision   → add required reviewers to gate apply/destroy
infra-stagenet-provision  → add required reviewers
infra-testnet-provision   → add required reviewers
```

### 3 — Add repo-level secrets (infra repo only)

In this repo: Settings → Secrets and variables → Actions → Repository secrets:

```
LINODE_TOKEN          — Linode API token (read/write: Linodes, StackScripts, Firewalls, Object Storage)
LINODE_OBJ_ACCESS_KEY — Object Storage access key (for tofu state backend)
LINODE_OBJ_SECRET_KEY — Object Storage secret key (for tofu state backend)
```

### 4 — Create Linode Object Storage state bucket

Before OpenTofu can run, the state bucket must exist:

```bash
linode-cli obj mb dcc-tofu-state --cluster us-east-1
# Verify:
linode-cli obj ls
```

### 5 — Create Cloudflare Pages projects (one-time)

The Exchange deploy workflow uploads to three Cloudflare Pages projects (one per
network). These must exist before the first deploy:

```bash
# Run from the DecentralChain monorepo root
pnpm add -w wrangler@4.93.1

# Create all three projects
npx wrangler@4.93.1 pages project create dcc-exchange-mainnet  --production-branch main
npx wrangler@4.93.1 pages project create dcc-exchange-stagenet --production-branch main
npx wrangler@4.93.1 pages project create dcc-exchange-testnet  --production-branch main
```

You must be logged in to Cloudflare first:
```bash
npx wrangler@4.93.1 login
```

### 6 — Add org-level secrets (in `Decentral-America` org Settings → Secrets)

**Required immediately (unblocks deploy-exchange and deploy-container):**
```
GHCR_TOKEN              — PAT with read:packages scope (for server docker pull)
CLOUDFLARE_API_TOKEN    — CF API token with Pages:Edit permission
CLOUDFLARE_ACCOUNT_ID   — CF account ID (32-char hex, not a secret but stored as one)
```

**Required for publish workflows (when ready to publish Maven/npm packages):**
```
MAVEN_CENTRAL_USERNAME  — Sonatype Central Portal token username
MAVEN_CENTRAL_PASSWORD  — Sonatype Central Portal token password
MAVEN_GPG_KEY_ID        — 8-char GPG short key ID
NVD_API_KEY             — NIST NVD API key (free, no approval required)
```

**Required for Cubensis Connect browser store publishing:**
```
CHROME_EXTENSION_ID, CHROME_CLIENT_ID, CHROME_CLIENT_SECRET, CHROME_REFRESH_TOKEN
FIREFOX_ADDON_GUID, FIREFOX_JWT_ISSUER, FIREFOX_JWT_SECRET
EDGE_PRODUCT_ID, EDGE_CLIENT_ID, EDGE_API_KEY
```

### 7 — Generate deploy SSH keypairs (once per network)

```bash
# Generate separate keypairs for each network
for NETWORK in mainnet stagenet testnet; do
  ssh-keygen -t ed25519 -C "github-actions-deploy-${NETWORK}" \
    -f "deploy_key_${NETWORK}" -N ""
  echo "=== ${NETWORK} public key (→ var.deploy_ssh_public_key in tofu) ==="
  cat "deploy_key_${NETWORK}.pub"
  echo "=== ${NETWORK} private key base64 (→ DEPLOY_SSH_KEY GitHub secret) ==="
  cat "deploy_key_${NETWORK}" | base64 | tr -d '\n'
  echo ""
done
```

Store each base64-encoded private key in the corresponding GitHub environment
(`mainnet`, `stagenet`, `testnet`) as `DEPLOY_SSH_KEY`.

Keep the `.pub` files — you need them as `var.deploy_ssh_public_key` when
running `tofu apply`.

Delete the plaintext private key files after storing the base64 in GitHub:
```bash
rm deploy_key_mainnet deploy_key_stagenet deploy_key_testnet
```

### 8 — Provision servers via OpenTofu

Trigger the `provision.yml` workflow manually from the Actions tab:

1. Select `action = plan`, `network = stagenet` first to verify the plan.
2. Review the plan output in the workflow logs.
3. Trigger again with `action = apply` — this requires approval from a required reviewer
   (configured on the `infra-stagenet-provision` environment).
4. After apply completes, copy the `backend_ip` output into the `DEPLOY_HOST` secret
   for the `stagenet` environment.
5. Repeat for `testnet` and `mainnet`.

### 9 — Obtain host fingerprints

After each server is provisioned and running:

```bash
# Replace <HOST> with the server's IP (from DEPLOY_HOST / tofu output)
ssh-keyscan -t ed25519 <HOST> 2>/dev/null \
  | awk '{print $2, $3}' \
  | ssh-keygen -lf - \
  | awk '{print $2}'
# Output: SHA256:nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8
```

Set this value as `DEPLOY_HOST_FINGERPRINT` in the corresponding GitHub environment.

### 10 — Set `DEPLOY_USER` secrets

In each deploy environment (`mainnet`, `stagenet`, `testnet`), set:
```
DEPLOY_USER = deploy
```
This matches the username created by `bootstrap.sh`. All three environments use
the same value.

---

## Activation

Once all secrets are in place, enable automated deploys by setting the repository
variable `INFRA_DEPLOY_ENABLED=true` in the `DecentralChain` repo:

```bash
gh variable set INFRA_DEPLOY_ENABLED --body "true" --repo Decentral-America/DecentralChain
```

The three container deploy workflows (`deploy-bps.yml`, `deploy-data-service.yml`,
`deploy-scanner.yml`) check this variable before calling `deploy-container.yml`.
While `false`, they skip the deploy step gracefully after building and pushing the
Docker image. This allows Docker image CI to run and validate on every commit even
before servers are provisioned.

**Current state:** `INFRA_DEPLOY_ENABLED = false`.
