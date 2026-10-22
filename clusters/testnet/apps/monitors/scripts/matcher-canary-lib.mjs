// Pure helpers for matcher-canary.mjs (no network, no signing) so they can be unit-tested
// with `node --test clusters/testnet/apps/monitors/scripts/`.

// Second canary account: a deterministic sibling of DCC_CANARY_SEED, funded once by
// matcher-canary-setup.mjs. A self-trade (same sender on both sides) is not used, so the
// canary exercises exactly what two real traders do.
export const B_SEED_SUFFIX = ' matcher-canary-b';

// 1.00000000 CANARY (8 decimals) at 0.01 DCC. Order v1-3 price is normalised by
// 10^(8 + priceDecimals - amountDecimals) = 10^8 here, so 0.01 DCC -> 1_000_000.
export const AMOUNT = 100_000_000;
export const PRICE = 1_000_000;

// Alternate who sells each hour so neither account drains: only matcher fees are spent.
export function roles(hourUtc) {
  return hourUtc % 2 === 0 ? { seller: 'A', buyer: 'B' } : { seller: 'B', buyer: 'A' };
}

export function matcherFee(settings) {
  const base = settings?.orderFee?.dynamic?.baseFee;
  if (!Number.isInteger(base) || base <= 0) {
    throw new Error(`matcher settings have no positive orderFee.dynamic.baseFee: ${JSON.stringify(settings?.orderFee)}`);
  }
  return base;
}

export function orderParams({ side, assetId, matcherPublicKey, fee }) {
  if (side !== 'buy' && side !== 'sell') throw new Error(`bad side ${side}`);
  return {
    amount: AMOUNT,
    amountAsset: assetId,
    matcherFee: fee,
    matcherPublicKey,
    orderType: side,
    price: PRICE,
    priceAsset: null,
    version: 3,
  };
}

// node GET /transactions/address/{a}/limit/{n} returns [[tx, ...]].
export function findSettlement(addressTxs, orderIdA, orderIdB) {
  const flat = (addressTxs ?? []).flat();
  return flat.find((tx) => {
    if (tx?.type !== 7) return false;
    const ids = [tx.order1?.id, tx.order2?.id];
    return ids.includes(orderIdA) && ids.includes(orderIdB);
  });
}
