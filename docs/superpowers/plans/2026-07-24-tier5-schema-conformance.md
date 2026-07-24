# Tier 5 — Contract/Schema Conformance — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close Tier 5 of the [E2E testing strategy](../specs/2026-07-24-e2e-testing-strategy-design.md) — the design spec itself flags this tier as lower-confidence (no primary source cleared the deep-research verification pass for contract/schema-conformance practices; recommendations here are general industry practice, not citation-backed). This plan is deliberately scoped to what the code audit actually found: both matcher and node-scala's REST APIs are documented by hand-written OpenAPI YAML with zero existing schema-diffing tooling (only `packages/sdk/protobuf-schemas` uses codegen, for gRPC, unrelated to REST), and the TS SDK's `node-api` REST client is entirely hand-written against literal path strings with no generation step at all.

**Architecture:** Two independent, additive CI checks — no production code changes:
1. Breaking-change detection on the two hand-written OpenAPI specs (matcher's `dex/src/main/resources/swagger-ui/openapi.yaml`, node-scala's `node/src/main/resources/swagger-ui/openapi.yaml` and `ride-runner/src/main/resources/swagger-ui/openapi.yaml`) using `oasdiff` (a real, widely-used open-source CLI for OpenAPI diffing), gated on any PR touching those files.
2. A small path-existence check script in DecentralChain: every literal REST path used by `packages/sdk/node-api`'s hand-written fetch calls must exist somewhere in node's `openapi.yaml` — catching drift where the SDK calls an endpoint the documented API doesn't (or no longer) have, without attempting full bidirectional type-level contract testing, which is a much larger and separately-scoped effort.

**Tech Stack:** `oasdiff` CLI (Go binary, installed via a GitHub Action or direct binary download in CI), GitHub Actions YAML, a small Node.js/TypeScript script for the path-existence check.

## Global Constraints

