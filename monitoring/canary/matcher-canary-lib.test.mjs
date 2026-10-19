import assert from 'node:assert/strict';
import test from 'node:test';
import { AMOUNT, PRICE, findSettlement, matcherFee, orderParams, roles } from './matcher-canary-lib.mjs';

test('roles alternate by hour', () => {
  assert.deepEqual(roles(0), { seller: 'A', buyer: 'B' });
  assert.deepEqual(roles(13), { seller: 'B', buyer: 'A' });
});

test('matcherFee reads the dynamic base fee and rejects garbage', () => {
  assert.equal(matcherFee({ orderFee: { dynamic: { baseFee: 300000 } } }), 300000);
  assert.throws(() => matcherFee({ orderFee: {} }));
  assert.throws(() => matcherFee(undefined));
});

test('orderParams builds a v3 DCC-priced limit order', () => {
  const o = orderParams({ side: 'sell', assetId: 'Asset1', matcherPublicKey: 'MPK', fee: 300000 });
  assert.deepEqual(o, {
    amount: AMOUNT, amountAsset: 'Asset1', matcherFee: 300000, matcherPublicKey: 'MPK',
    orderType: 'sell', price: PRICE, priceAsset: null, version: 3,
  });
  assert.throws(() => orderParams({ side: 'hold', assetId: 'a', matcherPublicKey: 'm', fee: 1 }));
});

test('findSettlement matches an exchange tx carrying both orders', () => {
  const txs = [[
    { type: 4, id: 't1' },
    { type: 7, id: 'x1', order1: { id: 'o1' }, order2: { id: 'zz' } },
    { type: 7, id: 'x2', order1: { id: 'o2' }, order2: { id: 'o1' } },
  ]];
  assert.equal(findSettlement(txs, 'o1', 'o2')?.id, 'x2');
  assert.equal(findSettlement(txs, 'o1', 'o3'), undefined);
  assert.equal(findSettlement(undefined, 'a', 'b'), undefined);
});
