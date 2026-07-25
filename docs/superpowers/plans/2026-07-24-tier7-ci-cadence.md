# Tier 7 — CI Cadence Reorganization — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close Tier 7 of the [E2E testing strategy](../specs/2026-07-24-e2e-testing-strategy-design.md): give the new, heavier suites introduced by Tiers 1-4 (Operation fuzzer, degraded-link chaos, settlement nemesis) a nightly home instead of gating every push/PR, and give the two big scheduling gaps found by the CI-cadence audit — node-it (`workflow_dispatch`-only, never automatic) and `admin-e2e.yml` (also `workflow_dispatch`-only) — an actual nightly cadence. The code audit backing this plan found **zero nightly test-cadence workflows exist anywhere across node-scala, matcher, or DecentralChain today** (only weekly security scans) — this tier introduces that pattern net-new, not by extending an existing one.

**Architecture:** No new test code — this tier only moves *when* things run. Four independent, small changes:
1. **node-scala**: tag `OperationFuzzSpecification`/`OperationDeterminismSpecification` (Tier 4) with a new `SlowTest` ScalaTest tag, exclude that tag from the push-gated `node-tests/test` run, add a nightly workflow that runs them (at a larger seed count).
2. **node-scala**: add a `schedule:` trigger to the existing `node-it.yml` (currently `workflow_dispatch`-only) so `FourNodeHotStuffTestSuite` and Tier 3's new `DegradedLinkHotStuffTestSuite` (both already matched by its default `com.decentralchain.it.sync.finalization.*` filter — no filter change needed) run nightly automatically.
3. **matcher**: exclude `@NetworkTests`-tagged suites (existing `NetworkIssuesTestSuite`/`DexClientFaultToleranceTestSuite` plus Tier 3's new `SettlementNemesisTestSuite`) from the PR-gated `fullCheck` job via the existing `SCALATEST_EXCLUDE_TAGS` mechanism (confirmed real, `project/ItTestPlugin.scala:29-38` — no tags are excluded today, since nothing sets this env var anywhere in CI), add a nightly workflow that explicitly runs them.
4. **infra**: add a `schedule:` trigger to `admin-e2e.yml` for a nightly `full`-suite run against the live testnet (currently manual-dispatch-only).

**Tech Stack:** GitHub Actions YAML, ScalaTest tags (`org.scalatest.Tag`).

## Global Constraints

- Do not change what runs on every push/PR beyond *removing* the newly-tagged slow specs from it — Tiers 1, 2, 5's push/PR-gated additions stay exactly as those plans specified.
- Every new nightly `schedule:` cron must not collide with the existing weekly security-scan schedules already in each repo (`semgrep.yml` Mon 05:15, `owasp-audit.yml` Mon 06:00, `codeql.yml`/`security.yml` Mon 05:30/06:45) — pick a daily off-peak UTC time (e.g. `17 3 * * *`) distinct from those, to avoid runner-queue contention once a week.
- Depends on Tiers 1, 2, 3, 4 being merged first (this plan tags/schedules files those plans create) — do not attempt Task 1 before Tier 4 lands, Task 2/3 before Tier 3 lands, etc.

---

### Task 1: Tag and reschedule node-scala's Operation fuzzer (Tier 4)

**Files:**
- Create: `node-scala/node/tests/src/test/scala/com/decentralchain/tags/SlowTest.scala`
- Modify: `node-scala/node/tests/src/test/scala/com/decentralchain/state/diffs/OperationFuzzSpecification.scala` (Tier 4)
- Modify: `node-scala/node/tests/src/test/scala/com/decentralchain/state/diffs/OperationDeterminismSpecification.scala` (Tier 4)
- Modify: `node-scala/.github/workflows/ci.yml` (exclude the tag from the push-gated run)
- Create: `node-scala/.github/workflows/nightly-slow-tests.yml`

- [ ] **Step 1: Define the tag**

```scala
package com.decentralchain.tags

import org.scalatest.Tag

/** Tests that do real per-block RocksDB state appends (via Domain.appendBlock), as opposed to
  * in-process-only simulation (e.g. the HotStuff DST harness) — excluded from the push-gated
  * node-tests run, run nightly instead with a larger seed count.
  */
object SlowTest extends Tag("com.decentralchain.tags.SlowTest")
```

- [ ] **Step 2: Apply the tag in both Tier 4 spec files**

In `OperationFuzzSpecification.scala`, change:
```scala
s"seed=$seed: every accepted transfer conserves balance exactly, every rejection is a no-op" in runFuzzRound(seed)
```
to:
```scala
s"seed=$seed: every accepted transfer conserves balance exactly, every rejection is a no-op" taggedAs SlowTest in runFuzzRound(seed)
```
(add `import com.decentralchain.tags.SlowTest` at the top). Apply the identical change to `OperationDeterminismSpecification.scala`'s one generated test line.

- [ ] **Step 3: Exclude the tag from the push-gated `node-tests/test` run**

In `node-scala/.github/workflows/ci.yml`'s `test` job, change:
```yaml
            "node-tests/test" \
```
to:
```yaml
            "node-tests/testOnly -- -l com.decentralchain.tags.SlowTest" \
```
Note: `sbt`'s `testOnly` with no class-name argument and a bare `--` tag-exclusion filter runs *all* tests except the excluded tag — confirm this exact invocation syntax works as intended locally (`sbt --batch "node-tests/testOnly -- -l com.decentralchain.tags.SlowTest"`) before relying on it in CI; if `testOnly` requires at least one test-name glob argument in this sbt/ScalaTest version, use `"node-tests/test"` combined with a project-wide `testOptions` tag-exclusion setting in `build.sbt` instead (mirroring matcher's `ItTestPlugin.scala` approach) rather than guessing which syntax this specific sbt version accepts.

