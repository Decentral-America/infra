# Audit: documentation truth vs reality (DCC testnet), 2026-10-18

Auditor scope: docs repo (origin/main 82ce82b, published docs.decentralchain.io), root Ecosystem docs,
in-repo docs of node-scala / matcher / infra / DecentralChain (all read at origin/main), dcc-report.
Read-only. No secret values reproduced (KEEWEB_BACKUP.md assessed by counts and masked structure only).

Live facts re-verified today (curl): testnet-node `/node/version` = `DecentralChain v1.8.0`, height ~73265,
`hotStuffFinalizedHeight` present, `generationPeriodLength` 100, features 1-26 ACTIVATED (26 at h12000),
`/generators/at/73200` = 4 members (31PmKN gen-0, 31XTtK val-0, 31RPEK main, 31dLhq gen-1), matcher pubkey
`BEtB5b2kX8Yge4sb5RRbTUqd5Va8Ah8PhphowcW31z6Y` -> address `31VMNVAvVh67dPZ41nMnYZvhoZFW7wwPrmq`,
networkByte 33. testnet-latest = testnet-pinned-fb4e980 = `sha256:8fccecebb65a…` = image pinned in
nodes.yaml x3 and vps-image.env. Main P2P 50.116.30.244:6868 reachable; LKE peers declare
139.162.144.243:6863/6864/6865. testnet-ws `/ws` upgrade = 101. Mainnet node = `DCC v1.3.5`, h 2.53M.

No BLOCKER found: nothing in this scope stops the testnet itself from running. Several HIGH items mean
the docs and the "final" sign-off do not describe the live system accurately.

---

## HIGH

### DOC-H1: docs.decentralchain.io root sends every visitor to the Portuguese build
- Evidence: `curl https://docs.decentralchain.io/` -> `<meta http-equiv="refresh" content="0; url='/pt/main/'">`;
  `/pt/main/` has `html lang="pt"` with UI chrome in Portuguese over untranslated English content.
  Cause: `docs/docs/buildDocs.sh:117-122` writes the redirect with `${current_language}`, which is the
  leftover loop variable from the `for current_language in ${languages}` loop at :72-73. `find` order picks
  the last language (old gh-pages build redirected to `/de/main/`; current one to `/pt/main/`).
- Fix: hardcode `url='/en/main/'` (and the `<a href>`) in buildDocs.sh.

### DOC-H2: the documented SDK install crashes on import (Node 24, the documented runtime)
- Evidence: fresh `npm install @decentralchain/transactions@5.0.0 @decentralchain/node-api-js@2.0.1`
  (exactly `02_client-libraries-and-sdk.md:60`, `03_how-to-guides.md:21`) then
  `import { transfer, broadcast } from '@decentralchain/transactions'` on node v24.18.0 ->
  `ERR_MODULE_NOT_FOUND ... node_modules/protobufjs/minimal imported from @decentralchain/protobuf-serialization/dist/index.js`.
  transactions 5.0.0 pins protobuf-serialization 2.0.0 (deps `protobufjs ^8.0.0`, resolves 8.8.1, no
  `exports` map, extensionless ESM import). `latest` dist-tag is 5.0.0. `next` tag 5.0.1 works: transfer
  built (fee 100000, type 4 v3), issue built (fee 1e8). node-api-js 2.0.1 sample works (balance + height
  returned against testnet). The docs CI (`docs_checks.yml:36-58`, `_samples/package.json`) only runs
  `tsc --noEmit`, so it cannot catch a runtime resolution failure.
- Fix: promote transactions 5.0.1 to `latest` (or fix protobuf-serialization 2.0.x import to
  `protobufjs/minimal.js`), pin docs to it, and add a runtime smoke step (`node -e "import(...)"`) to the
  samples job.

### DOC-H3: no way for an outside operator to join the public testnet from the docs
- Evidence: `05_node-guide/05_configuration.md:35` and `02_decentralchain/08_mainnet-testnet-stagenet.rst:55`
  say the built-in `testnet` profile "will not join" and to "use a custom config matching the Testnet's
  genesis and peers instead", but no page gives that config, genesis, or a peer address. The material
  exists: `node-scala/node/genesis-dcc-testnet-relaunch.conf` (timestamp 1788539579643 = live block 1
  timestamp) and `infra/node-config/testnet/dcc.conf` (main = 50.116.30.244:6868). Meanwhile
  `04_install-docker.md:33`, `05_configuration.md:27-30` and `08_mainnet-testnet-stagenet.rst:41-43`
  tell readers Testnet P2P is 6863, and `05_node-guide/index.md:14-24` / node-scala README:86-87 present
  `sbt -Dnetwork=testnet packageAll` / `testnet-latest` as the testnet path. dcc-report v3 (line 225)
  also says "reach out to the team" to run a node.
