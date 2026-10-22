// Canary transaction (Tier 6 synthetic monitoring). Signs, broadcasts and waits for confirmation of a
// minimal self-transfer from the canary wallet on the live testnet.
// Exit 0 = confirmed; 1 = failed; 3 = canary wallet unfunded (its own alert, issue #148).
// Env: DCC_CANARY_SEED. Runs in the LKE `canary-transaction` CronJob and, manually, from
// .github/workflows/canary-transaction.yml.
import { transfer, broadcast, waitForTx } from '@decentralchain/transactions';
import { address } from '@decentralchain/ts-lib-crypto';

const API_BASE = 'https://testnet-node.decentralchain.io/';
const CHAIN_ID = '!'; // matches DCC_TEST_CHAIN_ID used elsewhere in this project's E2E config
const SEED = process.env.DCC_CANARY_SEED;

if (!SEED) {
  console.error('Canary tx failed: DCC_CANARY_SEED is not set');
  process.exit(1);
}

// Self-transfer: avoids needing a second funded account to maintain.
const recipient = address(SEED, CHAIN_ID);

const start = Date.now();
const tx = transfer({ amount: 100_000, chainId: CHAIN_ID, recipient }, SEED);

// Unfunded-wallet guard (issue #148): an empty canary wallet gets its own alert (exit 3), not the
// generic network-failure one. If the balance read itself fails, the node is the problem, so that
// stays the generic failure (exit 1).
const MIN_BALANCE = 10 * Number(tx.fee);
let bal;
try {
  const res = await fetch(`${API_BASE}addresses/balance/${recipient}`, { signal: AbortSignal.timeout(15_000) });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  bal = Number((await res.json()).balance);
  if (!Number.isFinite(bal)) throw new Error('balance field missing or not a number');
} catch (err) {
  console.error(`Canary tx failed: balance lookup for ${recipient} failed: ${err?.message ?? err}`);
  process.exit(1);
}
if (bal < MIN_BALANCE) {
  console.error(`Canary tx failed: CANARY_UNFUNDED balance=${bal} min=${MIN_BALANCE} address=${recipient}`);
  process.exit(3);
}

try {
  await broadcast(tx, API_BASE);
  const confirmed = await waitForTx(tx.id, { apiBase: API_BASE, timeout: 120_000 });
  const latencyMs = Date.now() - start;
  console.log(`Canary tx ${tx.id} confirmed at height ${confirmed.height} in ${latencyMs}ms`);
  process.exit(0);
} catch (err) {
  console.error(`Canary tx failed: ${err?.message ?? err}`);
  process.exit(1);
}
