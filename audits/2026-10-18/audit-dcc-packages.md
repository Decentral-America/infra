# DCC Packages Audit (DecentralChain monorepo `packages/**`), 2026-10-18

Scope: `/Users/jourlez/Documents/Code/Blockchain/Ecosystem/DecentralChain/packages` (sdk/*, jvm/*, ride, e2e-blockchain), plus how consumers (apps, node-scala, matcher, docs) use them. The local tree is on branch `fix/renovate-trivy-pin`, and `git diff HEAD origin/main` is empty, so the content is identical to origin/main at a68d20af4.
Method: read-only. I queried the npm registry, Maven Central, crates.io, NuGet, GitHub API (runs, alerts, secrets *names only*), DNS/HTTP, ran pnpm audit, cargo audit, nx project resolution, local unit tests, publint/attw/size, and an EIP-155 known-answer vector. Prior AUDIT-REPORT.md was used as leads only.

---

## HIGH

### PKG-01 HIGH: npm registry is ~7 months stale; the 2026-06-23 "release" never reached npm; 5 packages were never published
- **Evidence:**
  - Source versions vs `npm view` (latest / next):
    - transactions 6.0.0 vs 5.0.0 / 5.0.1
    - signer 3.0.0 vs 1.1.0-beta / 2.0.1
    - crypto 2.0.0 vs 1.0.1 / 1.0.2
    - signature-adapter 8.0.0 vs 6.1.7 / 7.0.1
    - ledger 6.0.0 vs 5.1.0
    - marshall 2.0.0 vs 0.14.0 / 1.0.1
    - ts-lib-crypto 3.0.0 vs 2.0.0
    - data-entities 4.0.0 vs 3.0.0
    - assets-pairs-order 6.0.0 vs 4.0.0 / 5.0.2
    - …and the same pattern for all 21.
  - Every package's `time.modified` is 2026-03-13.
  - **E404 (never published):** `@decentralchain/node-api`, `node-api-grpc`, `protobuf-schemas`, `types`, `data-service-client`.
  - The `release.yml` run 27998018567 (2026-06-23, workflow_dispatch, main) is green on every step, including "Release (version + changelog + publish)" and "Generate SBOM". The SBOM step only runs when `!inputs.dry-run`, so this was not a dry run.
  - That run created 21 tags `@decentralchain/*@<new>` dated 2026-06-23 and commit ce09e8984 "chore(release): publish". npm got nothing.
  - The run logs have expired (HTTP 410), so the root cause can't be read back. `NPM_TOKEN` exists as an org secret (name only checked).
  - Unreleased since then:
    - EIP-155 Ethereum signer (#84, 2026-07-23)
    - InvokeExpression SDK (#80)
    - 10 more commits in `packages/sdk/transactions/src` after the 6.0.0 tag
  - Every package README says `npm install @decentralchain/<pkg>`. For the five E404 packages, and for docs `04_building-apps/05_node-grpc.md` (`npm install @decentralchain/node-api-grpc`), that command fails. For the rest it installs the old March code.
- **Why it matters:** External dApp developers, which is the whole reason signer, cubensis-connect-provider and node-api-grpc exist (none has an in-repo consumer, see PKG-17), can't get the current SDK. A green release job that publishes nothing is a silent false-success gate. Tags and changelogs say versions exist that don't. The testnet apps are not affected, because they use `workspace:*`.
- **Fix:**
  1. Run `release.yml` with dry-run, then for real, with log capture. Check each publish line.
  2. Add a post-publish verification step (`npm view @decentralchain/$p@$v version` for each released project) that fails the job.
  3. Drop `--first-release` from routine runs.
  4. Treat PKG-02 as a blocker for the re-run.

### PKG-02 HIGH: published JVM artifacts don't match source at the same version; published crypto 2.0.7 pulls BouncyCastle 1.84 (critical + high GHSAs)
- **Evidence:** I diffed the Central POMs against the source POMs.

  | Artifact | Central (published) | Source (same version number) |
  |---|---|---|
  | `crypto:2.0.7` | bcprov 1.84 | bcprov 1.86 |
  | `transactions:1.0.0` | protobuf-schemas 1.6.2, web3j-crypto 5.0.2, vertx-core 4.5.27, jackson 2.21.3 | protobuf-schemas 1.6.6, web3j 6.0.0, vertx 5.2.0, jackson 2.22.3, plus tuweni 2.8, bcprov 1.86, jackson 3 |
  | `java-sdk:2.0.1` | (older set) | protobuf-java 4.36.2, vertx 5.2.0, bcprov 1.86, logback… |
  | `curve25519:1.0.0` | jna 5.18.1 | jna 5.19.1 |

  - blst and groth16 match.
  - Central publish dates: all 2026-06-05/06, except protobuf-schemas 1.6.6 (2026-09-04).
  - OSV for bcprov-jdk18on 1.84:
    - GHSA-9pwp-9qqc-pr26 (CRITICAL, name-constraints bypass)
    - GHSA-qp49-qgx5-5m26 (HIGH, ASN.1 nesting DoS)
    - 1.86 is clean.
  - Mitigation in the ecosystem: node-scala (`Dependencies.scala:90`) and matcher (`Version.bcprov = "1.86"`) both force 1.86. Any other consumer of `io.decentralchain:crypto/transactions/java-sdk` from Central gets 1.84.
  - Matcher's integration kit consumes the old Central `transactions:1.0.0` (protobuf 1.6.2), which has no HotStuff schema.
- **Why it matters:** The same Maven coordinates mean two different things depending on whether you build from source (`mavenLocal` resolvers are still enabled in node-scala `build.sbt` and matcher `build.sbt:8-12`, "REMOVE after DCC-269 Phase 3"). Builds aren't reproducible, and the published artifacts ship a critical CVE.
- **Fix:**
  1. Bump versions (crypto 2.0.8, transactions 1.0.1, java-sdk 2.0.2, curve25519 1.0.1) and publish.
  2. Add a CI check that fails when a source POM's dependency set differs from the Central POM at an unchanged version.
  3. Remove the `Resolver.mavenLocal` fallbacks.

---

## MEDIUM

### PKG-03 MEDIUM: the documented Maven release pipeline has never run
- **Evidence:**
  - `gh api …/workflows/prepare-release.yml/runs` → total_count=0.
  - `publish-maven-package.yml` → total_count=0.
  - `gh release list` → empty.
  - The JVM artifacts were published out-of-band. The only run is `maven-central-deployment-status.yml` on 2026-08-13.
  - `infra/TESTNET-FINAL-PLAN.md:190` prescribes exactly this untested path for the pending crypto 2.0.8 release: `gh workflow run prepare-release.yml … -f package=crypto -f version=2.0.8`, then publish the draft.
  - Separately, the repo's unscoped `v1.1.0`…`v2.0.7` tags give no hint which package they belong to.
- **Why it matters:** The first real exercise will be the crypto security re-release (PKG-02). Release-day failure is likely: there is no precedent run, and Central rejects re-publishing an existing version.
- **Fix:** Run `prepare-release.yml` for a no-risk package (for example curve25519 1.0.1, which also carries a real jna bump) before crypto. Document which tag prefix each JVM package uses.

### PKG-04 MEDIUM: JVM `transactions` defaults to the Waves mainnet chain id `'W'`
- **Evidence:**
  - `packages/jvm/transactions/src/main/java/com/decentralchain/transactions/common/ChainId.java`: `MAINNET = 'W'; TESTNET = 'T'; STAGENET = 'S'`.
  - `DccConfig.java:7`: `private static byte chainId = ChainId.MAINNET;`.
  - 16 convenience constructors use `DccConfig.chainId()`: Transfer/Issue/Lease/Burn/Data/MassTransfer/Exchange/Order/Alias/SetScript/…
  - DCC uses `'?'` (63) for mainnet and `'!'` (33) for testnet. The TS `ts-lib-crypto/src/crypto/interface.ts:11-13` has this right.
  - Only `matcher/dex-load/.../TankGenerator.scala:62` overrides it (`DccConfig.chainId(AddressScheme.current.chainId)`).
- **Why it matters:** Any Java consumer of `io.decentralchain:transactions` that doesn't call `DccConfig.chainId(...)` builds transactions and addresses for the wrong network. These fail on DCC. The constant names actively mislead.
- **Fix:** Set `MAINNET='?'` and `TESTNET='!'`, and remove or rename the Waves constants (or keep them as `WAVES_*`). Add a test that asserts DCC addresses round-trip. Release as a major or minor version.

### PKG-05 MEDIUM: Signer's default `NODE_URL` points at a hostname that doesn't exist
- **Evidence:**
  - `packages/sdk/signer/src/constants.ts:5` `NODE_URL: 'https://nodes.decentralchain.io'`.
  - `dig +short nodes.decentralchain.io` → empty (NXDOMAIN).
  - `Signer.ts:110/129` merges defaults and immediately calls `getNetworkByte(this._options.NODE_URL)`.
  - By contrast, transactions `nodeInteraction.ts:44` defaults to `https://mainnet-node.decentralchain.io/` (resolves, `/node/version` 200), and cubensis-connect-provider uses the same mainnet-node host. So there are two different "mainnet" defaults.
  - `nodes.decentralchain.io` is also used in ~15 JSDoc examples in `transactions/src/nodeInteraction.ts`.
- **Why it matters:** `new Signer()` without options fails with a network-byte error for every integrator.
- **Fix:** Set the default to `https://mainnet-node.decentralchain.io` (or a shared constant) and fix the JSDoc examples. Optionally export a `TESTNET_NODE_URL` (`https://testnet-node.decentralchain.io`, which resolves).

### PKG-06 MEDIUM: licensing — undisclosed GPL-3.0 core dependency and POM/LICENSE mismatches
- **Evidence:**
  - `packages/jvm/curve25519` is **GPL-3.0-only** (both the POM and the LICENSE).
  - It is a compile dependency of `io.decentralchain:crypto` (MIT), which flows into transactions and java-sdk (MIT). node-scala `Dependencies.scala:67` and matcher `Dependencies.scala:111/272` depend on it directly, and both ship it in Docker images and Debian packages.
  - The GPL is disclosed only in curve25519's own README and KNOWN_ISSUES. There is nothing in the root LICENSE, crypto/java-sdk, node-scala or matcher.
  - POM license metadata contradicts the LICENSE files:
    - `groth16/pom.xml` says Apache-2.0, LICENSE says MIT.
    - `java-sdk/pom.xml` says Apache-2.0, LICENSE says MIT.
- **Why it matters:** Distributing combined binaries that include GPL-3.0 code brings GPL obligations (source offer, license the combined work under GPL terms). Wrong POM metadata misleads downstream license scanners. The prior audit reported "license sweep clean", which missed this.
- **Fix:**
  - Either replace curve25519 with a permissively licensed X25519/Ed25519 implementation (BouncyCastle already ships them), or document GPL compliance across the consumers.
  - Make the groth16 and java-sdk POMs and LICENSE files agree.

### PKG-07 MEDIUM: upstream MIT copyright notices removed or rewritten in forked code
- **Evidence:** Upstream LICENSE files (fetched raw from GitHub) compared with the forks:

  | Upstream | Upstream notice | Fork's notice |
  |---|---|---|
  | wavesplatform/Waves | "Copyright (c) 2018 WavesPlatform" | node-scala/LICENSE and matcher/LICENSE: "Copyright (c) 2018 **DccPlatform**" (the holder name was find-and-replaced) |
  | ts-lib-crypto | "2018 WavesPlatform" | packages/sdk/ts-lib-crypto: "2026-present DecentralChain" |
  | marshall | "2018 Wavesplatform LLC" | packages/sdk/marshall: "2026-present DecentralChain" |
  | signer | "2020 Inal Kardanov" | packages/sdk/signer: "2025-present DecentralChain" |
  | WavesJ | "2018 WavesPlatform" | jvm/java-sdk: "2024 DecentralChain" |
  | RIDE (extracted from node-scala/Waves, README:3) | (WavesPlatform) | packages/ride/LICENSE: "2026-present DecentralChain" |

  Some forks do keep the upstream notice: sdk/crypto (Sergey Slipchenko), jvm/crypto (Maxim Smolyakov), jvm/blst (Waves Protocol) and jvm/groth16 (Igor Gulamov).
- **Why it matters:** MIT's only condition is that "the above copyright notice … shall be included". Rewriting or removing it is non-compliance in every published artifact.
- **Fix:** Restore the original copyright lines alongside the DecentralChain line, and add a root NOTICE or THIRD_PARTY file that lists the Waves-derived packages.

### PKG-08 MEDIUM: two diverging RIDE compiler/evaluator copies; the published one is missing a node determinism fix
- **Evidence:**
  - `node-scala/lang` has 345 .scala files; `DecentralChain/packages/ride/lang` has 342. packages/ride is "extracted from node-scala" (README:3), but node-scala still builds its own lang (published as `io.decentralchain:lang` 1.7.0), while packages/ride publishes Maven `io.decentralchain:ride` 1.6.2 (a java-sdk dependency) and npm `@decentralchain/ride-lang` 1.6.2 / `@decentralchain/ride` 2.3.1.
  - Content diffs exist in ExpressionCompiler, PureContext, Functions, SerdeV1/V2 and CryptoContext. Many are formatting, but not all.
  - node-scala c80c4d1c39 (2026-10-10, "pin 'long overflow' message … same failed script could report different errors on different nodes") is absent from packages/ride (`grep 'long overflow'` in shared → 0 hits).
  - The CaseObj decode fix was ported by hand (158e5201a vs 71a01c86bc). The process is manual and lagging.
- **Why it matters:** Developer tooling and the java-sdk can compile or evaluate scripts differently from the deployed node.
- **Fix:** Pick one source of truth: either node-scala consumes `io.decentralchain:ride`, or packages/ride is generated from node-scala. Until then, add a CI diff check and port c80c4d1c39.

### PKG-09 MEDIUM: E2E suite (the "217/217") has vacuous tests and real feature gaps
- **Evidence (`packages/e2e-blockchain/src`):**
  - CommitToGeneration (type 19), `advanced-types.spec.ts:57-81`: "scans 50 recent blocks… // Always passes" with `expect(ctgTxs.length).toBeGreaterThanOrEqual(0)`.
  - The only other CTG test (`:83`) accepts any 400/422 for a garbage body. There is no positive CTG submit, even though the SDK has a `commitToGeneration` builder (`transactions/test/transactions/commit-to-generation.spec.ts`). CTG is the committed-generator and finality entry point.
  - InvokeExpression scan `:180` uses the same `>= 0` pattern.
  - `network/peers.spec.ts:45,69,81,111` do `if (!API_KEY) return; // silently pass`. infra `admin-e2e.yml:120-125` doesn't set `DCC_TEST_API_KEY`, so those tests are always no-ops in the official run.
  - Also: `ethereum.spec.ts:115` (`if (!result.result) return`), `update-asset-info.spec.ts:92` ("structural pass"), `throughput.spec.ts:70` ("Always passes").
  - Not covered at all (grep):
    - rejection of a wrong or foreign chain-id
    - duplicate or replayed tx rejection
    - Ethereum invoke (non-empty `data`)
    - HotStuff/BLS vote content
    - gRPC / blockchain-updates
    - websocket-api
  - The suite is manual-dispatch only (`admin-e2e.yml` has no schedule, a documented choice), so SDK PRs never run it. The last runs were 2026-10-11.
- **Why it matters:** The pass count overstates verified behavior on exactly the consensus-adjacent paths with recent incidents.
- **Fix:**
  - Replace the `>= 0` tests with real submit-and-confirm tests: CTG via the SDK builder with a real BLS key.
  - Use `it.skipIf(!API_KEY)` so skips show up, and set the API key in admin-e2e.
  - Add tests for chain-id mismatch and duplicate-tx rejection.

### PKG-10 MEDIUM: release gate fails today; 45 dev-dependency advisories; scanners disagree
- **Evidence:**
  - `pnpm audit --audit-level=moderate` (the exact `release.yml` step) exits **1**: 45 advisories, all dev-scope, as follows.
    - 1 critical: seroval GHSA-p6vx-979v-rg4c via `@tanstack/react-query-devtools`.
    - 21 high, including axios <1.20 via nx/@nx/devkit (7 GHSAs), undici <7.29.1 via vitest>jsdom, extract-zip and basic-ftp via webdriverio, sharp via wrangler, smol-toml via nx, brace-expansion and source-map-js via vite.
  - `--prod` → 0 unignored, exit 0. That is the CI gate at `ci.yml:85`.
  - The devtools import is behind `import.meta.env.DEV` (`apps/exchange/src/App.tsx:22`), so it isn't in the prod bundle.
  - The Dependabot alerts API shows **0 open** alerts, and `dependabot_security_updates` is disabled. GitHub's view disagrees with the npm advisory DB.
- **Why it matters:** PKG-01 can't be re-run until this is cleared. Supply-chain risk to CI runners (nx/axios, vitest/undici TLS bypass GHSA-w293) is real even though it's dev-only.
- **Fix:** Bump nx (axios), vitest/jsdom (undici), @tanstack devtools (seroval), and add pnpm overrides; check them with `pnpm why`. Either make release use `--prod` with the same ignore list, or keep the full audit and fix the advisories. Enable Dependabot security updates or add a scheduled `pnpm audit` job.

### PKG-11 MEDIUM (cross-ref matcher auditor): matcher compiles against node 1.7.0; testnet runs 1.8.0, which isn't on Central
- **Evidence:**
  - `matcher/dccNode.sbt:3` `Global / dccNodeVersion := "1.7.0"`.
  - Central `io.decentralchain:node` metadata lists 1.7.0 only (2026-07-25).
  - `node-scala/version.sbt` is 1.8.0, and `https://testnet-node.decentralchain.io/node/version` → "DecentralChain v1.8.0".
  - `matcher/project/ExtensionPackaging.scala:87-93` derives the package dependency `(>= 1.7.0) (<< 1.8.0)`, which declares itself incompatible with the running node.
- **Why it matters:** The matcher extension's compile-time API doesn't match the deployed node's. Debian packaging would refuse to co-install.
- **Fix:** Publish node 1.8.0 to Central, then bump `dccNodeVersion`.

---

## LOW

- **PKG-12 LOW, CI "License scan" is a no-op.**
  - `ci.yml` "License scan" runs `pnpm licenses list --prod`. Under pnpm 12.7.0 that prints nothing (CI log 2026-10-12: "License scan complete (0 entries)"; locally `--prod --json` → `{}`).
  - It isn't gating anyway. That's how PKG-06 slipped through.
  - Fix: use `pnpm licenses list --json` (without --prod), or license-checker, with an allowlist that fails on GPL/AGPL/unknown.
- **PKG-13 LOW, new Rust advisories and a false CI comment.**
  - `cargo audit` in `jvm/groth16`: RUSTSEC-2026-0346/0347/0348/0349 (rustls 0.23.45, fixed in >= 0.23.46) via `fastcrypto-zkp > reqwest > hyper-rustls`. These are new and not ignored, so groth16.yml's audit job will go red on its next path-triggered run. Nothing is scheduled, so it's silent until then.
  - `groth16.yml:174` says "rsa not in production dep tree", but `cargo tree -i rsa` shows `rsa > fastcrypto > fastcrypto-zkp > groth16_fastcrypto > groth16_jni`, so it is compiled into the node's native lib. Marvin (RUSTSEC-2023-0071) is probably not reachable, because no RSA decryption happens. The comment is still factually wrong. A network HTTP client is also linked into a consensus verifier library.
  - `sdk/protobuf-schemas` crate: RUSTSEC-2026-0258 (h2 0.4.14, build-time only via tonic-build).
  - Fix: `cargo update -p rustls`, correct the comment, and consider disabling the default features of fastcrypto-zkp. Add a weekly scheduled cargo audit.
- **PKG-14 LOW, code-scanning #114 (`packages/sdk/amm/src/amounts.ts:52`, `/0+$/`) is real but not exploitable.**
  - I timed it: quadratic (n=5e4 → 1.4 s). But the input `fracPart` is a slice of length `decimals` from bigint digits, and on-chain decimals are ≤ 8, so it can't be exploited.
  - Fix: a manual trailing-zero loop, then dismiss the alert.
  - Adjacent real correctness bugs in the same file:
    - `toRawAmount(1e-7, 8)` → `"1e-7"` → `BigInt` throws. Number inputs in exponential notation aren't handled.
    - `fromRawAmount(-5n, 8)` pads the minus sign into the middle (wrong output).
- **PKG-15 LOW, code-scanning #113 is a false positive.** In `apps/exchange/src/lib/tokenLogos/__tests__/csp.test.ts:65`, `directive.includes(LOGO_CDN)` is a test assertion, not URL sanitization. Dismiss it as a false positive, or tokenize the directive to match exactly (which also tightens the test).
- **PKG-16 LOW, missing LICENSE files.**
  - `packages/sdk/node-api-grpc`: its `files[]` lists LICENSE, but no file exists, so the tarball would ship without one.
  - `packages/jvm/transactions`: a published Maven artifact with no LICENSE.
  - `packages/sdk/amm`: private, but MIT is declared.
- **PKG-17 LOW, dead or externally-only packages.**
  - `@decentralchain/node-api-grpc` has zero consumers in the monorepo, was never published, and the docs tell users to install it.
  - `@decentralchain/signer` is consumed only by `cubensis-connect-provider`, which has zero consumers. Both are external-only, so their value depends entirely on PKG-01.
  - `@dcc-amm/sdk` breaks the `@decentralchain/` scope convention.
- **PKG-18 LOW, docs reference legacy packages.**
  - `docs/docs/_samples/package.json` and `04_building-apps/02/03_*.md` reference the legacy `@decentralchain/node-api-js@2.0.1` and `data-service-client-js@^4.2.0` (old-generation packages, not this monorepo's source) and `transactions@^5.0.0`.
  - The SDK docs are therefore written against a different codebase than the one in `packages/sdk`.
- **PKG-19 LOW, the same schema ships under four version numbers.** protobuf-schemas is npm 3.1.0 (unpublished), Maven 1.6.6, Cargo 1.5.2 (crates.io: does not exist) and NuGet `DecentralChain.Protobuf` 2.0.0 (NuGet: not found). There's no single schema version to reason about compatibility with.
- **PKG-20 LOW, stale vendored proto in matcher.**
  - `matcher/dex-grpc/src/main/protobuf/dcc/block.proto` is missing `FinalizationVoting.hotstuff_conflicts = 5` and the HotStuffVote/QC/EquivocationProof/Proposal messages that are in protobuf-schemas 1.6.6.
  - The other 16 vendored protos match (comment- and option-insensitive diff).
  - Harmless while the matcher only decodes, since proto3 keeps unknown fields. It's a drift risk.
  - Fix: consume the `protobuf-src` classifier the way node-scala does.
- **PKG-21 LOW, Java package/directory mismatch.** All 83 main sources in `jvm/transactions` live under `com/decentralchain/...` but declare `package io.decentralchain...`. Other JVM packages have 0 mismatches. This is a half-finished rename.
- **PKG-22 LOW, the documented local E2E path is broken.**
  - `packages/e2e-blockchain/docker-compose.yml:5` uses `ghcr.io/decentral-america/node-scala-private:latest`, which doesn't exist in the org's GHCR packages (it has node-scala, matcher, etc.). README:16 tells you to run it.
  - `env.ts` defaults mix a localhost node with the testnet data-service and matcher URLs.
- **PKG-23 LOW, broken error link in Signer.** `signer/src/SignerError.ts:2` links to `tree/main/packages/signer`. The package moved to `packages/sdk/signer`, so every Signer error message carries a 404 link.
- **PKG-24 LOW, local `check:publint`/`check:exports` race.** `nx run-many -t check:exports check:publint` in parallel failed on node-api-grpc, because both run `pnpm pack`, which triggers `prepack: rm -rf dist && tsdown` concurrently. It passes when run alone. CI runs these as sequential steps, so CI isn't affected. Fix: remove the `rm -rf` in prepack, or add a `dependsOn` or serialization.

---

## INFO

- **INFO-1, EIP-155 signer verified.** I fed the EIP-155 spec vector (privkey 0x46…46, the spec's signing-payload RLP) to `ethereumSign` from the ts-lib-crypto dist. It produced the exact spec r and s, and v=37. `ethereumTransfer` encodes v as chainId*2+35+recovery and uses low-S. The repo's own tests only check self-consistency (recovery round-trip). Add this known-answer test.
- **INFO-2, local unit tests all pass.** ts-lib-crypto, transactions, signer, crypto (WASM), marshall, signature-adapter and amm: 1,464 tests passed, 0 failed, with `--skip-nx-cache`. There are zero `.skip`/`.todo` in any SDK package.
- **INFO-3, JVM CI is green.** The last runs of blst/curve25519/groth16/java-sdk/transactions/crypto-tests/ride/integration are all green (2026-09-30 to 10-01). They're path-triggered, not scheduled. crypto-tests uses `-Dmaven.test.failure.ignore=true`, but the surefire-report action has `fail_on_test_failures: true`, so it does gate (it also has `fail_if_no_tests: false`).
- **INFO-4, CI exclusions verified.** I resolved the `ci.yml:131-150` exclusions with nx (`nx show projects --exclude=…`). The unscoped `crypto` and `transactions` resolve exactly to the JVM projects, so `@decentralchain/crypto` and `@decentralchain/transactions` *are* tested in CI. JVM packages are covered by dedicated workflows, ride by ride.yml, and e2e-blockchain by infra admin-e2e (manual).
- **INFO-5, TS SDK chain-id defaults are consistent.** Mainnet `'?'` (63) and testnet `'!'` (33). No Waves URLs or chain ids remain in the TS sources. Only JVM has the problem (PKG-04).
- **INFO-6, consumer versions exist on Central.** Every node-scala and matcher `io.decentralchain` dependency version is on Maven Central: protobuf-schemas 1.6.6, curve25519 1.0.0, groth16 0.2.1.0, blst 0.3.16.0, transactions 1.0.0, java-sdk 2.0.1. But see PKG-02 on content drift.
- **INFO-7, crypto 2.0.8 is confirmed unreleased.** Central latest is 2.0.7, which declares bcprov 1.84. The source is still 2.0.7 (with bcprov 1.86, see PKG-02).
- **INFO-8, Ledger.** It uses the Waves BIP-44 coin type 5741564 and Waves Ledger app APDUs. This is documented in `dcc-ledger.ts:38`.
- **INFO-9, prod dependency audit is clean.** `pnpm audit --prod` is clean apart from one documented ignore (braces GHSA-vfj7-8cjw-p6xm, no fix available).
- **INFO-10, process signals.** Since 2026-01 one author has made 902 of ~1,030 commits under packages/. The last 10 merged PRs have 0 reviews each. Bus factor and review quality are a Phase 12 risk.
- **INFO-11, duplicate crypto libraries.** `@decentralchain/crypto` (WASM/noble, used only by cubensis-connect) and `@decentralchain/ts-lib-crypto` (used everywhere else) both implement address and signing. Divergence risk is low, but they are Duplicate Code at package scale.

---

## Phase coverage

- **Phase 0:** done (tree, CI files, nx config, release config).
- **Phase 1:** dead packages and orphan images done. knip was not re-run (its config is reviewed; exports are excluded by design).
- **Phases 2-3:** sampled only (the RIDE duplication, the crypto duplication, the half-finished Java package rename).
- **Phase 4:** dependency vulns (pnpm, cargo, OSV for Maven), ReDoS triage, chain-id and URL defaults, crypto KAT.
- **Phase 5:** test runs, skip scan, E2E vacuity and coverage gaps.
- **Phase 6:** live run history for every package and publish workflow, registry-vs-source for npm, Maven, crates.io and NuGet.
- **Phase 11:** LICENSE/NOTICE per package, POM metadata, upstream notices, GPL dependency, the license-scan gate.
- **Phase 12:** bus factor, reviews, local E2E reproducibility.
- **Not done:** JVM `mvn dependency:tree` and OWASP dependency-check (NVD-heavy; I used published-POM diffs plus OSV instead), mutation testing, and a full semantic diff of the two RIDE trees.
