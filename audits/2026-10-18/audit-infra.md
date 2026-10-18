# Infra repo vs live testnet: audit (2026-10-18, read-only)

Scope: `Ecosystem/infra` at origin/main `4e903d2` (local main in sync), compared against the live VPS 50.116.30.244, LKE 663401, Linode API, GitHub (secrets/variables/runs/protection) and public DNS/TLS.
Method: REPO-AUDIT-PROMPT.md, "verify, don't guess". Every claim below comes from a command run today. No secret values are reproduced here. Secret checks compared names, lengths, or equality on the host only.

Auditor's note on a slip: while dumping the matcher `local.conf` with a masking sed, the `redis.address` line was not masked. The Redis password appeared in this auditor's tool output only. It is not in this report. Treat it as seen by the audit session and rotate it if the policy calls for that.

---

## HIGH

### INF-H1: Anonymous internet users can read the main node REST API key and the E2E rate-limit bypass key through Grafana and Loki
- **Evidence:**
  - `monitoring/grafana.ini` has `[auth.anonymous] enabled = true, org_role = Viewer`.
  - `curl https://grafana.testnet.decentralchain.io/api/datasources` (no auth) returned Loki and Prometheus.
  - An anonymous `POST /api/ds/query` with a LogQL query against uid `loki` returned HTTP 200 with data.
  - Caddy `log` (update-caddy.yml generated Caddyfile) writes full request headers into its access log. Loki ingests that log through alloy.
  - On the host, Loki query `{container="caddy-testnet"} |~ "X-E2e-Bypass\":[\""` over 30d returned **30,884 lines**. Sampled values are 64 chars and in **PLAINTEXT**.
  - `|~ "X-Api-Key\":[\"[^R\"]"` returned **10 lines**, all host `testnet-node.decentralchain.io`, uri `/debug/validate`. The value is 44 chars. An equality check on the host shows it **matches `MAIN_NODE_REST_API_KEY`** in `/opt/dcc/secrets/testnet.env`, which is the current key, rotated 2026-10-10.
  - `Authorization` is REDACTED by Caddy (12 lines). Custom headers are not.
- **Why it matters:** the main node's API key (rotated on 10-10 under Task 7.1) and the bypass secret are effectively public. The bypass header disables the node and matcher edge rate limits (update-caddy.yml lines ~201-237, 340). Any Viewer can also run arbitrary LogQL over every container log on the VPS.
- **Fix:**
  - In Caddy, use `log { format filter { request>headers>X-Api-Key delete; request>headers>X-E2e-Bypass delete } }`, or the `log_credentials`-style header filter, on every site block.
  - Disable Grafana anonymous access, or use a public-dashboard-only setup. A Viewer can always query any datasource.
  - Rotate `MAIN_NODE_REST_API_KEY` and `E2E_RATE_LIMIT_BYPASS_KEY`.
  - Delete the affected Loki streams, or let retention expire them after rotation.

