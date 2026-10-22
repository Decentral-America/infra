// Matcher order -> match -> on-chain settlement canary (AUD-043).
// Places a crossing sell and buy for 1 CANARY @ 0.01 DCC from two canary accounts,
// waits until the matcher reports both Filled, then waits for the ExchangeTransaction
// carrying both orders on the main node. Exit 0 = settled; 1 = failed; 3 = unfunded.
// Env: DCC_CANARY_SEED (account A), MATCHER_CANARY_ASSET_ID (issued by matcher-canary-setup.mjs).
import { cancelOrder, cancelSubmittedOrder, order, submitOrder } from '@decentralchain/transactions';
import { address } from '@decentralchain/ts-lib-crypto';
import { B_SEED_SUFFIX, AMOUNT, PRICE, findSettlement, matcherFee, orderParams, roles } from './matcher-canary-lib.mjs';

const NODE = 'https://testnet-node.decentralchain.io';
const MATCHER = 'https://testnet-matcher.decentralchain.io';
const CHAIN_ID = '!';
const SEED_A = process.env.DCC_CANARY_SEED;
const ASSET = process.env.MATCHER_CANARY_ASSET_ID;
if (!SEED_A || !ASSET) {
  console.error('matcher canary: DCC_CANARY_SEED and MATCHER_CANARY_ASSET_ID must be set');
  process.exit(1);
}
const SEED_B = SEED_A + B_SEED_SUFFIX;
const seeds = { A: SEED_A, B: SEED_B };

async function getJson(url) {
  const res = await fetch(url, { signal: AbortSignal.timeout(15_000) });
  if (!res.ok) throw new Error(`GET ${url} -> HTTP ${res.status}`);
  return res.json();
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const { seller, buyer } = roles(new Date().getUTCHours());
const addr = { A: address(SEED_A, CHAIN_ID), B: address(SEED_B, CHAIN_ID) };
const settings = await getJson(`${MATCHER}/matcher/settings`);
const fee = matcherFee(settings);
const matcherPublicKey = settings.matcherPublicKey;

// Funding guard: the buyer needs DCC for price + fee, the seller needs the asset + fee in DCC.
const dcc = async (a) => Number((await getJson(`${NODE}/addresses/balance/${a}`)).balance);
const asset = async (a) => Number((await getJson(`${NODE}/assets/balance/${a}/${ASSET}`)).balance);
const need = PRICE + 10 * fee;
if ((await dcc(addr[buyer])) < need || (await dcc(addr[seller])) < 10 * fee || (await asset(addr[seller])) < AMOUNT) {
  console.error(`matcher canary: CANARY_UNFUNDED seller=${addr[seller]} buyer=${addr[buyer]} (re-run matcher-canary-setup.mjs funding)`);
  process.exit(3);
}

const sell = order(orderParams({ side: 'sell', assetId: ASSET, matcherPublicKey, fee }), seeds[seller]);
const buy = order(orderParams({ side: 'buy', assetId: ASSET, matcherPublicKey, fee }), seeds[buyer]);
const start = Date.now();
const placed = [];
async function cleanup() {
  for (const [o, seed] of placed) {
    try {
      await cancelSubmittedOrder(cancelOrder({ orderId: o.id }, seed), ASSET, 'DCC', MATCHER);
    } catch { /* already filled or gone */ }
  }
}
try {
  for (const [o, seed] of [[sell, seeds[seller]], [buy, seeds[buyer]]]) {
    const r = await submitOrder(o, MATCHER);
    if (r?.status !== 'OrderAccepted') throw new Error(`order ${o.id} not accepted: ${JSON.stringify(r)}`);
    placed.push([o, seed]);
  }
  for (let i = 0; ; i++) {
    const st = await Promise.all([sell, buy].map((o) => getJson(`${MATCHER}/matcher/orderbook/${ASSET}/DCC/${o.id}`)));
    if (st.every((s) => s.status === 'Filled')) break;
    if (i >= 18) throw new Error(`orders not Filled after 90s: ${st.map((s) => s.status).join(',')}`);
    await sleep(5_000);
  }
  const filledMs = Date.now() - start;
  for (let i = 0; ; i++) {
    const tx = findSettlement(await getJson(`${NODE}/transactions/address/${addr.B}/limit/25`), sell.id, buy.id);
    if (tx) {
      console.log(`matcher canary OK: filled in ${filledMs}ms, ExchangeTransaction ${tx.id} at height ${tx.height} after ${Date.now() - start}ms`);
      process.exit(0);
    }
    if (i >= 36) throw new Error('no ExchangeTransaction with both orders on chain after 180s');
    await sleep(5_000);
  }
} catch (err) {
  console.error(`matcher canary FAILED: ${err?.message ?? err}`);
  await cleanup();
  process.exit(1);
}
