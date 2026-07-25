# Tier 4 — Property/Operation Fuzzing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close Tier 4 of the [E2E testing strategy](../specs/2026-07-24-e2e-testing-strategy-design.md): a Cosmos-SDK-style seeded "Operation" fuzzer for node-scala's transaction pipeline (targeting the open **Committed-Generators StateHash Finding**), and ScalaCheck property tests for matcher's fixed-point rounding math in `MatcherModel.scala` (targeting exactly the class of bug its own inline comment warns about: `// Should not round! It could lead to forks.`).

**Architecture:** node-scala's half builds on the existing `Domain.appendBlock`/`Domain.balance` test harness (`node/testkit/src/main/scala/com/decentralchain/history/Domain.scala`) and `TxHelpers` (`node/testkit/src/main/scala/com/decentralchain/transaction/TxHelpers.scala`) — both already used throughout `node/tests`. It does **not** reuse `TransactionGen.randomTransactionsGen` directly, because that generator conjures independent random accounts per transaction rather than a shared, coherently-funded pool — unsuitable for a sequence applied to one evolving blockchain state. Instead it introduces a small closed pool of `TxHelpers.signer(i)` accounts, genesis-funded via `withDomain(balances = ...)`, and a new seeded generator that picks senders/recipients from that pool. matcher's half is a plain ScalaCheck property spec (`AnyPropSpec with ScalaCheckPropertyChecks`, the exact style already used by `MapImplicitsSpec.scala`) with no new test infrastructure needed.

**Tech Stack:** Scala 3, ScalaCheck (already a dependency in both repos), ScalaTest.

## Global Constraints

- Do not modify `Domain.scala`/`TxHelpers.scala`/`MatcherModel.scala` (production/shared-testkit code) — all new code is new test files only.
- node-scala Task 1's invariant checks use `Domain.balance(address)` directly (before/after comparison), not the existing `WithState.assertBalanceInvariant` helper — that helper compares a `StateSnapshot` against a `RocksDBWriter` and isn't a natural fit for a `Domain`-level, block-by-block fuzzing loop; don't force it in.
- Cross-node determinism (Task 3) compares **balance state** across two independently-genesised `Domain` instances fed the identical operation sequence — it does not compare block IDs/signatures byte-for-byte, since two independently constructed test blocks may legitimately differ in timestamp without that being a bug. Do not conflate "balances diverged" (a real finding) with "block hashes differ" (expected, not a finding).
- matcher Task 4's properties must follow `MapImplicitsSpec.scala`'s exact style: `class X extends AnyPropSpec with ScalaCheckPropertyChecks with Matchers with NoShrink`, `Gen`, `forAll(...)`.

---

### Task 1: Pool-based Operation generator + transfer-only fuzzer with per-account balance invariants

**Files:**
- Create: `node-scala/node/tests/src/test/scala/com/decentralchain/state/diffs/OperationFuzzSpecification.scala`

**Interfaces:**
- Consumes: `Domain` (`withDomain(balances: Seq[AddrWithBalance])(test: Domain => A)`, `domain.appendBlockE(txs: Transaction*): Either[ValidationError, BlockApplyResult]`, `domain.balance(address: Address): Long`), `TxHelpers.signer(i: Int): SeedKeyPair`, `TxHelpers.transfer(from, to, amount, fee, ...): TransferTransaction`, `AddrWithBalance`.
- Produces: nothing consumed by later tasks in this file's own module — Task 2 extends this file directly (same class, more operation types), Task 3 is a new file reusing the same pool-setup pattern.

- [ ] **Step 1: Write the test**

