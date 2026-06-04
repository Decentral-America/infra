# DecentralChain Infrastructure

> **Public repo:** `Decentral-America/infra`
>
> **Why public?** GitHub Free plan only allows reusable workflows to be called
> across repos when the called workflow's repo is public. No secrets are in the
> code — all sensitive values live in GitHub Secrets or on-server
> `/opt/dcc/secrets/<network>.env` files. Public infra repos are standard practice
> in the industry (HashiCorp, Cloudflare, etc. all follow this pattern).
>
> **Canonical ecosystem deploy runbook:** see [../DEPLOY.md](../DEPLOY.md). This README stays focused on infra-repo internals.

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
- [How to deploy](#how-to-deploy)

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
| **Org** | `CENTRAL_USERNAME` | 1 | ✅ set (⚠ can delete — replaced by `MAVEN_CENTRAL_USERNAME`) |
| **Org** | `CENTRAL_PASSWORD` | 1 | ✅ set (⚠ can delete — replaced by `MAVEN_CENTRAL_PASSWORD`) |
| **Org** | `MAVEN_CENTRAL_USERNAME` | 1 | ✅ set |
| **Org** | `MAVEN_CENTRAL_PASSWORD` | 1 | ✅ set |
| **Org** | `CODECOV_TOKEN` | 1 | ✅ set |
| **Org** | `DOCKERHUB_TOKEN` | 1 | ✅ set |
| **Org** | `GHCR_TOKEN` | 1 | ✅ set |
| **Org** | `CLOUDFLARE_API_TOKEN` | 1 | ✅ set |
| **Org** | `CLOUDFLARE_ACCOUNT_ID` | 1 | ✅ set |
| **Org** | `SENTRY_AUTH_TOKEN` | 1 | ✅ set |
| **Org** | `MAVEN_GPG_KEY_ID` | 1 | ✅ set |
| **Org** | `NVD_API_KEY` | 1 | ✅ set |
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

> ✅ **MAVEN_CENTRAL naming mismatch — RESOLVED** (2026-05-23). `publish-protobuf-serialization.yml`
> was updated to use `MAVEN_CENTRAL_USERNAME` / `MAVEN_CENTRAL_PASSWORD` (matching all other
> 6 publish workflows). Both secrets are now set at org level. The legacy `CENTRAL_USERNAME` /
> `CENTRAL_PASSWORD` secrets can be safely deleted from the org once confirmed no other workflow
> references them:
> ```bash
> gh secret delete CENTRAL_USERNAME --org Decentral-America
> gh secret delete CENTRAL_PASSWORD --org Decentral-America
> ```

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
**Status:** ✅ already set.

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
**Status:** ✅ already set.

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
**Status:** ✅ already set.

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

**Where:** Org level — ✅ already set.
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

**Where:** Org level — ✅ set (2026-05-23).
**Used by:** All 7 publish workflows: `publish-blst.yml`, `publish-curve25519.yml`,
`publish-groth16.yml`, `publish-java-sdk.yml`, `publish-protobuf-serialization.yml`,
`publish-ride.yml`, `publish-transactions.yml`.

Credentials for the Maven Central Portal (central.sonatype.com). These are the
Portal Token credentials, **not** your Sonatype Jira credentials (the legacy OSSRH
portal used Jira login; the new Central Portal uses separate API tokens).

**How to obtain Portal Tokens:**
1. Log in to central.sonatype.com with your Sonatype account.
2. Click your profile → Generate User Token.
3. The username token and password token displayed are
   `MAVEN_CENTRAL_USERNAME` and `MAVEN_CENTRAL_PASSWORD` respectively.
4. These tokens expire unless you extend them — note the expiry date.

---

#### `CENTRAL_USERNAME` / `CENTRAL_PASSWORD`

**Where:** Org level ✅ already set.
**Used by:** `publish-protobuf-serialization.yml` only.

Same type of Maven Central Portal Token as above. See `MAVEN_CENTRAL_USERNAME`
for how to obtain. The naming inconsistency is documented — see ⚠ in the
[master inventory](#master-secrets-inventory).

---

#### `NVD_API_KEY`

**Where:** Org level — ✅ already set.
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

#### `SENTRY_AUTH_TOKEN`

**Where:** Org level ✅ already set.
**Used by:** `deploy-exchange.yml`, `deploy-scanner.yml` — at Vite build time by
`@sentry/vite-plugin` to upload source maps and create Sentry releases.

**Why this is required:** Without source maps, every Sentry error shows minified
stack traces (`at o (main.abc123.js:1:8472)`) with no actionable file or line
number. This token authenticates the plugin to upload `.map` files to Sentry at
build time and then delete them from the output bundle so they are never served
to end users.

This is **different from the DSN**. The DSN is embedded in the app bundle (it is
safe to be public — it only accepts incoming events). This token is a server-side
secret used only during the CI build step.

**Required permissions:**
- `Project: Read & Write`
- `Release: Admin`

**How to create:**
1. Log in to sentry.io → your organisation → Settings → Auth Tokens.
2. Click **Create New Token**.
3. Select scopes: `project:read`, `project:write`, `project:releases`.
4. Copy the token — it is shown only once.
5. Store as org secret `SENTRY_AUTH_TOKEN`.

**How it is used in CI (example):**
```yaml
- name: Build exchange
  env:
    SENTRY_AUTH_TOKEN: ${{ secrets.SENTRY_AUTH_TOKEN }}
  run: pnpm --filter exchange build
```

The `@sentry/vite-plugin` in both `apps/exchange/vite.config.ts` and
`apps/scanner/vite.config.ts` reads `process.env.SENTRY_AUTH_TOKEN`. It
automatically no-ops when the variable is absent (local dev, forks) via the
`disable: !process.env.SENTRY_AUTH_TOKEN` guard already in the config.

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

---

## How to deploy

Everything in one place: what to tag, what fires, what must be set up first,
and how to verify each service after deploy.

---

### Deploy workflow reference

| Workflow | Tag trigger | Default network | Target | Required secrets |
|----------|------------|-----------------|--------|-----------------|
| `deploy-exchange.yml` | `exchange/v*.*.*` | mainnet | Cloudflare Pages | `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, `SENTRY_AUTH_TOKEN` |
| `deploy-scanner.yml` | `scanner/v*.*.*` | mainnet | GHCR image → SSH docker pull | `GHCR_TOKEN` (via infra), `SENTRY_AUTH_TOKEN` |
| `deploy-data-service.yml` | `data-service/v*.*.*` | mainnet | GHCR image → SSH docker pull | `GHCR_TOKEN` (via infra) |
| `deploy-bps.yml` | `bps/v*.*.*` | mainnet | GHCR image → SSH docker pull | `GHCR_TOKEN` (via infra) |
| `deploy-cubensis.yml` | `cubensis/v*.*.*` | — | Chrome / Firefox / Edge stores | All `CHROME_*`, `FIREFOX_*`, `EDGE_*` secrets |

Tag-based workflows target **mainnet** automatically. Any network can be targeted
at any time via **Actions → workflow → Run workflow** (manual `workflow_dispatch`).

---

### Tag naming convention

```bash
# Format: <product>/v<MAJOR>.<MINOR>.<PATCH>
git tag exchange/v1.0.0     && git push origin exchange/v1.0.0
git tag scanner/v1.0.0      && git push origin scanner/v1.0.0
git tag data-service/v1.0.0 && git push origin data-service/v1.0.0
git tag bps/v1.0.0          && git push origin bps/v1.0.0
git tag cubensis/v1.0.0     && git push origin cubensis/v1.0.0
```

The tag name becomes `SENTRY_RELEASE` and `GITHUB_REF_NAME` inside the workflow,
so it also labels the Sentry release that source maps are uploaded against.

---

### Complete pre-deploy requirements

Not one secret, variable, or file value is omitted. Every layer is listed.

---

#### Layer 1 — GitHub org secrets (`Decentral-America` → Settings → Secrets → Actions)

| Secret | Status | Used by | Notes |
|--------|--------|---------|-------|
| `NX_CLOUD_ACCESS_TOKEN` | ✅ set | `ci.yml`, all workflows | Nx remote task cache. Read-only. |
| `NPM_TOKEN` | ✅ set | `release.yml`, `publish-ride.yml` | Publish `@decentralchain/*` to npm. |
| `MAVEN_GPG_PRIVATE_KEY` | ✅ set | All `publish-*.yml` (JVM) | ASCII-armored GPG private key. Signs Maven artifacts. |
| `MAVEN_GPG_PASSPHRASE` | ✅ set | All `publish-*.yml` (JVM) | Passphrase protecting `MAVEN_GPG_PRIVATE_KEY`. |
| `MAVEN_CENTRAL_USERNAME` | ✅ set | All 7 JVM publish workflows | Sonatype Central Portal token username. |
| `MAVEN_CENTRAL_PASSWORD` | ✅ set | All 7 JVM publish workflows | Sonatype Central Portal token password. |
| `CODECOV_TOKEN` | ✅ set | CI coverage jobs | Repo upload token from codecov.io. |
| `DOCKERHUB_TOKEN` | ✅ set | Docker Hub image push | Access token from hub.docker.com. |
| `GHCR_TOKEN` | ✅ set | `deploy-container.yml` (infra, via SSH) | PAT `read:packages` only. Forwarded to Linode server for `docker login ghcr.io`. |
| `CLOUDFLARE_API_TOKEN` | ✅ set | `deploy-exchange.yml` | CF API token, `account:cloudflare_pages:edit` scope. Skipped gracefully when absent. |
| `CLOUDFLARE_ACCOUNT_ID` | ✅ set | `deploy-exchange.yml` | 32-char hex from `dash.cloudflare.com/<ACCOUNT_ID>`. |
| `SENTRY_AUTH_TOKEN` | ✅ set | `deploy-exchange.yml` (build env), `deploy-scanner.yml` (Docker secret) | Source-map upload. Scopes: `project:read`, `project:write`, `project:releases`. No-ops when absent. |
| `MAVEN_GPG_KEY_ID` | ❌ missing | `publish-blst.yml`, `publish-curve25519.yml`, `publish-groth16.yml`, `publish-java-sdk.yml`, `publish-ride.yml`, `publish-transactions.yml` | 8-char GPG short key ID: `gpg --list-secret-keys --keyid-format=short` |
| `NVD_API_KEY` | ✅ set | 5 JVM publish workflows | NIST NVD API key. Free, no approval — nvd.nist.gov/developers/request-an-api-key. |
| `CHROME_EXTENSION_ID` | ❌ missing | `deploy-cubensis.yml` | Chrome Web Store extension ID (32-char string). |
| `CHROME_CLIENT_ID` | ❌ missing | `deploy-cubensis.yml` | Google OAuth 2.0 client ID. |
| `CHROME_CLIENT_SECRET` | ❌ missing | `deploy-cubensis.yml` | Google OAuth 2.0 client secret. |
| `CHROME_REFRESH_TOKEN` | ❌ missing | `deploy-cubensis.yml` | Long-lived OAuth refresh token: `npx chrome-webstore-upload-cli@3 --action login` |
| `FIREFOX_ADDON_GUID` | ❌ missing | `deploy-cubensis.yml` | AMO addon GUID `{xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}`. |
| `FIREFOX_JWT_ISSUER` | ❌ missing | `deploy-cubensis.yml` | AMO API key issuer. addons.mozilla.org → User → API Keys. |
| `FIREFOX_JWT_SECRET` | ❌ missing | `deploy-cubensis.yml` | AMO API key secret (same page as issuer). |
| `EDGE_PRODUCT_ID` | ❌ missing | `deploy-cubensis.yml` | Microsoft Partner Center product ID. |
| `EDGE_CLIENT_ID` | ❌ missing | `deploy-cubensis.yml` | Microsoft Edge Addons API client ID. |
| `EDGE_API_KEY` | ❌ missing | `deploy-cubensis.yml` | Microsoft Edge Addons API key. |

> `GITHUB_TOKEN` is automatic — provided by GitHub Actions for every run. No setup needed.

> **Clean up legacy duplicates** (safe to delete — replaced by `MAVEN_CENTRAL_*`):
> ```bash
> gh secret delete CENTRAL_USERNAME --org Decentral-America
> gh secret delete CENTRAL_PASSWORD --org Decentral-America
> ```

---

#### Layer 2 — GitHub repository variable (`DecentralChain` repo → Settings → Variables → Actions)

| Variable | Required value | Status | Used by |
|----------|----------------|--------|---------|
| `INFRA_DEPLOY_ENABLED` | `true` | ❌ currently `false` | `deploy-scanner.yml`, `deploy-data-service.yml`, `deploy-bps.yml` |

```bash
# Enable when servers are provisioned and DEPLOY_* secrets are in place:
gh variable set INFRA_DEPLOY_ENABLED --body "true" --repo Decentral-America/DecentralChain
```

---

#### Layer 3 — infra repo environment secrets (`Decentral-America/infra` → Settings → Environments)

Four secrets × three networks = 12 values. All ❌ missing until servers are provisioned.

| Secret | mainnet | stagenet | testnet | Value |
|--------|---------|----------|---------|-------|
| `DEPLOY_HOST` | ❌ | ❌ | ❌ | IPv4 of Linode server — from `tofu output backend_ip` |
| `DEPLOY_USER` | ❌ | ❌ | ❌ | Always `deploy` |
| `DEPLOY_SSH_KEY` | ❌ | ❌ | ❌ | Ed25519 private key, base64-encoded single line |
| `DEPLOY_HOST_FINGERPRINT` | ❌ | ❌ | ❌ | `SHA256:...` from `ssh-keyscan -t ed25519 <HOST>` |

---

#### Layer 4 — infra repo secrets (repo-level, Settings → Secrets → Actions)

Used exclusively by `provision.yml` (OpenTofu). Not needed for day-to-day deploys.

| Secret | Status | Purpose |
|--------|--------|---------|
| `LINODE_TOKEN` | ❌ missing | Linode API — read/write Linodes, StackScripts, Firewalls, Object Storage |
| `LINODE_OBJ_ACCESS_KEY` | ❌ missing | OpenTofu S3 state backend (`dcc-tofu-state` bucket) |
| `LINODE_OBJ_SECRET_KEY` | ❌ missing | Same |

---

#### Layer 5 — App build-time env files (committed in the repo)

Not GitHub secrets. Baked into the build by Vite/Docker at CI time. Every variable listed.

**`apps/exchange/.env.production`** — mainnet (`exchange/v*.*.*` tag or `workflow_dispatch network=mainnet`)

| Variable | Committed value | Action |
|----------|----------------|--------|
| `VITE_APP_ENV` | `production` | ✅ |
| `VITE_NETWORK` | `mainnet` | ✅ |
| `VITE_NETWORK_BYTE` | `?` | ✅ |
| `VITE_NODE_URL` | `https://mainnet-node.decentralchain.io` | ✅ |
| `VITE_MATCHER_URL` | `https://mainnet-matcher.decentralchain.io/matcher` | ✅ |
| `VITE_API_URL` | `https://data-service.decentralchain.io` | ✅ |
| `VITE_DATA_SERVICE_URL` | `https://data-service.decentralchain.io` | ✅ |
| `VITE_EXPLORER_URL` | `https://decentralscan.com` | ✅ |
| `VITE_DEBUG` | `false` | ✅ |
| `VITE_ENABLE_MOCKS` | `false` | ✅ |
| `VITE_SENTRY_ENABLED` | `true` | ✅ |
| `VITE_SENTRY_DSN` | _(empty)_ | **⚠ fill in** — DSN from `dcc-exchange` Sentry project |

**`apps/exchange/.env.staging`** — stagenet (`workflow_dispatch network=stagenet`)

| Variable | Committed value | Action |
|----------|----------------|--------|
| `VITE_APP_ENV` | `staging` | ✅ |
| `VITE_NETWORK` | `stagenet` | ✅ |
| `VITE_NETWORK_BYTE` | `S` | ✅ |
| `VITE_NODE_URL` | `https://stagenet-node.decentralchain.io` | ✅ |
| `VITE_MATCHER_URL` | `https://stagenet-matcher.decentralchain.io/matcher` | ✅ |
| `VITE_API_URL` | `https://stagenet-data-service.decentralchain.io` | ✅ |
| `VITE_DATA_SERVICE_URL` | `https://stagenet-data-service.decentralchain.io` | ✅ |
| `VITE_EXPLORER_URL` | `https://stagenet.decentralscan.com` | ✅ |
| `VITE_DEBUG` | `true` | ✅ |
| `VITE_ENABLE_MOCKS` | `false` | ✅ |
| `VITE_SENTRY_ENABLED` | `true` | ✅ |
| `VITE_SENTRY_DSN` | _(empty)_ | **⚠ fill in** — DSN from `dcc-exchange` Sentry project |

**`apps/exchange/.env.testnet`** — testnet (`workflow_dispatch network=testnet`)

| Variable | Committed value | Action |
|----------|----------------|--------|
| `VITE_APP_ENV` | `testnet` | ✅ |
| `VITE_NETWORK` | `testnet` | ✅ |
| `VITE_NETWORK_BYTE` | `!` | ✅ |
| `VITE_NODE_URL` | `https://testnet-node.decentralchain.io` | ✅ |
| `VITE_MATCHER_URL` | `https://matcher.decentralchain.io/matcher` | ✅ |
| `VITE_API_URL` | `https://testnet-data-service.decentralchain.io` | ✅ |
| `VITE_DATA_SERVICE_URL` | `https://testnet-data-service.decentralchain.io` | ✅ |
| `VITE_EXPLORER_URL` | `https://testnet.decentralscan.com` | ✅ |
| `VITE_DEBUG` | `true` | ✅ |
| `VITE_ENABLE_MOCKS` | `false` | ✅ |
| `VITE_SENTRY_ENABLED` | `false` | ✅ — Sentry disabled on testnet by design |
| `VITE_SENTRY_DSN` | _(empty)_ | ✅ — disabled, no action needed |

**`apps/scanner/.env.production`** — every scanner Docker build

| Variable | Committed value | Action |
|----------|----------------|--------|
| `VITE_SENTRY_DSN` | _(empty)_ | **⚠ fill in** — DSN from `dcc-scanner` Sentry project |
| `VITE_APP_VERSION` | `0.0.0` | ✅ — CI overrides via `SENTRY_RELEASE` Docker build arg. Local-dev fallback only. |

**`apps/cubensis-connect/.env`** — bundled into the extension at build time

| Variable | Committed value | Action |
|----------|----------------|--------|
| `CUBENSIS_VERSION` | `0.0.0` | ✅ — CI overrides from tag (e.g. `cubensis/v1.2.3` → `1.2.3`) |
| `SENTRY_DSN` | _(empty)_ | **⚠ fill in** — DSN from `dcc-cubensis-connect` Sentry project |
| `SENTRY_ENVIRONMENT` | `production` | ✅ |

> **DSN values are safe to commit.** Sentry DSNs are public by design — they only accept inbound events. Never commit `SENTRY_AUTH_TOKEN` — that belongs in GitHub org secrets only.

---

#### Layer 6 — CI-injected variables (automatic — no setup needed)

| Variable | Injected as | Used in |
|----------|------------|---------|
| `SENTRY_RELEASE` | `${{ github.ref_name }}` (e.g. `exchange/v1.2.3`) | Exchange build step `env:`; Scanner Docker `build-args:` |
| `VITE_APP_VERSION` | `${SENTRY_RELEASE}` inside Dockerfile `ARG` | Scanner Vite build (`import.meta.env.VITE_APP_VERSION`) |
| `GITHUB_TOKEN` | Automatic GitHub Actions token | All workflows — GHCR image push, CF Pages deployment status |

---

#### Layer 7 — On-server variables (`/opt/dcc/secrets/<network>.env`)

Written once at server provision time by `bootstrap.sh` via Linode StackScript UDF. Never in GitHub. Sourced by Docker Compose `env_file:`.

| Variable | Example (mainnet) | Used by |
|----------|------------------|---------|
| `NETWORK` | `mainnet` | All containers |
| `CHAIN_ID` | `63` (`?`=63, `S`=83, `!`=33) | All containers |
| `POSTGRES_PASSWORD` | `<random 32+ chars>` | All containers (DB auth) |
| `POSTGRES_USER` | `dcc` | All containers |
| `POSTGRES_DB` | `dcc_mainnet` | All containers |
| `PGHOST` | `localhost` | CLI clients on server |
| `PGPORT` | `5432` | CLI clients |
| `PGDATABASE` | `dcc_mainnet` | CLI clients |
| `PGUSER` | `dcc` | CLI clients |
| `PGPASSWORD` | `<same as POSTGRES_PASSWORD>` | CLI clients |
| `DCC_NODE_URL` | `https://mainnet-node.decentralchain.io` | scanner |
| `DCC_MATCHER_URL` | `https://mainnet-matcher.decentralchain.io` | scanner |
| `DCC_DATA_SERVICE_URL` | `https://data-service.decentralchain.io/v0` | scanner |
| `BLOCKCHAIN_UPDATES_URL` | `grpc://mainnet-node.decentralchain.io:6881` | blockchain-postgres-sync |
| `DEFAULT_MATCHER` | `<DCC blockchain address>` | data-service |
| `RATE_PAIR_ACCEPTANCE_VOLUME_THRESHOLD` | `0` | data-service |
| `RATE_THRESHOLD_ASSET_ID` | `DCC` | data-service |

> These 17 values are passed to the Linode StackScript as OpenTofu `var.*` inputs during `tofu apply`. They are written to disk at provision time and never transmitted after that.

---

#### Priority — what blocks what

| Priority | Missing item | Blocks |
|----------|-------------|--------|
| 🔴 Critical path | `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID` | Exchange deploy |
| 🔴 Critical path | `GHCR_TOKEN` | All 3 container deploys (scanner, data-service, BPS) |
| 🔴 Critical path | `DEPLOY_*` × 3 + `LINODE_*` | Gate 3 server go-live (Gabriel) |
| 🟡 Pre-release | `SENTRY_AUTH_TOKEN` | Source maps in exchange + scanner (no-ops gracefully when absent) |
| 🟡 Pre-release | `MAVEN_GPG_KEY_ID` + `NVD_API_KEY` | All 7 JVM publish workflows |
| 🟡 Pre-release | `CHROME_*` / `FIREFOX_*` / `EDGE_*` | Cubensis browser store publish |
| 📝 Config (commit) | `VITE_SENTRY_DSN` in exchange `.env.production` + `.env.staging` | Sentry in exchange |
| 📝 Config (commit) | `VITE_SENTRY_DSN` in scanner `.env.production` | Sentry in scanner |
| 📝 Config (commit) | `SENTRY_DSN` in cubensis `.env` | Sentry in cubensis |

---

#### Minimum to get Exchange live (no server required)

| # | Action | Where |
|---|--------|-------|
| 1 | Create `dcc-exchange` project in Sentry | sentry.io |
| 2 | Fill `VITE_SENTRY_DSN` in `apps/exchange/.env.production` + `.env.staging` | commit to repo |
| 3 | Set `CLOUDFLARE_API_TOKEN` | GitHub org secret |
| 4 | Set `CLOUDFLARE_ACCOUNT_ID` | GitHub org secret |
| 5 | Set `SENTRY_AUTH_TOKEN` | GitHub org secret |
| 6 | Create CF Pages projects (one-time — see [setup step 5](#5--create-cloudflare-pages-projects-one-time)) | `npx wrangler pages project create` |
| 7 | Push `exchange/v1.0.0` tag | git |

#### Minimum to get Scanner / Data Service / BPS live (requires server)

| # | Action | Where |
|---|--------|-------|
| 1 | Provision Linode server (`provision.yml` apply) | GitHub Actions |
| 2 | Set `DEPLOY_HOST` from `tofu output backend_ip` | infra repo mainnet environment |
| 3 | Set `DEPLOY_USER = deploy` | infra repo mainnet environment |
| 4 | Generate + set `DEPLOY_SSH_KEY` | infra repo mainnet environment |
| 5 | Set `DEPLOY_HOST_FINGERPRINT` from `ssh-keyscan` | infra repo mainnet environment |
| 6 | Set `GHCR_TOKEN` (`read:packages` PAT) | GitHub org secret |
| 7 | Set `INFRA_DEPLOY_ENABLED = true` | `DecentralChain` repo variable |
| 8 | Create `dcc-scanner` project in Sentry | sentry.io |
| 9 | Fill `VITE_SENTRY_DSN` in `apps/scanner/.env.production` | commit to repo |
| 10 | Set `SENTRY_AUTH_TOKEN` | GitHub org secret |
| 11 | Push `scanner/v1.0.0` tag | git |

---


### Exchange deploy (Cloudflare Pages)

```bash
# 1. Fill VITE_SENTRY_DSN in apps/exchange/.env.production (commit it)
# 2. Ensure CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID org secrets are set
# 3. Ensure SENTRY_AUTH_TOKEN org secret is set (source map uploads)
# 4. Tag and push — CI builds and deploys to mainnet automatically:
git tag exchange/v1.2.3 && git push origin exchange/v1.2.3

# Deploy to stagenet without a tag (manual dispatch):
gh workflow run deploy-exchange.yml --field network=stagenet
```

**What happens:** Vite builds the SPA with the network baked in via `--mode`.
`@sentry/vite-plugin` uploads source maps to Sentry then deletes the `.map` files
from `dist/`. Wrangler uploads the output to the appropriate Cloudflare Pages project
(`dcc-exchange-mainnet`, `dcc-exchange-stagenet`, or `dcc-exchange-testnet`).

**Verify:**
```bash
# Mainnet
curl -sI https://decentral.exchange | grep -E "HTTP|CF-Ray|x-frame"
# Stagenet
curl -sI https://stagenet.decentral.exchange | grep -E "HTTP|CF-Ray"
```

---

### Scanner deploy (Docker → Linode)

```bash
# Prerequisites:
#   - INFRA_DEPLOY_ENABLED=true (repository variable in DecentralChain repo)
#   - DEPLOY_* secrets set in infra repo mainnet environment
#   - SENTRY_AUTH_TOKEN org secret set
#   - VITE_SENTRY_DSN committed in apps/scanner/.env.production

git tag scanner/v1.2.3 && git push origin scanner/v1.2.3

# Manual deploy to testnet:
gh workflow run deploy-scanner.yml --field network=testnet
```

**What happens:** Docker builds a multi-stage image. During the build stage,
`SENTRY_RELEASE` is passed as a build arg and becomes `VITE_APP_VERSION` for the
Vite build; `SENTRY_AUTH_TOKEN` is mounted as a Docker secret (never baked into
image layers) so `@sentry/vite-plugin` can upload maps. The image is pushed to
GHCR. The infra `deploy-container.yml` workflow then SSHs to the server, runs
`docker pull ghcr.io/decentral-america/scanner:<sha>`, and restarts the container.

**Verify:**
```bash
curl -sI https://scanner.decentralchain.io/ | grep HTTP
# Should return HTTP/2 200
```

---

### Data Service deploy (Docker → Linode)

```bash
git tag data-service/v1.2.3 && git push origin data-service/v1.2.3

# Verify after deploy:
curl -s "https://data-service.decentralchain.io/v0/assets?ids[]=DCC" | jq .data[0].id
# Should return "DCC" (or equivalent native asset entry)
```

---

### blockchain-postgres-sync deploy (Docker → Linode)

```bash
git tag bps/v1.2.3 && git push origin bps/v1.2.3

# Verify on the server after deploy:
# SSH to the Linode and check that the sync daemon is progressing:
ssh deploy@<DEPLOY_HOST> "docker logs --tail=20 blockchain-postgres-sync"
# Look for lines like: "synced block <HEIGHT>"
```

---

### Cubensis Connect publish (browser stores)

```bash
# Prerequisites: all CHROME_*, FIREFOX_*, EDGE_* org secrets set
# Fill SENTRY_DSN in apps/cubensis-connect/.env (commit it)

git tag cubensis/v1.2.3 && git push origin cubensis/v1.2.3
```

**What happens:** Builds separate zip packages for Chrome MV3, Firefox MV2, and
Edge. Submits each package to its store via the store's publish API. Also produces
a `cubensis-opera-<version>.zip` release artifact for manual Opera submission
(Opera has no publish API; it installs Chrome extensions directly).

**Verify:** Check the store developer dashboards for submission status. Store
review takes hours (Chrome) to days (Firefox) — the workflow succeeds when the
upload is accepted by the store, not when review is complete.

---

### Post-deploy verification checklist

| Product | Command / URL | What to look for |
|---------|--------------|-----------------|
| Exchange | https://decentral.exchange | Page loads, order book populates, no JS console errors |
| Scanner | https://scanner.decentralchain.io | Latest block shows, transactions link correctly |
| Data service | `curl "https://data-service.decentralchain.io/v0/assets?ids[]=DCC"` | `200 OK`, non-empty `data[]` array |
| BPS | `docker logs blockchain-postgres-sync` (on server) | Block height advancing, no `ERROR` lines |
| Cubensis | Load extension → open popup | No Sentry errors in sentry.io |
| Sentry source maps | Trigger a test error in the app | Stack trace in Sentry shows real file + line number (not minified) |

---

### Rollback

All products use immutable deployments — rolling back means re-deploying the
previous tag.

```bash
# Exchange: redeploy previous tag to CF Pages (atomic — CF keeps last 3 deployments)
gh workflow run deploy-exchange.yml --field network=mainnet
# (from the previous tag's commit, or use CF dashboard "Rollback deployment" directly)

# Scanner / data-service / BPS: previous image is still in GHCR with its SHA tag.
# SSH to server and restart with the previous image:
ssh deploy@<DEPLOY_HOST> \
  "docker pull ghcr.io/decentral-america/scanner:<PREVIOUS_SHA> && \
   docker stop scanner && \
   docker run -d --name scanner --env-file /opt/dcc/secrets/mainnet.env \
     ghcr.io/decentral-america/scanner:<PREVIOUS_SHA>"
```