- Do not modify any production route/handler code, nor the hand-written `openapi.yaml` files themselves, in this plan — this is CI tooling only.
- `oasdiff`'s `breaking` command needs a "base" version of the spec (the target branch's copy) and a "revision" version (the PR's copy) — both new CI jobs must check out or fetch the base-branch file before diffing, not assume it's already present.
- The path-existence script (Task 3) checks for **path drift**, not full request/response schema conformance — say so explicitly in the script's own header comment so a future reader doesn't assume more coverage than exists.
- This tier's design-spec confidence is explicitly lower than Tiers 1-4 (general practice, not research-verified) — do not present its outputs with more certainty than that in commit messages or follow-up documentation.

---

### Task 1: `oasdiff` breaking-change gate for matcher's OpenAPI spec

**Files:**
- Modify: `matcher/.github/workflows/ci.yml` (add a new job)

- [ ] **Step 1: Confirm the spec file's current path and that it's tracked in git**

Run: `git -C matcher ls-files dex/src/main/resources/swagger-ui/openapi.yaml`
Expected: prints the path, confirming it's a tracked file (not generated at build time) that a base-vs-PR diff can actually compare.

- [ ] **Step 2: Add the CI job**

In `matcher/.github/workflows/ci.yml`, add a new top-level job (parallel to `quality`/`integration`, no dependency needed since it only reads two file revisions):
```yaml
  api-schema-conformance:
    name: OpenAPI Breaking-Change Check
    runs-on: ubuntu-latest
    timeout-minutes: 10
    if: github.event_name == 'pull_request'
    steps:
      - name: Checkout PR branch
        uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
        with:
          fetch-depth: 0

      - name: Extract base-branch spec
        run: git show "origin/${{ github.base_ref }}:dex/src/main/resources/swagger-ui/openapi.yaml" > /tmp/openapi-base.yaml

      - name: Install oasdiff
        run: |
          curl -fsSL https://github.com/oasdiff/oasdiff/releases/latest/download/oasdiff_linux_amd64.tar.gz | tar -xz -C /usr/local/bin oasdiff

      - name: Check for breaking changes
        run: |
          oasdiff breaking /tmp/openapi-base.yaml dex/src/main/resources/swagger-ui/openapi.yaml --fail-on ERR
```
Note: `oasdiff`'s exact release-asset naming (`oasdiff_linux_amd64.tar.gz`) and flag names (`--fail-on ERR`) should be double-checked against the tool's current release page/`--help` output before merging — this plan specifies the intent (install the CLI, diff base vs. PR spec, fail the job on breaking changes) precisely; the exact download URL/flags are the kind of detail that drifts with tool versions and must be verified live, not trusted blindly from this plan.

- [ ] **Step 3: Validate YAML syntax locally**

Run: `python3 -c "import yaml; yaml.safe_load(open('matcher/.github/workflows/ci.yml'))" && echo OK`
Expected: `OK`.

- [ ] **Step 4: Open a PR with an intentionally non-breaking change to the spec (e.g. add a new optional field to one schema) and confirm the job passes**

This is the only way to prove the job actually runs and passes correctly — a YAML-syntax check alone doesn't prove `oasdiff` installs and runs correctly in the real CI environment. Do not claim this task complete without observing one real green run.

- [ ] **Step 5: Commit**

```bash
cd /Users/jourlez/Documents/Code/Blockchain/Ecosystem/matcher
git add .github/workflows/ci.yml
git commit -m "ci: add oasdiff breaking-change gate for the matcher OpenAPI spec"
```

---

### Task 2: `oasdiff` breaking-change gate for node-scala's OpenAPI specs

**Files:**
- Modify: `node-scala/.github/workflows/ci.yml` (add a new job)

- [ ] **Step 1: Confirm both spec files are tracked**

Run: `git -C node-scala ls-files node/src/main/resources/swagger-ui/openapi.yaml ride-runner/src/main/resources/swagger-ui/openapi.yaml`
Expected: both paths print.

- [ ] **Step 2: Add the CI job (mirrors Task 1's matcher job, run for both specs)**

```yaml
  api-schema-conformance:
    name: OpenAPI Breaking-Change Check
    runs-on: ubuntu-latest
    timeout-minutes: 10
    if: github.event_name == 'pull_request'
    steps:
      - name: Checkout PR branch
        uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
        with:
          fetch-depth: 0

      - name: Install oasdiff
        run: |
          curl -fsSL https://github.com/oasdiff/oasdiff/releases/latest/download/oasdiff_linux_amd64.tar.gz | tar -xz -C /usr/local/bin oasdiff

      - name: Check node REST API for breaking changes
        run: |
          git show "origin/${{ github.base_ref }}:node/src/main/resources/swagger-ui/openapi.yaml" > /tmp/node-openapi-base.yaml
          oasdiff breaking /tmp/node-openapi-base.yaml node/src/main/resources/swagger-ui/openapi.yaml --fail-on ERR

      - name: Check ride-runner REST API for breaking changes
        run: |
          git show "origin/${{ github.base_ref }}:ride-runner/src/main/resources/swagger-ui/openapi.yaml" > /tmp/ride-runner-openapi-base.yaml
          oasdiff breaking /tmp/ride-runner-openapi-base.yaml ride-runner/src/main/resources/swagger-ui/openapi.yaml --fail-on ERR
```

- [ ] **Step 3: Validate YAML syntax locally**

Run: `python3 -c "import yaml; yaml.safe_load(open('node-scala/.github/workflows/ci.yml'))" && echo OK`
Expected: `OK`.

- [ ] **Step 4: Open a PR with an intentionally non-breaking spec change and confirm the job passes**

Same reasoning as Task 1 Step 4 — a real green CI run is the only real proof.

- [ ] **Step 5: Commit**

```bash
cd /Users/jourlez/Documents/Code/Blockchain/Ecosystem/node-scala
git add .github/workflows/ci.yml
git commit -m "ci: add oasdiff breaking-change gate for node-scala's OpenAPI specs (node + ride-runner)"
```

---

### Task 3: Path-existence check — TS SDK `node-api` vs. node's `openapi.yaml`

**Files:**
- Create: `DecentralChain/scripts/check-node-api-paths.mjs`
- Modify: `DecentralChain/.github/workflows/ci.yml` (add a step invoking it)

**Interfaces:** None consumed from other tasks — standalone Node.js script reading two things: node's `openapi.yaml` (parsed for its declared `paths:` keys) and `packages/sdk/node-api/src/api-node/**/*.ts` (grepped for literal REST path template strings).

- [ ] **Step 1: Write the script**

```js
#!/usr/bin/env node
// Path-existence check ONLY — this does NOT check request/response schema conformance, HTTP method
// correctness, or parameter types. It only catches the case where node-api's hand-written fetch calls
// reference a REST path that no longer exists (or never existed) in node's documented OpenAPI spec.
// Full bidirectional type-level contract testing is a separately-scoped, larger effort.

import { readFileSync } from 'node:fs';
import { globSync } from 'node:fs';
import path from 'node:path';
import yaml from 'js-yaml';

const REPO_ROOT = path.resolve(import.meta.dirname, '..');
const OPENAPI_PATH = path.join(REPO_ROOT, '../node-scala/node/src/main/resources/swagger-ui/openapi.yaml');
const NODE_API_SRC = path.join(REPO_ROOT, 'packages/sdk/node-api/src/api-node');

function loadDocumentedPaths() {
  const spec = yaml.load(readFileSync(OPENAPI_PATH, 'utf8'));
  // OpenAPI paths use {param} placeholders; normalize to a regex-friendly template so a literal
  // `/addresses/data/${address}/${key}` call site can match `/addresses/data/{address}/{key}`.
  return Object.keys(spec.paths).map((p) => p.replace(/\{[^}]+\}/g, '*'));
}

function pathMatchesTemplate(literalPath, template) {
  const templateRegex = new RegExp(
    '^' + template.split('*').map((seg) => seg.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('[^/]+') + '$',
  );
  return templateRegex.test(literalPath);
}

function extractLiteralPaths() {
  const files = globSync(`${NODE_API_SRC}/**/*.ts`);
  const found = [];
  const urlLiteralPattern = /url:\s*`([^`]+)`/g;
  for (const file of files) {
    const content = readFileSync(file, 'utf8');
    let match;
    while ((match = urlLiteralPattern.exec(content)) !== null) {
      // Collapse template-literal interpolations (${...}) to a single wildcard segment marker.
      const normalized = match[1].replace(/\$\{[^}]+\}/g, '*');
      found.push({ file: path.relative(REPO_ROOT, file), path: normalized });
    }
  }
  return found;
}

const documentedTemplates = loadDocumentedPaths();
const usedPaths = extractLiteralPaths();

const undocumented = usedPaths.filter(
  ({ path: usedPath }) => !documentedTemplates.some((template) => pathMatchesTemplate(usedPath, template)),
);

if (undocumented.length > 0) {
  console.error('The following node-api paths have no matching entry in node/openapi.yaml:');
  for (const { file, path: p } of undocumented) {
    console.error(`  ${file}: ${p}`);
  }
  process.exit(1);
}

console.log(`OK: all ${usedPaths.length} node-api path references matched a documented OpenAPI path.`);
```

- [ ] **Step 2: Run it locally to see the current, real state (expect some noise on the first run)**

Run: `cd DecentralChain && node scripts/check-node-api-paths.mjs`
Expected: this is a NEW script checking real, previously-unchecked drift — it is very plausible the first run finds genuine mismatches (e.g. the regex-based URL-literal extraction pattern (`url:\s*`([^\`]+)`) may not match every call style actually used in `node-api`'s source, or there may be real undocumented paths). Do not hardcode an exclusion list to force a clean pass; instead:
  - If the failure is the script's own extraction pattern missing real call sites (a script bug), fix the regex/extraction logic against the actual file contents.
  - If the failure is a genuinely undocumented-but-real path, that's a valid finding — decide with the user whether to add the path to the spec or fix the SDK, don't silently suppress it in this script.

- [ ] **Step 3: Iterate until the script accurately reflects real coverage (may take a few passes against real source, per Step 2)**

Run: `cd DecentralChain && node scripts/check-node-api-paths.mjs`
Expected: eventually PASS (`OK: all N node-api path references matched...`) once genuine mismatches are resolved or explicitly triaged.

- [ ] **Step 4: Wire it into CI**

In `DecentralChain/.github/workflows/ci.yml`, add a step (in whichever existing job builds/lints the SDK packages — check the file for the right job before adding a whole new one):
```yaml
      - name: Check node-api path conformance against node's OpenAPI spec
        run: node scripts/check-node-api-paths.mjs
```
Note: this script reads `../node-scala/node/src/main/resources/swagger-ui/openapi.yaml` — a path outside this repo. In CI, that means this job needs `node-scala` checked out alongside `DecentralChain` (they are normally separate repos, not present in the same checkout) — add an `actions/checkout` step for `Decentral-America/node-scala` at a pinned ref (matching whatever version pin convention `DecentralChain`'s other cross-repo CI steps already use, e.g. the `DCC_NODE_VERSION`-style env var seen in matcher's CI) alongside the existing checkout, into a sibling directory, before this step runs.

- [ ] **Step 5: Validate YAML syntax and commit**

Run: `python3 -c "import yaml; yaml.safe_load(open('DecentralChain/.github/workflows/ci.yml'))" && echo OK`
```bash
cd /Users/jourlez/Documents/Code/Blockchain/Ecosystem/DecentralChain
git add scripts/check-node-api-paths.mjs .github/workflows/ci.yml
git commit -m "ci: add node-api path-existence check against node-scala's OpenAPI spec"
```

---

## What this plan does not cover

- Full bidirectional request/response schema-level contract testing (Pact-style consumer-driven contracts, or generating TS types directly from the OpenAPI specs) — genuinely larger, separately-scoped work; this plan only catches path-existence drift.
- gRPC schema conformance — already covered by the existing `buf` toolchain in `packages/sdk/protobuf-schemas`; not touched here since it isn't broken.
- The exact `oasdiff` CLI flags/release-asset names in Tasks 1-2 need live verification against the tool's current release before merging (flagged inline in each task) — this plan specifies intent precisely but the tool's exact invocation surface is the kind of detail that must be checked live, not trusted from written text.
