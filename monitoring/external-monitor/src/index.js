// dcc-ops-monitor: (A) POST /alert, Alertmanager webhook -> SMTP over implicit TLS (Linode blocks
// outbound SMTP, so the VPS relays through this Worker); (B) cron uptime monitor of public endpoints.
// No dependencies. Secrets: SMTP_PASSWORD, ALERT_RELAY_TOKEN. State: KV binding STATE.
import { connect } from 'cloudflare:sockets';

const TARGETS = [
  { name: 'testnet-node', url: 'https://testnet-node.decentralchain.io/blocks/height', keyword: 'height' },
  { name: 'testnet-data-service', url: 'https://testnet-data-service.decentralchain.io/v0', keyword: 'version' },
  { name: 'testnet-matcher', url: 'https://testnet-matcher.decentralchain.io/matcher/settings', keyword: 'matcherPublicKey' },
  { name: 'testnet-explorer', url: 'https://testnet.decentralscan.com/', keyword: '<html' },
  { name: 'testnet-exchange', url: 'https://testnet.decentral.exchange/', keyword: '<html' },
  { name: 'testnet-grafana', url: 'https://grafana.testnet.decentralchain.io/api/health', keyword: 'database' },
  { name: 'mainnet-node', url: 'https://mainnet-node.decentralchain.io/node/version', keyword: 'version' },
  { name: 'mainnet-exchange', url: 'https://decentral.exchange/', keyword: '<html' },
  { name: 'mainnet-explorer', url: 'https://decentralscan.com/', keyword: '<html' },
  { name: 'docs', url: 'https://docs.decentralchain.io/', keyword: '<html' },
];

const CHECK_TIMEOUT_MS = 10_000;
const FAILS_BEFORE_ALERT = 2;
const REALERT_MS = 6 * 3600 * 1000;
const SMTP_TIMEOUT_MS = 15_000;

// ---------- helpers ----------
function timingSafeEqual(a, b) {
  const enc = new TextEncoder();
  const x = enc.encode(a), y = enc.encode(b);
  // Pad to equal length so the loop time does not depend on where the inputs differ.
  const n = Math.max(x.length, y.length);
  let diff = x.length ^ y.length;
  for (let i = 0; i < n; i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

function authorized(request, env) {
  const m = /^Bearer (.+)$/.exec(request.headers.get('Authorization') || '');
  return !!(m && env.ALERT_RELAY_TOKEN && timingSafeEqual(m[1], env.ALERT_RELAY_TOKEN));
}

const withTimeout = (p, ms, what) =>
  Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error(`${what} timeout`)), ms))]);

// Header values must never carry CR/LF (header injection).
const oneLine = (s) => String(s).replace(/[\r\n]+/g, ' ').slice(0, 300);