- [ ] **Step 4: Add the nightly workflow**

```yaml
name: Nightly Slow Tests (Operation Fuzzer)
# Tier 4's Operation fuzzer does real per-block RocksDB appends (not free in-process simulation
# like the HotStuff DST harness) — excluded from the push-gated node-tests run, runs here nightly
# at a larger seed count for deeper coverage than the push-gated budget allows.
on:
  schedule:
    - cron: '17 3 * * *'  # daily 03:17 UTC — distinct from existing weekly Monday security scans
  workflow_dispatch:
    inputs:
      seed-count:
        description: 'Override OperationCount seed sweep size (system property)'
        required: false
        default: '2000'
permissions:
  contents: read
jobs:
  slow-tests:
    runs-on: ubuntu-latest
    timeout-minutes: 60
    env:
      JAVA_TOOL_OPTIONS: "-XX:MaxRAMPercentage=70.0 -XX:-UseZGC -XX:+UseG1GC -Xss4m -XX:MaxMetaspaceSize=1g"
    steps:
      - uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0  # v7.0.0
      - uses: actions/setup-java@1bcf9fb12cf4aa7d266a90ae39939e61372fe520  # v5.4.0
        with:
          distribution: 'temurin'
          java-version: '25'
          cache: 'sbt'
      - uses: sbt/setup-sbt@af116cce31c00823d3903ce687f9cda3a4f19f1b  # v1.2.1
      - uses: ./.github/actions/install-dcc-native-deps
      - name: Run the Operation fuzzer at nightly depth
        run: |
          sbt --batch "node-tests/testOnly com.decentralchain.state.diffs.OperationFuzzSpecification com.decentralchain.state.diffs.OperationDeterminismSpecification"
```
Note: the `seed-count` dispatch input is aspirational in this draft — actually varying `OperationCount`/the seed range at runtime requires threading a system property or env var into the two spec files (e.g. `sys.props.get("dcc.fuzz.seedCount").map(_.toInt).getOrElse(50)`), which Tier 4's plan did not originally include. Add that small parameterization to both spec files as part of this task (a 2-3 line change each), rather than leaving the workflow input disconnected from actual behavior.

- [ ] **Step 5: Validate and run**

Run: `python3 -c "import yaml; yaml.safe_load(open('node-scala/.github/workflows/nightly-slow-tests.yml'))" && echo OK`, then `sbt --batch "node-tests/compile"` to confirm the tag/import changes compile, then dispatch the new workflow manually once (`gh workflow run nightly-slow-tests.yml -R Decentral-America/node-scala`) and confirm a real green run before considering this task done.

- [ ] **Step 6: Commit**

```bash
cd /Users/jourlez/Documents/Code/Blockchain/Ecosystem/node-scala
git add node/tests/src/test/scala/com/decentralchain/tags/SlowTest.scala \
        node/tests/src/test/scala/com/decentralchain/state/diffs/OperationFuzzSpecification.scala \
        node/tests/src/test/scala/com/decentralchain/state/diffs/OperationDeterminismSpecification.scala \
        .github/workflows/ci.yml .github/workflows/nightly-slow-tests.yml
git commit -m "ci: move Operation fuzzer to nightly cadence (SlowTest tag), keep push-gated run fast"
```

