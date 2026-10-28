#!/usr/bin/env python3
"""
DCC chain metrics exporter for the testnet main VPS (Dallas, 50.116.30.244).
Scrapes the public node REST API over HTTPS — no extra firewall rules needed.
Exposes Prometheus metrics on :9101/metrics.

Metrics exposed:
  dcc_block_height                  — current blockchain height (chain tip)
  dcc_blockchain_height_age_seconds — seconds since last block (staleness)
  dcc_finalized_height              — feature-25 Deterministic Finality finalized
                                      height (from GET /blocks/height/finalized)
  dcc_finality_lag                  — blocks behind the tip not yet finalized
  dcc_peers_connected               — connected P2P peers (0 if API key required)
  dcc_scrape_error                  — 1 if last scrape failed, 0 otherwise
  dcc_generation_period_pct_elapsed — % of the current generation period elapsed (0-100+),
                                      computed as (height mod generationPeriodLength) / length.
                                      Steady-state approximation: the node exposes
                                      generationPeriodLength via /node/status but not the
                                      activation height, so this ignores the one-time zero-period
                                      offset near activation (fine long after activation, which is
                                      this testnet's actual state).
  dcc_tls_cert_expiry_timestamp_seconds — notAfter (unix s) of each public host's TLS certificate
                                      (refreshed every 10 min; feeds TlsCertExpiringSoon)
  dcc_tls_cert_probe_ok             — 1 if the TLS handshake with the host succeeded
  dcc_next_period_committee_size    — generator count from GET /generators/at/{nextPeriodStart}.
                                      -1 if the endpoint returned a non-200 status (distinct from
                                      a genuine empty committee at HTTP 200 — see CommitteeGapUpcoming
                                      alert comment in alerts.yml for why this distinction matters).
"""
import concurrent.futures, http.server, json, os, socket, ssl, time, urllib.request

PORT = int(os.getenv("EXPORTER_PORT", "9101"))

_raw = os.getenv("NODE_URLS", "main-node=https://testnet-node.decentralchain.io")
NODES = []
for entry in _raw.split(","):
    entry = entry.strip()
    if "=" in entry:
        label, url = entry.split("=", 1)
        NODES.append((label.strip(), url.strip().rstrip("/")))

ctx = ssl.create_default_context()

def fetch(url):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "dcc-exporter/1.0"})
        with urllib.request.urlopen(req, timeout=5, context=ctx) as r:
            return json.loads(r.read())
    except Exception:
        return None

def fetch_with_status(url, data=None):
    """Like fetch(), but also returns the HTTP status code (or None on connection
    failure). Needed for /generators/at/{height}: it returns HTTP 404 with body
    "[]" when the height is out of range, which must NOT be confused with a
    genuine HTTP-200 empty committee -- see CommitteeGapUpcoming in alerts.yml."""
    try:
        headers = {"User-Agent": "dcc-exporter/1.0"}
        if data is not None:
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, headers=headers)
        with urllib.request.urlopen(req, timeout=5, context=ctx) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        try:
            body = json.loads(e.read())
        except Exception:
            body = None
        return e.code, body
    except Exception:
        return None, None

