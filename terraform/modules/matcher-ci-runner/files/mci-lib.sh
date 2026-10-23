#!/usr/bin/env bash
# Shared helpers of the matcher CI runner host. Source it, or run `mci-lib.sh <command>`.
#
# GitHub credential (/etc/matcher-ci/credential.env, root 0600, pushed over SSH from SOPS
# secrets/matcher-ci-runner.env; never in user data, never printed). One of:
#   GitHub App (preferred):  GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, GITHUB_APP_PRIVATE_KEY_B64
#   fine-grained PAT:        GITHUB_PAT            (repository: matcher only)
# Both need repository permissions "Administration: read & write" (runner registration) and
# "Variables: read & write" (the MATCHER_CI_RUNNER_HEARTBEAT repository variable).
# Bootstrap only: /etc/matcher-ci/registration-token (a 1-hour registration token minted by an
# operator, `REGISTRATION_TOKEN=... EXPIRES_AT=<epoch>`); it can register runners and nothing else.
#
# Nothing in this file may print a token. Do not add `set -x`.
# shellcheck disable=SC1090  # config/credential files are root-owned and sourced by design
set -euo pipefail

MCI_CONFIG="${MCI_CONFIG:-/etc/matcher-ci/config.env}"
MCI_CRED="${MCI_CRED:-/etc/matcher-ci/credential.env}"
MCI_REGTOKEN="${MCI_REGTOKEN:-/etc/matcher-ci/registration-token}"
MCI_RUN="${MCI_RUN:-/run/matcher-ci}"
MCI_TEXTFILE="${MCI_TEXTFILE:-/var/lib/node_exporter/textfile}"
MCI_API=https://api.github.com
MCI_NFT_TMPL="${MCI_NFT_TMPL:-/opt/matcher-ci/matcher-ci.nft.tmpl}"

# shellcheck disable=SC1090
[ -f "$MCI_CONFIG" ] && source "$MCI_CONFIG"

mci_log() { echo "matcher-ci: $*" >&2; }

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# Prints the credential mode: app | pat | regtoken | none
mci_cred_mode() {
  if [ -f "$MCI_CRED" ]; then
    # shellcheck disable=SC1090
    ( source "$MCI_CRED"
      if [ -n "${GITHUB_APP_ID:-}" ] && [ -n "${GITHUB_APP_INSTALLATION_ID:-}" ] && [ -n "${GITHUB_APP_PRIVATE_KEY_B64:-}" ]; then echo app
      elif [ -n "${GITHUB_PAT:-}" ]; then echo pat
      else echo none; fi )
  elif [ -f "$MCI_REGTOKEN" ]; then echo regtoken
  else echo none; fi
}

# GitHub App JWT (RS256, 9 minutes).
mci_app_jwt() {
  local now iat exp header payload key sig
  now=$(date +%s); iat=$((now - 60)); exp=$((now + 540))
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$iat" "$exp" "$GITHUB_APP_ID" | b64url)
  key=$(mktemp "${MCI_RUN}/key.XXXXXX"); chmod 600 "$key"
  printf '%s' "$GITHUB_APP_PRIVATE_KEY_B64" | openssl base64 -d -A > "$key"
  sig=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$key" | b64url) || { rm -f "$key"; return 1; }
  rm -f "$key"
  printf '%s.%s.%s' "$header" "$payload" "$sig"
}

# An API token (installation token, cached until 5 minutes before expiry, or the PAT). Fails in regtoken/none mode.
mci_api_token() {
  install -d -m 0700 "$MCI_RUN"
  local mode; mode=$(mci_cred_mode)
  case "$mode" in
    pat) ( source "$MCI_CRED"; printf '%s' "$GITHUB_PAT" ) ;;
    app)
      local cache="$MCI_RUN/installation-token" now; now=$(date +%s)
      if [ -f "$cache" ] && [ "$(sed -n 1p "$cache")" -gt $((now + 300)) ] 2>/dev/null; then sed -n 2p "$cache"; return 0; fi
      local jwt resp tok expires
      jwt=$( source "$MCI_CRED"; mci_app_jwt ) || return 1
      resp=$( source "$MCI_CRED"
              curl -fsS --max-time 20 -X POST -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" \
                "$MCI_API/app/installations/${GITHUB_APP_INSTALLATION_ID}/access_tokens" ) || return 1
      tok=$(printf '%s' "$resp" | jq -r '.token // empty'); expires=$(printf '%s' "$resp" | jq -r '.expires_at // empty')
      [ -n "$tok" ] || return 1
      ( umask 077; printf '%s\n%s\n' "$(date -d "$expires" +%s)" "$tok" > "$cache" )
      printf '%s' "$tok" ;;
    *) return 1 ;;
  esac
}

# curl against the GitHub API with the credential. Args: METHOD PATH [JSON-BODY]
mci_gh() {
  local tok args=()
  tok=$(mci_api_token) || return 1
  [ -z "${3:-}" ] || args=(-H "Content-Type: application/json" --data "$3")
  curl -fsS --max-time 30 -X "$1" -H "Authorization: Bearer $tok" -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" "${args[@]}" "$MCI_API/$2"
}

# A runner registration token for $MCI_REPO.
mci_registration_token() {
  local mode; mode=$(mci_cred_mode)
  case "$mode" in
    app | pat) mci_gh POST "repos/${MCI_REPO}/actions/runners/registration-token" | jq -er '.token' ;;
    regtoken)
      ( source "$MCI_REGTOKEN"
        [ "${EXPIRES_AT:-0}" -gt $(( $(date +%s) + 120 )) ] || { mci_log "bootstrap registration token expired"; exit 1; }
        printf '%s' "$REGISTRATION_TOKEN" ) ;;
    *) mci_log "no GitHub credential installed (see runbooks/matcher-ci-runner.md)"; return 1 ;;
  esac
}

# Atomic textfile-collector write. Args: NAME (stdin: metrics)
mci_metrics() {
  local tmp; tmp=$(mktemp "${MCI_TEXTFILE}/.${1}.XXXXXX")
  cat > "$tmp"; chmod 0644 "$tmp"; mv -f "$tmp" "${MCI_TEXTFILE}/${1}.prom"
}

# Renders the host nftables ruleset from the template and config.env.
mci_render_nft() {
  local ssh metrics
  ssh=$(printf '%s' "${MCI_SSH_ALLOWED_V4:-}" | tr ',' '\n' | sed '/^$/d' | paste -sd, - | sed 's/,/, /g')
  metrics=$(printf '%s' "${MCI_METRICS_ALLOWED_V4:-}" | tr ',' '\n' | sed '/^$/d' | paste -sd, - | sed 's/,/, /g')
  # nft rejects an empty element list; 192.0.2.1 (TEST-NET-1) is unroutable and stands for "nobody".
  [ -n "$ssh" ] || ssh=192.0.2.1
  [ -n "$metrics" ] || metrics=192.0.2.1
  sed -e "s|@SSH_ALLOWED_V4@|${ssh}|" -e "s|@METRICS_ALLOWED_V4@|${metrics}|" "$MCI_NFT_TMPL"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    render-nft) mci_render_nft ;;
    cred-mode) mci_cred_mode ;;
    *) echo "usage: mci-lib.sh render-nft|cred-mode" >&2; exit 2 ;;
  esac
fi