---

### Task 2: Schedule node-it (Tier 1 + Tier 3 chaos scenarios) nightly

**Files:**
- Modify: `node-scala/.github/workflows/node-it.yml`

- [ ] **Step 1: Add a schedule trigger alongside the existing `workflow_dispatch`**

```yaml
on:
  schedule:
    - cron: '37 3 * * *'  # daily 03:37 UTC
  workflow_dispatch:
    inputs:
      suite:
        description: 'testOnly filter (space-separated glob(s))'
        required: false
        default: 'com.decentralchain.it.sync.finalization.*'
      monorepo-ref:
        description: 'DecentralChain monorepo git ref for JVM deps (empty = default branch)'
        required: false
        default: '2c886b76999e658bf4fa058a290eacb40b83c1d3'
```
Note: on a `schedule` trigger, `inputs.suite` is unavailable (inputs only populate on `workflow_dispatch`) — confirm the job's `run: sbt --batch "node-it/testOnly ${{ inputs.suite }}"`-style step (wherever it appears later in the file) has a fallback default when `inputs.suite` is empty/null on a scheduled run, e.g. `${{ inputs.suite || 'com.decentralchain.it.sync.finalization.*' }}`, rather than passing an empty string to `testOnly` on the nightly trigger.

- [ ] **Step 2: Validate and dispatch once to confirm the schedule-triggered code path works (can't wait for 03:37 UTC to verify)**

Run: `python3 -c "import yaml; yaml.safe_load(open('node-scala/.github/workflows/node-it.yml'))" && echo OK`, then manually dispatch with no `suite` input provided (leave it blank in the dispatch UI/`gh workflow run` call) to simulate what a scheduled run's inputs look like, and confirm the fallback default kicks in correctly.

- [ ] **Step 3: Commit**

```bash
cd /Users/jourlez/Documents/Code/Blockchain/Ecosystem/node-scala
git add .github/workflows/node-it.yml
git commit -m "ci: add nightly schedule to node-it.yml (was workflow_dispatch-only), covers HotStuff DST/chaos suites"
```

---

### Task 3: Exclude matcher's `@NetworkTests` from PR-gated `fullCheck`, run nightly instead

**Files:**
- Modify: `matcher/.github/workflows/ci.yml` (Tier 2's `integration` job)
- Create: `matcher/.github/workflows/nightly-network-tests.yml`

- [ ] **Step 1: Exclude the tag from the PR-gated run**

In `matcher/.github/workflows/ci.yml`'s `integration` job (as edited by Tier 2's plan — the `Run fullCheck` step), add the env var the existing `ItTestPlugin.scala` already reads:
```yaml
      - name: Run fullCheck (compile + unit tests + dex-it/dex-integration-it E2E, excluding @NetworkTests)
        env:
          SCALATEST_EXCLUDE_TAGS: com.decentralchain.it.tags.NetworkTests
        run: sbt fullCheck
```

- [ ] **Step 2: Add the nightly workflow**

```yaml
name: Nightly Network/Chaos Tests
# @NetworkTests-tagged suites (existing NetworkIssuesTestSuite, DexClientFaultToleranceTestSuite, and
# Tier 3's new SettlementNemesisTestSuite) are excluded from the PR-gated fullCheck run (network-timing
# fault injection is slower and less deterministic than unit/API tests) — run here nightly instead.
on:
  schedule:
    - cron: '57 3 * * *'  # daily 03:57 UTC
  workflow_dispatch: {}
permissions:
  contents: read
jobs:
  network-tests:
    runs-on: ubuntu-latest
    timeout-minutes: 120
    steps:
      - uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
      - uses: actions/setup-java@1bcf9fb12cf4aa7d266a90ae39939e61372fe520  # v5.4.0
        with:
          distribution: temurin
          java-version: ${{ env.JAVA_VERSION }}
          cache: sbt
      - uses: sbt/setup-sbt@af116cce31c00823d3903ce687f9cda3a4f19f1b # v1.2.1
      - uses: ./.github/actions/setup-dcc-jvm-deps
        with:
          dcc-node-version: ${{ env.DCC_NODE_VERSION }}
      - name: Run @NetworkTests-tagged suites
        env:
          SCALATEST_INCLUDE_TAGS: com.decentralchain.it.tags.NetworkTests
        run: |
          sbt --batch "dex-integration-it/docker" "dex-it/docker" "dex-it/test" "dex-integration-it/test"
```
Note: this job needs the same `env.JAVA_VERSION`/`env.DCC_NODE_VERSION` workflow-level env block the existing `ci.yml` already defines — copy that block into this new file's `env:` section (check `ci.yml`'s top-level `env:` for the exact current values before copying, rather than guessing them).