```scala
package com.decentralchain.state.diffs

import com.decentralchain.db.WithState.AddrWithBalance
import com.decentralchain.test.FreeSpec
import com.decentralchain.transaction.TxHelpers

import scala.util.Random

/** Seeded "Operation" fuzzer over a small closed pool of accounts: applies a sequence of randomly
  * generated transfers between pool accounts to one evolving blockchain state (via `Domain`), checking
  * per-account balance conservation after every accepted block and no-op after every rejected one.
  * Modeled on the Cosmos SDK simulation framework's "Operations" pattern (random Msg sequences +
  * invariant checks), scoped down to transfers first — see Task 2 for broader operation types.
  */
class OperationFuzzSpecification extends FreeSpec {
  private val PoolSize      = 5
  private val OperationCount = 200
  private val InitialBalance = 1000.dcc
  private val TransferFee    = 100000L // TestValues.fee-equivalent; see Step 1 note if this drifts from TxHelpers default

  private val pool = (0 until PoolSize).map(TxHelpers.signer)

  private def runFuzzRound(seed: Long): Unit = {
    val rnd = new Random(seed)
    withDomain(balances = pool.map(kp => AddrWithBalance(kp.toAddress, InitialBalance))) { domain =>
      (1 to OperationCount).foreach { step =>
        val from   = pool(rnd.nextInt(PoolSize))
        val to     = pool(rnd.nextInt(PoolSize))
        val amount = rnd.nextInt(InitialBalance.toInt) // deliberately includes amounts likely to overdraft
        val tx     = TxHelpers.transfer(from, to.toAddress, amount, fee = TransferFee)

        val beforeSender    = domain.balance(from.toAddress)
        val beforeRecipient = domain.balance(to.toAddress)

        val result = domain.appendBlockE(tx)

        val afterSender    = domain.balance(from.toAddress)
        val afterRecipient = domain.balance(to.toAddress)

        withClue(s"seed=$seed step=$step from=${from.toAddress} to=${to.toAddress} amount=$amount result=$result: ") {
          result match {
            case Right(_) if from != to =>
              afterSender shouldBe (beforeSender - amount - TransferFee)
              afterRecipient shouldBe (beforeRecipient + amount)
            case Right(_) =>
              // self-transfer: sender pays only the fee, amount cancels out
              afterSender shouldBe (beforeSender - TransferFee)
            case Left(_) =>
              // rejected (e.g. insufficient balance) — must be all-or-nothing, no partial application
              afterSender shouldBe beforeSender
              afterRecipient shouldBe beforeRecipient
          }
        }
      }
    }
  }

  "a pool of 5 accounts under 200 random transfers per seed" - {
    (0 until 50).foreach { seed =>
      s"seed=$seed: every accepted transfer conserves balance exactly, every rejection is a no-op" in runFuzzRound(seed)
    }
  }
}
```

- [ ] **Step 2: Run test to verify it fails or passes on first attempt**

