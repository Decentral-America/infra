#!/usr/bin/env bash
# gh-wait-and-download.sh — wait for a GH Actions run then download its artifact.
#
# REPLACES: gh run watch  (which burns ~1200 REST calls/hour)
# COST:     0 REST calls while waiting (GraphQL only) + 3 REST calls at the end
#
# Usage:
#   ./gh-wait-and-download.sh <run_id> <repo> [artifact_name] [output_dir]
#
# Examples:
#   ./gh-wait-and-download.sh 28166217103 Decentral-America/infra resync-results-28166217103
#   ./gh-wait-and-download.sh 28166217103 Decentral-America/infra diag-results-28166217103 /tmp/out
#
set -euo pipefail

RUN_ID="${1:?run_id required}"
REPO="${2:?repo (owner/name) required}"
ARTIFACT="${3:-}"          # optional artifact name glob
OUTDIR="${4:-.}"

OWNER="${REPO%%/*}"
NAME="${REPO##*/}"

# ── Wait for completion via GraphQL (zero REST cost) ────────────────────────
echo "Waiting for run $RUN_ID on $REPO (GraphQL polling, 0 REST cost)..."
while true; do
  RESULT=$(gh api graphql -f query="
    {
      repository(owner:\"$OWNER\", name:\"$NAME\") {
        workflowRun: object(expression: \"\") { __typename }
      }
      node(id: \"WFR_$(printf '%s' "$RUN_ID" | base64 | tr -d '=')\") {
        ... on WorkflowRun { status conclusion databaseId }
      }
    }
  " 2>/dev/null || echo '{}')

  # Simpler fallback: use the checkSuites approach
  STATUS=$(gh api graphql -f query="
    {
      repository(owner:\"$OWNER\", name:\"$NAME\") {
        ref(qualifiedName:\"refs/heads/main\") {
          target {
            ... on Commit {
              checkSuites(last:10) {
                nodes {
                  workflowRun { databaseId }
                  status conclusion
                }
              }
            }
          }
        }
      }
    }
  " --jq ".data.repository.ref.target.checkSuites.nodes[] | select(.workflowRun.databaseId == $RUN_ID) | {status, conclusion}" 2>/dev/null || echo '{}')

  STATUS_VAL=$(echo "$STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null || echo "")

  if [ "$STATUS_VAL" = "COMPLETED" ]; then
    CONCLUSION=$(echo "$STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('conclusion',''))" 2>/dev/null || echo "")
    echo "Run $RUN_ID completed: $CONCLUSION"
    break
  elif [ -z "$STATUS_VAL" ]; then
    echo "  Run not yet visible in checkSuites, waiting 30s..."
  else
    echo "  Status: $STATUS_VAL — waiting 30s..."
  fi
  sleep 30
done

# ── Download artifact (2 REST calls: list + download) ────────────────────────
if [ -n "$ARTIFACT" ]; then
  echo "Downloading artifact '$ARTIFACT'..."
  mkdir -p "$OUTDIR"
  gh run download "$RUN_ID" --repo "$REPO" -n "$ARTIFACT" --dir "$OUTDIR"
  echo "Results in $OUTDIR:"
  ls -la "$OUTDIR"
  if [ -f "$OUTDIR/results.json" ]; then
    echo "=== results.json ==="
    cat "$OUTDIR/results.json"
  fi
else
  echo "No artifact name provided — skipping download."
  echo "To download later (2 REST calls): gh run download $RUN_ID --repo $REPO -n <artifact> --dir <dir>"
fi
