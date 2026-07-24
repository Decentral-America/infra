# Tier 2 — Matcher CI Wiring, Settlement E2E, CommitToGeneration Builder Coverage — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close Tier 2 of the [E2E testing strategy](../specs/2026-07-24-e2e-testing-strategy-design.md): fix the actual root cause blocking matcher's real E2E suites (`dex-it`/`dex-integration-it`) from running in CI, get the existing cross-repo DEX-settlement spec into the routine smoke suite instead of manual-only, and cover the SDK's `commitToGeneration()` builder function, which has zero test calls anywhere today.

**Architecture:** Three independent, narrowly-scoped fixes, each grounded in a prior code audit (see spec Tier 2, corrected 2026-07-24): (1) a one-line base-image reference fix in matcher's `dex-ext/build.sbt` plus a `ci.yml` job change from `quickCheck` to `fullCheck`; (2) a one-line addition to `infra/.github/workflows/admin-e2e.yml`'s smoke spec list, since the settlement spec (`exchange.spec.ts`) already exists and works; (3) a new unit-test file for `commitToGeneration()` in DecentralChain's transactions package, following the exact pattern already established by sibling builders (`alias.spec.ts`).

**Tech Stack:** sbt (matcher), GitHub Actions YAML (matcher + infra), Vitest/TypeScript (DecentralChain SDK).

## Global Constraints

- Task 1's fix is a single-line change to a base image reference — do not restructure `dex-ext/build.sbt` beyond that line.
- Task 2 flips `ci.yml`'s `integration` job from `quickCheck` to `fullCheck` — this job's timeout must increase to accommodate Docker image builds (`dex-ext`, `dex`, `dex-integration-it`, `dex-it` — four sequential `docker` builds per `fullCheckRaw`, see spec) — do not just change the command and leave the old `timeout-minutes` in place.
- Task 2's actual success can only be confirmed by a real CI run (this plan's "Run" steps can validate compilation/local behavior, but the CI YAML change itself is only fully proven once a PR runs it) — say so plainly rather than claiming certainty from a local check alone.
- Task 3 must not create a new `dex-settlement-flow.spec.ts` — that would duplicate `exchange.spec.ts`, which the code audit confirmed already implements this scenario in full.
- Task 4's new spec file must follow the exact existing conventions in `packages/sdk/transactions/test/transactions/` (see `alias.spec.ts` quoted in this plan) — same import style, same `validateTxSignature` helper, same `describe`/`it` structure. Do not invent a different test style for this one builder.
- Do not assert behavior this plan hasn't verified. In particular, do not add a "zero fee throws" test for `commitToGeneration()` — its validator uses `isNaturalNumberOrZeroLike` for `fee` (`validators/commit-to-generaction.ts`), which may permit zero; this differs from other builders (e.g. `alias`) that reject zero fee, and asserting throw-behavior without checking would be a fabricated claim.

---

### Task 1: Fix matcher's `dex-ext` base image reference

**Files:**
- Modify: `matcher/dex-ext/build.sbt` (the `from(s"decentralchain/dccnode:${dccNodeVersion.value}")` line — code audit located it at line 111; confirm the exact current line number before editing, since the file may have shifted).

**Interfaces:** None — this is a Docker base-image string literal, no Scala API surface changes.

- [ ] **Step 1: Confirm the current broken reference**

Run: `grep -n 'decentralchain/dccnode' matcher/dex-ext/build.sbt`
Expected output: one line, e.g. `from(s"decentralchain/dccnode:${dccNodeVersion.value}")` — confirm this is the only occurrence in the file before editing (a second occurrence would mean the fix is incomplete if only one is changed).

- [ ] **Step 2: Confirm the real published image name**

Run: `grep -n 'IMAGE_NAME' /Users/jourlez/Documents/Code/Blockchain/Ecosystem/node-scala/.github/workflows/publish-node-scala.yml`
Expected: `ghcr.io/decentral-america/node-scala` — this is the actual name node-scala's release workflow pushes to (confirmed by prior code audit). This is the value the base image reference must point at instead.