Run: `cd node-scala && sbt --batch "node-tests/testOnly com.decentralchain.state.diffs.OperationFuzzSpecification"`
Expected: likely FAIL on the first attempt, for a mundane reason: `TransferFee`/`InitialBalance`/`.dcc` extension and `withDomain`/`FreeSpec` imports need confirming against the actual testkit (`.dcc` is a unit-suffix implicit likely defined somewhere in `TestValues`/`NumericExt` — grep for `implicit class.*dcc\b` in `node/testkit` if this doesn't resolve, and adjust the import). Do not guess further blind — read the actual compiler error and fix imports/helper names to match what really exists, since this plan's code was written from grep evidence but not compiled.

- [ ] **Step 3: Fix any compilation issues found in Step 2, then re-run until green**

Run: `cd node-scala && sbt --batch "node-tests/testOnly com.decentralchain.state.diffs.OperationFuzzSpecification"`
Expected: PASS, 50 tests (one per seed). If a specific seed's balance-conservation assertion fails (not a compile error, a real assertion failure), STOP — this is a potential real bug in transaction processing, not a fuzzer bug. Record the exact seed, step, and observed vs. expected balances, and escalate as a new finding rather than adjusting the assertion.

- [ ] **Step 4: Commit**

```bash
cd /Users/jourlez/Documents/Code/Blockchain/Ecosystem/node-scala
git add node/tests/src/test/scala/com/decentralchain/state/diffs/OperationFuzzSpecification.scala
git commit -m "test: add pool-based transfer Operation fuzzer with per-account balance invariants"
```

---

### Task 2: Broaden Operation types — lease and data transactions among the pool

**Files:**
- Modify: `node-scala/node/tests/src/test/scala/com/decentralchain/state/diffs/OperationFuzzSpecification.scala` (Task 1's file)

**Interfaces:**
- Consumes: `TxHelpers.lease(from, to, amount, fee): LeaseTransaction`, `TxHelpers.data(from, entries, fee): DataTransaction` (confirm exact parameter names/order against `TxHelpers.scala` before writing — Task 1's research covered `transfer`/`genesis` in full detail but not these two; read the file's `lease`/`data` function definitions directly rather than guessing their parameter lists).

- [ ] **Step 1: Read the real `lease`/`data` signatures**

Run: `grep -n -A8 'def lease(\|def data(' node/testkit/src/main/scala/com/decentralchain/transaction/TxHelpers.scala`
Use the exact real parameter names/defaults printed here for Step 2 — do not proceed on assumption.

- [ ] **Step 2: Add a second operation kind to the fuzz loop**

Extend `runFuzzRound` in `OperationFuzzSpecification.scala` so each step picks one of `{transfer, lease}` at random (`rnd.nextBoolean()`), using the real `TxHelpers.lease` signature from Step 1. For a lease operation, the invariant checked is different from transfer's balance-conservation: leasing doesn't move the DCC balance, it moves the **lease balance** — assert `domain.blockchainUpdater.leaseBalance(from.toAddress).out` increases by `amount` on `Right(_)`, and is unchanged on `Left(_)`. Confirm `Domain`/`BlockchainUpdaterImpl` actually exposes `leaseBalance(address): LeaseBalance` (with an `.out`/`.in` field) by grepping `def leaseBalance` in `node/src/main/scala/com/decentralchain/state/BlockchainUpdaterImpl.scala` before writing this assertion — do not guess the field names.

- [ ] **Step 3: Run and confirm it passes**

Run: `cd node-scala && sbt --batch "node-tests/testOnly com.decentralchain.state.diffs.OperationFuzzSpecification"`
Expected: PASS, 50 tests, now exercising both transfer and lease operations per seed.

- [ ] **Step 4: Commit**

```bash
cd /Users/jourlez/Documents/Code/Blockchain/Ecosystem/node-scala
git add node/tests/src/test/scala/com/decentralchain/state/diffs/OperationFuzzSpecification.scala
git commit -m "test: broaden Operation fuzzer to include lease transactions with lease-balance invariants"
```

---

### Task 3: Cross-node determinism check (targets the Committed-Generators StateHash Finding)

**Files:**
- Create: `node-scala/node/tests/src/test/scala/com/decentralchain/state/diffs/OperationDeterminismSpecification.scala`

**Interfaces:**
- Consumes: same `Domain`/`TxHelpers` pool-setup pattern as Task 1.

**Why this exists:** the project's own open **Committed-Generators StateHash Finding** (a state-hash divergence bug at post-commitment height, per prior memory) is exactly a cross-instance non-determinism bug. This test reruns the identical operation sequence against two independently-constructed `Domain` instances and checks their balance state matches at every step — a mismatch here would be a strong lead on that finding's root cause.

- [ ] **Step 1: Write the test**

```scala
package com.decentralchain.state.diffs

import com.decentralchain.db.WithState.AddrWithBalance
import com.decentralchain.test.FreeSpec
import com.decentralchain.transaction.TxHelpers

import scala.util.Random

/** Applies the SAME seeded operation sequence to two independently-genesised Domain instances and
  * checks their per-account balance state matches at every step. A divergence here is exactly the
  * "two nodes computed different state from the same transaction sequence" failure class behind the
  * open Committed-Generators StateHash Finding.
  */
class OperationDeterminismSpecification extends FreeSpec {
  private val PoolSize       = 5
  private val OperationCount = 200
  private val InitialBalance = 1000.dcc
  private val TransferFee    = 100000L

  private val pool = (0 until PoolSize).map(TxHelpers.signer)

  private def genesisBalances = pool.map(kp => AddrWithBalance(kp.toAddress, InitialBalance))

  "two independent blockchain instances fed the identical seeded operation sequence" - {
    (0 until 50).foreach { seed =>
      s"seed=$seed: must reach identical balance state at every step" in {
        val rnd = new Random(seed)
        val ops = (1 to OperationCount).map { _ =>
          val from   = pool(rnd.nextInt(PoolSize))
          val to     = pool(rnd.nextInt(PoolSize))
          val amount = rnd.nextInt(InitialBalance.toInt)
          (from, to, amount)
        }

        withDomain(balances = genesisBalances) { domainA =>
          withDomain(balances = genesisBalances) { domainB =>
            ops.zipWithIndex.foreach { case ((from, to, amount), step) =>
              val tx = TxHelpers.transfer(from, to.toAddress, amount, fee = TransferFee)
              val resultA = domainA.appendBlockE(tx)
              val resultB = domainB.appendBlockE(tx)

              withClue(s"seed=$seed step=$step: acceptance diverged (A=$resultA, B=$resultB): ") {
                resultA.isRight shouldBe resultB.isRight
              }

              pool.foreach { account =>
                withClue(s"seed=$seed step=$step account=${account.toAddress}: balance diverged between the two instances: ") {
                  domainA.balance(account.toAddress) shouldBe domainB.balance(account.toAddress)
                }
              }
            }
          }
        }
      }
    }
  }
}
```

- [ ] **Step 2: Run and confirm it passes**

Run: `cd node-scala && sbt --batch "node-tests/testOnly com.decentralchain.state.diffs.OperationDeterminismSpecification"`
Expected: PASS, 50 tests. A failure here is a significant finding — do not adjust the equality assertion to tolerate a mismatch; stop and escalate with the exact seed/step/account/balances.

- [ ] **Step 3: Commit**

```bash
cd /Users/jourlez/Documents/Code/Blockchain/Ecosystem/node-scala
git add node/tests/src/test/scala/com/decentralchain/state/diffs/OperationDeterminismSpecification.scala
git commit -m "test: add cross-instance determinism check targeting the Committed-Generators StateHash finding"
```

---

### Task 4: ScalaCheck property tests for matcher's fixed-point rounding math

**Files:**
- Create: `matcher/dex/src/test/scala/com/decentralchain/dex/model/MatcherModelPropertySpecification.scala`

**Interfaces:**
- Consumes: `com.decentralchain.dex.model.MatcherModel.{partialFee, calcAmountOfPriceAsset, correctedAmountOfAmountAsset}` (all confirmed real, quoted in the code audit backing this plan — `matcher/dex/src/main/scala/com/decentralchain/dex/model/MatcherModel.scala:121-147`).

- [ ] **Step 1: Write the test**

```scala
package com.decentralchain.dex.model

import com.decentralchain.dex.NoShrink
import org.scalacheck.Gen
import org.scalatest.matchers.should.Matchers
import org.scalatest.propspec.AnyPropSpec
import org.scalatestplus.scalacheck.{ScalaCheckPropertyChecks => PropertyChecks}

import java.math.{BigDecimal => JBigDecimal}

/** Property tests for MatcherModel's fixed-point rounding math, targeting exactly the risk its own
  * inline comment flags: "Should not round! It could lead to forks." (MatcherModel.scala:124).
  */
class MatcherModelPropertySpecification extends AnyPropSpec with PropertyChecks with Matchers with NoShrink {

  private val positiveLongGen  = Gen.choose(1L, 1_000_000_000_000L)
  private val matcherFeeGen    = Gen.choose(1L, 1_000_000L)

  property("partialFee: the full amount consumes exactly the full fee (no rounding loss at the boundary)") {
    forAll(matcherFeeGen, positiveLongGen) { (fee, total) =>
      MatcherModel.partialFee(fee, scala.BigDecimal(total), scala.BigDecimal(total)) shouldBe fee
    }
  }

  property("partialFee: splitting an amount into two parts never charges more than the whole fee (no value created)") {
    forAll(matcherFeeGen, positiveLongGen, Gen.choose(0.0, 1.0)) { (fee, total, splitRatio) =>
      val part1 = (scala.BigDecimal(total) * splitRatio).setScale(0, BigDecimal.RoundingMode.FLOOR)
      val part2 = scala.BigDecimal(total) - part1

      val fee1 = MatcherModel.partialFee(fee, scala.BigDecimal(total), part1)
      val fee2 = MatcherModel.partialFee(fee, scala.BigDecimal(total), part2)

      (fee1 + fee2) should be <= fee
    }
  }

  property("correctedAmountOfAmountAsset: increasing the amount (fixed price) never decreases the corrected result") {
    forAll(positiveLongGen, positiveLongGen, Gen.choose(1L, 1000L)) { (a, delta, price) =>
      val smaller = MatcherModel.correctedAmountOfAmountAsset(a, price)
      val larger  = MatcherModel.correctedAmountOfAmountAsset(a + delta, price)

      larger should be >= smaller
    }
  }

  property("calcAmountOfPriceAsset: never returns a negative result for non-negative inputs") {
    forAll(Gen.choose(0L, 1_000_000_000_000L), Gen.choose(0L, 1_000_000_000L)) { (amount, price) =>
      MatcherModel.calcAmountOfPriceAsset(amount, price) should be >= 0L
    }
  }
}
```

- [ ] **Step 2: Run test to verify it fails or passes**

Run: `cd matcher && sbt --batch "dex/testOnly com.decentralchain.dex.model.MatcherModelPropertySpecification"`
Expected: this plan's code was written from real quoted signatures but not compiled — a likely first-pass issue is the `NoShrink` trait's exact import path (confirmed used at `matcher/dex/src/test/scala/com/decentralchain/dex/fp/MapImplicitsSpec.scala:5` as `com.decentralchain.dex.NoShrink`) and whether `MatcherModel`'s functions are called as `MatcherModel.partialFee(...)` (object-scoped) or need a different import if they're actually top-level package functions — confirm against the real file before assuming the call site is correct.

- [ ] **Step 3: Fix any compilation issues, then re-run until green**

Run: `cd matcher && sbt --batch "dex/testOnly com.decentralchain.dex.model.MatcherModelPropertySpecification"`
Expected: PASS, 4 properties (each running ScalaCheck's default 100 examples). If the "no value created" or monotonicity property fails on a real generated case, STOP — given the function's own comment already flags fork risk from rounding, a genuine counterexample here is a valuable, real finding. Record the exact failing inputs ScalaCheck reports and escalate; do not loosen the property to pass.

- [ ] **Step 4: Commit**

```bash
cd /Users/jourlez/Documents/Code/Blockchain/Ecosystem/matcher
git add dex/src/test/scala/com/decentralchain/dex/model/MatcherModelPropertySpecification.scala
git commit -m "test: add ScalaCheck property tests for MatcherModel fixed-point rounding math"
```

---

## What this plan does not cover

- Broader Operation types beyond transfer/lease (data, alias, sponsorship, issue/reissue/burn, invoke-script) — Task 2 establishes the pattern; extending further is mechanical repetition of the same shape and is left as natural follow-up, not because it's hard, but to keep this plan's tasks reviewable one at a time.
- State export/import round-trip and hard-fork replay simulation modes (both part of the Cosmos SDK pattern this plan draws from) — genuinely new scope requiring separate research into node-scala's actual state-export mechanism; not fabricated here.