# ── Web-service liveness (MON-1) ──────────────────────────────────────────────
# Each user-facing service is probed with a plain GET; "up" means it answered with
# any HTTP status < 500 (a 400/403/404 still proves the service is serving). A
# connection failure / timeout / 5xx => down. Health URLs are chosen so a healthy
# service returns <500 (ws answers 4xx to a bare GET, which is still "up").
_svc_raw = os.getenv(
    "SERVICE_URLS",
    "matcher=https://testnet-matcher.decentralchain.io/matcher,"
    "data-service=https://testnet-data-service.decentralchain.io/v0,"
    "explorer=https://testnet.decentralscan.com/,"
    "websocket=https://testnet-ws.decentralchain.io/ws,"
    "grafana=https://grafana.testnet.decentralchain.io/api/health,"
    "admin=https://testnet-admin.decentralchain.io/",
)
# No faucet entry: GET /api/faucet has no loader (HTTP 400) and this probe alone sent
# ~5k requests/day into the faucet's 5/h per-IP edge limit (2026-10-18 audit, AUD-141).
# The explorer probe already covers the scanner process that serves the faucet.
# Grafana datasources whose health must be OK (HTTP 200, status "OK"). /api/health above only
# proves Grafana serves; on 2026-10-18 it was 200 for days while the Prometheus and Loki plugins were
# unregistered and every dashboard was empty. The anonymous Viewer may call the health endpoint.
GRAFANA_URL = os.getenv("GRAFANA_URL", "https://grafana.testnet.decentralchain.io")
GRAFANA_DATASOURCES = [d.strip() for d in os.getenv("GRAFANA_DATASOURCES", "prometheus").split(",") if d.strip()]
# Anonymous access is off (mainnet bar A7), so /api/datasources/<uid>/health returns 401. The probe
# instead runs one panel query of the PUBLIC (shared) dashboard, which needs no login and goes
# through the datasource. The token is a public constant, the same one as in deploy-monitoring.sh
# and compose/admin-dashboard.yml. Panel 1 is a Prometheus stat panel.
GRAFANA_PUBLIC_TOKEN = os.getenv("GRAFANA_PUBLIC_TOKEN", "1255a802508eddc1e9e74080cf7b68c8")
GRAFANA_PROBE_PANEL = os.getenv("GRAFANA_PROBE_PANEL", "1")

# Public hosts whose TLS certificate expiry is exported (TlsCertExpiringSoon).
TLS_HOSTS = [h.strip() for h in os.getenv(
    "TLS_HOSTS",
    "testnet-node.decentralchain.io,testnet-matcher.decentralchain.io,"
    "testnet-data-service.decentralchain.io,testnet-ws.decentralchain.io,"
    "testnet.decentralscan.com,testnet-admin.decentralchain.io,grafana.testnet.decentralchain.io",
).split(",") if h.strip()]
TLS_REFRESH_SECONDS = 600
_tls_cache = {}  # host -> (checked_at, not_after_seconds or None)

def tls_not_after(host):
    """notAfter of host:443's certificate as unix seconds, or None if the handshake failed.
    Cached for TLS_REFRESH_SECONDS so a 30s scrape does not open 7 TLS sessions every time."""
    now = time.time()
    hit = _tls_cache.get(host)
    if hit and now - hit[0] < TLS_REFRESH_SECONDS:
        return hit[1]
    value = None
    try:
        with socket.create_connection((host, 443), timeout=5) as sock:
            with ctx.wrap_socket(sock, server_hostname=host) as tls:
                value = ssl.cert_time_to_seconds(tls.getpeercert()["notAfter"])
    except Exception:
        value = None
    _tls_cache[host] = (now, value)
    return value

SERVICES = []
for entry in _svc_raw.split(","):
    if "=" in entry:
        label, url = entry.split("=", 1)
        SERVICES.append((label.strip(), url.strip()))

def probe_status(url):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "dcc-exporter/1.0"})
        with urllib.request.urlopen(req, timeout=6, context=ctx) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code          # 4xx/5xx: service responded
    except Exception:
        return None            # connection refused / timeout / DNS: down

