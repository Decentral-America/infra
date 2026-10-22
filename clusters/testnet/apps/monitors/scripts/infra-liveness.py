#!/usr/bin/env python3
"""Infra liveness (Tier 0), run in-cluster by the LKE `infra-liveness` CronJob every 30 min.

Pages on a dead testnet regardless of wallet balances (the 2026-09-17 outage went unnoticed for 6+
days). Checks, all of them every run so one alert reports every broken half:
  1. main node height advances (two samples WAIT_SECONDS apart; running in-cluster, the wait is free)
  2. every LKE node is Ready (Kubernetes API; replaces the Linode pool API call)
  3. every Flux Kustomization is Ready (suspended ones only warn: staggered rollouts suspend on
     purpose, runbooks/staggered-node-rollout.md) and flux-system controller pods are ready
On failure it opens ONE alert issue (title below, same as the old workflow), via the same
create-only GitHub token the canaries use.

NOT checked here, because it cannot be seen from the cluster: Alertmanager holds `Watchdog` and
alert-webhook is healthy (both on the VPS). That deadman stays off-box in
.github/workflows/infra-liveness.yml (every 3 h), together with a check that these CronJobs still run.
Stdlib only (python:3.14-slim, read-only root filesystem).
"""
import json
import os
import ssl
import sys
import time
import urllib.request

TITLE = "[ALERT] InfraLiveness: testnet liveness, alerting deadman or Flux check failed"
PREFIX = "[ALERT] InfraLiveness"
SA = "/var/run/secrets/kubernetes.io/serviceaccount"


def http_json(url, headers=None, method="GET", body=None, cafile=None, timeout=15):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    ctx = ssl.create_default_context(cafile=cafile) if cafile else None
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
        return r.status, json.loads(r.read() or b"null")


def check_height(get_height, sleep, wait):
    h1 = get_height()
    sleep(wait)
    h2 = get_height()
    print(f"main node height h1={h1} h2={h2}")
    if not h2 > h1:
        return [f"main node height did not advance ({h1} -> {h2})"]
    return []


def check_nodes(items):
    bad = []
    for n in items:
        ready = next((c for c in n.get("status", {}).get("conditions", []) if c.get("type") == "Ready"), {})
        print(f"node {n['metadata']['name']}: Ready={ready.get('status')}")
        if ready.get("status") != "True":
            bad.append(f"LKE node {n['metadata']['name']} not Ready ({ready.get('reason')})")
    if not items:
        bad.append("no LKE nodes returned by the Kubernetes API")
    return bad


def check_flux(kustomizations, pods):
    bad = []
    for k in kustomizations:
        name = k["metadata"]["name"]
        if k.get("spec", {}).get("suspend"):
            print(f"warning: Kustomization {name} is SUSPENDED (expected only during a staggered rollout)")
            continue
        ready = next((c for c in k.get("status", {}).get("conditions", []) if c.get("type") == "Ready"), {})
        print(f"{name}: Ready={ready.get('status')} rev={k.get('status', {}).get('lastAppliedRevision', '?')}")
        if ready.get("status") != "True":
            bad.append(f"Flux Kustomization {name} not Ready: {ready.get('reason')} {str(ready.get('message', ''))[:200]}")
    for p in pods:
        cs = (p.get("status", {}).get("containerStatuses") or [{}])[0]
        # AUD-195: controller restarts are recorded on every run (the 45h co-restart was never explained).
        print(f"pod {p['metadata']['name']}: ready={cs.get('ready')} restarts={cs.get('restartCount')}")
        if cs.get("ready") is not True:
            bad.append(f"flux-system pod {p['metadata']['name']} not ready")
    return bad


def raise_alert(failures, post_json, get_json, repo, run_ref):
    """Create the alert issue unless one is already open. Returns 'created' / 'exists'."""
    _, issues = get_json(f"https://api.github.com/repos/{repo}/issues?state=open&per_page=100")
    for i in issues:
        if "pull_request" not in i and i.get("title", "").startswith(PREFIX):
            return "exists", i["number"]
    body = (
        "## HIGH — testnet liveness check failed\n\n**Network:** testnet\n**Alert:** `InfraLiveness`\n"
        "**Severity:** high\n**Run:** " + run_ref + "\n\n" + "\n".join(f"- {f}" for f in failures)
        + "\n\n> Auto-opened by the in-cluster infra-liveness monitor (clusters/testnet/apps/monitors). Close when resolved."
    )
    status, created = post_json(f"https://api.github.com/repos/{repo}/issues", {"title": TITLE, "body": body})
    if status != 201:
        raise RuntimeError(f"create issue -> HTTP {status}")
    return "created", created["number"]


def main():
    node_url = os.environ.get("NODE_URL", "https://testnet-node.decentralchain.io").rstrip("/")
    repo = os.environ.get("GITHUB_REPO", "Decentral-America/infra")
    wait = int(os.environ.get("WAIT_SECONDS", "150"))
    # KUBE_API is overridden only for a local dry run through `kubectl proxy` (plain http, no token).
    kube = os.environ.get("KUBE_API", "https://kubernetes.default.svc")
    if kube.startswith("https://"):
        kh, cafile = {"Authorization": "Bearer " + open(f"{SA}/token").read().strip()}, f"{SA}/ca.crt"
    else:
        kh, cafile = {}, None

    def kget(path):
        return http_json(kube + path, kh, cafile=cafile)[1]

    def height():
        return int(http_json(f"{node_url}/blocks/height", {"User-Agent": "dcc-infra-liveness"})[1]["height"])

    failures = []
    steps = [
        ("main node height", lambda: check_height(height, time.sleep, wait)),
        ("LKE nodes", lambda: check_nodes(kget("/api/v1/nodes")["items"])),
        ("Flux", lambda: check_flux(
            kget("/apis/kustomize.toolkit.fluxcd.io/v1/namespaces/flux-system/kustomizations")["items"],
            kget("/api/v1/namespaces/flux-system/pods")["items"])),
    ]
    for label, step in steps:
        try:
            failures += step()
        except Exception as e:  # a check that cannot run is a failed check
            failures.append(f"{label} check could not run: {type(e).__name__}: {e}")
    if not failures:
        print("infra liveness OK")
        return 0
    for f in failures:
        print(f"FAIL: {f}")
    gh = {"Authorization": f"Bearer {os.environ['GITHUB_TOKEN']}", "Accept": "application/vnd.github+json",
          "User-Agent": "dcc-in-cluster-monitor", "X-GitHub-Api-Version": "2022-11-28"}
    try:
        action, number = raise_alert(
            failures,
            lambda url, body: http_json(url, gh, "POST", body),
            lambda url: http_json(url, gh),
            repo,
            f"CronJob `infra-liveness`, pod `{os.environ.get('HOSTNAME', '?')}` (namespace dcc)",
        )
        print(f"alert issue #{number} {action}")
    except Exception as e:
        print(f"alert delivery failed: {type(e).__name__}: {e}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