- [ ] **Step 3: Apply the fix**

In `matcher/dex-ext/build.sbt`, change:
```scala
from(s"decentralchain/dccnode:${dccNodeVersion.value}")
```
to:
```scala
from(s"ghcr.io/decentral-america/node-scala:${dccNodeVersion.value}")
```

- [ ] **Step 4: Verify the sbt build definition still parses**

Run: `cd matcher && sbt --batch "dex-ext/Docker/dockerfile"` (or, if that exact task key doesn't print the rendered Dockerfile in this sbt-docker-plugin setup, run `sbt --batch "show dex-ext/Docker/dockerfile"` — use whichever resolves; the goal is to print the rendered `Dockerfile` content without actually invoking the Docker daemon, to catch a typo before a real docker build attempt)
Expected: the printed Dockerfile's `FROM` line reads `FROM ghcr.io/decentral-america/node-scala:1.6.3` (or whatever `dccNodeVersion` currently resolves to — cross-check against `ci.yml`'s `DCC_NODE_VERSION` env var, currently `1.6.3`).

- [ ] **Step 5: Attempt a real local docker build (best-effort — requires Docker daemon and network access to ghcr.io)**

Run: `cd matcher && sbt --batch "dex-ext/Docker/docker"`
Expected: PASS if Docker is available locally and `ghcr.io/decentral-america/node-scala:1.6.3` is a public (or locally-authenticated) pullable image. If this fails specifically on "manifest not found" or similar, the version pin (`dccNodeVersion` in matcher's build) may not match an actually-published node-scala release tag — check `matcher/project/Dependencies.scala` (or wherever `dccNodeVersion` is set) against node-scala's actual published release tags before concluding the fix itself is wrong.

- [ ] **Step 6: Commit**

```bash
cd /Users/jourlez/Documents/Code/Blockchain/Ecosystem/matcher
git add dex-ext/build.sbt
git commit -m "fix: point dex-ext base image at the real published node-scala release (ghcr.io/decentral-america/node-scala)"
```

---

### Task 2: Wire `fullCheck` into matcher's CI

**Files:**
- Modify: `matcher/.github/workflows/ci.yml` (the `integration` job, quoted in full in this plan's research — lines 117-148 as of the code audit).

**Interfaces:** None — GitHub Actions YAML only.

**Depends on Task 1** — do not run this before Task 1's fix is merged, or `fullCheck` will fail on the same base-image pull error Task 1 fixes.

- [ ] **Step 1: Read the current job before editing**

Run: `sed -n '117,148p' matcher/.github/workflows/ci.yml`
Confirm it still matches the quoted block below (re-quoted from the code audit) before editing — if it has drifted, adapt the edit to the actual current content rather than blindly overwriting:
```yaml
  # ── Integration tests ──────────────────────────────────────────────────────
  # fullCheck requires Docker images built from GitHub release artifacts and a
  # live DCC node — neither is available in CI until the first release is published.
  # quickCheck provides a second-opinion compile + unit test pass in a clean
  # environment with freshly published node-scala artifacts.
  integration:
    name: Integration Tests (quickCheck — fullCheck requires releases)
    runs-on: ubuntu-latest
    timeout-minutes: 90
    needs: quality

    steps:
      - name: Checkout
        uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0

      - name: Set up Java ${{ env.JAVA_VERSION }}
        uses: actions/setup-java@1bcf9fb12cf4aa7d266a90ae39939e61372fe520  # v5.4.0
        with:
          distribution: temurin
          java-version: ${{ env.JAVA_VERSION }}
          cache: sbt

      - name: Set up SBT
        uses: sbt/setup-sbt@af116cce31c00823d3903ce687f9cda3a4f19f1b # v1.2.1

      - name: Set up DCC JVM dependencies
        uses: ./.github/actions/setup-dcc-jvm-deps
        with:
          dcc-node-version: ${{ env.DCC_NODE_VERSION }}

      - name: Run quickCheck (compile + scalafix + unit tests)
        run: sbt quickCheck
```

- [ ] **Step 2: Apply the edit**

Replace the block above with:
```yaml
  # ── Integration tests ──────────────────────────────────────────────────────
  # fullCheck builds dex-ext/dex/dex-integration-it/dex-it Docker images (the
  # dex-ext base-image fix landed separately) and runs the real dex-it /
  # dex-integration-it E2E suites — this is the actual E2E gate, not a proxy.
  integration:
    name: Integration Tests (fullCheck)
    runs-on: ubuntu-latest
    timeout-minutes: 150
    needs: quality

    steps:
      - name: Checkout
        uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0

      - name: Set up Java ${{ env.JAVA_VERSION }}
        uses: actions/setup-java@1bcf9fb12cf4aa7d266a90ae39939e61372fe520  # v5.4.0
        with:
          distribution: temurin
          java-version: ${{ env.JAVA_VERSION }}
          cache: sbt

      - name: Set up SBT
        uses: sbt/setup-sbt@af116cce31c00823d3903ce687f9cda3a4f19f1b # v1.2.1

      - name: Set up DCC JVM dependencies
        uses: ./.github/actions/setup-dcc-jvm-deps
        with:
          dcc-node-version: ${{ env.DCC_NODE_VERSION }}

      - name: Run fullCheck (compile + unit tests + dex-it/dex-integration-it E2E)
        run: sbt fullCheck
```
Note: `timeout-minutes: 150` is a starting estimate (90 original + budget for 4 sequential Docker builds plus two real it-suites) — Step 4 below is where this gets corrected against a real run; do not treat 150 as final without that evidence.

- [ ] **Step 3: Validate YAML syntax locally**

Run: `python3 -c "import yaml, sys; yaml.safe_load(open('matcher/.github/workflows/ci.yml'))" && echo OK`
Expected: `OK` (catches indentation/syntax errors before pushing).

- [ ] **Step 4: Commit, then open a PR and observe the real run**

```bash
cd /Users/jourlez/Documents/Code/Blockchain/Ecosystem/matcher
git add .github/workflows/ci.yml
git commit -m "ci: run fullCheck (real dex-it/dex-integration-it E2E) instead of quickCheck in the integration job"
```
Push and open a PR; do not claim this task complete until the `integration` job has actually run once and either passed or produced an interpretable failure that becomes a follow-up finding. Record the actual wall-clock time from that run and adjust `timeout-minutes` in a follow-up commit if 150 is far off.

---

### Task 3: Add the settlement spec to `admin-e2e.yml`'s smoke suite

**Files:**
- Modify: `infra/.github/workflows/admin-e2e.yml` (the "Resolve spec set" step — confirmed at lines 92-106 by the code audit).

**Interfaces:** None — GitHub Actions YAML only. Depends on nothing else in this plan (independent of Tasks 1-2 and 4).

- [ ] **Step 1: Read the current step before editing**

Run: `sed -n '92,106p' infra/.github/workflows/admin-e2e.yml`
Confirm it matches:
```yaml
      - name: Resolve spec set
        id: specs
        run: |
          set -euo pipefail
          case "${{ inputs.suite || 'smoke' }}" in
            smoke)
              echo "specs=src/network/node-api.spec.ts src/network/peers.spec.ts src/transactions/transfer.spec.ts" >> "$GITHUB_OUTPUT"
              ;;
            full)
              echo "specs=" >> "$GITHUB_OUTPUT"
              ;;
            custom)
              echo "specs=${{ inputs.specs }}" >> "$GITHUB_OUTPUT"
              ;;
          esac
```

- [ ] **Step 2: Apply the edit — add `exchange.spec.ts` to the smoke list**

```yaml
      - name: Resolve spec set
        id: specs
        run: |
          set -euo pipefail
          case "${{ inputs.suite || 'smoke' }}" in
            smoke)
              echo "specs=src/network/node-api.spec.ts src/network/peers.spec.ts src/transactions/transfer.spec.ts src/transactions/exchange.spec.ts" >> "$GITHUB_OUTPUT"
              ;;
            full)
              echo "specs=" >> "$GITHUB_OUTPUT"
              ;;
            custom)
              echo "specs=${{ inputs.specs }}" >> "$GITHUB_OUTPUT"
              ;;
          esac
```

- [ ] **Step 3: Validate YAML syntax locally**

Run: `python3 -c "import yaml, sys; yaml.safe_load(open('infra/.github/workflows/admin-e2e.yml'))" && echo OK`
Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
cd /Users/jourlez/Documents/Code/Blockchain/Ecosystem/infra
git add .github/workflows/admin-e2e.yml
git commit -m "ci: add matcher settlement coverage (exchange.spec.ts) to the admin-e2e smoke suite"
```

Note: this does not require a code change to `exchange.spec.ts` itself, and does not require re-verifying `DCC_TEST_MATCHER_URL` — the code audit confirmed it is already correctly wired (`admin-e2e.yml` env block already sets it to `https://testnet-matcher.decentralchain.io`).

- [ ] **Step 5: Manually dispatch the smoke suite once to confirm the addition works against the live testnet**

Run: `gh workflow run admin-e2e.yml -f suite=smoke -R Decentral-America/infra` (adjust the `-R` owner/repo slug to match the actual GitHub remote — check with `git -C infra remote -v` first)
Expected: the dispatched run's job summary includes `exchange.spec.ts` in its output and it passes. Do not claim this task complete without observing this real run's result.

---

### Task 4: Unit-test coverage for the `commitToGeneration()` SDK builder

**Files:**
- Create: `DecentralChain/packages/sdk/transactions/test/transactions/commit-to-generation.spec.ts`

**Interfaces:**
- Consumes: `commitToGeneration` (`packages/sdk/transactions/src/transactions/commit-to-generation.ts`, signature: `commitToGeneration(params: ICommitToGenerationParams, seed: TSeedTypes): CommitToGenerationTransaction & WithId & WithProofs`, and the `WithSender`-overload for pre-signed/precomputed-key cases); `publicKey` from `@decentralchain/ts-lib-crypto`; `validateTxSignature` from the existing `../utils` test helper (`(tx, protoBytesMinVersion, proofNumber?, publicKey?) => boolean`, already used identically by every sibling `test/transactions/*.spec.ts` file).

- [ ] **Step 1: Write the failing test**

```ts
import { publicKey } from '@decentralchain/ts-lib-crypto';
import { commitToGeneration } from '../../src';
import { validateTxSignature } from '../utils';

describe('commitToGeneration', () => {
  const stringSeed = 'adsa';

  it('should build with a sender-derived BLS endorser key and commitment signature', () => {
    const tx = commitToGeneration({ generationPeriodStart: 1000 }, stringSeed);

    expect(tx.type).toBe(19);
    expect(tx.generationPeriodStart).toBe(1000);
    expect(tx.senderPublicKey).toBe(publicKey(stringSeed));
    // BLS endorser key must be distinct from the ed25519 sender key — proves real
    // BLS derivation happened rather than accidentally reusing the sender's key.
    expect(tx.endorserPublicKey).not.toBe(tx.senderPublicKey);
    expect(tx.endorserPublicKey.length).toBeGreaterThan(0);
    expect(tx.commitmentSignature.length).toBeGreaterThan(0);
  });

  it('should get a correct ed25519 proof signature over the proto-serialized tx', () => {
    const tx = commitToGeneration({ generationPeriodStart: 1000 }, stringSeed);
    // protoBytesMinVersion=0 forces the proto-bytes branch in validateTxSignature,
    // since CommitToGeneration is always version 1 (tx.version > 0 is true).
    expect(validateTxSignature(tx, 0)).toBe(true);
  });

  it('should be deterministic for a fixed timestamp: same params+seed -> same id and BLS fields', () => {
    const tsFixed = 1700000000000;
    const tx1 = commitToGeneration({ generationPeriodStart: 1000, timestamp: tsFixed }, stringSeed);
    const tx2 = commitToGeneration({ generationPeriodStart: 1000, timestamp: tsFixed }, stringSeed);

    expect(tx2.id).toBe(tx1.id);
    expect(tx2.commitmentSignature).toBe(tx1.commitmentSignature);
    expect(tx2.endorserPublicKey).toBe(tx1.endorserPublicKey);
  });

  it('should accept a precomputed endorserPublicKey/commitmentSignature without re-deriving from the seed', () => {
    const derived = commitToGeneration({ generationPeriodStart: 1000 }, stringSeed);
    const tx = commitToGeneration(
      {
        generationPeriodStart: 1000,
        endorserPublicKey: derived.endorserPublicKey,
        commitmentSignature: derived.commitmentSignature,
      },
      stringSeed,
    );

    expect(tx.endorserPublicKey).toBe(derived.endorserPublicKey);
    expect(tx.commitmentSignature).toBe(derived.commitmentSignature);
  });

  it('should throw when neither a seed nor a precomputed endorserPublicKey/commitmentSignature is given', () => {
    expect(() =>
      commitToGeneration({
        generationPeriodStart: 1000,
        senderPublicKey: publicKey(stringSeed),
      } as Parameters<typeof commitToGeneration>[0]),
    ).toThrowError(/endorserPublicKey/);
  });
});
```

- [ ] **Step 2: Run test to verify it fails (file doesn't exist yet, or an assertion is wrong before implementation exists to check against)**

Run: `cd DecentralChain/packages/sdk/transactions && pnpm vitest run test/transactions/commit-to-generation.spec.ts`
Expected: FAIL — file not found (since the test file itself is new, this validates the test harness picks it up; there is no separate "implementation" step for this task — `commitToGeneration()` already exists and is correct, per the code audit, so this task is pure test-writing, not TDD red-green against new production code).

- [ ] **Step 3: Create the file exactly as written in Step 1, then run again**

Run: `cd DecentralChain/packages/sdk/transactions && pnpm vitest run test/transactions/commit-to-generation.spec.ts`
Expected: PASS, 5 tests. If any assertion fails, that is either a real bug in `commitToGeneration()` (in which case: stop, do not adjust the assertion to match broken behavior, escalate as a new finding) or a mistaken assumption in this plan about the builder's exact behavior (in which case: re-read `commit-to-generation.ts` and correct the test to check real, correct behavior — not to paper over an actual defect).

- [ ] **Step 4: Run the full transactions package test suite to confirm nothing else broke**

Run: `cd DecentralChain/packages/sdk/transactions && pnpm vitest run`
Expected: PASS, same pre-existing test count plus the 5 new tests.

- [ ] **Step 5: Commit**

```bash
cd /Users/jourlez/Documents/Code/Blockchain/Ecosystem/DecentralChain
git add packages/sdk/transactions/test/transactions/commit-to-generation.spec.ts
git commit -m "test: add unit coverage for the commitToGeneration SDK builder (previously zero test calls)"
```

---

## What this plan does not cover

- A live-testnet broadcast of a real `commitToGeneration()`-built transaction using an actual registered generator's BLS key (e.g. the gen-0 seed already available to CI as `secrets.GEN_0_SEED_PHRASE`) was considered and deliberately excluded from Task 4: picking a correct, currently-valid `generationPeriodStart` and tolerating "already committed for this period"-style application-level rejection without also tolerating a real structural/signature rejection is a distinct, fiddlier scenario better suited to Tier 6 (live synthetic/canary monitoring), not a unit test.
- Task 2's `timeout-minutes: 150` and the overall `fullCheck`-in-CI approach is unproven until a real PR runs it once — this plan is honest that Step 4 of Task 2 is where real validation happens, not before.
