import { test } from 'node:test';
import assert from 'node:assert/strict';
import { issueBody, raiseAlert } from './alert-issue.mjs';

const base = { name: 'CanaryTransactionFailed', severity: 'high', summary: 's', runRef: 'r', repo: 'o/r', token: 't' };
const json = (status, body) => ({ status, ok: status < 300, json: async () => body });

test('body carries the fields alert-issues.yml parses', () => {
  const b = issueBody({ ...base, detail: 'x' });
  assert.match(b, /^\*\*Severity:\*\* high/m);
  assert.match(b, /\*\*Alert:\*\* `CanaryTransactionFailed`/);
});

test('creates when no open issue matches', async () => {
  const calls = [];
  const fetchImpl = async (url, init = {}) => {
    calls.push([init.method ?? 'GET', url]);
    return init.method === 'POST' ? json(201, { number: 7 }) : json(200, [{ title: '[ALERT] Other: x' }]);
  };
  assert.deepEqual(await raiseAlert({ ...base, fetchImpl }), { action: 'created', number: 7 });
  assert.equal(calls.at(-1)[0], 'POST');
});

test('does not duplicate an open alert, ignores pull requests', async () => {
  const fetchImpl = async () => json(200, [
    { title: '[ALERT] CanaryTransactionFailed: pr', pull_request: {}, number: 1 },
    { title: '[ALERT] CanaryTransactionFailed: real', number: 2 },
  ]);
  assert.deepEqual(await raiseAlert({ ...base, fetchImpl }), { action: 'exists', number: 2 });
});

test('a failed create is an error, not a silent success', async () => {
  const fetchImpl = async (url, init = {}) => (init.method === 'POST' ? json(403, {}) : json(200, []));
  await assert.rejects(raiseAlert({ ...base, fetchImpl }), /HTTP 403/);
});
