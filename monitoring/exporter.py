#!/usr/bin/env python3
"""
DCC chain metrics exporter for Newark backend.
Scrapes the public node REST API over HTTPS — no extra firewall rules needed.
Exposes Prometheus metrics on :9101/metrics.
"""
import http.server, urllib.request, urllib.error, json, time, os, ssl

PORT = int(os.getenv("EXPORTER_PORT", "9101"))

# Parse NODE_URLS env: "label=https://url,label2=https://url2"
# Falls back to the local testnet node.
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
        req = urllib.request.Request(url, headers={"User-Agent": "exporter/1.0"})
        with urllib.request.urlopen(req, timeout=5, context=ctx) as r:
            return json.loads(r.read())
    except Exception:
        return None

def metrics():
    lines = [
        "# HELP dcc_block_height Current blockchain height",
        "# TYPE dcc_block_height gauge",
        "# HELP dcc_blockchain_height_age_seconds Seconds since last block timestamp",
        "# TYPE dcc_blockchain_height_age_seconds gauge",
    ]
    for name, base in NODES:
        h = fetch(f"{base}/blocks/height")
        s = fetch(f"{base}/node/status")
        if h and "height" in h:
            lines.append(f'dcc_block_height{{node="{name}"}} {h["height"]}')
        if s and "updatedTimestamp" in s:
            age = max(0, (time.time() * 1000 - s["updatedTimestamp"]) / 1000)
            lines.append(f'dcc_blockchain_height_age_seconds{{node="{name}"}} {age:.1f}')
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
