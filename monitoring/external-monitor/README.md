# dcc-ops-monitor

Cloudflare Worker: HTTPS-to-SMTP alert relay (`POST /alert`) and external uptime monitor (cron every 5 minutes,
`GET /status`). Plain JavaScript, no dependencies. Full description, monitor list and deploy steps:
[`../EXTERNAL-UPTIME.md`](../EXTERNAL-UPTIME.md).

Secrets (never in git): `SMTP_PASSWORD`, `ALERT_RELAY_TOKEN` via `wrangler secret put`.
Vars are in `wrangler.toml`. KV binding `STATE` holds per-target state.
Deploy: `npx wrangler@4 deploy` from this directory.
