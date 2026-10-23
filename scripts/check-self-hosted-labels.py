#!/usr/bin/env python3
"""Fails if any PUBLIC repository of the org targets the matcher CI self-hosted runners.

The runner host (terraform/modules/matcher-ci-runner) executes untrusted pull-request code on hardware
we own; GitHub's guidance is to never let public repositories use self-hosted runners. The runners are
registered at REPOSITORY level on the private matcher repository (so GitHub would never assign them a
public repo's job anyway); this guard is the second line: it keeps the label out of every public
workflow, so a later move to org-level registration cannot silently expose them.

A workflow is rejected when any string value in it (runs-on, a matrix entry, a reusable-workflow input,
an expression) has a reserved label as a whole token, or when `self-hosted` appears under a `runs-on` key or
as a whole value. Tokens are runs of [A-Za-z0-9_./-], so file paths such as `matcher-ci-runner/` or
`matcher-ci.nft` are not labels. Comments are ignored (the YAML is parsed).

  check-self-hosted-labels.py --org Decentral-America          # every public repo, via the API
  check-self-hosted-labels.py --path DIR [--path DIR ...]       # local workflow directories (tests, pre-push)
Exit 1 on a violation, 2 on an API/parse error. GH_TOKEN (optional) raises the API rate limit.
"""
import argparse
import base64
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

import yaml

RESERVED_LABELS = ("matcher-ci",)
SELF_HOSTED = "self-hosted"
API = "https://api.github.com"


TOKEN = re.compile(r"[A-Za-z0-9_./-]+")


def violations_in(doc, where, under_runs_on=False):
    """Yields (where, value) for every string that targets the reserved runners."""
    if isinstance(doc, dict):
        for k, v in doc.items():
            yield from violations_in(k, where, under_runs_on)
            yield from violations_in(v, f"{where}.{k}", under_runs_on or k == "runs-on")
    elif isinstance(doc, list):
        for i, v in enumerate(doc):
            yield from violations_in(v, f"{where}[{i}]", under_runs_on)
    elif isinstance(doc, str):
        tokens = {t.lower() for t in TOKEN.findall(doc)}
        if any(label in tokens for label in RESERVED_LABELS) \
           or doc.strip().lower() == SELF_HOSTED or (under_runs_on and SELF_HOSTED in tokens):
            yield where, doc


def check_text(text, name):
    try:
        doc = yaml.safe_load(text)
    except yaml.YAMLError as e:
        raise SystemExit(f"check-self-hosted-labels: cannot parse {name}: {e}")
    return [(name, w, v) for w, v in violations_in(doc, "$")]


def gh(path):
    req = urllib.request.Request(f"{API}/{path}", headers={"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"})
    tok = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if tok:
        req.add_header("Authorization", f"Bearer {tok}")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def org_workflows(org):
    page = 1
    while True:
        repos = gh(f"orgs/{org}/repos?type=public&per_page=100&page={page}")
        if not repos:
            return
        for repo in repos:
            if repo.get("private") or repo.get("archived"):
                continue
            name = repo["full_name"]
            try:
                entries = gh(f"repos/{name}/contents/.github/workflows")
            except urllib.error.HTTPError as e:
                if e.code == 404:
                    continue
                raise
            for ent in entries:
                if ent["type"] == "file" and ent["name"].endswith((".yml", ".yaml")):
                    blob = gh(f"repos/{name}/contents/{ent['path']}?ref={repo['default_branch']}")
                    yield f"{name}/{ent['path']}", base64.b64decode(blob["content"]).decode("utf-8", "replace")
        page += 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--org")
    ap.add_argument("--path", action="append", default=[])
    a = ap.parse_args()
    if not a.org and not a.path:
        ap.error("--org or --path is required")

    found, scanned = [], 0
    try:
        sources = list(org_workflows(a.org)) if a.org else []
    except urllib.error.URLError as e:
        print(f"check-self-hosted-labels: GitHub API error: {e}", file=sys.stderr)
        return 2
    for d in a.path:
        for f in sorted(Path(d).glob("*.y*ml")):
            sources.append((str(f), f.read_text(encoding="utf-8")))
    for name, text in sources:
        scanned += 1
        found += check_text(text, name)

    for name, where, value in found:
        print(f"::error file={name}::public workflow targets the matcher self-hosted runners at {where}: {value!r}")
    print(f"check-self-hosted-labels: {scanned} workflow file(s) scanned, {len(found)} violation(s)")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
