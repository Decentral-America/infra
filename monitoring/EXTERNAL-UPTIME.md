# External uptime monitor and alert relay (ECO-63, ECO-70)

One Cloudflare Worker, `dcc-ops-monitor`, in the DCC Cloudflare account. Code: `monitoring/external-monitor/`
(`wrangler.toml`, `src/index.js`, `README.md`). No credentials are in this repository.

## Why

* ECO-63: the Linode VPS cannot open outbound SMTP (Linode default restriction, support ticket 27787085),
  so Alertmanager's own email receiver cannot send. Alertmanager instead posts the webhook to the Worker,
  which sends the mail over SMTPS (port 465, implicit TLS) from Cloudflare.
* ECO-70: an outage of the VPS, LKE or the whole Linode account must be detected from outside Linode.
  GitHub cron is unreliable, so the Worker runs its own cron every 5 minutes.

## Alert relay (`POST /alert`)

Alertmanager receiver `github-and-email` has a second webhook to `https://dcc-ops-monitor.<subdomain>.workers.dev/alert`
with `send_resolved: true` and `Authorization: Bearer` read from `/run/alertmanager/relay_token`
(tmpfs, written by the alertmanager entrypoint in `compose/prometheus.yml` from SOPS key `ALERT_RELAY_TOKEN`).
The Worker checks the token in constant time (401 otherwise), builds a plain-text mail
(`[FIRING:n] alertname network (severity)` or `[RESOLVED] ...`), and relays it to `info@decentralchain.io`.
An SMTP failure returns 502, so Alertmanager retries and increments `alertmanager_notifications_failed_total`
(`AlertmanagerNotificationsFailing`). The smtp_* globals in `alertmanager.yml` are now unused and kept only
as a one-edit fallback.

## Monitors (HTTPS, 10 s timeout, expected keyword, every 5 minutes)

| Name | URL | Keyword |
|---|---|---|
| testnet-node | https://testnet-node.decentralchain.io/blocks/height | `height` |
| testnet-data-service | https://testnet-data-service.decentralchain.io/v0 | `version` |
| testnet-matcher | https://testnet-matcher.decentralchain.io/matcher/settings | `matcherPublicKey` |
| testnet-explorer | https://testnet.decentralscan.com/ | `<html` |
| testnet-exchange | https://testnet.decentral.exchange/ | `<html` |
| testnet-grafana | https://grafana.testnet.decentralchain.io/api/health | `database` |
| mainnet-node | https://mainnet-node.decentralchain.io/node/version | `version` |
| mainnet-exchange | https://decentral.exchange/ | `<html` |
| mainnet-explorer | https://decentralscan.com/ | `<html` |
| docs | https://docs.decentralchain.io/ | `<html` |

The matcher entry uses `/matcher/settings` (JSON with a keyword) rather than `/matcher`, which returns a bare
quoted string with nothing stable to match.

## What alerts

* DOWN email after 2 consecutive failed runs (about 10 minutes). No repeat while down more often than every 6 hours.
* One RECOVERED email when the target passes again (only if a DOWN email was sent).
* State per target (status, consecutive failures, since, last alert) is in the KV namespace `STATE`.
* `GET /status` with the same bearer token returns the JSON of all targets (evidence, and a manual health check).

## Deploy (workstation, not CI)

```
cd monitoring/external-monitor
npx wrangler@4 deploy
# first time only: KV namespace + secrets
npx wrangler@4 kv namespace create STATE        # put the id in wrangler.toml
npx wrangler@4 secret put SMTP_PASSWORD
npx wrangler@4 secret put ALERT_RELAY_TOKEN     # same value as the SOPS key ALERT_RELAY_TOKEN
```

To add or change a monitor, edit `TARGETS` in `src/index.js` and redeploy. To rotate the relay token, change the SOPS key,
`wrangler secret put ALERT_RELAY_TOKEN`, then run push-secrets and restart alertmanager.

## Verifying

`curl -H "Authorization: Bearer $TOKEN" https://dcc-ops-monitor.<subdomain>.workers.dev/status`, and `npx wrangler@4 tail dcc-ops-monitor`.
