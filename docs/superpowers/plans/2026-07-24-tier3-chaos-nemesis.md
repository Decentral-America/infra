# Tier 3 — Chaos/Nemesis Testing on Real Containers — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close Tier 3 of the [E2E testing strategy](../specs/2026-07-24-e2e-testing-strategy-design.md): add real-container fault injection (latency, bandwidth throttling, full cut) to node-scala's `node-it` (which today has only binary connect/disconnect and crash/restart — no degraded-link simulation), and use matcher's *already-existing* ToxiProxy+iptables fault-injection infrastructure to write a new nemesis scenario targeting the matcher↔node settlement boundary — the priority target per the spec, since this is exactly the failure class behind the **Matcher Unfunded Account** memory finding (4 stacked bugs that masked DEX settlement).

**Architecture:** Two independent halves, because the two repos start from very different places:
- **node-scala** has zero fault-injection infrastructure beyond full connect/disconnect (`Docker.scala`'s `disconnectFromNetwork`/`connectToNetwork`) and container kill/restart. This half ports matcher's proven `HasToxiProxy` + `ConfigurableToxicProxyContainer` pattern (same `shopify/toxiproxy:2.1.0` image, same `testcontainers-toxiproxy` library) into node-it, scoped to a two-node degraded-link scenario first (not a full 4-node mesh — see Global Constraints).
- **matcher**'s `dex-it` already has ToxiProxy (`HasToxiProxy`) and iptables-based (`DexContainer.switchOutgoingTrafficOnPort`) fault injection, proven in `NetworkIssuesTestSuite`. This half only needs a *new scenario*, not new infrastructure: inject latency/cut on the matcher↔node gRPC extension link while orders are settling, and check balance/order invariants exactly as `BouncingBalancesTestSuite` already does for its own (different) fault type (blockchain rollback).

**Tech Stack:** Scala 3, sbt, Docker/Testcontainers, `eu.rekawek.toxiproxy` (Java client), ScalaTest.

## Global Constraints

- **Scope limitation, stated up front:** the node-scala half of this plan proxies exactly one P2P link between two of the four `FourNodeHotStuffTestSuite` nodes, not a full mesh. Rerouting all inter-node peer connections through per-pair proxies requires deeper changes to `NodeConfigs.scala`'s peer-address wiring than this plan covers — call this out explicitly as follow-up work in Task 2's completion notes, do not silently under-deliver without saying so.
- Do not touch matcher's existing `HasToxiProxy`/`ConfigurableToxicProxyContainer`/`DexContainer` — Task 3 only adds a new test file that consumes this existing, working infrastructure.
- New node-scala dependencies go in `node-it/build.sbt` only (test-scope), matching matcher's exact versions confirmed by code audit: `"com.dimafeng" %% "testcontainers-scala" % "0.44.1"` and `"org.testcontainers" % "testcontainers-toxiproxy" % "2.0.5"` — do not pick different versions without a reason.
- All safety assertions in Task 2/3's new scenarios must reuse the vocabulary already established by the suites they extend (`finalizedHeight` monotonicity per `FourNodeHotStuffTestSuite`; `getTradableBalanceByAssetPairAndAddress`/order-status polling per `BouncingBalancesTestSuite`) — do not invent a parallel assertion style.

---

### Task 1: `ToxiProxyHarness` — port matcher's ToxiProxy pattern into node-it

**Files:**
- Modify: `node-scala/node-it/build.sbt` (add dependencies)
- Create: `node-scala/node-it/src/test/scala/com/decentralchain/it/ToxiProxyHarness.scala`

**Interfaces:**
- Consumes: node-it's existing `Docker` (for `network`, container start/IP helpers — see `Docker.scala`), and each node's real P2P port, read from its resolved config at `dcc.network.port` (the exact same config key already read at `Docker.scala:228`, `val networkPort = actualConfig.getString("dcc.network.port")`).
- Produces: `trait ToxiProxyHarness { self: DockerBased => protected val toxiProxyHostName: String; protected val toxiContainer: ConfigurableToxicProxyContainer; protected def mkToxiProxy(hostname: String, port: Int): ContainerProxy; protected def getInnerToxiProxyPort(proxy: ContainerProxy): Int }` — a direct structural port of matcher's `HasToxiProxy`, adapted to node-it's own `Docker`/network-naming conventions (matcher's original is quoted in full below as the template).

- [ ] **Step 1: Add the dependencies**

In `node-scala/node-it/build.sbt`, add to `libraryDependencies`:
```scala
libraryDependencies ++= Seq(
  "com.dimafeng" %% "testcontainers-scala" % "0.44.1",
  "org.testcontainers" % "testcontainers-toxiproxy" % "2.0.5"
)
```

- [ ] **Step 2: Confirm the dependencies resolve**

Run: `cd node-scala && sbt --batch "node-it/update"`
Expected: PASS, no dependency resolution errors.

- [ ] **Step 3: Write the harness, adapted from matcher's proven template**

Reference template (matcher's real, working file — `matcher/dex-it-common/src/main/scala/com/decentralchain/dex/it/api/HasToxiProxy.scala`, quoted for the port):
```scala
package com.decentralchain.dex.it.api

import com.decentralchain.dex.it.docker.{ConfigurableToxicProxyContainer, PortBindingKeeper, NodeContainer}
import com.decentralchain.dex.it.docker.ConfigurableToxicProxyContainer.ContainerProxy
import scala.jdk.CollectionConverters._

trait HasToxiProxy { self: BaseContainersKit =>
  protected val toxiProxyHostName = s"$networkName-toxiproxy"
  private val exposedPorts = Seq(NodeContainer.matcherGrpcExtensionPort, NodeContainer.blockchainUpdatesGrpcExtensionPort)
  protected val toxiContainer: ConfigurableToxicProxyContainer = mkToxiProxyContainer

  private def mkToxiProxyContainer = {
    val cfgContainer = new ConfigurableToxicProxyContainer("shopify/toxiproxy:2.1.0", exposedPorts.size)
    cfgContainer.container.withNetwork(network)
    cfgContainer.container.withNetworkAliases(toxiProxyHostName)
    cfgContainer.container.withCreateContainerCmdModifier { cmd =>
      cmd.withName(toxiProxyHostName)
      cmd.withIpv4Address(getIp(13))
      cmd.getHostConfig.withPortBindings(PortBindingKeeper.getBindings(cmd, exposedPorts))
    }
    cfgContainer
  }

  protected def getInnerToxiProxyPort(proxy: ContainerProxy): Int =
    toxiContainer.getContainerInfo.getNetworkSettings.getPorts.getBindings.asScala
      .find { case (_, bindings) => Option(bindings).flatMap(_.headOption).exists(_.getHostPortSpec == proxy.proxyPort.toString) }
      .map(_._1.getPort)
      .getOrElse(throw new IllegalStateException(s"There is no inner port for proxied one: ${proxy.proxyPort}"))

  protected def mkToxiProxy(hostname: String, port: Int): ContainerProxy = toxiContainer.getProxy(hostname, port)

  toxiContainer.start()
}
```

Node-scala's port, adapted for node-it's own base trait (`DockerBased`, node-it's equivalent of matcher's `BaseContainersKit` — confirm the exact mixin point by reading `node-it/src/test/scala/com/decentralchain/it/DockerBased.scala` for the members it already exposes, e.g. `network`, `networkName`, `getIp`, before finalizing this file, since node-it's `Docker`/`DockerBased` split is not identical to matcher's `BaseContainersKit`):

```scala
package com.decentralchain.it

import com.decentralchain.dex.it.docker.ConfigurableToxicProxyContainer
import com.decentralchain.dex.it.docker.ConfigurableToxicProxyContainer.ContainerProxy

import scala.jdk.CollectionConverters._

/** Ports matcher's proven `HasToxiProxy` pattern into node-it: a single `shopify/toxiproxy` container
  * proxying one node's P2P port, so a scenario can inject latency/bandwidth-throttling/full-cut on that
  * link without the binary all-or-nothing of `Docker.disconnectFromNetwork`. node-it had zero
  * degraded-link fault injection before this file (only full connect/disconnect and container kill).
  */
trait ToxiProxyHarness { self: DockerBased =>
  protected val toxiProxyHostName: String = s"${self.network.getId.take(8)}-toxiproxy"
  private val maxProxiedPorts = 4 // enough headroom for a small number of proxied node P2P ports in one suite

  protected val toxiContainer: ConfigurableToxicProxyContainer = {
    val c = new ConfigurableToxicProxyContainer("shopify/toxiproxy:2.1.0", maxProxiedPorts)
    c.container.withNetwork(self.network)
    c.container.withNetworkAliases(toxiProxyHostName)
    c
  }

  protected def getInnerToxiProxyPort(proxy: ContainerProxy): Int =
    toxiContainer.getContainerInfo.getNetworkSettings.getPorts.getBindings.asScala
      .find { case (_, bindings) => Option(bindings).flatMap(_.headOption).exists(_.getHostPortSpec == proxy.proxyPort.toString) }
      .map(_._1.getPort)
      .getOrElse(throw new IllegalStateException(s"There is no inner port for proxied one: ${proxy.proxyPort}"))

  /** Proxy `hostname:port` (typically a node container's alias and P2P port, read from its resolved
    * `dcc.network.port` config). Returns a handle for injecting latency/bandwidth/cut toxics.
    */
  protected def mkToxiProxy(hostname: String, port: Int): ContainerProxy = toxiContainer.getProxy(hostname, port)

  toxiContainer.start()
}
```

- [ ] **Step 4: Compile**

Run: `cd node-scala && sbt --batch "node-it/compile"`
Expected: PASS. If `DockerBased` doesn't actually expose a `network: Network` member with this exact name/type, adjust the `self: DockerBased =>` self-type and the `self.network`/`self.network.getId` references to whatever `DockerBased.scala` actually exposes — read that file first if this doesn't compile cleanly, don't guess further.

- [ ] **Step 5: Commit**

```bash
cd /Users/jourlez/Documents/Code/Blockchain/Ecosystem/node-scala
git add node-it/build.sbt node-it/src/test/scala/com/decentralchain/it/ToxiProxyHarness.scala
git commit -m "test: add ToxiProxyHarness to node-it, porting matcher's proven latency/bandwidth fault-injection pattern"
```

---

### Task 2: Degraded-link HotStuff scenario (node-scala)

**Files:**
- Create: `node-scala/node-it/src/test/scala/com/decentralchain/it/sync/finalization/DegradedLinkHotStuffTestSuite.scala`

**Interfaces:**
- Consumes: `ToxiProxyHarness` (Task 1); the existing 4-node HotStuff harness pattern from `FourNodeHotStuffTestSuite.scala` (same `NodeConfigs.newBuilder...withDefault(4).buildNonConflicting()` setup, same `hsNodes`/`finalizedHeight`/`waitForSameBlockHeadersAt` vocabulary — reuse this suite's setup verbatim rather than inventing a new one).

**Scope limitation** (restated from Global Constraints): this proxies one link between two of the four nodes, not the full mesh. Read the existing `FourNodeHotStuffTestSuite.scala`'s node-setup section fully before writing this file, and confirm which node index's P2P address you can route through the proxy (this requires each node's `known-peers` config for that one pair to point at `toxiProxyHostName:<proxied-port>` instead of the peer's real address — check `NodeConfigs.scala`'s peer-address templating to do this correctly rather than guessing the config key).

- [ ] **Step 1: Write the test**

```scala
package com.decentralchain.it.sync.finalization

import com.decentralchain.it.{ToxiProxyHarness, FourNodeHotStuffTestSuite}
import eu.rekawek.toxiproxy.model.ToxicDirection
import scala.concurrent.duration.DurationInt

/** Same 4-node HotStuff cluster as FourNodeHotStuffTestSuite, but instead of a binary partition
  * (Docker.disconnectFromNetwork), the link between two nodes is degraded (latency + bandwidth
  * throttle) via a real ToxiProxy container. Checks the same safety invariant already used by the
  * happy-path/partition scenarios: finalizedHeight must never regress on any node.
  */
class DegradedLinkHotStuffTestSuite extends FourNodeHotStuffTestSuite with ToxiProxyHarness {

  "a 4-node HotStuff cluster with a degraded (not fully cut) link between two nodes" should
    "keep finalizing without any node's finalizedHeight regressing" in {
      val proxiedLink = mkToxiProxy(hsNodes(1).networkAddress.getHostString, hsNodes(1).nodeExternalPort)
      proxiedLink.toxics().latency("degraded-link-latency", ToxicDirection.DOWNSTREAM, 800)
      proxiedLink.toxics().bandwidth("degraded-link-bandwidth", ToxicDirection.DOWNSTREAM, 32) // 32 KB/s

      val start = leader.finalizedHeight
      val target = start + 2
      val deadline = 6.minutes.fromNow // longer than the happy-path deadline: the link is degraded, not down
      var done = false
      while (!done && deadline.hasTimeLeft()) {
        leader.transfer(leader.keyPair, hsNodes(1).address, 1.dcc, waitForTx = true)
        val fhs = hsNodes.map(_.finalizedHeight)
        fhs.foreach(fh => if (fh < start) fail(s"finalized height regressed below $start under a degraded link: got $fh"))
        done = fhs.forall(_ >= target)
      }
      if (!done)
        fail(s"HotStuff-enabled cluster with a degraded link did not finalize to $target within the deadline; per-node finalized=${hsNodes.map(_.finalizedHeight)}")

      proxiedLink.toxics().get("degraded-link-latency").remove()
      proxiedLink.toxics().get("degraded-link-bandwidth").remove()
    }
}
```

Note: `hsNodes(1).networkAddress.getHostString`/`.nodeExternalPort` are placeholders for whatever `FourNodeHotStuffTestSuite`'s actual `Node`/`DockerNode` type exposes for a peer's real P2P host/port — confirm the exact accessor names by reading `Node.scala`/`NodeInfo` (quoted partially in Tier 1's research: `NodeInfo(restApiPort: Int, networkPort: Int, dccIpAddress: String, ports: Ports)`) before finalizing; do not leave a guessed accessor name in the merged code.

- [ ] **Step 2: Run and confirm it passes**

Run: `cd node-scala && sbt --batch "node-it/docker" && sbt --batch "node-it/testOnly com.decentralchain.it.sync.finalization.DegradedLinkHotStuffTestSuite"`
Expected: PASS within the 6-minute deadline. If it times out, that itself may be a real finding (HotStuff's round-timeout tuning may not tolerate this exact latency/bandwidth combination) — before assuming it's a harness bug, check whether `dcc.hotstuff.round-timeout` (confirmed at `1200ms` in `FourNodeHotStuffTestSuite`, per Tier 1 research) is simply too short for an 800ms one-way latency injection, and if so, that's a legitimate tuning finding to record, not something to silently loosen the test's fault parameters to make it pass.

- [ ] **Step 3: Commit**

```bash
cd /Users/jourlez/Documents/Code/Blockchain/Ecosystem/node-scala
git add node-it/src/test/scala/com/decentralchain/it/sync/finalization/DegradedLinkHotStuffTestSuite.scala
git commit -m "test: add degraded-link (latency/bandwidth) HotStuff chaos scenario via ToxiProxyHarness"
```

---

### Task 3: Matcher↔node settlement nemesis scenario (matcher, no new infrastructure)

**Files:**
- Create: `matcher/dex-it/src/test/scala/com/decentralchain/it/sync/networking/SettlementNemesisTestSuite.scala`

**Interfaces:**
- Consumes: `HasToxiProxy` (existing, `matcher/dex-it-common/src/main/scala/com/decentralchain/dex/it/api/HasToxiProxy.scala` — do not modify); `WsSuiteBase`/`MatcherSuiteBase` helpers already used identically by `BouncingBalancesTestSuite` and `NetworkIssuesTestSuite` — `mkAccountWithBalance`, `mkOrderDP`, `dex1.api.place`, `dex1.api.waitForOrderStatus`, `dex1.api.getTradableBalanceByAssetPairAndAddress`, `NodeContainer.nodeNetAlias`/`NodeContainer.matcherGrpcExtensionPort`.

- [ ] **Step 1: Write the test**

```scala
package com.decentralchain.it.sync.networking

import com.typesafe.config.Config
import com.decentralchain.dex.api.http.entities.HttpOrderStatus.Status
import com.decentralchain.dex.domain.asset.Asset.Dcc
import com.decentralchain.dex.domain.order.OrderType.{BUY, SELL}
import com.decentralchain.dex.it.api.HasToxiProxy
import com.decentralchain.dex.it.docker.NodeContainer
import com.decentralchain.it.WsSuiteBase
import com.decentralchain.it.tags.NetworkTests
import eu.rekawek.toxiproxy.model.ToxicDirection

/** Priority Tier-3 nemesis scenario: inject latency + a brief full cut on the matcher<->node gRPC
  * extension link (the boundary implicated in the "Matcher Unfunded Account" bug history — 4 stacked
  * bugs that masked DEX settlement) WHILE two crossing orders are placed and expected to settle.
  * Asserts no double-settlement and monotonic, consistent tradable balances once the link recovers —
  * reusing the exact balance-assertion vocabulary BouncingBalancesTestSuite already established for a
  * different fault type (blockchain rollback). Extends WsSuiteBase (not MatcherSuiteBase directly)
  * because `mkAccountWithBalance`/`usd`/`waitForOrderAtNode`/`eventually` are confirmed reachable from
  * WsSuiteBase (BouncingBalancesTestSuite already uses all of them from that same base) — confirm the
  * exact defining trait in dex-it-common/dex-test-common if you need to reference it directly, rather
  * than assuming MatcherSuiteBase alone provides them.
  */
@NetworkTests
class SettlementNemesisTestSuite extends WsSuiteBase with HasToxiProxy {

  private val matcherExtensionProxy = mkToxiProxy(NodeContainer.nodeNetAlias, NodeContainer.matcherGrpcExtensionPort)

  override protected def dexInitialSuiteConfig: Config =
    com.typesafe.config.ConfigFactory
      .parseString(
        s"""dcc.dex {
           |  price-assets = [ "DCC" ]
           |  dcc-blockchain-client.grpc.target = "dns:///$toxiProxyHostName:${getInnerToxiProxyPort(matcherExtensionProxy)}"
           |}""".stripMargin
      )

  "the matcher-node settlement boundary under a degraded-then-cut link" should
    "settle exactly once with no double-fill and a consistent final tradable balance" in {
      val alice1 = mkAccountWithBalance(100000.dcc -> Dcc, 100000.usd -> usd)
      val bob1 = mkAccountWithBalance(100000.dcc -> Dcc, 100000.usd -> usd)

      val aliceBalanceBefore = dex1.api.getTradableBalanceByAssetPairAndAddress(alice1, dccUsdPair)
      val bobBalanceBefore = dex1.api.getTradableBalanceByAssetPairAndAddress(bob1, dccUsdPair)

      matcherExtensionProxy.toxics().latency("settlement-latency", ToxicDirection.DOWNSTREAM, 2000)

      val buyOrder = mkOrderDP(alice1, dccUsdPair, BUY, 10.dcc, 10)
      val sellOrder = mkOrderDP(bob1, dccUsdPair, SELL, 10.dcc, 10)
      dex1.api.place(buyOrder)
      dex1.api.place(sellOrder)

      // Brief full cut mid-settlement, then heal — the exact class of fault the "Matcher Unfunded
      // Account" history showed real settlement bugs hide behind.
      matcherExtensionProxy.toxics().bandwidth("settlement-cut", ToxicDirection.DOWNSTREAM, 0)
      Thread.sleep(3000)
      matcherExtensionProxy.toxics().get("settlement-cut").remove()
      matcherExtensionProxy.toxics().get("settlement-latency").remove()

      dex1.api.waitForOrderStatus(buyOrder, Status.Filled)
      dex1.api.waitForOrderStatus(sellOrder, Status.Filled)
      waitForOrderAtNode(buyOrder)
      waitForOrderAtNode(sellOrder)

      eventually {
        val aliceBalanceAfter = dex1.api.getTradableBalanceByAssetPairAndAddress(alice1, dccUsdPair)
        val bobBalanceAfter = dex1.api.getTradableBalanceByAssetPairAndAddress(bob1, dccUsdPair)

        withClue("settlement must not double-fill or lose the trade:\n") {
          aliceBalanceAfter.getOrElse(usd, 0L) shouldBe (aliceBalanceBefore.getOrElse(usd, 0L) - 100.usd)
          bobBalanceAfter.getOrElse(usd, 0L) shouldBe (bobBalanceBefore.getOrElse(usd, 0L) + 100.usd)
        }
      }
    }
}
```

- [ ] **Step 2: Run and confirm it passes — treat a failure as a genuine finding, not a harness bug to paper over**

Run: `cd matcher && sbt --batch "dex-it/docker" && sbt --batch "dex-it/testOnly com.decentralchain.it.sync.networking.SettlementNemesisTestSuite"`
Expected: PASS. Given the exact bug class this targets was previously masked by 4 stacked bugs (per project history) before being fixed, a failure here is plausible and valuable — if it fails, record the exact assertion and balances observed, do not adjust the expected-balance math to match a wrong result.

- [ ] **Step 3: Commit**

```bash
cd /Users/jourlez/Documents/Code/Blockchain/Ecosystem/matcher
git add dex-it/src/test/scala/com/decentralchain/it/sync/networking/SettlementNemesisTestSuite.scala
git commit -m "test: add matcher-node settlement nemesis scenario (latency + brief cut) using existing ToxiProxy infra"
```

---

## What this plan does not cover

- Full 4-node mesh fault injection in node-scala (only one link is proxied) — flagged as explicit follow-up in Task 2.
- iptables-based (as opposed to ToxiProxy-based) fault injection for node-scala — matcher has both tools available; this plan only ports the ToxiProxy half, since it covers degraded-link scenarios that full connect/disconnect (already available in node-it) cannot.
- Wiring either new suite into CI cadence — that's Tier 7's job (CI cadence reorganization across all repos), not this plan's.
