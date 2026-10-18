#!/usr/bin/env bash
# Structural checks on compose files that unit tests elsewhere cannot see.
# Run: bash scripts/tests/compose-services.test.sh   (needs python3 + PyYAML)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "${ROOT}" <<'PY'
import sys, yaml
root = sys.argv[1]
def load(name):
    return yaml.safe_load(open(f"{root}/compose/{name}"))["services"]

ds = load("data-service.yml")
assert set(ds) == {"data-service", "pairs-daemon"}, f"data-service.yml services: {sorted(ds)}"
p, d = ds["pairs-daemon"], ds["data-service"]
assert p["command"] == ["node", "dist/daemons/pairs/index.mjs"], p["command"]
assert p["image"] == d["image"], "pairs-daemon must run the data-service image"
assert p["env_file"] == d["env_file"], "pairs-daemon must use the data-service env file"
assert p["network_mode"] == "host"
assert p["environment"]["PGSTATEMENTTIMEOUT"] == d["environment"]["PGSTATEMENTTIMEOUT"] == "25000"
print("PASS compose-services")
PY