- [ ] **Step 3: Validate and dispatch once to confirm**

Run: `python3 -c "import yaml; yaml.safe_load(open('matcher/.github/workflows/ci.yml'))" && echo OK` and the same for the new file, then manually dispatch the new nightly workflow and confirm a real run (expect it to actually exercise `SettlementNemesisTestSuite` from Tier 3 and the pre-existing network suites) before considering this task done.

- [ ] **Step 4: Commit**

```bash
cd /Users/jourlez/Documents/Code/Blockchain/Ecosystem/matcher
git add .github/workflows/ci.yml .github/workflows/nightly-network-tests.yml
git commit -m "ci: move @NetworkTests suites (chaos/nemesis) to nightly cadence, keep PR-gated fullCheck faster"
```

---

### Task 4: Schedule `admin-e2e.yml` nightly (infra)

**Files:**
- Modify: `infra/.github/workflows/admin-e2e.yml`

- [ ] **Step 1: Add a schedule trigger**

In `infra/.github/workflows/admin-e2e.yml`, add alongside the existing `workflow_dispatch:`:
```yaml
on:
  schedule:
    - cron: '13 4 * * *'  # daily 04:13 UTC
  workflow_dispatch:
    inputs:
      suite:
        # ... existing inputs unchanged
```
Then find the step that resolves `inputs.suite || 'smoke'` (quoted in the code audit backing Tier 2's plan, `admin-e2e.yml:92-106`'s `case "${{ inputs.suite || 'smoke' }}" in`) and change the nightly default to `full` rather than `smoke`, since a nightly run has the time budget a per-push/PR trigger wouldn't:
```yaml
          case "${{ inputs.suite || (github.event_name == 'schedule' && 'full' || 'smoke') }}" in
```
Confirm this exact conditional-expression syntax is valid in the actual GitHub Actions expression grammar used elsewhere in this file before relying on it — if not, use a separate preceding step that sets a `suite` output based on `github.event_name` and reference that instead, rather than a possibly-invalid inline nested ternary.

- [ ] **Step 2: Validate and confirm**

Run: `python3 -c "import yaml; yaml.safe_load(open('infra/.github/workflows/admin-e2e.yml'))" && echo OK`, then manually dispatch with no `suite` input to simulate the scheduled-trigger default path, and confirm it resolves to the `full` spec set (empty filter = vitest runs everything, per the existing `full)` case already quoted in Tier 2's plan).

- [ ] **Step 3: Commit**

```bash
cd /Users/jourlez/Documents/Code/Blockchain/Ecosystem/infra
git add .github/workflows/admin-e2e.yml
git commit -m "ci: add nightly schedule to admin-e2e.yml (was workflow_dispatch-only), full suite against live testnet"
```

---

## Final cadence summary (after Tiers 1-7 land)

| Trigger | What runs |
|---|---|
| Every push (node-scala) | unit tests + HotStuff DST harness (Tier 1) |
| Every push touching API (matcher/node-scala/DecentralChain) | oasdiff breaking-change check (Tier 5) |
| Every PR to main (matcher) | `fullCheck` minus `@NetworkTests` (Tier 2, this tier) |
| Every 15 min (infra) | canary transaction against live testnet (Tier 6) |
| Nightly (node-scala) | Operation fuzzer at 2000-seed depth, node-it (HotStuff DST-class suites + Tier 3 degraded-link chaos) |
| Nightly (matcher) | `@NetworkTests` suites (existing network fault tests + Tier 3 settlement nemesis) |
| Nightly (infra) | `admin-e2e.yml` full suite against live testnet |
| Weekly Monday (all repos, pre-existing, untouched) | security scans (semgrep, OWASP, CodeQL) |

## What this plan does not cover

- General flake-rate tracking/dashboarding across all these new suites — the design spec's Tier 7 section mentions this as general practice with no specific tool prescribed; introducing one (e.g. a flaky-test-detector service) is separate, unscoped follow-up work, not fabricated here.
