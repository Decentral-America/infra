#!/usr/bin/env bash
# Retention logic of the dcc-ops-monitor Worker (pruneBackups) against an in-memory R2 stub.
# Run: bash scripts/tests/backup-worker.test.sh. Skipped when node is not installed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v node >/dev/null || { echo "SKIP backup-worker (no node)"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
# The Worker imports cloudflare:sockets (runtime-only); strip it for this pure-logic test.
grep -v "from 'cloudflare:sockets'" "${ROOT}/monitoring/external-monitor/src/index.js" > "${T}/w.mjs"
cat > "${T}/t.mjs" <<'JS'
import { pruneBackups } from './w.mjs';
const keys = [];
for (let d = 1; d <= 10; d++) {
  keys.push(`pg/bps_testnet-202611${String(d).padStart(2, '0')}T031500Z.dump`);
}
keys.push('pg/admin_testnet-20261101T031500Z.dump', 'pg/admin_testnet-20261102T031500Z.dump', 'pg/notes.txt');
const store = new Map(keys.map((k, i) => [k, { key: k, size: 1, uploaded: new Date(1e12 + i * 1000) }]));
const env = { BACKUPS: {
  async list() { return { objects: [...store.values()], truncated: false }; },
  async delete(k) { store.delete(k); },
} };
const deleted = await pruneBackups(env);
const fail = (m) => { console.error('FAIL: ' + m); process.exit(1); };
if (deleted.length !== 3) fail('expected 3 deleted, got ' + deleted.join());
for (const d of ['01', '02', '03']) if (store.has(`pg/bps_testnet-202611${d}T031500Z.dump`)) fail('old dump kept ' + d);
if (!store.has('pg/bps_testnet-20261104T031500Z.dump') || !store.has('pg/bps_testnet-20261110T031500Z.dump')) fail('kept window wrong');
if (!store.has('pg/admin_testnet-20261101T031500Z.dump')) fail('other prefix touched');
if (!store.has('pg/notes.txt')) fail('non-conforming object deleted');
JS
node "${T}/t.mjs"
echo "PASS backup-worker"
