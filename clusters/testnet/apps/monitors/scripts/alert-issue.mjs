// Opens ONE GitHub issue per alert, in the format monitoring/alert-webhook.py and the old canary
// workflows used: title `[ALERT] <Name>: <summary>`, body with **Severity:**. The alert-issues.yml
// workflow labels it (this token can create issues but not label or comment). A still-open issue
// whose title starts with `[ALERT] <Name>` suppresses a duplicate.
// CLI: node alert-issue.mjs <Name> <severity> <summary> [detail-log-file]
// Env: GITHUB_TOKEN, GITHUB_REPO (default Decentral-America/infra), MONITOR_NAME, HOSTNAME.
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const API = 'https://api.github.com';

export function issueBody({ name, severity, summary, detail, runRef }) {
  const tail = detail ? `\n\n<details><summary>Last output</summary>\n\n\`\`\`\n${detail}\n\`\`\`\n</details>` : '';
  return (
    `## ${severity.toUpperCase()} — ${summary}\n\n` +
    `**Network:** testnet\n**Alert:** \`${name}\`\n**Severity:** ${severity}\n**Run:** ${runRef}\n\n` +
    `> Auto-opened by the in-cluster monitor (clusters/testnet/apps/monitors). Close when resolved.${tail}`
  );
}

export async function raiseAlert({ name, severity, summary, detail = '', runRef, repo, token, fetchImpl = fetch }) {
  const headers = {
    Authorization: `Bearer ${token}`,
    Accept: 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'dcc-in-cluster-monitor',
  };
  const prefix = `[ALERT] ${name}`;
  for (let page = 1; page <= 3; page++) {
    const res = await fetchImpl(`${API}/repos/${repo}/issues?state=open&per_page=100&page=${page}`, { headers });
    if (!res.ok) throw new Error(`list issues -> HTTP ${res.status}`);
    const items = await res.json();
    const hit = items.find((i) => !i.pull_request && typeof i.title === 'string' && i.title.startsWith(prefix));
    if (hit) return { action: 'exists', number: hit.number };
    if (items.length < 100) break;
  }
  const res = await fetchImpl(`${API}/repos/${repo}/issues`, {
    method: 'POST',
    headers: { ...headers, 'Content-Type': 'application/json' },
    body: JSON.stringify({ title: `${prefix}: ${summary}`, body: issueBody({ name, severity, summary, detail, runRef }) }),
  });
  if (res.status !== 201) throw new Error(`create issue -> HTTP ${res.status}`);
  return { action: 'created', number: (await res.json()).number };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [name, severity, summary, logFile] = process.argv.slice(2);
  if (!name || !severity || !summary || !process.env.GITHUB_TOKEN) {
    console.error('usage: GITHUB_TOKEN=... node alert-issue.mjs <Name> <severity> <summary> [log-file]');
    process.exit(2);
  }
  let detail = '';
  if (logFile) {
    try {
      detail = readFileSync(logFile, 'utf8').trim().split('\n').slice(-20).join('\n').slice(0, 3000);
    } catch { /* no log */ }
  }
  const runRef = `CronJob \`${process.env.MONITOR_NAME ?? 'unknown'}\`, pod \`${process.env.HOSTNAME ?? 'unknown'}\` (namespace dcc, context in runbooks/in-cluster-monitors.md)`;
  try {
    const r = await raiseAlert({
      name, severity, summary, detail, runRef,
      repo: process.env.GITHUB_REPO ?? 'Decentral-America/infra',
      token: process.env.GITHUB_TOKEN,
    });
    console.log(`alert ${name}: issue #${r.number} ${r.action}`);
  } catch (err) {
    console.error(`alert delivery failed: ${err?.message ?? err}`);
    process.exit(5);
  }
}
