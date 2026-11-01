# DCC DNS inventory

**Source: public DNS queries on 2026-10-31 (commands below). A full registrar/DNS console export
(SiteGround, Namecheap, GoDaddy) is still PENDING (Owner console access) — records not visible from
public DNS (e.g. unlinked subdomains) may exist.** Every row below was seen in a live query; nothing is
copied from older docs. Re-run the commands after any DNS change and update this file in the same PR.

DNS is not managed as code. The weekly `.github/workflows/domain-expiry.yml` watches registration
expiry; `monitoring/exporter.py` (`dcc_tls_cert_expiry_timestamp_seconds`) watches certificates.

## Domains (ECO-64)

| Domain | Registrar (RDAP) | DNS provider (NS) | Registered | Expires (RDAP, UTC) | Auto-renew | RDAP status |
|---|---|---|---|---|---|---|
| decentralchain.io | NameCheap, Inc. (IANA 1068) | SiteGround (`ns1/ns2.siteground.net`) | 2021-01-30 | **2027-01-30T17:44:00Z** | unverified — owner console | client transfer prohibited |
| decentralscan.com | NameCheap, Inc. (IANA 1068) | Namecheap BasicDNS (`dns1/dns2.registrar-servers.com`) | 2021-03-01 | **2027-03-01T22:57:15Z** | unverified — owner console | client transfer prohibited |
| decentral.exchange | NameCheap, Inc. (IANA 1068) | Namecheap BasicDNS (`dns1/dns2.registrar-servers.com`) | 2021-03-05 | **2027-03-05T21:12:57Z** | unverified — owner console | client transfer prohibited |
| decentralchain.com | GoDaddy.com, LLC (IANA 146) | GoDaddy (`ns29/ns30.domaincontrol.com`) | 2017-08-05 | **2027-08-05T19:03:48Z** | unverified — owner console | client delete/renew/transfer/update prohibited |

RDAP does not expose the registrar's auto-renew setting (the EPP "client renew prohibited" flag is a
registrar lock, not auto-renew). The Owner must confirm auto-renew in the Namecheap (3 domains) and
GoDaddy (1 domain) consoles and record the date here. Note: decentralchain.io is **registered** at
Namecheap but its **DNS** is hosted at SiteGround.

RDAP endpoints: `.com` → `https://rdap.verisign.com/com/v1/`, `.exchange` →
`https://rdap.identitydigital.services/rdap/` (both from the IANA bootstrap). `.io` is not in the IANA
bootstrap (rdap.org answers 404), its registry endpoint is `https://rdap.identitydigital.services/rdap/`.

### TLS certificates outside the testnet VPS (openssl, 2026-10-31)

Exporter `TLS_HOSTS` covers every host below; `TlsCertExpiresWithin21Days` / `...7Days` alert on them.

| Host | Issuer | notAfter (UTC) | Renewal |
|---|---|---|---|
| decentralchain.com | GoDaddy TLS Intermediate CA DV | 2026-12-27 04:31 | **manual (paid DV certificate): Owner must renew before 2026-12-27**; the 21-day alert fires ~2026-12-06 |
| docs.decentralchain.io | Let's Encrypt | 2026-12-01 18:39 | GitHub Pages (automatic) |
| mainnet-matcher.decentralchain.io | Let's Encrypt | 2026-12-20 22:39 | third party (owner unknown, see below) |
| decentralchain.io, www.decentralchain.io | Let's Encrypt | 2027-01-13, 2027-01-08 | Railway-managed |
| mainnet-node, data-service.decentralchain.io, decentral.exchange, charts.decentral.exchange, decentralscan.com | Let's Encrypt | 2027-01-08 | production web / legacy mainnet hosts; renewal mechanism is not in this repo (Owner) |
| testnet.decentral.exchange | Google Trust Services | 2027-01-04 | Cloudflare (automatic) |

## Records

Owner system = what serves the record. Known addresses: **testnet VPS** `50.116.30.244` (Linode,
infra `terraform/`); **legacy mainnet** `173.255.238.171` (Linode); **production web** `172.237.135.228`
(Linode); Namecheap-hosted servers `104.207.82.46`, `162.0.224.184`, `162.0.236.119` (IP RDAP: NAMEC-4,
Namecheap, Inc.; outside this repo); Railway `69.46.46.x` (IP RDAP: RLWY-HIKARI-01).

