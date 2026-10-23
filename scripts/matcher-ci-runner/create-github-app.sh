#!/usr/bin/env bash
# One-time: creates the GitHub App the runner host authenticates with, via GitHub's App-manifest flow,
# and stores its credential in SOPS (secrets/matcher-ci-runner.env) WITHOUT printing it. Two clicks:
#   1. "Create GitHub App" on the page this script opens (org Decentral-America, permissions preset:
#      Administration read/write = register runners, Variables read/write = heartbeat variable, Metadata read)
#   2. "Install" -> "Only select repositories" -> matcher
# The script then finds the installation, refuses it unless it covers exactly the matcher repository,
# records GITHUB_APP_INSTALLATION_ID, and runs push-credential.sh.
#   scripts/matcher-ci-runner/create-github-app.sh
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "$0")/common.sh"
ORG="${REPO%%/*}"
PORT="${PORT:-8765}"
STATE=$(openssl rand -hex 16)
WORK=$(mktemp -d); chmod 700 "$WORK"; trap 'rm -rf "$WORK"' EXIT

python3 - "$ORG" "$PORT" "$STATE" "$WORK" <<'PY'
import http.server, json, sys, urllib.parse, urllib.request, webbrowser
org, port, state, work = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
manifest = {
    "name": "dcc-matcher-ci-runner",
    "url": "https://github.com/Decentral-America/infra/blob/main/runbooks/matcher-ci-runner.md",
    "hook_attributes": {"url": "https://example.invalid/unused", "active": False},
    "redirect_url": f"http://127.0.0.1:{port}/callback",
    "public": False,
    "default_permissions": {"administration": "write", "actions_variables": "write", "metadata": "read"},
    "default_events": [],
}
page = f"""<html><body onload="document.forms[0].submit()"><form method="post"
 action="https://github.com/organizations/{org}/settings/apps/new?state={state}">
<input type="hidden" name="manifest" value='{json.dumps(manifest)}'></form></body></html>"""
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        u = urllib.parse.urlparse(self.path); q = urllib.parse.parse_qs(u.query)
        if u.path == "/":
            self.send_response(200); self.end_headers(); self.wfile.write(page.encode()); return
        if u.path == "/callback" and q.get("state", [""])[0] == state and "code" in q:
            req = urllib.request.Request(f"https://api.github.com/app-manifests/{q['code'][0]}/conversions", method="POST",
                                         headers={"Accept": "application/vnd.github+json"})
            app = json.load(urllib.request.urlopen(req, timeout=30))
            with open(f"{work}/app.json", "w") as f:
                json.dump({"id": app["id"], "slug": app["slug"], "pem": app["pem"]}, f)
            self.send_response(200); self.end_headers()
            self.wfile.write(f"App {app['slug']} created. Now install it on the matcher repository only: "
                             f"https://github.com/apps/{app['slug']}/installations/new".encode())
            raise SystemExit(0)
        self.send_response(400); self.end_headers()
srv = http.server.HTTPServer(("127.0.0.1", port), H)
print(f"opening http://127.0.0.1:{port}/ (submits the App manifest to GitHub)")
webbrowser.open(f"http://127.0.0.1:{port}/")
try:
    srv.serve_forever()
except SystemExit:
    pass
PY

APP_ID=$(jq -r .id "$WORK/app.json"); SLUG=$(jq -r .slug "$WORK/app.json")
jq -r .pem "$WORK/app.json" > "$WORK/key.pem"; chmod 600 "$WORK/key.pem"
KEY_B64=$(openssl base64 -A < "$WORK/key.pem")
echo "App ${SLUG} (id ${APP_ID}) created. Install it: https://github.com/apps/${SLUG}/installations/new (only the matcher repository)"
command -v open >/dev/null && open "https://github.com/apps/${SLUG}/installations/new" || true

jwt() {
  local now h p s; now=$(date +%s)
  h=$(printf '{"alg":"RS256","typ":"JWT"}' | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  p=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$APP_ID" | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  s=$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -sign "$WORK/key.pem" | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  printf '%s.%s.%s' "$h" "$p" "$s"
}
INST=""
for _ in $(seq 1 120); do
  INST=$(curl -fsS -H "Authorization: Bearer $(jwt)" -H "Accept: application/vnd.github+json" https://api.github.com/app/installations | jq -r '.[0].id // empty')
  [ -n "$INST" ] && break; sleep 5
done
[ -n "$INST" ] || { echo "no installation after 10 minutes" >&2; exit 1; }
TOK=$(curl -fsS -X POST -H "Authorization: Bearer $(jwt)" -H "Accept: application/vnd.github+json" "https://api.github.com/app/installations/${INST}/access_tokens" | jq -r .token)
REPOS=$(curl -fsS -H "Authorization: Bearer ${TOK}" -H "Accept: application/vnd.github+json" https://api.github.com/installation/repositories | jq -r '[.repositories[].full_name] | join(",")')
unset TOK
[ "$REPOS" = "$REPO" ] || { echo "installation ${INST} covers [${REPOS}], not exactly ${REPO}; fix it under the App's installation settings" >&2; exit 1; }

sops set "$SECRETS" '["GITHUB_APP_ID"]' "\"${APP_ID}\""
sops set "$SECRETS" '["GITHUB_APP_INSTALLATION_ID"]' "\"${INST}\""
sops set "$SECRETS" '["GITHUB_APP_PRIVATE_KEY_B64"]' "\"${KEY_B64}\""
unset KEY_B64
echo "credential stored in ${SECRETS} (encrypted). Installing it on the runner host..."
"$(dirname "$0")/push-credential.sh"