// ---------- SMTP ----------
export async function sendMail(env, { subject, text }) {
  const socket = connect({ hostname: env.SMTP_HOST, port: Number(env.SMTP_PORT) }, { secureTransport: 'on', allowHalfOpen: false });
  const reader = socket.readable.getReader();
  const writer = socket.writable.getWriter();
  const enc = new TextEncoder(), dec = new TextDecoder();
  let buf = '';

  // Read one full (possibly multi-line) SMTP reply; returns [code, text].
  async function reply() {
    for (;;) {
      const lines = buf.split('\r\n');
      // A reply is complete when a line "NNN " (space, not dash) is followed by CRLF.
      for (let i = 0; i < lines.length - 1; i++) {
        if (/^\d{3} /.test(lines[i]) || /^\d{3}$/.test(lines[i])) {
          const out = lines.slice(0, i + 1).join('\n');
          buf = lines.slice(i + 1).join('\r\n');
          return [Number(out.slice(0, 3)), out];
        }
      }
      const { value, done } = await reader.read();
      if (done) throw new Error('smtp connection closed');
      buf += dec.decode(value, { stream: true });
    }
  }
  async function step(cmd, ok, label, log = true) {
    if (cmd !== null) await writer.write(enc.encode(cmd + '\r\n'));
    const [code] = await reply();
    if (!ok.includes(code)) throw new Error(`smtp ${label} failed (${code})`);
    return code;
  }

  const run = async () => {
    await step(null, [220], 'greeting');
    await step('EHLO dcc-ops-monitor.workers.dev', [250], 'EHLO');
    await step('AUTH LOGIN', [334], 'AUTH');
    await step(btoa(env.SMTP_USER), [334], 'AUTH user');
    await step(btoa(env.SMTP_PASSWORD), [235], 'AUTH pass');
    await step(`MAIL FROM:<${env.MAIL_FROM}>`, [250], 'MAIL FROM');
    await step(`RCPT TO:<${env.MAIL_TO}>`, [250, 251], 'RCPT TO');
    await step('DATA', [354], 'DATA');
    const body = String(text).replace(/\r\n|\r|\n/g, '\n').split('\n')
      .map((l) => (l.startsWith('.') ? '.' + l : l)).join('\r\n');
    const msg =
      `From: DCC Ops Monitor <${env.MAIL_FROM}>\r\nTo: ${env.MAIL_TO}\r\n` +
      `Subject: ${oneLine(subject)}\r\nDate: ${new Date().toUTCString()}\r\n` +
      `Message-ID: <${crypto.randomUUID()}@dcc-ops-monitor>\r\n` +
      `MIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n` +
      `${body}\r\n.`;
    await step(msg, [250], 'message');
    try { await writer.write(enc.encode('QUIT\r\n')); } catch { /* best effort */ }
  };
  try {
    await withTimeout(run(), SMTP_TIMEOUT_MS, 'smtp');
  } finally {
    try { socket.close(); } catch { /* already closed */ }
  }
}

// ---------- (A) Alertmanager webhook -> email ----------
function buildAlertMail(p) {
  const alerts = Array.isArray(p.alerts) ? p.alerts : [];
  const cl = p.commonLabels || {};
  const firing = alerts.filter((a) => a.status === 'firing').length;
  const status = p.status === 'resolved' ? 'RESOLVED' : `FIRING:${firing || alerts.length}`;
  const subject = `[${status}] ${cl.alertname || 'alert'} ${cl.network || '-'} (${cl.severity || '-'})`;
  const parts = alerts.map((a, i) => {
    const l = a.labels || {}, an = a.annotations || {};
    const lines = [`#${i + 1} ${a.status || p.status || ''} ${l.alertname || ''}`.trim()];
    lines.push('Labels:');
    for (const k of Object.keys(l).sort()) lines.push(`  ${k}=${l[k]}`);
    if (an.summary) lines.push(`Summary: ${an.summary}`);
    if (an.description) lines.push(`Description: ${an.description}`);
    if (a.startsAt) lines.push(`Started: ${a.startsAt}`);
    if (a.status === 'resolved' && a.endsAt) lines.push(`Ended: ${a.endsAt}`);
    if (a.generatorURL) lines.push(`Source: ${a.generatorURL}`);
    return lines.join('\n');
  });
  const text = [`Status: ${p.status}`, `Alerts: ${alerts.length}`, p.externalURL ? `Alertmanager: ${p.externalURL}` : '', '', ...parts.map((s) => s + '\n')]
    .join('\n');
  return { subject, text };
}

async function handleAlert(request, env) {
  let payload;
  try { payload = await request.json(); } catch { return new Response('bad json\n', { status: 400 }); }
  if (!payload || typeof payload !== 'object' || !Array.isArray(payload.alerts) || !payload.status) {
    return new Response('not an alertmanager webhook payload\n', { status: 400 });
  }
  try {
    await sendMail(env, buildAlertMail(payload));
  } catch (e) {
    console.error('alert relay failed', e.message);
    return new Response(`smtp failure: ${e.message}\n`, { status: 502 });
  }
  return new Response('ok\n');
}

