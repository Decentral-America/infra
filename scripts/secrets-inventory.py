#!/usr/bin/env python3
"""Markdown inventory of the GitHub Actions secrets this repo depends on (NAMES ONLY, never values),
with where each name is referenced across the ecosystem's workflows. Feeds DEPLOY.md sections A-D
and flags unreferenced secrets for cleanup.

Usage:
  scripts/secrets-inventory.py --eco <Ecosystem dir>                  # live: gh secret list (org, infra repo, infra envs)
  scripts/secrets-inventory.py --eco <dir> --names-file <json>        # offline: [{"scope": "...", "name": "...", "updated": "..."}]
"""
import argparse, json, pathlib, re, subprocess, sys

REPOS = ["infra", "node-scala", "matcher", "DecentralChain", "docs"]


def workflow_texts(eco):
    texts = {}
    for repo in REPOS:
        base = pathlib.Path(eco) / repo / ".github"
        if not base.is_dir():
            continue
        for f in sorted(base.rglob("*")):
            if f.suffix in (".yml", ".yaml") and "archived-workflows" not in f.parts:
                texts[f"{repo}:{f.name}"] = f.read_text(errors="ignore")
    return texts


def references(name, texts):
    # GitHub secret names are case-insensitive: `secrets.Foo_bar` resolves FOO_BAR.
    pat = re.compile(r"secrets\.%s\b" % re.escape(name), re.IGNORECASE)
    return sorted(k for k, t in texts.items() if pat.search(t))


def gh_list(*args):
    out = subprocess.run(["gh", "secret", "list", *args, "--json", "name,updatedAt"],
                         check=True, capture_output=True, text=True).stdout
    return json.loads(out or "[]")


def live_names():
    rows = [{"scope": "org", "name": s["name"], "updated": s["updatedAt"][:10]}
            for s in gh_list("--org", "Decentral-America")]
    rows += [{"scope": "infra repo", "name": s["name"], "updated": s["updatedAt"][:10]}
             for s in gh_list("-R", "Decentral-America/infra")]
    envs = json.loads(subprocess.run(["gh", "api", "repos/Decentral-America/infra/environments"],
                                     check=True, capture_output=True, text=True).stdout)["environments"]
    for e in envs:
        rows += [{"scope": f"infra env {e['name']}", "name": s["name"], "updated": s["updatedAt"][:10]}
                 for s in gh_list("-R", "Decentral-America/infra", "--env", e["name"])]
    return rows


def render(rows, texts):
    lines = ["| Scope | Secret | Updated | Referenced by (workflow files; archived excluded) |",
             "|---|---|---|---|"]
    unref = 0
    for r in sorted(rows, key=lambda r: (r["scope"], r["name"])):
        refs = references(r["name"], texts)
        unref += not refs
        lines.append(f"| {r['scope']} | `{r['name']}` | {r['updated']} | {', '.join(refs) if refs else '**unreferenced**'} |")
    lines.append("")
    lines.append(f"{len(rows)} secrets, {unref} unreferenced.")
    return "\n".join(lines) + "\n"


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--eco", required=True)
    ap.add_argument("--names-file")
    a = ap.parse_args(argv)
    rows = json.load(open(a.names_file)) if a.names_file else live_names()
    sys.stdout.write(render(rows, workflow_texts(a.eco)))


if __name__ == "__main__":
    main(sys.argv[1:])
