# DCC Mainnet-Readiness — Research-Backed Plan

> Production/mainnet-grade best practices for the DecentralChain (DCC) stack — a Waves-platform
> fork (Scala node, FairPoS/Waves-NG + BLS 2/3-committed-stake deterministic finality) with a DEX
> matcher, explorer, data-service, websocket API, faucet and wallet, on Linode VPS + LKE k8s,
> Caddy edge, SOPS+age secrets, GitHub Actions CI/CD.
>
> Source: deep multi-source research pass (2026-07-16), 28 sources, 24/25 claims confirmed via
> 3-vote adversarial verification (1 refuted). This doc maps each finding to **our actual stack**
> and gives a prioritized, owner-tagged action plan. It is the SSOT for the testnet→mainnet hardening.

**Status legend:** ✅ done/good · 🟡 partial · 🔴 gap · ⏳ needs owner input/accounts · 🧊 mainnet-launch item

---

## Executive summary

The research **validated the security fixes shipped 2026-07-16** (localhost+reverse-proxy, no public
`/debug`·`/wallet`·`/admin`, TLS-terminated edge, service uptime alerts) and gave clear answers to the two
items previously flagged as blocked/deferred (SSH access → Tailscale ephemeral mesh; feature activation →
governance/height voting for mainnet). It also surfaced **three higher-order gaps** that outrank the
leftover punch-list for a real mainnet: **stake blast-radius (leasing), sentry-node topology, and our
`enable-blacklisting=no` + empty `known-peers` eclipse exposure.**

---

## Area 1 — Secure access & key custody

### Findings (verified)
- Waves binds REST to `127.0.0.1` and recommends a reverse proxy / SSH-forward, **never** public exposure. *(primary: Waves node-configuration)*
- Private methods (sign, seed export) require the `X-Api-Key` header, but it travels **plaintext** → must be behind TLS; the API key is **not** a sufficient primary control (the "`api-key-hash` protects all private endpoints" claim was **refuted 0-3**). *(Waves api-key docs)*
- The FairPoS account seed **both controls funds and signs blocks** → inherently a HOT key. Best practice: externalize it (remote signer/KMS/HSM) and **lease stake in rather than hold it on the generating account**. *(Waves how-to-generate-blocks; CometBFT/tmkms; ethereum.org staking)*
- CI-to-private-infra over SSH without public exposure: **Tailscale ephemeral nodes via the official GitHub Action** — runners join the tailnet as short-lived, authenticated, tagged nodes that expire when the job ends. *(Tailscale docs)*
- Remote-signer patterns (tmkms, Web3Signer, Horcrux) are the mature model but **none speak Waves' Curve25519 scheme** — analogies, not drop-ins. *(primary repos/docs)*

### Our status
- ✅ Node on `127.0.0.1` behind Caddy; TLS at the edge; `/debug/*`·`/wallet`·`/addresses` blocked publicly (SEC-1 fix).
- ✅ Seed **not** left in plaintext — injected at runtime by `entrypoint.sh` from `/opt/dcc/secrets/testnet.env` (SOPS-delivered); on-disk `wallet.dat` encrypted.
- 🔴 **Stake blast-radius:** generators hold **22–27M DCC directly on the hot generating account** the node signs with. A node compromise can drain the stake.
- 🟡 **SSH is `0.0.0.0/0` — ACCEPTED with mitigations (decision 2026-07-16).** It is already `PasswordAuthentication no` (key-only), `PermitRootLogin no`, `AllowUsers deploy` (single user), `MaxAuthTries 3`, fail2ban (5/10min → 1h ban), X11 off, and strong ciphers/MACs/KEX. So the exposed surface is a single key-only, no-root, rate-limited account; residual risk = an OpenSSH 0-day or a leaked deploy key (held in a GH secret + KeePassium). This is a widely-accepted small-team baseline. A VPN layer (Tailscale rejected as an unwanted third-party dependency; self-hosted WireGuard is the zero-vendor equivalent) is a nice-to-have, **not** a mainnet blocker.
- 🧊 Signing-key externalization (Waves-compatible remote signer) — custom work; roadmap.