### decentralchain.io (DNS: SiteGround)

| Host | Type | Value | Purpose | Owner system | Keep/remove |
|---|---|---|---|---|---|
| decentralchain.io | A | 69.46.46.90 | apex; HTTPS 301 → `https://www.decentralchain.io/` | Railway | KEEP |
| www.decentralchain.io | CNAME | fh6a4oiv.up.railway.app. | marketing site (HTTPS 200) | Railway | KEEP |
| decentralchain.io | MX | 10/20/30 mx{10,20,30}.antispam.mailspamprotection.com. | inbound mail (`info@decentralchain.io`) | SiteGround mail | KEEP |
| decentralchain.io | TXT | `v=spf1 +a +mx +ip4:34.174.29.180 include:decentralchain.io.spf.auto.dnssmarthost.net ~all` | SPF | SiteGround mail | KEEP |
| decentralchain.io | TXT | `nhxedcdyil` | unknown (looks like a verification token) | unknown | REVIEW (Owner) |
| _dmarc.decentralchain.io | TXT | `v=DMARC1; p=none; aspf=r; adkim=r;` | DMARC, monitor-only | SiteGround mail | KEEP |
| decentralchain.io | NS | ns1.siteground.net., ns2.siteground.net. | delegation | SiteGround | KEEP |
| decentralchain.io | SOA | ns1.siteground.net. admins.siteground.com. 440 … | zone | SiteGround | KEEP |
| testnet-node.decentralchain.io | A | 50.116.30.244 | testnet main node REST (Caddy) | testnet VPS | KEEP |
| testnet-matcher.decentralchain.io | A | 50.116.30.244 | testnet matcher | testnet VPS | KEEP |
| testnet-data-service.decentralchain.io | A | 50.116.30.244 | testnet data-service | testnet VPS | KEEP |
| testnet-ws.decentralchain.io | A | 50.116.30.244 | testnet websocket-api | testnet VPS | KEEP |
| testnet-admin.decentralchain.io | A | 50.116.30.244 | testnet admin-dashboard | testnet VPS | KEEP |
| grafana.testnet.decentralchain.io | A | 50.116.30.244 | testnet Grafana | testnet VPS | KEEP |
| mainnet-node.decentralchain.io | A | 173.255.238.171 | **live legacy mainnet node**: `GET /node/version` → `{"version":"DCC v1.3.5"}` (HTTPS 200, 2026-10-31) | legacy mainnet | **KEEP — DO NOT DELETE** (see below) |
| mainnet-matcher.decentralchain.io | A | 104.207.82.46 | live mainnet matcher: `GET /matcher` → matcher public key `BWK6Avs2…`; `/` 308 → `/api-docs/index.html`; `Server: nginx/1.14.2` | Namecheap-hosted server | **KEEP** (see below) |
| data-service.decentralchain.io | A | 172.237.135.228 | production data-service (`/v0/` HTTPS 200) | production web | KEEP |
| docs.decentralchain.io | CNAME | decentral-america.github.io. | public docs (HTTPS 200) | GitHub Pages (Decentral-America/docs) | KEEP |
| matcher.decentralchain.io | A | 162.0.224.184 | unknown: no answer on 80 or 443 | Namecheap-hosted server | REVIEW (Owner): likely stale; remove if no owner claims it |
| node.decentralchain.io | A | 162.0.236.119 | unknown: no answer on 80; TLS handshake fails on 443 | Namecheap-hosted server | REVIEW (Owner): likely stale; remove if no owner claims it |

### decentralscan.com (DNS: Namecheap)