// ---------- (B) uptime monitor ----------
async function check(t) {
  const started = Date.now();
  try {
    const r = await fetch(t.url, { signal: AbortSignal.timeout(CHECK_TIMEOUT_MS), redirect: 'follow', headers: { 'User-Agent': 'dcc-ops-monitor/1' } });
    const body = (await r.text()).slice(0, 1_000_000);
    if (!r.ok) return { ok: false, reason: `HTTP ${r.status}`, ms: Date.now() - started };
    if (!body.toLowerCase().includes(t.keyword.toLowerCase())) return { ok: false, reason: `keyword "${t.keyword}" missing`, ms: Date.now() - started };
    return { ok: true, reason: `HTTP ${r.status}`, ms: Date.now() - started };
  } catch (e) {
    return { ok: false, reason: oneLine(e.name === 'TimeoutError' ? 'timeout 10s' : e.message), ms: Date.now() - started };
  }
}

async function runMonitor(env, targets = TARGETS, now = Date.now()) {
  const results = await Promise.all(targets.map(async (t) => [t, await check(t)]));
  const mails = [];
  for (const [t, r] of results) {
    const key = `target:${t.name}`;
    const prev = (await env.STATE.get(key, 'json')) || { status: 'up', failures: 0, since: new Date(now).toISOString(), lastAlert: 0 };
    const st = { ...prev, url: t.url, lastCheck: new Date(now).toISOString(), lastReason: r.reason, lastMs: r.ms };
    if (r.ok) {
      if (prev.status === 'down' && prev.alerted) {
        mails.push({ subject: `[RECOVERED] ${t.name} is UP`, text: `${t.name} (${t.url}) is reachable again.\nDown since: ${prev.since}\nRecovered: ${st.lastCheck}\nCheck: ${r.reason} in ${r.ms} ms\n` });
      }
      if (prev.status !== 'up') st.since = st.lastCheck;
      Object.assign(st, { status: 'up', failures: 0, alerted: false, lastAlert: 0 });
    } else {
      st.failures = prev.failures + 1;
      if (prev.status !== 'down' && st.failures >= FAILS_BEFORE_ALERT) { st.status = 'down'; st.since = st.lastCheck; }
      if (st.failures >= FAILS_BEFORE_ALERT && now - (prev.lastAlert || 0) >= REALERT_MS) {
        mails.push({ subject: `[DOWN] ${t.name} (${t.url})`, text: `${t.name} failed ${st.failures} consecutive checks (every 5 min).\nURL: ${t.url}\nReason: ${r.reason}\nDown since: ${st.since}\nChecked from Cloudflare, independent of the Linode account.\nNo further email for this target for 6 hours unless it recovers.\n` });
        st.lastAlert = now;
        st.alerted = true;
      }
    }
    await env.STATE.put(key, JSON.stringify(st));
  }
  for (const m of mails) {
    try { await sendMail(env, m); } catch (e) { console.error('monitor mail failed', e.message); }
  }
  return results.map(([t, r]) => ({ name: t.name, ...r }));
}

async function handleStatus(env) {
  const out = {};
  for (const t of TARGETS) out[t.name] = (await env.STATE.get(`target:${t.name}`, 'json')) || { status: 'unknown' };
  return Response.json({ now: new Date().toISOString(), targets: out });
}

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);
    if (pathname !== '/alert' && pathname !== '/status') return new Response('not found\n', { status: 404 });
    if (!authorized(request, env)) return new Response('unauthorized\n', { status: 401 });
    if (pathname === '/alert') return request.method === 'POST' ? handleAlert(request, env) : new Response('method not allowed\n', { status: 405 });
    return request.method === 'GET' ? handleStatus(env) : new Response('method not allowed\n', { status: 405 });
  },
  async scheduled(_event, env, ctx) {
    ctx.waitUntil(runMonitor(env));
  },
};
