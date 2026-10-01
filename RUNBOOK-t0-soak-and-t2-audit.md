# Runbook — T0 60-Day Soak & T2 HotStuff External Audit

Neither of these two mainnet gates is a code change. This runbook exists so they're tracked with the
same rigor as code work instead of sitting as a checkbox in HANDOFF.md with no owner or trigger date.

## Gate 1 — T0 DeterministicFinality 60-day stabilization soak

**What it is:** T0 (feature 25) must run stably on a live chain for ≥60 consecutive days before it can
be activated on mainnet. The soak clock has **not started** as of 2026-08-22 — this is calendar time,
not implementation work; the only "task" is starting it and not letting it get silently reset.

**Why 60 days, not less:** matches the project's existing bar for consensus-critical features going live
without an external audit backstopping them continuously (T0 has no separate external audit gate the way
T2/HotStuff does — the soak period IS its verification). Don't shorten this without an explicit decision
recorded here with a name and date attached.

### Step 1 — Start the clock

- [ ] Confirm T0 is live and authoritative on the chain the soak will run against (mainnet candidate
      chain, or stagenet if the decision is to soak on stagenet first and treat that as a proxy —
      **decide and record which** before starting; soaking on testnet does NOT count, testnet has
      already had T0 live for a while and mixing "started soaking" dates causes confusion later).
- [ ] Record the exact start timestamp in this file (append to the table below) — this is the
      single source of truth for "how many days has it been."
- [ ] Set a calendar reminder / cron-based check (see Step 2) for day 60.

| Chain | Soak start (UTC) | Target end (UTC) | Status |
|---|---|---|---|
| _(not yet started)_ | — | — | NOT STARTED |

### Step 2 — What resets the clock (do not fudge this)

Any of the following during the soak window means **restart the clock from zero**, not "subtract the
downtime and keep going":
- A crash of the finality-critical process (node process death, OOM-kill, panic) on any soaking node.
- A network partition lasting long enough that T0 finality visibly stalled (`finalizedHeight` stopped
  advancing) rather than just individual peers reconnecting.
- Any manual chain-state intervention (genesis reset, state transplant, rollback) on the soaking chain —
  this includes the `migrate-state-snapshot.yml` (IR-5) recovery mechanism already used on testnet; if
  that's ever invoked on the soaking chain, the soak restarts.
- Any code change to T0's finality logic itself (`feature 25` / `DeterministicFinality` implementation)
  deployed to the soaking chain — a fix elsewhere (e.g. the height-3325 StateHash fix) does NOT reset the
  clock unless it touches T0's own code path; record the reasoning either way when it comes up.

### Step 3 — Monitoring during the soak

- [ ] Add a Grafana panel (or extend the existing testnet one — check `infra/clusters/testnet` for the
      dashboard-as-code source) tracking `finalizedHeight` lag and any crash/restart count for every
      soaking node, visible at a glance without needing to SSH in.
- [ ] Add a Prometheus alert that fires if `finalizedHeight` stalls for more than N minutes (pick N based
      on the existing testnet alert thresholds — check `infra/` for the 5 production alerts already
      deployed and match their style) — a silent stall discovered on day 55 instead of day 5 wastes 50
      days for nothing.

### Step 4 — Day 60 checklist

- [ ] Confirm zero resets occurred (check this file's table + the monitoring from Step 3).
- [ ] Write up the soak result as the "formal multi-day soak record (crash/partition/equivocation)"
      that `docs/hotstuff-audit-readiness.md`'s mainnet checklist requires — note that T2's own soak
      record is a SEPARATE requirement from this one (T0 vs T2 are different consensus mechanisms); don't
      conflate the two even though they may run on the same physical chain at the same time.
- [ ] Get sign-off recorded here (name + date) before treating T0 as mainnet-cleared.

---

## Gate 2 — T2 HotStuff external consensus audit

**What it is:** an external, paid consensus-security audit of the HotStuff implementation, required
before `dcc.hotstuff.authoritative = true` can go live on mainnet (it's already live on testnet by
deliberate, scoped, human decision — see `HANDOFF.md`/`docs/hotstuff-audit-readiness.md`). This has not
been engaged yet as of 2026-08-22 — it's a procurement action, not something that gets "done" by writing
code.

### Step 1 — Scope the audit engagement

- [ ] Use `docs/hotstuff-audit-readiness.md` as the audit scope document as-is — it already defines
      in-scope surface, threat scenarios (T1-T10), and current handling for each. Do not re-derive this;
      it exists specifically so an external auditor has a ready starting point.
- [ ] **Before sending this out, fold in the equivocation-to-slashing wiring** from
      `node-scala/docs/superpowers/plans/2026-08-22-hotstuff-equivocation-slashing.md` if it's landed —
      that plan explicitly adds new consensus wire-format surface (Task 3's evidence-encoding decision)
      that must be in scope, not omitted because it postdates the existing readiness doc.
- [ ] Confirm the "needs live multi-node Docker evidence of an actual T10 committee-epoch transition"
      gap (currently unit/DST-sim only) is closed or explicitly still open in the scope doc sent to the
      auditor — don't let the auditor discover mid-engagement that a claimed-tested scenario wasn't
      actually exercised live.

### Step 2 — Vendor selection

- [ ] Identify 2-3 candidate firms with prior BFT/HotStuff or similar consensus-audit track record
      (this is a judgment call for whoever owns vendor relationships — not something to automate).
- [ ] Get quotes + timeline estimates; consensus audits commonly run 2-6 weeks depending on scope and
      firm availability — budget calendar time accordingly, this is usually the longest lead-time item
      in a mainnet-launch plan, so start outreach now even if other gates aren't ready yet.
- [ ] Record the chosen vendor, contract dates, and point of contact here once selected:

| Vendor | Engaged (date) | Scope doc version sent | Expected delivery | Status |
|---|---|---|---|---|
| _(not yet engaged)_ | — | — | — | NOT STARTED |

### Step 3 — During the engagement

- [ ] Designate one engineer as the auditor's point of contact (answers questions, provides repo access,
      doesn't require the whole team to context-switch every time the auditor has a question).
- [ ] Track findings as they come in — don't wait for the final report to start triaging; a consensus
      audit finding severity-ranked as "critical" mid-engagement should get attention immediately, not
      after the engagement formally closes.

### Step 4 — Closing the gate

- [ ] All audit findings triaged: fixed, or explicitly accepted-risk with a written rationale and a
      named approver — no finding left in limbo.
- [ ] Sign-off recorded here (auditor's final verdict, date, link to report) before flipping
      `dcc.hotstuff.authoritative = true` on mainnet's `dcc.conf`.
- [ ] Cross-check against `docs/hotstuff-audit-readiness.md`'s existing mainnet checklist — this gate and
      that document's checklist should reach "done" together, not independently.

---

## How these two gates interact with the rest of mainnet readiness

Both gates are independent of the height-3325 StateHash fix (`node-scala/docs/superpowers/plans/
2026-08-22-height-3325-statehash-fix.md`) and don't block starting stagenet — but do NOT let stagenet
work distract from starting Gate 1's clock and Gate 2's vendor outreach in parallel; both have long
minimum durations (60 days; multi-week audit) that don't compress no matter how much other work happens
alongside them. Starting them late is the single most common way a "ready for mainnet" date slips.
