#!/usr/bin/env python3
"""Month-to-date GitHub Actions minutes report for the Decentral-America org.

Input: the JSON of `GET /organizations/Decentral-America/settings/billing/usage?year=Y&month=M`
(needs an org-billing-read token; the workflow token cannot read it). Only product=actions rows with
unitType=Minutes are counted (storage rows are GB-hours).
Usage: actions_minutes_report.py <usage.json> [--issue-body FILE] [--now ISO8601]
Prints a markdown report; with --issue-body writes the issue text; when $GITHUB_OUTPUT is set it
sets alert=true|false.

Operator rule: no repository is free. Every Actions minute in ANY repo counts against the org's
2000 free-minute pool here (GitHub itself only charges private repos; billing net shows that
separately). Pool minutes are weighted by runner multiplier (Linux 1x, Windows 2x, macOS 10x).
Thresholds (env): POOL_FREE_MIN=2000, BURST_DAY_MIN=500 (one repo, one day), MAX_PROJECTED_NET_USD=15.
Alert when: any repo-day above BURST_DAY_MIN, projected pool consumption above POOL_FREE_MIN, or
projected net above MAX_PROJECTED_NET_USD. Projection is linear and skipped during the first 2 days.
"""
import calendar
import json
import os
import sys
from collections import defaultdict
from datetime import datetime, timezone


def multiplier(sku):
    if "macOS" in sku:
        return 10
    if "Windows" in sku:
        return 2
    return 1


def analyse(usage, now, pool_free=2000.0, burst=500.0, max_net=15.0):
    repos = defaultdict(lambda: {"min": 0.0, "pool": 0.0, "gross": 0.0, "net": 0.0})
    days = defaultdict(float)  # (repo, day) -> pool minutes
    skus = defaultdict(float)
    for it in usage.get("usageItems", []):
        if it.get("product") != "actions" or it.get("unitType") != "Minutes":
            continue
        repo = it.get("repositoryName") or "(org)"
        q = float(it["quantity"])
        w = q * multiplier(it.get("sku", ""))
        r = repos[repo]
        r["min"] += q
        r["pool"] += w
        r["gross"] += float(it.get("grossAmount", 0))
        r["net"] += float(it.get("netAmount", 0))
        days[(repo, it["date"][:10])] += w
        skus[it.get("sku", "?")] += q
    total = {k: sum(r[k] for r in repos.values()) for k in ("min", "pool", "gross", "net")}
    dim = calendar.monthrange(now.year, now.month)[1]
    elapsed = (now - now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)).total_seconds() / 86400
    can_project = elapsed >= 2
    factor = dim / elapsed if can_project else None
    proj = {k: total[k] * factor for k in total} if can_project else None
    bursts = sorted(((d, repo, m) for (repo, d), m in days.items() if m > burst), reverse=True)
    reasons = []
    if bursts:
        reasons.append(f"{len(bursts)} burst repo-day(s) above {burst:.0f} min")
    if proj and proj["pool"] > pool_free:
        reasons.append(f"projected pool consumption {proj['pool']:.0f} min exceeds the {pool_free:.0f} free minutes")
    if proj and proj["net"] > max_net:
        reasons.append(f"projected net cost ${proj['net']:.2f} exceeds ${max_net:.2f}")
    return {"repos": dict(repos), "total": total, "proj": proj, "dim": dim, "elapsed": elapsed,
            "bursts": bursts, "reasons": reasons, "skus": dict(skus), "pool_free": pool_free,
            "burst": burst, "max_net": max_net}


def render(a, now):
    L = [f"## Actions minutes, {now:%Y-%m} (through {now:%Y-%m-%d %H:%M} UTC)", ""]
    t, p = a["total"], a["proj"]
    pct = 100 * t["pool"] / a["pool_free"]
    L.append(f"Pool (every repo counts, operator rule): **{t['pool']:.0f}** weighted min of {a['pool_free']:.0f} free = **{pct:.0f}%**."
             + (f" Projected month end: **{p['pool']:.0f}** min, net **${p['net']:.2f}**." if p else " Projection starts on day 3 of the month."))
    L += ["", "| Repo | Minutes | Pool min (weighted) | Gross $ | Net $ | Projected pool min |", "|---|---:|---:|---:|---:|---:|"]
    f = a["dim"] / a["elapsed"] if p else None
    for name, r in sorted(a["repos"].items(), key=lambda kv: -kv[1]["pool"]):
        L.append(f"| {name} | {r['min']:.0f} | {r['pool']:.0f} | {r['gross']:.2f} | {r['net']:.2f} | {r['pool'] * f:.0f} |" if f
                 else f"| {name} | {r['min']:.0f} | {r['pool']:.0f} | {r['gross']:.2f} | {r['net']:.2f} | n/a |")
    L.append(f"| **Total** | {t['min']:.0f} | {t['pool']:.0f} | {t['gross']:.2f} | {t['net']:.2f} | " + (f"{p['pool']:.0f} |" if p else "n/a |"))
    L += ["", f"Burst days (one repo, one day, above {a['burst']:.0f} weighted min): " + ("none" if not a["bursts"] else "")]
    for d, repo, m in a["bursts"][:15]:
        L.append(f"- {d} {repo}: {m:.0f} min")
    L += ["", "Runner SKUs (minutes): " + ", ".join(f"{k} {v:.0f}" for k, v in sorted(a["skus"].items(), key=lambda kv: -kv[1])), ""]
    L.append("**Thresholds exceeded:** " + ("; ".join(a["reasons"]) if a["reasons"] else "none"))
    return "\n".join(L) + "\n"


def main(argv):
    path = argv[1]
    now = datetime.now(timezone.utc)
    body_file = None
    args = argv[2:]
    while args:
        k = args.pop(0)
        if k == "--issue-body":
            body_file = args.pop(0)
        elif k == "--now":
            now = datetime.fromisoformat(args.pop(0).replace("Z", "+00:00"))
    env = os.environ.get
    a = analyse(json.load(open(path)), now, float(env("POOL_FREE_MIN", 2000)), float(env("BURST_DAY_MIN", 500)),
                float(env("MAX_PROJECTED_NET_USD", 15)))
    md = render(a, now)
    print(md)
    if body_file:
        open(body_file, "w").write(md + "\nOpened and refreshed by `actions-minutes-report.yml`. Closed automatically when no threshold is exceeded.\n")
    out = env("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as fh:
            fh.write(f"alert={'true' if a['reasons'] else 'false'}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
