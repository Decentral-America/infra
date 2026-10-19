// One-time setup for matcher-canary.mjs (run by an operator, see the plan task).
// Issues the CANARY asset from account A, gives account B half of it plus 50 DCC.
// Prints the asset id for: gh variable set MATCHER_CANARY_ASSET_ID --repo Decentral-America/infra
// Env: DCC_CANARY_SEED. Never prints seeds.
import { broadcast, issue, transfer, waitForTx } from '@decentralchain/transactions';
import { address } from '@decentralchain/ts-lib-crypto';
import { B_SEED_SUFFIX } from './matcher-canary-lib.mjs';

const NODE = 'https://testnet-node.decentralchain.io/';
const CHAIN_ID = '!';
const SEED_A = process.env.DCC_CANARY_SEED;
if (!SEED_A) { console.error('DCC_CANARY_SEED must be set'); process.exit(1); }
const B = address(SEED_A + B_SEED_SUFFIX, CHAIN_ID);

const iss = issue({
  name: 'DCCCANARY', description: 'matcher settlement canary (infra matcher-canary.yml)',
  quantity: 1_000_000 * 1e8, decimals: 8, reissuable: false, chainId: CHAIN_ID,
}, SEED_A);
await broadcast(iss, NODE);
await waitForTx(iss.id, { apiBase: NODE, timeout: 180_000 });
console.log(`issued asset ${iss.id}`);
for (const t of [
  transfer({ recipient: B, amount: 500_000 * 1e8, assetId: iss.id, chainId: CHAIN_ID }, SEED_A),
  transfer({ recipient: B, amount: 50 * 1e8, chainId: CHAIN_ID }, SEED_A),
]) {
  await broadcast(t, NODE);
  await waitForTx(t.id, { apiBase: NODE, timeout: 180_000 });
  console.log(`transfer ${t.id} confirmed`);
}
console.log(`account A: ${address(SEED_A, CHAIN_ID)}  account B: ${B}`);
console.log(`MATCHER_CANARY_ASSET_ID=${iss.id}`);
