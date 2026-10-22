#!/usr/bin/env python3
"""Off-box deadman for the in-cluster monitors (clusters/testnet/apps/monitors).

The CronJobs replace the GitHub-dispatched canary/liveness workflows, so nothing outside the cluster
would notice if they stopped. infra-liveness.yml (every 3 h) runs this against
`kubectl get cronjobs -n dcc -o json` and the open [ALERT] issue titles.

A monitor is unhealthy when
  - it has not been scheduled within MAX_SCHEDULE_AGE (CronJob controller or cluster scheduling dead), or
  - it has not SUCCEEDED within MAX_SUCCESS_AGE and no matching [ALERT] issue is open. A monitor that
    fails because the testnet is broken has already filed its alert (the issue is the signal); one that
    fails silently (image pull, bad token, npm outage) has not, and this is the only thing that sees it.
Usage: check-monitor-cronjobs.py <cronjobs.json> <open-issue-titles.json>   (titles: JSON array of strings)
"""
import json
import sys
from datetime import datetime, timezone

# name -> (max schedule age s, max success age s, alert title prefixes that explain a red monitor)
MONITORS = {
    "canary-transaction": (35 * 60, 75 * 60, ("[ALERT] CanaryTransactionFailed", "[ALERT] CanaryWalletUnfunded")),
    "infra-liveness": (75 * 60, 2 * 3600, ("[ALERT] InfraLiveness",)),
    "matcher-canary": (2 * 3600, 4 * 3600, ("[ALERT] MatcherSettlementCanaryFailed", "[ALERT] MatcherCanaryUnfunded")),
}


def parse(ts):
    return datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def evaluate(cronjobs, titles, now):
    by_name = {c["metadata"]["name"]: c for c in cronjobs["items"]}
    bad = []
    for name, (max_sched, max_ok, prefixes) in MONITORS.items():
        cj = by_name.get(name)
        if cj is None:
            bad.append(f"CronJob {name} is missing from namespace dcc")
            continue
        if cj.get("spec", {}).get("suspend"):
            print(f"warning: CronJob {name} is suspended")
            continue
        created = (now - parse(cj["metadata"]["creationTimestamp"])).total_seconds()
        st = cj.get("status", {})
        sched = st.get("lastScheduleTime")
        ok = st.get("lastSuccessfulTime")
        sched_age = (now - parse(sched)).total_seconds() if sched else None
        ok_age = (now - parse(ok)).total_seconds() if ok else None
        print(f"{name}: lastSchedule age={sched_age} lastSuccess age={ok_age}")
        if sched_age is None:
            if created > max_sched:
                bad.append(f"CronJob {name} has never been scheduled (created {int(created // 60)} min ago)")
            continue
        if sched_age > max_sched:
            bad.append(f"CronJob {name} was last scheduled {int(sched_age // 60)} min ago (limit {max_sched // 60})")
        too_old = (ok_age is None and created > max_ok) or (ok_age is not None and ok_age > max_ok)
        if too_old and not any(t.startswith(p) for t in titles for p in prefixes):
            shown = "never" if ok_age is None else f"{int(ok_age // 60)} min ago"
            bad.append(f"CronJob {name} last succeeded {shown} (limit {max_ok // 60}) and no matching alert issue is open")
    return bad


def main(argv):
    cronjobs = json.load(open(argv[1]))
    titles = json.load(open(argv[2]))
    bad = evaluate(cronjobs, titles, datetime.now(timezone.utc))
    for b in bad:
        print(f"::error::{b}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
