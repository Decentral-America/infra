#!/bin/sh
# Runs one node-based canary inside the LKE CronJob and files an alert issue when it fails.
# Usage: run-canary.sh <script.mjs> <FailAlertName> <fail summary> <UnfundedAlertName> <unfunded summary>
# Exit codes: the canary's own (0 ok, 1 failed, 3 unfunded); 4 = monitor infrastructure error
# (npm install failed: not a testnet fault, so no alert issue; the off-box deadman in
# infra-liveness.yml flags a monitor that keeps failing without an open alert).
set -u
script="$1" fail_name="$2" fail_summary="$3" unfunded_name="$4" unfunded_summary="$5"
W=/work
cp /app/*.mjs "$W/"
cd "$W" || exit 4
# Exact versions: the same pair matcher-canary.yml proved on Node 24 (transactions@5.0.1 imports cleanly).
npm install --no-save --no-audit --no-fund --loglevel=error --prefix "$W" \
  @decentralchain/transactions@5.0.1 @decentralchain/ts-lib-crypto@2.0.0 \
  || { echo "monitor infrastructure error: npm install failed" >&2; exit 4; }
rc=0
node "$script" >"$W/out.log" 2>&1 || rc=$?
cat "$W/out.log"
[ "$rc" -eq 0 ] && exit 0
if [ "$rc" -eq 3 ]; then
  node alert-issue.mjs "$unfunded_name" high "$unfunded_summary" "$W/out.log" || true
else
  node alert-issue.mjs "$fail_name" high "$fail_summary" "$W/out.log" || true
fi
exit "$rc"
