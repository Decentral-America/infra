#!/usr/bin/env python3
"""
DCC chain metrics exporter for Newark backend.
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
"""
import http.server, json, os, ssl, time, urllib.request

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

# ── Web-service liveness (MON-1) ──────────────────────────────────────────────
# Each user-facing service is probed with a plain GET; "up" means it answered with
# any HTTP status < 500 (a 400/403/404 still proves the service is serving). A
# connection failure / timeout / 5xx => down. Health URLs are chosen so a healthy
# service returns <500 (ws/faucet answer 4xx to a bare GET, which is still "up").
_svc_raw = os.getenv(
    "SERVICE_URLS",
    "matcher=https://testnet-matcher.decentralchain.io/matcher,"
    "data-service=https://testnet-data-service.decentralchain.io/v0,"
    "explorer=https://testnet.decentralscan.com/,"
    "websocket=https://testnet-ws.decentralchain.io/ws,"
    "grafana=https://grafana.testnet.decentralchain.io/api/health,"
    "admin=https://testnet-admin.decentralchain.io/,"
    "faucet=https://testnet.decentralscan.com/api/faucet",
)
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
        "# HELP dcc_peers_connected Number of currently connected P2P peers",
        "# TYPE dcc_peers_connected gauge",
        "# HELP dcc_scrape_error 1 if the last scrape failed for any endpoint, 0 otherwise",
        "# TYPE dcc_scrape_error gauge",
        "# HELP dcc_service_up 1 if the web service answered with HTTP <500, 0 if down (conn error/timeout/5xx)",
        "# TYPE dcc_service_up gauge",
    ]

    # Web-service liveness for every user-facing service (matcher, data-service,
    # explorer, websocket, grafana, admin, faucet) — so an outage of any of them pages.
    for svc, url in SERVICES:
        code = probe_status(url)
        up = 1 if (code is not None and code < 500) else 0
        lines.append(f'dcc_service_up{{service="{svc}"}} {up}')

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

        # /peers/connected may require X-API-Key; silently return 0 without marking error
        peers = fetch(f"{base}/peers/connected")
        peer_count = len(peers.get("peers", [])) if peers and "peers" in peers else 0
        lines.append(f'dcc_peers_connected{{{lbl}}} {peer_count}')

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

http.server.HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()