### INF-H2: The "final" sign-off is no longer the running system, and its image has been deleted from GHCR
- **Evidence:**
  - `git ls-remote --tags origin`: `testnet-final-2026-10-14` points to `08d4223` (#214).
  - `git show testnet-final-2026-10-14:node-config/testnet/vps-image.env` pins `sha256:9283525c26aa…`.
  - HEAD and live (VPS `docker inspect`, all three STS) run `sha256:8fccecebb65a…` (#213, 2026-10-15: "HotStuff equivocation deposit forfeiture from height 60000"). That is a consensus-rule change made after the soak and the sign-off.
  - `gh api --paginate orgs/Decentral-America/packages/container/node-scala/versions`: 36 versions and **no `9283525c`**. Only `testnet-pinned-fb4e980` exists, because #217 came too late to protect the earlier pins.
  - The only copy left is an untagged local image on the VPS (`docker images`: `9283525c26aa 7 days ago`).
  - `gh release list`: no releases.
  - TESTNET-FINAL-PLAN Phase 9: all 13 boxes unchecked.
- **Why it matters:** the tag claims "soak PASS" for a binary that no longer runs and can no longer be pulled. The live binary changed consensus rules without a soak. Rollback to the signed-off build is impossible from the registry.
- **Fix:**
  - Re-tag `testnet-pinned-9283525c` from the VPS local image (`docker tag` + push), or record that it is gone.
  - Run a new soak on `8fccecebb` and re-tag `testnet-final-<date>` on `e05181a`+.
  - Publish a GitHub Release listing the digests.
  - Tick the Phase 9 boxes with Soak Log lines, or state that they were waived.

### INF-H3: Unexplained live stake movement during this read-only audit window
- **Evidence:**
  - `GET /transactions/address/<gen-0>/limit/40`: a type-4 transfer at **h73262, 2026-10-18 15:45:17Z**, 31PmKN… to 31RPEK… (main), **13,000,000 DCC**.
  - gen-1 did the same at **h73269** (13,000,000 DCC to main).
  - No infra PR, issue or plan entry mentions it. The latest PRs are #213-#217.
  - Balances now: main 46.73M, gen-0 7.29M, gen-1 7.22M. `/generators/at/<h>` still shows the pre-transfer generating balances (main 20.73M, val-0 20.11M, gen-0 7.28M, gen-1 7.22M), so the window is still settling.
  - Docs claim otherwise:
    - TOPOLOGY.md:51-53 says "~26.7M DCC" each.
    - TESTNET-FINAL-PLAN (B4) says "4×~20M generators (1-failure tolerance)".
  - With quorum `endorsed*3 >= total*2` (plan RC notes, `FinalizationState.scala:111-115`) and the settled balances (total ≈81.35M, 2/3 ≈54.23M):
    - Losing main halts finality (34.6M).
    - main+gen-0 (54.02M) and main+gen-1 (53.95M) are each just under quorum.
- **Why it matters:** every funded key is public by accepted decision, so a transfer signed by the gen keys proves nothing about who sent it. If it was an operator rebalance toward "main authoritative", it is undocumented. If not, someone is moving stake.
- **Fix:** the operator confirms who sent the transfers and why. Then update TOPOLOGY.md, the plan's B4 claim and the fault-tolerance statement to the real distribution.

---

## MEDIUM

### INF-M1: The main node is not compose-managed. The repo healthcheck (Task 2.6) is not live, and several deploy paths diverge.
- **Evidence:**
  - `docker inspect node-scala-testnet` has no `com.docker.compose.*` labels.
  - The live healthcheck is the image default `wget … /node/status`.
  - The repo `compose/node-scala.yml:79-92` has the height-stall check (`/blocks/height`, 900s).
  - The host `/opt/dcc/compose/node-scala.yml` (dated Sep 12) has a third variant (`/node/version`, 30s, retries 5). Diff: 15 lines. This is the only compose file that differs; the other 11 are byte-identical.
  - The node is started by four copies of the same `docker run`: `update-node-image.yml`, `deploy-node-config.yml:55`, `restart-host-network.yml:69` and `deploy-specific-sha.yml:42`.
  - A fifth path, `node-scala/.github/workflows/deploy-node-scala.yml:49` → `deploy-container.yml` (`service: node-scala`, tag `node-scala-<net>-<sha>`), would bring the node up through the stale on-host compose file. It would use a tag rather than `vps-image.env`, which breaks rule D6 and is the "tag-drift bomb" class again.
  - Plan line 155 already lists this as open.
- **Fix:**
  - Pick one path: compose with a digest from `vps-image.env`, or a single shared script.
  - Delete the other `docker run` copies.
  - Point node-scala's deploy-node-scala.yml at it, or delete it.
  - Sync compose to the host, then verify `docker inspect …Healthcheck`.

### INF-M2: The node deploy workflows report success when the deploy fails
- **Evidence:**
  - `update-node-image.yml` remote block runs under `set +e`: pull, stop, rm and run are unchecked.
  - The only gate is the class-linkage check: `docker logs --since 2m node-scala-testnet 2>&1 | grep -cE '…' || true`. If the container does not exist, that returns `0`, so the step passes.
  - There is no height, health or `docker inspect` gate. The same `docker run` block is copied into the three sibling workflows.
- **Why it matters:** a failed pull or a bad image leaves the main node (the authoritative stake) down behind a green run.
- **Fix:**
  - Use `set -euo pipefail`.
  - After the run, require `docker inspect -f '{{.State.Running}}'` = true plus a height advance (like infra-liveness).
  - Fail on a missing container.

### INF-M3: No workflow verifies the VPS SSH host key
- **Evidence:**
  - `grep StrictHostKeyChecking`:
    - `=no` in deploy-node-config, deploy-specific-sha, restart-services, update-node-image (x4), verify-api-keys, vps-node-status and deploy-container.
    - `accept-new` in push-secrets.
    - `=yes` only after a fresh `ssh-keyscan`, which is TOFU (deploy-monitoring-stack:71, update-caddy:420, restart-host-network:56).
  - `deploy-container.yml:166-171` comments "KNOWN GAP: DEPLOY_HOST_FINGERPRINT … never actually compared".
  - The secrets `DEPLOY_HOST_FINGERPRINT` (env testnet) and `TESTNET_DEPLOY_HOST_FINGERPRINT` (org) exist with 0 references.
  - The deploy user has `NOPASSWD: ALL` (`/etc/sudoers.d`).
- **Why it matters:** an attacker in the path between the runner and the VPS gets root plus every secret pushed by push-secrets.
- **Fix:** write a pinned `known_hosts` line from a secret in one shared setup step. Use `StrictHostKeyChecking=yes` everywhere.

### INF-M4: Every app container gets the whole testnet.env, including third-party credentials
- **Evidence:**
  - `docker inspect` env-var names: node-scala (18 secret-like names), admin-dashboard (20), websocket-api (18), scanner, data-service, BPS, matcher, postgres-exporter and alert-webhook (17 each).
  - The variables include `ADMIN_DASHBOARD_GITHUB_PAT`, `ADMIN_DASHBOARD_GITHUB_OAUTH_CLIENT_SECRET`, `ADMIN_DASHBOARD_JWT_SECRET`, `SENTRY_AUTH_TOKEN`, `MATCHER_ACCOUNT_SEED`, `DCC_FAUCET_SEED`, `DCC_CANARY_SEED`, `DCC_WALLET_SEED`, `REDIS_PASSWORD` and the PG passwords.
  - The plan defers this "for mainnet (testnet seeds are public by decision)". That decision covers testnet seeds, not the GitHub PAT, OAuth or Sentry credentials.
- **Why it matters:** the public scanner, data-service and websocket processes hold org-level GitHub and Sentry credentials. Any RCE or SSRF in them leaks those credentials.
- **Fix:** per-service env files built by push-secrets, then rotate the PAT, OAuth secret and Sentry token.

### INF-M5: Grafana is OOM-killed repeatedly at its 256 MiB limit and is at 99.9% now
- **Evidence:**
  - `dmesg -T`: 4 `Killed process (grafana)` events (10-11 x2, 10-15 07:34, 10-16 21:23), memcg-constrained.
  - `docker stats`: `grafana-testnet 255.7MiB / 256MiB 99.89%` after today's #216 recreate.
  - `compose/grafana.yml:59` sets `memory: 256m`.
- **Fix:** raise the limit to 512m or more (the host has 4 GB available). Add an OOM or container-restart alert (node_exporter/cAdvisor or the exporter).

### INF-M6: Some failure modes have no alert at all
- **Evidence:**
  - The live rules API shows 16 alerting rules (list in alerts.yml).
  - Prometheus targets: alloy, bps, dcc-chain, lke-chain, loki, node, postgres, redis (all up).
- **Missing coverage:**
  - BPS lag or down: `bps_last_synced_height` is scraped but unused, and nothing alerts on `up{job="bps"}`. The explorer and data-service would go stale silently.
  - Redis, Loki and alloy `up==0` (CapacityExporterDown covers only node and postgres).
  - Flux reconcile failure: notification-controller was removed and Flux metrics are not scraped. A bad manifest silently freezes the cluster spec.
  - Matcher order and settlement path: the canary sends transfers only (`canary-transaction.yml`, no matcher calls).
  - Early TLS expiry warning: ServiceDown only fires once a certificate has already failed. testnet-admin expires 2026-11-18.
  - Container OOM or restart loops (see M5).
  - Prometheus and Alertmanager self-monitoring (no Watchdog or deadman). The alert stack runs on the VPS it monitors. infra-liveness covers only main height and LKE readiness.
- Only 5 of 16 rules have promtool tests (`monitoring/tests/alerts_test.yml`).
- **Fix:**
  - Add BPS-lag (`dcc_block_height - bps_last_synced_height > N for 10m`), generic `up==0`, cert-expiry (blackbox or exporter `notAfter`) and container-restart rules.
  - Scrape kustomize-controller metrics via NodePort, or have infra-liveness check `kubectl get ks`.
  - Add a deadman that pings an external check.
  - Add a matcher order round-trip canary.

### INF-M7: The LKE worker recycle runbook would leave the cluster broken and unprotected
- **Evidence:**
  - `clusters/testnet/RUNBOOK.md:32-46` (Scenario A) says to recycle the pool and that "Flux reconciles automatically… 5–10 minutes". But a recycled worker gets a new Linode ID and a new public IP, and:
    - `apps/nodes.yaml:101,275,423` hardcode `declared-address = "139.162.144.243:686x"`.
    - The LKE Cloud Firewall attaches by Linode ID through tofu (`terraform/lke.tf:178-180`; live firewall entity is 107392353 only). The new node runs with no cloud firewall (kubelet 10250 and NodePorts public) until `provision.yml apply`.
    - The VPS egress rule `allow-lke-exporter-out` is pinned to `139.162.144.243/32` (live firewall 35536772), so the `lke-chain` scrape breaks until tofu apply and `deploy-monitoring-stack.yml` run again.
    - The HEP labels (label-hostendpoint-nodes.yml) also have to be re-applied.
  - Single worker (`lke_node_count = 1`).
- **Fix:** rewrite Scenario A with the ordered steps: provision.yml plan/apply, update the IP in nodes.yaml via PR, run deploy-monitoring-stack, run label-hostendpoint-nodes, then verify `/peers/connected`.

### INF-M8: CI does not validate the GitOps path or the generated configs
- **Evidence:**
  - `.github/workflows/ci.yml` steps: digest parity, checksum annotations, plugin shadowing, tofu fmt/init/validate, compose validate, promtool, shellcheck, ASCII.
  - Not in CI:
    - `kustomize build`/kubeconform of `clusters/testnet` (applied by Flux with `prune: true`).
    - actionlint (local run: 24 expression and 33 shellcheck findings, mostly benign).
    - `caddy validate` of the generated Caddyfile.
    - `tofu test`, although `terraform/main.tftest.hcl` exists.
    - Secret scanning in a **public** repo whose history leaked seeds (plan B5).
  - Branch protection requires only `Validate Infrastructure` plus 1 review, and `enforce_admins=false`.
- **Fix:** add `kustomize build clusters/testnet/* | kubeconform -strict`, actionlint, a render + `caddy validate` step, `tofu test`, and gitleaks.

### INF-M9: The main VPS has no host firewall, and every service binds to all interfaces
- **Evidence:**
  - `iptables -S INPUT`: `-P INPUT ACCEPT` (only the f2b chain), and ufw is not installed.
  - `ss -tlnp` shows `0.0.0.0`/`*` binds on 3000, 3001, 3002, 6868, 6869 (REST, via `DCC_REST_API_BIND=0.0.0.0` in all four docker-run copies), 6881 and 6887 (gRPC), 6886 (matcher), 8080, 8081, 9090 (BPS), 9094 TCP/UDP (alertmanager gossip) and UDP 36096.
  - Only the Linode firewall `dcc-firewall-testnet` (inbound 22/80/443/6868) protects them, so one firewall edit exposes the node REST API.
  - Plan line 155 already lists this as open.
- **Fix:**
  - Bind to 127.0.0.1 wherever Caddy fronts the service.
  - Set alertmanager `--cluster.listen-address=""`.
  - Add an nftables default-drop that allows 22/80/443/6868.

### INF-M10: TESTNET-FINAL-PLAN.md is internally inconsistent and stale
- **Evidence:**
  - Line 7 architecture says "main (Linode VPS `66.228.55.154`, docker-compose…)". Both the IP and the deploy mechanism are wrong (see M1).
  - Line 155 says "fail2ban has been failed since boot". Today `systemctl is-active fail2ban` = active and the jail is `sshd`.
  - Line 154 says "`REDIS_PASSWORD` is not in SOPS … `local.conf` is chmod 644". SOPS key names include `REDIS_PASSWORD`, and live `local.conf` is `-rw-r----- root:113`.
  - B9 (line 67) is unchecked, but `testnet.decentralscan.com` resolves to 50.116.30.244 with a Let's Encrypt certificate valid to 2027-01-06.
  - B10 (lines 68 and 126) is unchecked and says "Cloudflare token". Off-box liveness actually runs via the LKE CronJob `liveness-trigger` (every 15 min, last runs Completed), and the canary has 257 successful dispatches.
  - The Phase 9 criterion "`/generators/at/<next>` = 3 addresses" contradicts the 4-generator committee (B4).
  - Recovery-section items stay open: gen-2 (Phase 2), and "Verify: … resynced", which is already true.
  - Task 6.1 (Bug 2) has no evidence.
  - 181 unchecked vs 58 checked boxes, with many done-but-unticked. Sections are out of chronological order (10-04 audit above the 09-30 status).
- **Fix:** run one reconciliation pass and mark each item with its date and evidence. Move superseded sections to an appendix.

---

## LOW

- **INF-L1 VPS leftovers.**
  - 57 images, 12.58 GB reclaimable (`docker system df`), including 5 old node-scala and 2 matcher images.
  - 18 dangling volumes, including `promtail-positions-testnet`.
  - `/opt/dcc/monitoring/promtail-config.yaml`, left over after the move to alloy.
  - 7 `Caddyfile.bak*` from June, `dcc.conf.bak-20261004`, `dcc.conf.bak-before-bu-disable`, `secrets/testnet.env.bak-dexext` (Jul), `compose/redis.yml.bak-20261010`.
  - `/opt/dcc/load-tester` (4.5 MB binary), `/opt/dcc/test-wallets.csv` (383 KB, root:deploy 640), `/opt/dcc/matcher-patch`, `/opt/dcc/plugins/disabled`.
  - Fix: prune them (`docker image prune -a`, volume prune after review) and delete the .bak files.
- **INF-L2 Dead nightly cron.** `crontab -u postgres`: `0 2 * * * /opt/dcc/scripts/pg-backup.sh >> /var/log/pg-backup.log`. The log file does not exist (postgres cannot create files in /var/log), so the job never runs, and `/opt/dcc/backups` is empty. Backups are not wanted (operator), so delete the cron instead of leaving a silently failing job.
- **INF-L3 Matcher config and BPS runbook name a database that does not exist.**
  - Live databases (`psql`): `postgres`, `admin_testnet`, `bps_testnet` only.
  - Matcher `local.conf` `postgres.database = "dcc_testnet"` (written by push-secrets).
  - `runbooks/reset-bps-testnet.md:33-34` says the matcher uses `dcc_testnet`, "Do not drop". The matcher logs show no Postgres use.
  - Fix: remove the dead block and correct the runbook and `bootstrap.sh`.
- **INF-L4 Upgrades outside unattended-upgrades scope.**
  - Only Debian origins are allowed.
  - Pending: docker-ce 29.5.3→29.9.1, containerd 2.2.4→2.4.2, compose 5.1.4→5.6.0, PostgreSQL 18.4→18.6 (pgdg).
  - `/var/run/reboot-required` lists `linux-image-6.1.0-54` but has no effect: the boot kernel is Linode `latest-64bit` 7.1.9, which is current. Debian 12 is now on LTS.
- **INF-L5 Secret-store debris.**
  - Unreferenced secrets: env `DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_HOST_FINGERPRINT`, `BACKUP_OBJ_ENDPOINT`; org `TESTNET_DEPLOY_HOST_FINGERPRINT`; repo `TESTNET_REDIS_PASSWORD` (archived workflow only).
  - Duplicates whose equality was not verified: repo `GEN_0_SEED_PHRASE` (2026-06-30, used by admin-e2e and stress-test) vs SOPS `GEN_0_NODE_WALLET_SEED`; `AGE_KEY_TESTNET` vs env `AGE_SECRET_KEY`; `DEPLOY_SSH_KEY` vs org `TESTNET_DEPLOY_SSH_KEY`.
  - `TF_VAR_ROOT_PASSWORD` dates from 2026-06-04, before the 10-04 restore.
  - Workflows reference `MAINNET_/STAGENET_DEPLOY_*`, which don't exist.
- **INF-L6 CODEOWNERS is broken.** `gh api …/codeowners/errors`: "Unknown owner … @Decentral-America/release-approvers" (`.github/CODEOWNERS:9`, team lacks write access). The root `CODEOWNERS` is shadowed and names `@Decentral-America/infra`, which does not exist (the org has only `release-approvers`).
- **INF-L7 Branch hygiene.** 76 remote branches, 39 already merged into main. `origin/dev` is 5 behind main.
- **INF-L8 Host-endpoint policy is completely inert.**
  - `StagedGlobalNetworkPolicy dcc-hostendpoint-p2p` has been staged since 2026-07-05 (f194b46) and never promoted.
  - The live HEP `lke663401-982638-8xbp9-auto-hep` has only `projectcalico.org/created-by`, not `kubernetes-host`, so even the staged policy selects nothing. label-hostendpoint-nodes.yml last ran 07-07 against a previous cluster.
  - The k8s NetworkPolicies are a no-op for hostNetwork pods (documented). Only `default-allow` (LKE) and the Linode firewall apply.
- **INF-L9 Orphan Linode firewall** `nodes-firewall` (3567028), with 0 entities.
- **INF-L10 `wireguard/` is speculative and unapplied.** It contains DRAFT files: a workflow outside `.github` that is never runnable, placeholder keys, and a `66.228.55.154` reference. Archive it or delete it.
- **INF-L11 Orphans.** `monitoring/scripts/check-val0.sh` is referenced only by an archived workflow and uses port 16871. GitHub still lists workflow 301232854 ("Resync testnet main node…", path `wipe-chain.yml`) as `active` although the file was archived; no branch has the file. Disable it.
- **INF-L12 GHCR token persisted on the host.** `/home/deploy/.docker/config.json` holds `ghcr.io` auth. update-node-image passes `GHCR_TOKEN` inside the remote command string (visible in `ps`). The packages are public, so the login is unnecessary.
- **INF-L13 Host Caddyfile is world-readable and holds keys.** `/opt/dcc/caddy/Caddyfile` is `0644` (update-caddy chmods it 644) and embeds `MAIN_NODE_REST_API_KEY` and the bypass key.
- **INF-L14 App images pinned by mutable tag, not digest.** scanner, data-service, websocket-api, admin-dashboard, BPS and matcher use `:<sha>` tags (`docker inspect .Config.Image`). The node, grafana, prometheus and others use `@sha256`.
- **INF-L15 drift-detect summary misleads.** It prints "No drift detected" for stagenet and mainnet, which were skipped (run 38257337532). The 4 `mainnet`-tagged Linodes are not in this IaC (out of testnet scope).
- **INF-L16 Stale docs.**
  - `README.md:164` and `DEPLOY.md:355,1042,1620` have the old IP 66.228.55.154, and DEPLOY.md still has LKE 615553.
  - `TOPOLOGY.md:7,29,51-55` says "Newark", claims compose deploys, has wrong balances, and omits val-0.
  - `node-config/testnet/vps-image.env:2` and `terraform/main.tf:231` say "Newark"; it is Dallas `us-central`.
  - `update-caddy.yml:7-11` still warns not to run until the ratelimit image is pinned (it is pinned).
  - `compose/caddy.yml` header says bootstrap writes the Caddyfile.
- **INF-L17 Dead or unproven workflows.** `stress-test.yml` has one run (2026-06-30, failure). `restart-services.yml` was last green 07-06, `label-hostendpoint-nodes.yml` last ran 07-07, and `verify-api-keys.yml` last ran 08-12, before the 10-10 rotation.

## INFO

- **INF-I1** The testnet GitHub environment has no protection rules or branch policy. Org `TESTNET_DEPLOY_SSH_KEY` reaches 4 repos, and the deploy user has NOPASSWD sudo. This matches the "testnet ungated" policy.
- **INF-I2** Alerts are delivered only to GitHub issues (no paging). Delivery was proven (#186/#189/#208/#211, opened and auto-closed).
- **INF-I3** kustomize-controller, source-controller and calico-kube-controllers restarted together 45h ago (4/4/3 restarts). The cause was not investigated, and nothing alerts on it.
- **INF-I4** The single-replica PDBs (`maxUnavailable: 1`) give no protection. This is by design with one worker.
- **INF-I5** SSH to the VPS is open to 0/0 (needed for GitHub runners) with fail2ban and a hardened sshd (`sshd -T`: root no, password no, AllowUsers deploy). LKE SSH is limited to 201.182.55.117/32.

## Verified OK today (parity evidence)

- **Caddy:** the live Caddyfile equals the update-caddy.yml rendering of `testnet.tfvars` (diff empty, keys masked on both sides).
- **Node config and plugins:** live `/opt/dcc/config/node-testnet/dcc.conf` equals the repo (220 lines, api-key-hash equal). `plugins/testnet/{ext,grpc}.jar` sha256 equals the host, with 0 linkage errors in the node log.
- **Compose:** 11 of 12 files byte-identical; node-scala.yml differs (M1).
- **Monitoring:** every `/opt/dcc/monitoring` file equals the repo. The only extras are file_sd and the promtail leftover.
- **Cluster:** Flux Kustomizations apps, flux-system, monitoring and policy are Ready at `main@4e903d2`. No unmanaged objects in `dcc`. All 3 STS and the VPS run `sha256:8fccecebb65a…` (the `vps-image.env` and nodes.yaml pins).
- **Firewalls and IaC:** Linode firewall rules match `terraform/main.tf` and `lke.tf`. drift-detect testnet on 10-12: "No changes".
- **Chain:** height 73269, finalized 73266 (lag 3), `bps_last_synced_height` = tip, 3 peers.
- **TLS:** valid on all 7 public names; the earliest expiry is testnet-admin on 2026-11-18.
- **Unresolved names:** `testnet-scanner.decentralchain.io`, `testnet.decentralchain.io` and `testnet-exchange.decentralchain.io` have no records (known).
- **Host:** NTP synced (chrony), no failed systemd units, all 19 containers healthy, json-file log rotation 50m×5, journald 220M, disk 18%.
- **Workflow runs:** CI, canary (257/257), infra-liveness (137/137), ghcr-cleanup, prune-volumes and deploy-monitoring-stack are all green recently.

## Phase coverage

- **Phases 0, 1, 3, 6 and 7:** done for this scope (workflows, compose, Caddy, node-config, clusters, terraform, monitoring, secrets, scripts, runbooks, plugins, host, firewalls, DNS, plan).
- **Phase 4:** done for infra/edge only (secrets, TLS, host, supply chain).
- **Phase 8:** observability and resilience covered.
- **Phase 2:** shell/YAML only; findings limited to duplication (M1).
- **Phases 5, 9, 10 and 11:** N/A or out of scope (no app code or schema in this repo).
- **Not done:**
  - `tofu plan` locally (no state credentials; relied on the drift-detect run instead).
  - SOPS decryption (the local age key does not match the testnet recipient; key names were read from the plaintext dotenv keys).
  - `kubectl diff` (relied on Flux Ready at HEAD).
