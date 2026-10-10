// Dispatches the testnet health workflows on a reliable schedule (see wrangler.jsonc).
// Every 15 min: canary-transaction.yml. Every 30 min: infra-liveness.yml.

/** Workflows due at this cron tick. */
export function dueWorkflows(scheduledTime) {
  const minute = new Date(scheduledTime).getUTCMinutes();
  const due = ['canary-transaction.yml'];
  if (minute % 30 < 15) due.push('infra-liveness.yml');
  return due;
}

async function dispatch(env, workflow) {
  const res = await fetch(
    `https://api.github.com/repos/${env.GITHUB_REPO}/actions/workflows/${workflow}/dispatches`,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.GITHUB_TOKEN}`,
        Accept: 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'dcc-liveness-trigger',
      },
      body: JSON.stringify({ ref: 'main' }),
    },
  );
  if (res.status !== 204) {
    throw new Error(`dispatch ${workflow} -> HTTP ${res.status}: ${(await res.text()).slice(0, 200)}`);
  }
  console.log(`dispatched ${workflow}`);
}

export default {
  async scheduled(event, env) {
    if (!env.GITHUB_TOKEN) throw new Error('GITHUB_TOKEN secret is not set');
    const results = await Promise.allSettled(dueWorkflows(event.scheduledTime).map((w) => dispatch(env, w)));
    const failed = results.filter((r) => r.status === 'rejected');
    // A thrown error marks the cron invocation as failed in Workers observability.
    if (failed.length) throw new Error(failed.map((f) => f.reason.message).join('; '));
  },
  async fetch() {
    return new Response('dcc-liveness-trigger: cron only\n', { status: 404 });
  },
};
