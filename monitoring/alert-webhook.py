#!/usr/bin/env python3
"""
Alertmanager webhook → GitHub Issues.
Creates/closes GitHub issues when Prometheus alerts fire/resolve.
Runs as a lightweight HTTP server on localhost:9099.

Required env vars:
  GITHUB_TOKEN   — PAT with repo scope (write:issues)
  GITHUB_REPO    — owner/repo (e.g. Decentral-America/infra)
"""
import http.server, json, os, urllib.request, urllib.error, logging

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
log = logging.getLogger(__name__)

PORT       = int(os.getenv('ALERT_WEBHOOK_PORT', '9099'))
GITHUB_TOKEN = os.getenv('GITHUB_TOKEN', '')
GITHUB_REPO  = os.getenv('GITHUB_REPO', 'Decentral-America/infra')
API_BASE     = f'https://api.github.com/repos/{GITHUB_REPO}'

def gh(method: str, path: str, body: dict | None = None) -> dict:
    data = json.dumps(body).encode() if body else None
    req  = urllib.request.Request(
        f'{API_BASE}/{path}',
        data=data,
        method=method,
        headers={
            'Authorization': f'Bearer {GITHUB_TOKEN}',
            'Accept': 'application/vnd.github+json',
            'Content-Type': 'application/json',
            'X-GitHub-Api-Version': '2022-11-28',
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        log.error('GitHub API %s %s → %s %s', method, path, e.code, e.read()[:200])
        return {}

def find_open_issue(title_prefix: str) -> int | None:
    issues = gh('GET', f'issues?state=open&labels=alert&per_page=50')
    for issue in (issues if isinstance(issues, list) else []):
        if issue.get('title', '').startswith(title_prefix):
            return issue['number']
    return None

def handle_alert(alert: dict) -> None:
    name    = alert.get('labels', {}).get('alertname', 'Unknown')
    status  = alert.get('status', 'firing')
    sev     = alert.get('labels', {}).get('severity', 'unknown')
    summary = alert.get('annotations', {}).get('summary', name)
    desc    = alert.get('annotations', {}).get('description', '')
    prefix  = f'[ALERT] {name}'

    if status == 'firing':
        existing = find_open_issue(prefix)
        if existing:
            log.info('Alert %s already open as issue #%s', name, existing)
            return
        body = (
            f'## {sev.upper()} — {summary}\n\n'
            f'{desc}\n\n'
            f'**Network:** testnet  \n'
            f'**Alert:** `{name}`  \n'
            f'**Severity:** {sev}  \n\n'
            f'> Auto-opened by Alertmanager. Close when resolved.\n'
        )
        result = gh('POST', 'issues', {
            'title': f'{prefix}: {summary}',
            'body': body,
            'labels': ['alert', f'severity:{sev}'],
        })
        if result.get('number'):
            log.info('Created issue #%s for alert %s', result['number'], name)
        else:
            log.warning('Failed to create issue for alert %s', name)

    elif status == 'resolved':
        num = find_open_issue(prefix)
        if num:
            gh('POST', f'issues/{num}/comments', {'body': 'Alert resolved — auto-closing.'})
            gh('PATCH', f'issues/{num}', {'state': 'closed'})
            log.info('Closed issue #%s for resolved alert %s', num, name)

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != '/alert':
            self.send_response(404); self.end_headers(); return
        length = int(self.headers.get('Content-Length', 0))
        payload = json.loads(self.rfile.read(length) or b'{}')
        for alert in payload.get('alerts', []):
            try:
                handle_alert(alert)
            except Exception as e:
                log.error('Error handling alert: %s', e)
        self.send_response(200); self.end_headers()
        self.wfile.write(b'OK')

    def log_message(self, *_): pass

if __name__ == '__main__':
    if not GITHUB_TOKEN:
        log.warning('GITHUB_TOKEN not set — alerts will not create issues')
    log.info('Alert webhook listening on :%d → %s', PORT, GITHUB_REPO)
    http.server.HTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