| Host | Type | Value | Purpose | Owner system | Keep/remove |
|---|---|---|---|---|---|
| decentralscan.com | A | 172.237.135.228 | production explorer ("Decentralchain Explorer", HTTPS 200) | production web | KEEP |
| testnet.decentralscan.com | A | 50.116.30.244 | testnet explorer + faucet (scanner) | testnet VPS | KEEP |
| decentralscan.com | MX | eforward1-5.registrar-servers.com. | Namecheap email forwarding | Namecheap | KEEP |
| decentralscan.com | TXT | `v=spf1 include:spf.efwd.registrar-servers.com ~all` | SPF for forwarding | Namecheap | KEEP |
| _dmarc.decentralscan.com | TXT | (none) | no DMARC record | — | Owner review (mail policy) |
| decentralscan.com | NS | dns1/dns2.registrar-servers.com. | delegation | Namecheap | KEEP |

### decentral.exchange (DNS: Namecheap)

| Host | Type | Value | Purpose | Owner system | Keep/remove |
|---|---|---|---|---|---|
| decentral.exchange | A | 172.237.135.228 | production exchange ("Decentral.Exchange", HTTPS 200) | production web | KEEP |
| testnet.decentral.exchange | CNAME | exchange-testnet.pages.dev. | testnet exchange (HTTPS 200) | Cloudflare Pages (DecentralChain `deploy-exchange.yml`) | KEEP |
| charts.decentral.exchange | A | 172.237.135.228 | charts host; serves the default "Welcome to nginx!" page (HTTPS 200) | production web | KEEP (Owner: confirm it should serve charts) |
| decentral.exchange | MX | eforward1-5.registrar-servers.com. | Namecheap email forwarding | Namecheap | KEEP |
| decentral.exchange | TXT | `v=spf1 include:spf.efwd.registrar-servers.com ~all` | SPF for forwarding | Namecheap | KEEP |
| _dmarc.decentral.exchange | TXT | (none) | no DMARC record | — | Owner review (mail policy) |
| decentral.exchange | NS | dns1/dns2.registrar-servers.com. | delegation | Namecheap | KEEP |

### decentralchain.com (DNS: GoDaddy)

| Host | Type | Value | Purpose | Owner system | Keep/remove |
|---|---|---|---|---|---|
| decentralchain.com | A | 3.33.130.190, 15.197.148.33 | apex (HTTPS 200); IP RDAP AT-88-Z, Amazon (GoDaddy-hosted website/forwarding range, not verified) | GoDaddy | KEEP |
| www.decentralchain.com | CNAME | decentralchain.com. | www alias | GoDaddy | KEEP |
| decentralchain.com | MX / TXT / _dmarc | (none) | no mail; no SPF | — | Owner review (mail policy) |
| decentralchain.com | NS | ns29/ns30.domaincontrol.com. | delegation | GoDaddy | KEEP |

### Names with NO record (NXDOMAIN at the authoritative server)

Keep absent; must not be referenced. Anyone who later creates these names (or registers a lookalike)
would receive traffic meant for DCC.

`mail.decentralchain.io` (Alertmanager uses `gtxm1040.siteground.biz:465` instead),
`testnet-scanner.decentralchain.io`, `testnet.decentralchain.io`, `explorer.decentralchain.io`,
`testnet.explorer.decentralchain.io`, `stagenet.decentralchain.io`, `stagenet-node.decentralchain.io`,
`stagenet-matcher.decentralchain.io`, `stagenet-data-service.decentralchain.io`,
`stagenet-ws.decentralchain.io`, `ide.decentralchain.io`, `client.decentralchain.io`,
`dex.decentralchain.io`, `forum.decentralchain.io`, `blog.decentralchain.io`, `api.decentralchain.io`,
`support.decentralchain.io`, `scanner.decentralchain.io`, `nodes.decentralchain.io`,
`id.decentralchain.io`, `exchange.decentralchain.io`, `admin.decentralchain.io`,
`mainnet-ws.decentralchain.io`, `mainnet-admin.decentralchain.io`, `swap-api.decentralchain.io`,
`grafana.decentralchain.io`, `wallet.decentralchain.io`, `www.decentralscan.com`,
`stagenet.decentralscan.com`, `tokenrating.decentralscan.com`, `nodes.decentralscan.com`,
`matcher.decentralscan.com`, `api.decentralscan.com`, `www.decentral.exchange`,
`stagenet.decentral.exchange`, `support.decentral.exchange`.