def metrics():
    lines = [
        "# HELP dcc_block_height Current blockchain height",
        "# TYPE dcc_block_height gauge",
        "# HELP dcc_blockchain_height_age_seconds Seconds since last block timestamp (block production staleness)",
        "# TYPE dcc_blockchain_height_age_seconds gauge",
        "# HELP dcc_finalized_height Feature-25 Deterministic Finality finalized block height (GET /blocks/height/finalized)",
        "# TYPE dcc_finalized_height gauge",
        "# HELP dcc_finality_lag Blocks behind the chain tip that have not yet been finalized",
        "# TYPE dcc_finality_lag gauge",
        "# HELP dcc_hotstuff_finalized_height Observational T2 HotStuff committed height (only present when hotstuff.enabled and it has committed >=1 block; feature-25 remains authoritative)",
        "# TYPE dcc_hotstuff_finalized_height gauge",
        "# HELP dcc_hotstuff_lag Blocks the observational HotStuff commit is behind the chain tip",
        "# TYPE dcc_hotstuff_lag gauge",
        "# HELP dcc_hotstuff_equivocations_total Real HotStuff equivocations detected in production (voter signed conflicting votes at the same view/phase). Any nonzero value is a critical finding.",
        "# TYPE dcc_hotstuff_equivocations_total gauge",
        "# HELP dcc_peers_connected Number of currently connected P2P peers",
        "# TYPE dcc_peers_connected gauge",
        "# HELP dcc_scrape_error 1 if the last scrape failed for any endpoint, 0 otherwise",
        "# TYPE dcc_scrape_error gauge",
        "# HELP dcc_service_up 1 if the web service answered with HTTP <500, 0 if down (conn error/timeout/5xx)",
        "# TYPE dcc_service_up gauge",
        "# HELP dcc_generation_period_pct_elapsed Percent of the current generation period elapsed (steady-state approximation via height mod generationPeriodLength; see module docstring)",
        "# TYPE dcc_generation_period_pct_elapsed gauge",
        "# HELP dcc_next_period_committee_size Generator count for the NEXT generation period from GET /generators/at/{nextPeriodStart}. -1 means the endpoint returned a non-200 status (distinct from a genuine HTTP-200 empty committee)",
        "# TYPE dcc_next_period_committee_size gauge",
        "# HELP dcc_current_period_committee_size Generator count of the CURRENT generation period (GET /generators/at/{currentPeriodStart})",
        "# TYPE dcc_current_period_committee_size gauge",
    ]

    # Web-service liveness for every user-facing service (matcher, data-service,
    # explorer, websocket, grafana, admin) — so an outage of any of them pages.
    # Probed in parallel: sequentially, every dead service added its full 6s timeout, so
    # two unreachable hosts (explorer + faucet during the 2026-10-04 DNS move) pushed a
    # scrape to ~25s. That is past Prometheus' 10s scrape timeout, which then dropped the
    # node metrics as well and raised a false MainNodeUnreachable. Now a scrape takes as
    # long as the slowest single probe.
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, len(SERVICES))) as pool:
        codes = list(pool.map(lambda su: probe_status(su[1]), SERVICES))
    for (svc, _), code in zip(SERVICES, codes):
        up = 1 if (code is not None and code < 500) else 0
        lines.append(f'dcc_service_up{{service="{svc}"}} {up}')

    lines += [
        "# HELP dcc_tls_cert_expiry_timestamp_seconds notAfter of the host's TLS certificate (unix seconds)",
        "# TYPE dcc_tls_cert_expiry_timestamp_seconds gauge",
        "# HELP dcc_tls_cert_probe_ok 1 if a TLS handshake with host:443 succeeded",
        "# TYPE dcc_tls_cert_probe_ok gauge",
    ]
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, len(TLS_HOSTS))) as pool:
        not_afters = list(pool.map(tls_not_after, TLS_HOSTS))
    for host, not_after in zip(TLS_HOSTS, not_afters):
        lines.append(f'dcc_tls_cert_probe_ok{{host="{host}"}} {0 if not_after is None else 1}')
        if not_after is not None:
            lines.append(f'dcc_tls_cert_expiry_timestamp_seconds{{host="{host}"}} {not_after:.0f}')

    lines += [
        "# HELP dcc_grafana_datasource_up 1 if a public-dashboard panel query through the datasource returns HTTP 200 with every result status 200",
        "# TYPE dcc_grafana_datasource_up gauge",
    ]
    for uid in GRAFANA_DATASOURCES:
        code, body = fetch_with_status(
            f"{GRAFANA_URL}/api/public/dashboards/{GRAFANA_PUBLIC_TOKEN}/panels/{GRAFANA_PROBE_PANEL}/query",
            data=b'{"intervalMs":60000,"maxDataPoints":100}',
        )
        results = body.get("results") if isinstance(body, dict) else None
        ok = 1 if (code == 200 and isinstance(results, dict) and results
                   and all(isinstance(r, dict) and r.get("status") == 200 and not r.get("error")
                           for r in results.values())) else 0
        lines.append(f'dcc_grafana_datasource_up{{datasource="{uid}"}} {ok}')

    for name, base in NODES:
        lbl = f'node="{name}"'
        error = 0
        height = None

        h = fetch(f"{base}/blocks/height")
        s = fetch(f"{base}/node/status")
        if h and "height" in h:
            height = h["height"]
            lines.append(f'dcc_block_height{{{lbl}}} {height}')
        else:
            error = 1

        if s and "updatedTimestamp" in s:
            age = max(0.0, (time.time() * 1000 - s["updatedTimestamp"]) / 1000)
            lines.append(f'dcc_blockchain_height_age_seconds{{{lbl}}} {age:.1f}')
        else:
            error = 1

        fin = fetch(f"{base}/blocks/height/finalized")
        if fin and "height" in fin:
            finalized = fin["height"]
            lines.append(f'dcc_finalized_height{{{lbl}}} {finalized}')
            if height:
                lines.append(f'dcc_finality_lag{{{lbl}}} {max(0, height - finalized)}')
        else:
            error = 1

        # Observational T2 HotStuff height, surfaced on /node/status only when hotstuff is enabled and
        # has committed a block. Absent (HotStuff off/idle) => emit nothing, and do NOT flag an error.
        if s and "hotStuffFinalizedHeight" in s:
            hs = s["hotStuffFinalizedHeight"]
            lines.append(f'dcc_hotstuff_finalized_height{{{lbl}}} {hs}')
            if height:
                lines.append(f'dcc_hotstuff_lag{{{lbl}}} {max(0, height - hs)}')

        # Real HotStuff equivocations (voter signed conflicting votes at the same view/phase),
        # surfaced on /node/status only when equivocation detection is active and >=1 has occurred.
        # Absent => emit nothing (no error), but ANY nonzero value is a critical finding.
        if s and "hotStuffEquivocationsTotal" in s:
            eq = s["hotStuffEquivocationsTotal"]
            lines.append(f'dcc_hotstuff_equivocations_total{{{lbl}}} {eq}')

        # /peers/connected may require X-API-Key; silently return 0 without marking error
        peers = fetch(f"{base}/peers/connected")
        peer_count = len(peers.get("peers", [])) if peers and "peers" in peers else 0
        lines.append(f'dcc_peers_connected{{{lbl}}} {peer_count}')

        # ── CommitteeGapUpcoming inputs ────────────────────────────────────────
        # Steady-state approximation (see module docstring): the node exposes
        # generationPeriodLength via /node/status but not the activation height,
        # so period-start math here ignores the one-time zero-period offset near
        # activation. Fine long after activation (this testnet's actual state);
        # would be off-by-<length> right at activation.
        if s and height and "generationPeriodLength" in s:
            period_len = s["generationPeriodLength"]
            if period_len > 0:
                # Periods are [x01, x00+len]: compute from height-1 so the period's last block (x00)
                # belongs to the current period. The old (height // len) put x00 in the next period:
                # pct read 0% and the "next" start was one period too far (404 -> -1) once per period.
                period_start = ((height - 1) // period_len) * period_len + 1
                pct_elapsed = ((height - period_start + 1) / period_len) * 100
                lines.append(f'dcc_generation_period_pct_elapsed{{{lbl}}} {pct_elapsed:.1f}')

                cur_code, cur = fetch_with_status(f"{base}/generators/at/{period_start}")
                if cur_code == 200 and isinstance(cur, list):
                    lines.append(f'dcc_current_period_committee_size{{{lbl}}} {len(cur)}')

                next_period_start = period_start + period_len
                status_code, committee = fetch_with_status(f"{base}/generators/at/{next_period_start}")
                if status_code == 200 and isinstance(committee, list):
                    lines.append(f'dcc_next_period_committee_size{{{lbl}}} {len(committee)}')
                else:
                    # Non-200 (e.g. 404 out-of-range) is NOT the same as a genuine
                    # empty committee -- emit -1 so PromQL can distinguish
                    # "no data" from "data says zero generators".
                    lines.append(f'dcc_next_period_committee_size{{{lbl}}} -1')

        lines.append(f'dcc_scrape_error{{{lbl}}} {error}')

    return "\n".join(lines) + "\n"

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/metrics":
            body = metrics().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", len(body))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *_):
        pass

if __name__ == "__main__":
    http.server.HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()

