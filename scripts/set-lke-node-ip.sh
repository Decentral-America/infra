#!/usr/bin/env bash
# Point every config that hardcodes the LKE worker's public IP at a new IP
# (after an LKE worker recycle, see clusters/testnet/RUNBOOK.md Scenario A).
# Rewrites clusters/testnet/apps/nodes.yaml (declared-address x3,
# blacklist-exempt x3, comments) and node-config/testnet/dcc.conf
# (blacklist-exempt), then refreshes the StatefulSet checksum/config
# annotations so Kubernetes rolls the pods.
#
# Usage (from anywhere): scripts/set-lke-node-ip.sh <new-ipv4>
set -euo pipefail
NEW="${1:?usage: set-lke-node-ip.sh <new-ipv4>}"
[[ "${NEW}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "set-lke-node-ip: not an IPv4 address: ${NEW}" >&2; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
NODES=clusters/testnet/apps/nodes.yaml
MAIN_CONF=node-config/testnet/dcc.conf

OLD="$(grep -m1 -oE 'declared-address = "[0-9.]+:6863"' "${NODES}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')"
[[ -n "${OLD}" ]] || { echo "set-lke-node-ip: cannot find gen-0's declared-address in ${NODES}" >&2; exit 1; }
if [[ "${OLD}" == "${NEW}" ]]; then echo "set-lke-node-ip: already ${NEW}"; exit 0; fi

OLD_RE="${OLD//./\\.}"
for f in "${NODES}" "${MAIN_CONF}"; do
  sed -i.bak -E "s/(^|[^0-9.])${OLD_RE}([^0-9]|$)/\\1${NEW}\\2/g" "${f}"
  rm -f "${f}.bak"
done
if grep -qF "${OLD}" "${NODES}" "${MAIN_CONF}"; then
  echo "set-lke-node-ip: ${OLD} still present after rewrite" >&2; exit 1
fi
python3 scripts/config-checksums.py --fix
python3 scripts/config-checksums.py --check
echo "set-lke-node-ip: ${OLD} -> ${NEW} in ${NODES} and ${MAIN_CONF}"