Several still appear in code (mostly upstream-inherited defaults in DecentralChain and the docs locales);
stagenet names get created when stagenet is stood up, from this file.

## Keep reasons: mainnet-node and mainnet-matcher

- **mainnet-node.decentralchain.io → 173.255.238.171: DO NOT DELETE.** It serves the live legacy
  mainnet (v1.3.5, verified above). It is the default mainnet node in DecentralChain:
  `apps/cubensis-connect/src/constants.ts:31` (`nodeBaseUrl`), `apps/exchange/src/configs/mainnet.json:28`,
  `apps/exchange/src/config/amm.ts:18`, `apps/exchange/src/config/bridge.ts:23`,
  `apps/scanner/src/lib/api.ts:76-77`, `apps/scanner/src/root.tsx:31`, and the Java SDK
  `Profile.MAINNET`. Older plan text that said "delete the stale mainnet-node record" was wrong.
- **mainnet-matcher.decentralchain.io → 104.207.82.46: KEEP.** It answers as a live matcher and is the
  default mainnet matcher in `apps/cubensis-connect/src/constants.ts:28` (`matcherBaseUrl`),
  `apps/exchange/src/configs/mainnet.json:22` and `apps/scanner/src/root.tsx:30`. Its server is not in
  this repo or the Linode account (IP RDAP: Namecheap); who operates it is PENDING (Owner). Note: the
  ECO-109 ticket (2026-10-24) recorded 66.29.149.223; on 2026-10-31 it resolves to 104.207.82.46.
- **Cubensis negative test.** `apps/cubensis-connect/src/constants.ts:98` whitelists only
  `decentralchain.io`, `decentral.exchange`, `testnet.decentral.exchange`, and
  `apps/cubensis-connect/src/constants.test.ts:13-20` asserts that `explorer.decentralchain.io`,
  `testnet.decentralchain.io` and `stagenet.decentralchain.io` are NOT whitelisted, because those names
  do not resolve and anyone who later created them would be auto-permitted by the wallet. Those three
  names must therefore stay absent (or the test and whitelist be revisited together). mainnet-node and
  mainnet-matcher are not whitelisted; the wallet uses them only as API endpoints, which is why they
  must keep resolving.

## Commands used (2026-10-31)

```bash
# Delegation and zone per domain
for d in decentralchain.io decentralscan.com decentral.exchange decentralchain.com; do
  dig +short NS "$d" @1.1.1.1
  for t in MX TXT SOA CAA; do dig +short "$t" "$d" @1.1.1.1; done
  dig +short TXT "_dmarc.$d" @1.1.1.1
done
# Every host: recursive answer AND the authoritative server's answer + status (NXDOMAIN check)
# (auth NS: ns1.siteground.net for decentralchain.io, dns1.registrar-servers.com for
#  decentralscan.com/decentral.exchange, ns29.domaincontrol.com for decentralchain.com)
for t in CNAME A AAAA; do dig +short "$t" "$host" @1.1.1.1; dig +short "$t" "$host" @"$auth_ns"; done
dig "$host" A @"$auth_ns" +noall +comments | grep -oE 'status: [A-Z]+'
# Host list: the names above plus every *.decentralchain.io / *.decentralscan.com /
# *.decentral.exchange name found by grep in infra, DecentralChain and docs.
# IP ownership
curl -sL "https://rdap.org/ip/$ip" | jq -r '.name, (.entities[]? | select(.roles | index("registrant")) | .vcardArray[1][]? | select(.[0]=="fn") | .[3])'
# Service checks
curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "https://$host/"
curl -s https://mainnet-node.decentralchain.io/node/version
curl -s https://mainnet-matcher.decentralchain.io/matcher
# Registration (RDAP)
curl -sL "https://rdap.org/domain/$d"                                       # .com, .exchange
curl -s  "https://rdap.identitydigital.services/rdap/domain/decentralchain.io"  # .io (not in IANA bootstrap)
jq -c '[.events[] | select(.eventAction=="expiration" or .eventAction=="registration")]'
jq -r '.entities[] | select(.roles | index("registrar")) | .vcardArray[1][] | select(.[0]=="fn") | .[3]'
```