- Fix: add a "Join the public Testnet" page: image `ghcr.io/decentral-america/node-scala:testnet-latest`
  (or the pinned digest), a minimal CUSTOM `dcc.conf` with the relaunch genesis block, `known-peers =
  ["50.116.30.244:6868"]`, chain id `!`; and drop "Testnet uses 6863" from the port tables.

### DOC-H4: built-in known-peers for the mainnet and testnet profiles are Waves nodes
- Evidence: `node-scala/node/src/main/resources/network-defaults.conf:9-14` (testnet) and `:145-150`
  (mainnet). `curl http://168.119.116.189:6869/node/version`, `http://159.69.126.149:6869/...`,
  `http://94.130.105.239:6869/...` all return `{"version":"Waves v1.6.4-1-g2ef3164"}`.
  `node-scala/RUNBOOK.md:238-246` presents the same 4 IPs as "Mainnet seed peers (as of release 1.6.1)"
  configured in `node/decentralchain-mainnet.conf`; docs `08_mainnet-testnet-stagenet.rst:57` and
  `05_configuration.md:32` send readers to network-defaults.conf for peers. A node started with
  `DCC_NETWORK=testnet|mainnet` dials Waves infrastructure (handshake chain-id mismatch, never syncs).
- Fix: replace with real DCC seeds (or empty lists plus a doc'd peer), and fix RUNBOOK.md:236-246.

### DOC-H5: the "testnet final" sign-off does not describe what is running, and its image is gone
- Evidence: `infra/SOAK-2026-10-12.md:10,91` and annotated tag `testnet-final-2026-10-14` (infra) name
  node image `sha256:9283525c26aa…` (node-scala 104ddc70e8). GHCR manifest for that digest -> HTTP 404
  (same request for live 8fcceceb -> 200); infra commit 4e903d2 (#217) states 9283525c was already
  deleted by ghcr-cleanup. Live fleet runs fb4e980576 (#77, equivocation-deposit forfeiture from
  h60000, infra e05181a) which was never soaked; there is no soak record for it. TESTNET-FINAL-PLAN.md
  Phase 9 (:781-799) has every box unchecked and prescribes the tag in node-scala
  (`cd $NODE && git tag …`); node-scala has no `testnet-final*` tag. Its committee box still says
  "3 addresses every period" vs live 4.
- Fix: add a SOAK addendum for fb4e980/8fcceceb (or a short re-soak), note in SOAK and tag notes that
  the signed-off digest is unrecoverable, tick or rewrite Phase 9 with Soak Log evidence, align the
  tag location with the plan.

### DOC-H6: the testnet DR runbook tells responders to run workflows that no longer exist
- Evidence: `infra/clusters/testnet/RUNBOOK.md:212,222` (`auto-commit-generators.yml`), `:224`
  (`commit-generators-hotstuff.yml`), `:216` (`peer-check.yml`), `:204,366,382,396` (`migrate-state-snapshot.yml`,
  the only described recovery for a far-behind gen node), `:340` (auto-commit as mitigation),
  `:437` (`peer-watchdog.yml`). None is in infra `.github/workflows/` (retired in 849148d, archived).
  Same file, Scenario D table `:270-275`: main known-peers "the 3 Frankfurt nodes" and gen
  known-peers "Dallas:6868 + gen-1 + val-0", but `node-config/testnet/dcc.conf:104` is `known-peers = []`
  and `nodes.yaml:103,277,425` are main-only. `:297-316` "KNOWN OPEN ISSUE (as of 2026-06-10) ...
  Newark has never had a peer" (long resolved). `:212` "all 3 generators" (4 now). `:266-286` Newark naming.
- Fix: rewrite Scenario F around in-process `self-commit-to-generation` (+ the manual
  `/transactions/sign` path already at :228), replace migrate-state-snapshot with the current recovery
  path (or restore the workflow), fix the topology table, delete the June open-issue block.

### DOC-H7: infra/DEPLOY.md, the self-declared canonical deploy runbook, has a false "Current Truth"
- Evidence: `infra/DEPLOY.md:343-363`: Newark 66.228.55.154 + LKE 615553, `DecentralChain v1.7.0`
  `sha-9c49632`, height 108,096 (previous chain; live chain is at ~73k), mainnet "Not provisioned"
  (mainnet-node.decentralchain.io is live, `DCC v1.3.5`, h 2,534,695), Exchange mainnet "Pages
  projects not created" (decentral.exchange 200). Also `:355,362,1042,1620` (old IP), `:1228`,
  `:22-30,351` cite `HANDOFF.md`, which no longer exists anywhere.
- Fix: replace the table with today's values (or a pointer to TOPOLOGY.md as the single topology
  source) and remove HANDOFF.md citations.

---

## MEDIUM

### DOC-M1: public docs say HotStuff is experimental/off; testnet runs it authoritatively
- `docs/05_node-guide/10_features-and-activation.md:66-68` ("off by default ... Do not enable"),
  `05_configuration.md:58`, `08_release-notes.md:9`. Live `/node/status` reports
  `hotStuffFinalizedHeight`; `infra/node-config/testnet/dcc.conf:171,176` and `nodes.yaml:175-176,327-328`
  have `enabled = true`, `authoritative = true`. Fix: add a Testnet note that T2 HotStuff is enabled and
  authoritative there (not on Mainnet), so finality numbers make sense to integrators.

### DOC-M2: data-service/matcher pages contradict the network page; matcher identity unpublished
- `04_building-apps/06_data-service-api.md:10,72` say no production rootUrl or matcher address is
  published ("confirm with whoever operates"), while `_static/.../026_Data-Service-API.csv` lists
  `https://testnet-data-service.decentralchain.io` (200; `/v0/pairs?matcher=31VMNV…` 200) and 028 lists
  the testnet matcher. No page states the testnet matcher public key/address
  (`BEtB5b2kX8Yge4sb5RRbTUqd5Va8Ah8PhphowcW31z6Y` / `31VMNVAvVh67dPZ41nMnYZvhoZFW7wwPrmq`). Fix: put rootUrl
  `https://testnet-data-service.decentralchain.io/v0`, matcher URL, pubkey and address on both pages.

### DOC-M3: testnet runs an unreleased, untagged 1.8.0; docs are "verified against v1.7.0"
- node-scala `version.sbt:3` = 1.8.0; tags stop at v1.7.0; `gh release list` = only v1.7.0; GHCR
  has tag `1.7.0` but no `1.8.0`. Docs `_terminology.md:16` baseline and every node-guide page note
  say v1.7.0; `08_release-notes.md` has no 1.8.0 entry; `10_features-and-activation.md:27-58` table is
  the 1.7.0 numbering (the :61 note corrects it). Fix: cut v1.8.0 (tag + release + GHCR tag), add
  release notes, re-baseline pages that describe testnet behaviour.

### DOC-M4: gRPC page has no working endpoint
- `04_building-apps/05_node-grpc.md:26,55` target `mainnet-node.decentralchain.io` ports 6870/6881:
  `nc` closed on mainnet-node and testnet-node (6870, 6877, 6881). The package is unpublished (npm
  E404), yet the page links its npm URL. Fix: state that no public gRPC endpoint exists, or expose one.

### DOC-M5: mainnet matcher URL on the networks page does not resolve
- `_static/02_decentralchain/tables/028_API-of-Decentral.Exchange-Matcher.csv` ->
  `https://mainnet-matcher.decentralchain.io/api-docs/index.html`: no DNS answer, curl 000. Fix: remove
  or replace with the real mainnet matcher.

### DOC-M6: TOPOLOGY.md and nodes.yaml comments wrong about val-0, balances, commands
- `infra/clusters/testnet/TOPOLOGY.md:17` "val-0 (non-mining)", but `31XTtK5S8b1DigEB4LCkgrCHHcU7qXPpSbV`
  is in `/generators/at/73200` with 20.1M generating balance and forged 19 of blocks 73160-73250.
  `:14-16` share percentages and `:51-53` "~26.7M DCC" each; live regular balances: main 33.73M, gen-0
  7.29M, gen-1 20.22M; val-0 missing from the table. `:7,29,51-54` Newark/Frankfurt naming.
  `:82` `kubectl logs deploy/dcc-gen-0`, but the nodes are StatefulSets (`nodes.yaml:501,503`).
  `nodes.yaml:446-449` comment "val-0 is unfunded at genesis and never forges" is stale too.
  Fix: update roles/balances, add val-0's address, use `sts/dcc-gen-0` or the pod `dcc-gen-0-0`.

### DOC-M7: TESTNET-FINAL-PLAN.md not reconciled with its own outcomes
- `infra/TESTNET-FINAL-PLAN.md:7` architecture still says main is `66.228.55.154` (dead); `:249,418,
  455,532,543` commands SSH to the dead IP; launch blockers B1-B10 (`:61-70`) all unchecked though B4
  (`:127`), B6 (matcher key, infra #184) and B9 (explorer/faucet now 200) are done; 181 `- [ ]` vs 58
  `- [x]`. Fix: tick or strike with evidence, fix the IP, add a closing status block.

### DOC-M8: infra README.md documents a deleted workflow and the dead IP
- `infra/README.md:1316-1358` full section on `auto-commit-generators.yml` as live, including a
  `gh workflow run` command; `:164` "server live: 66.228.55.154"; `:11-19` admits secrets-inventory
  overlap with DEPLOY.md "not yet reconciled (2026-08-13)", still not done.

### DOC-M9: DecentralChain admin-dashboard README "Live infrastructure" is pre-relaunch
- `DecentralChain/apps/admin-dashboard/README.md:131,133,418` (66.228.55.154), `:138` LKE
  `139.162.152.128` (now 139.162.144.243), `:141` cluster 615553 (now 663401), `:146-149,334-335`
  balances 50M/35M/15M/val-0 0, `:151-157` "Known infrastructure issue (2026-06-22)". Code twin:
  `apps/admin-dashboard/src/pages/ServiceHealth.tsx:155` renders "Newark Services (66.228.55.154)" in the UI.

### DOC-M10: load-bearing docs are outside version control, and one is already lost
- Root repo `/Users/jourlez/Documents/Code/Blockchain/.gitignore:6` ignores `Ecosystem/`, so
  `AUDIT-REPORT.md`, `GH_ACTIONS_INVENTORY.md`, `REPO-AUDIT-PROMPT.md`, `KEEWEB_BACKUP.md` are in no repo.
  The root repo still tracks `Ecosystem/DEPLOY.md`, `HANDOFF.md`, `INCIDENT-GEN0-PEERS.md`, `STATUS.md`
  (deleted on disk, `D` in status). `INCIDENT-GEN0-PEERS.md` is cited by node-scala code
  (`FatalErrorHandler.scala:16`, `NetworkServer.scala:136,151`, `PeerDatabaseImpl.scala:102`) and by
  `infra/clusters/testnet/RUNBOOK.md:202` as `docs/incidents/INCIDENT-GEN0-PEERS.md`; that path exists in no
  repo at origin/main. Soak evidence `/Users/jourlez/Documents/Code/Blockchain/.soak/soak-sample.sh` and
  `soak.log` (cited by SOAK-2026-10-12.md:11) are untracked. Fix: commit INCIDENT-GEN0-PEERS.md into
  `infra/docs/incidents/`, move the soak sampler into infra, decide whether the root
  audit/inventory docs belong in infra.

### DOC-M11: KEEWEB_BACKUP.md is a plaintext secrets file, and an older copy is in local git history
- `Ecosystem/KEEWEB_BACKUP.md` (mode 0600, untracked, not excluded from Time Machine): 31 entries;
  masked scan shows plaintext values for the wallet seeds (6 seed-phrase-like lines, 20 base58 values
  of 32+ chars), `#16 AGE_SECRET_KEY` (SOPS key for all testnet secrets) and `#17` personal age key
  (2 `AGE-SECRET-KEY` matches). Linode/R2/Tofu/root-password entries are pointers only (no value).
  Root repo history: `391c3f438d` (2026-06-15) added `KEEWEB_BACKUP.md` (13 base58 values, 24
  secret labels), `d571d91282` (2026-07-07) deleted it. Still reachable from `main` and 4 local
  branches/worktrees. The only remote is `upstream-waves` (no matching remote-tracking ref), so it looks
  unpushed. Also `/Users/jourlez/Documents/Code/Blockchain/.soak/kc` is a plaintext kubeconfig
  (2 apiVersion/credential markers). The operator accepted testnet seeds as public, but the AGE key
  opens every SOPS-encrypted testnet secret. Plan Phase 9 "KeeWeb backup cleaned" is unchecked.
  Content is stale too: headings say Newark/Frankfurt, balances 50M/35M/15M/val-0 0, entry number 27
  is used twice; RUNBOOK.md:415 calls the store "KeePassium".
- Fix: move values into the KeeWeb/KeePassium vault only, keep a pointer-only index, delete `.soak/kc`,
  and expire the history copy (`git filter-repo`) before the root repo ever gets a real remote.

### DOC-M12: GH_ACTIONS_INVENTORY.md is out of date
- `Ecosystem/GH_ACTIONS_INVENTORY.md:3,11` "as of 2026-09-22 ... 74 active (infra 25, ...)". It names
  workflows now absent from every repo's `.github/workflows` (peer-check, hotstuff-status,
  migrate-state-snapshot, build-native, debug-state-hash, deep-finality-diag,
  deploy-redis, fund-load-test-senders, inject-redis-secret, list-senders, live-statehash-divergence,
  promote-vps-image, rebalance-validators, restart-admin, set-redis-policy, tag-release), and omits
  live `alert-issues.yml`, `infra-liveness.yml`. infra now has 28 workflow files. Fix: regenerate
  from `.github/workflows` listings, or retire it in favour of each repo's archived-workflows README.

### DOC-M13: matcher README promises releases that don't exist; dead links
- `matcher/README.md:4-13` badge and "latest release ... in the Releases section":
  `gh release list -R Decentral-America/matcher` is empty. `:10` "Fork of Decentral-America/matcher"
  (self-reference). Dead: `:93` sbt 1.0/docs (404), `:200` docs.decentralchain.io/en/node/how-to-install-a-node/... (404),
  `:212` docs.dcc.tech (no DNS), `:261` node-scala `version-1.2.x` branch (404).

---

## LOW

- DOC-L1: `_static/thebelab-helper.js` and `thebelab.css` 404 on every published page (en and pt
  checked; referenced in every page head). Remove the extension or ship the assets.
- DOC-L2: `08_mainnet-testnet-stagenet.rst:65` repeats the Chain-ID paragraph under "API of Pool of Public
  Nodes"; `:28` caption "Parameters shipped in node v1.7.0".
- DOC-L3: `02_decentralchain/04_block.rst:19` "60 seconds" block time; testnet genesis
  `average-block-delay = 30s` (genesis-dcc-testnet-relaunch.conf:12; TOPOLOGY.md:4 "~30s").
- DOC-L4: Java SDK snippet `02_client-libraries-and-sdk.md:75` uses `<version>LATEST</version>`;
  Maven Central `release` is 2.0.1; pin it.
- DOC-L5: SDK version table drift: `next` tags ahead for signer 2.0.1, transactions 5.0.1, marshall
  1.0.1, assets-pairs-order 5.0.2, signature-adapter 7.0.1, protobuf-serialization 3.0.0
  (transactions 5.0.0 itself depends on marshall 1.0.0, which the table lists as 0.14.0).
- DOC-L6: `origin/gh-pages` last updated 2026-09-02 with root redirect `/de/main/`; Pages now
  deploys from the Actions artifact (deploy runs 10-11, 10-12 green). The orphan branch carries a CNAME and
  misleads anyone inspecting it. Delete or mark it.
- DOC-L7: node-scala `README.md:61` sbt `1.0/docs` links 404 (docs repo fixed the same in ce25981).
- DOC-L8: `infra/.github/archived-workflows/README.md:85-90` says `monitoring/alerts.yml` still names the
  deleted workflows; grep of `monitoring/` now finds none. That note is stale.
- DOC-L9: RUNBOOK.md Scenario A (`:15-17`) says Retain-policy volumes survive node loss; the 2026-10-01
  account-level deletion destroyed them (TESTNET-FINAL-PLAN.md:30). Add the caveat.
- DOC-L10: `DecentralChain/packages/e2e-blockchain/.env.testnet:11` commented matcher URL on dead IP.
- DOC-L11: node-scala design/plan docs keep Newark/3-generator facts (`docs/consensus-upgrade-plan.md:408,418,440`,
  `docs/hotstuff-maturation-decision-2026-08-31.md:15`) and code comments say Newark
  (`Miner.scala:525`, `NetworkServer.scala:134`); `infra/compose/grafana.yml:1`, `compose/prometheus.yml:1`,
  `monitoring/exporter.py:3`, `node-config/testnet/vps-image.env:2`, `terraform/main.tf:231`. Rename
  to "main (Dallas)" or add a "historical" header.
- DOC-L12: `AUDIT-REPORT.md` (2026-08-13) predates the relaunch, the Linode wipe and the new IPs, and has
  no "historical snapshot" banner.
- DOC-L13: dcc-report: own git repo, remote `github.com/dylanpersonguy/dcc-report` (a personal account,
  private, not the org); last content commit 2026-06-22; v3 PDF untracked. Report v3 claims are stale:
  `decentralchain-ecosystem-report-v3.md:9,193-195` "June 11 testnet launch ... one in Newark, three in
  Frankfurt", "running the same software the mainnet will run" (testnet 1.8.0 vs mainnet DCC v1.3.5).
  `generate-pdf-v3.js` works (run in a scratch copy: HTML + PDF produced) but hardcodes
  `/Applications/Google Chrome.app` (:265). The Python generators need `reportlab` (not installed) and
  there is no requirements file.
- DOC-L14: npm link for non-existent `@decentralchain/node-api-grpc` in 05_node-grpc.md (registry E404).

## INFO

- DOC-I1: "Edit on GitHub" links contain `docs//` (works, 200).
- DOC-I2: docs `origin/docs/live-testnet-endpoints` and other fix branches have 0 commits ahead of main
  (merged). Stale branches could be pruned.
- DOC-I3: local docs checkout is on `review/pr15` tracking `origin/docs/expansion-wp0`, not main
  (working tree clean).
- DOC-I4: root `/Users/jourlez/Documents/Code/Blockchain/TESTNET-FINAL-PLAN-2026-09-23.md` is a correct
  "moved to infra" pointer.

---

## Verified clean (checked, no finding)

- Testnet hostnames in docs/DecentralChain/infra all resolve and answer: node /node/version 200,
  data-service /v0/assets 200, testnet.decentral.exchange 200, testnet-matcher /matcher 200 + api-docs 200,
  testnet.decentralscan.com and /faucet 200, testnet-admin 302->/login, grafana 200, testnet-ws /ws 101.
- Chain ID `!`/33, address prefix `31`, chainId '!' in every testnet sample; sample recipient
  `31LAqgq…` validates on the testnet node.
- REST spot-checks of documented endpoints on testnet: /node/status, /node/version, /blocks/height,
  /blocks/last, /blocks/height/finalized, /blocks/headers/finalized, /blockchain/rewards,
  /activation/status, /transactions/unconfirmed, /utils/seed, /utils/time, /api-docs/openapi.yaml all 200;
  POST /transactions/calculateFee (no key) returns `{"feeAmount":100000}`; public GET /peers/* lists open on the
  gateway as documented (01_node-rest-api.md:37). Feature-26 note (10_features:61) matches live.
- Published-site crawl: 55 HTML pages, 164 internal URLs, 0 broken internal anchors; only internal
  404s are the thebelab assets (L1). External: 117 checked; real failures = mainnet-matcher (M5); npmjs
  403s are bot-blocking (the packages exist per registry); GitHub 429 rate limiting.
- Published content is current with origin/main (sample address and the feature-26 note present on
  en/main); Deploy Documentation runs on 10-11 and 10-12 succeeded.
- npm packages named in the docs exist with the stated `latest` versions (except node-api-grpc, which
  the docs say is unpublished). io.decentralchain:java-sdk 2.0.1 is on Maven Central.
- GHCR tags listed in 04_install-docker.md:27 exist (mainnet-latest, testnet-latest, stagenet-latest, 1.7.0, sha-*).
- Image consistency: nodes.yaml x3 and vps-image.env pin the same digest as live testnet-latest (8fcceceb).
- Live genesis (block 1 timestamp 1788539579643) matches infra dcc.conf and node-scala
  genesis-dcc-testnet-relaunch.conf.
- infra runbooks/reset-bps-testnet.md, reset-matcher-testnet.md, staggered-node-rollout.md reference only
  workflows that exist (restart-services.yml, update-node-image.yml) and no dead IPs.
- DecentralChain README/AGENTS/CLAUDE/CONTRIBUTING and other app READMEs: no stale IPs/regions
  (only admin-dashboard, M9). matcher docs/*.md: no testnet-specific stale facts.