### Actions
1. 🔴 **Lease, don't hold** — hold minimal balance on each hot generating account; accrue stake via `Lease` from a separately-custodied cold treasury account. Native Waves feature; biggest custody win. *(mainnet design + testnet demo)* See **`LEASING-CUSTODY-DESIGN.md`** (design ready; testnet rehearsal is the next executable step).
2. 🟡 **SSH: accepted as-is.** Optional zero-dependency hardening (not yet applied — a live SSH-port change carries lockout risk and must be coordinated with the CI deploy workflows): (a) move sshd off port 22 to a non-standard port to cut automated-scan noise (requires updating bootstrap.sh sshd `Port`, the Linode firewall rule, the fail2ban jail, and every deploy workflow's SSH port together), (b) periodically rotate the `DEPLOY_SSH_KEY`. Only pursue self-hosted **WireGuard** if "no public SSH at all" ever becomes a hard requirement.
3. 🧊 Evaluate HSM/vault-backed seed storage and a Waves-compatible remote/threshold signer.

---

## Area 2 — Mainnet launch & consensus

### Findings (verified)
- Mature Waves practice = **height/voting-based governance activation**, not pre-activating from genesis: a feature is Approved at ≥80% support (9000 of 10000 blocks by mainnet default), then activation is **delayed a further 10,000 blocks** so operators can upgrade; `auto-shutdown-on-unsupported-feature` defaults on. Values are per-network configurable. *(Waves activation-protocol, node-configuration)*
- DCC finality (Feature **#25**) requires each generator to broadcast **`CommitToGeneration` (tx type 19)** per generation period (start read from `/blockchain/finality`), ~100-token deposit; blocks final at **2/3 committed generating-balance**. *(Waves how-to-generate-blocks, commit-to-generation reference; type had a 2-1 split vs a stray "20" — verify against our code)*

### Our status
- 🟡 Voting machinery present but **tuned differently** (ours: `feature-check-blocks-period=3000`, `blocks-for-feature-activation=2700` = 90%) and **everything pre-activated `{1–25,28}` from height 0** → governance never exercised (CFG-1).
- 🟡 Finality: `auto-commit-generators.yml` re-commits generators; `FinalizationStalled` alert exists. Missing: committed-stake **headroom** monitoring.

### Actions
1. 🧊 **Mainnet genesis** = pre-activate only a small stable core; gate all post-launch protocol changes (incl. BLS finality #25) through height voting. Requires a **fresh mainnet genesis** (not a testnet reset).
2. 🔴 **Finality-headroom monitoring** — track committed generating-balance fraction; alert when it approaches 2/3 **from above** (stall risk before it happens). *(actionable now — see Area 4)*
3. 🧊 Decide + document mainnet chain params (block time, `generation-period-length`, activation cadence) and the validator-onboarding/decentralization sequence.

---

## Area 3 — Public RPC/edge + P2P hardening

### Findings (verified)
- Keep `debug`/`wallet`/`admin` off the public internet behind a TLS reverse proxy (see Area 1). *(Waves)*
- P2P ships anti-sybil controls: `enable-blacklisting=yes`, `max-single-host-connections=3`, in/out caps of 100, and a `known-peers` bootstrap list. *(Waves node-configuration)*
- **Sentry-node architecture**: run generators with **no public IP** behind public sentry relays that mark the generator as a private peer (hide its IP) — primarily DDoS/eclipse protection. *(CometBFT)*

### Our status
- ✅ Edge hardening solid: default-DROP firewall (only 80/443/22 + P2P), TLS+HSTS+CSP+security headers, CORS allowlist, per-path + per-IP rate limiting (incl. faucet), `/debug/rollback`→403.
- 🔴 **`enable-blacklisting = no`** (set to fix the RC#2 peer-cycling loop) + **`known-peers = []`** → weakened eclipse resistance. See `[[project_dcc_rc2_fix]]`.
- 🔴 **No sentry topology** — the main node is a *public* generator.

### Actions
1. 🔴 **Re-enable blacklisting for mainnet** (or resolve RC#2 another way) + curate a **diverse `known-peers`** set across regions/ASNs. Test on testnet carefully — flipping it live risks reintroducing the RC#2 loop.
2. 🧊 **Sentry-node topology** for mainnet: generators private (no public IP / declared-address), behind a small fleet of public sentry/relay nodes.

---

## Area 4 — Observability, DR & incident response

### Findings (verified / noted)
- Prometheus + Grafana + Alertmanager is canonical; monitor missed blocks, uptime, and finality committed-stake. *(staking-provider guides)*
- DR: peer re-sync recovers **chain state**, but **cannot recover signing keys** — keys MUST be backed up independently. So "no chain backup, rely on peer resync" is acceptable **iff** keys are backed up. *(validator DR docs)*
- *(This was the thinnest-covered area in verified evidence — treat as partially researched.)*

### Our status
- ✅ Prometheus/Grafana/Alertmanager deployed; alerts: BlockProductionStalled, FinalizationStalled/NotAdvancing, HotStuffCommitNotAdvancing, ServiceDown (all services), Exporter health. Grafana locked down (SEC-2).
- ✅ Keys backed up (SOPS + KeePassium) → the no-chain-backup posture is acceptable per the research.
- ✅ Fault soak (crash/partition) passed.
- 🟡 Missing: finality committed-stake **headroom** signal; formal incident-response runbooks (chain halt, finality stall, key compromise, fork).

### Actions
1. 🔴 **Add committed-stake-fraction / finality-headroom metric + alert** (actionable now).
2. 🧊 Write incident-response runbooks: chain halt, finality stall, key compromise, fork/reorg.
3. 🧊 (Optional) snapshot/fast-bootstrap for faster node recovery — nice-to-have given peer resync works.

---

## Prioritized action plan

| # | Item | Area | Severity | Owner / blocker |
|---|------|------|----------|-----------------|
| 1 | Lease stake instead of holding on hot generator accounts | 1 | 🔴 High | design now, exec needs treasury accts |
| 2 | SSH exposure — ACCEPTED w/ mitigations (key-only, no-root, fail2ban) | 1 | 🟡 Low | decided 2026-07-16; optional port-move/key-rotation later |
| 3 | Finality committed-stake headroom metric + alert | 2/4 | 🔴 High | **actionable now** |
| 4 | Re-enable P2P blacklisting + curated known-peers | 3 | 🔴 High | test vs RC#2 loop first |
| 5 | Sentry-node topology (private generators) | 3 | 🟠 Med | 🧊 mainnet |
| 6 | Governance/height feature activation at mainnet genesis | 2 | 🟠 Med | 🧊 mainnet genesis |
| 7 | Incident-response runbooks | 4 | 🟠 Med | doc |
| 8 | Waves-compatible remote signer / HSM | 1 | 🟡 Low | 🧊 roadmap (custom) |

## Sources (primary unless noted)
- Waves: activation-protocol, node-configuration, node-api/api-key, how-to-generate-blocks, commit-to-generation-transaction
- CometBFT docs; tmkms (iqlusioninc); Web3Signer (Consensys); Horcrux (Strangelove); ethereum.org/staking
- Tailscale: connect-CI-to-private-infra, ephemeral-nodes; HashiCorp Vault KV; Flux SOPS; CIS Kubernetes Benchmark / CNCF hardening
- Validator ops: Simply Staking (Cosmos monitoring), Kiln cosmos-validator-watcher, sync.global DR, Everstake uptime guide

_Verification: 3-vote adversarial per claim (≥2/3 refutes to kill). Caveats: activation numbers are Waves
defaults & per-network configurable (DCC uses 3000/2700); CommitToGeneration type 19 had a 2-1 split
(verify vs code); tmkms/Web3Signer/Horcrux are architectural analogies, not Waves drop-ins._
