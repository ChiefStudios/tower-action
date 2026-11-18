#!/usr/bin/env bash
# Deploys through tower with a GitHub OIDC token, then polls until the deploy is terminal.
set -euo pipefail

: "${TOWER_URL:?}"
POLL_INTERVAL="${TOWER_POLL_INTERVAL:-10}"
TIMEOUT_MIN="${TOWER_TIMEOUT_MIN:-15}"
BASE="${TOWER_URL%/}"
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-0}"

# 1. OIDC token (GITHUB_OIDC_TOKEN lets tests skip the GitHub call)
if [ -n "${GITHUB_OIDC_TOKEN:-}" ]; then
  JWT="$GITHUB_OIDC_TOKEN"
else
  JWT=$(curl -fsS -H "Authorization: Bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN:?need permissions: id-token: write}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL:?need permissions: id-token: write}&audience=tower" | jq -r .value)
fi
echo "::add-mask::$JWT"

# 2. deploy (retry when tower says busy)
attempt=0
while :; do
  attempt=$((attempt + 1))
  HDRS=$(mktemp); BODY=$(mktemp)
  CODE=$(curl -sS -o "$BODY" -D "$HDRS" -w '%{http_code}' -X POST "$BASE/api/ci/deploy" \
    -H "Authorization: Bearer $JWT" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg u "$RUN_URL" '{run_url:$u}')") || CODE=000
  case "$CODE" in
    200) break ;;
    503)
      if [ "$attempt" -ge 3 ]; then echo "::error::tower is busy, giving up"; exit 1; fi
      WAIT=$(awk 'tolower($1)=="retry-after:"{print $2+0}' "$HDRS"); sleep "${TOWER_RETRY_SLEEP:-${WAIT:-10}}" ;;
    401) echo "::error::tower rejected the OIDC token (invalid, expired or replayed)"; exit 1 ;;
    403) MSG=$(jq -r '.error // empty' "$BODY" 2>/dev/null || true); echo "::error::${MSG:-no tower binding for ${GITHUB_REPOSITORY:-?}@${GITHUB_REF:-?}}"; exit 1 ;;
    *) echo "::error::tower deploy request failed (HTTP $CODE)"; exit 1 ;;
  esac
done

jq -e .deploy_id "$BODY" >/dev/null 2>&1 || { echo "::error::tower returned an unexpected response (not a deploy ticket)"; exit 1; }
DEPLOY_ID=$(jq -r .deploy_id "$BODY"); POLL_URL=$(jq -r .poll_url "$BODY"); POLL_TOKEN=$(jq -r .poll_token "$BODY")
echo "::add-mask::$POLL_TOKEN"
echo "Deploy $DEPLOY_ID queued"

# 3. poll
DEADLINE=$(( $(date +%s) + TIMEOUT_MIN * 60 ))
STATUS=queued; SITE=""
while :; do
  R=$(curl -sS -H "Authorization: Bearer $POLL_TOKEN" "$POLL_URL" || echo '{}')
  # a non-JSON response (for example a proxy 502 while tower restarts) is "no update"
  if echo "$R" | jq -e . >/dev/null 2>&1; then
    S=$(echo "$R" | jq -r '.status // empty' 2>/dev/null || true); [ -n "$S" ] && STATUS="$S"
    SITE=$(echo "$R" | jq -r '.site_url // empty' 2>/dev/null || true)
    [ "$(echo "$R" | jq -r '.terminal // false' 2>/dev/null || true)" = "true" ] && break
  fi
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then echo "::error::timed out waiting for deploy (last status: $STATUS)"; exit 1; fi
  sleep "$POLL_INTERVAL"
done

# 4. summary
LINE="tower deploy $DEPLOY_ID: $STATUS${SITE:+ — $SITE}"
echo "$LINE"
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "$LINE" >> "$GITHUB_STEP_SUMMARY"
[ "$STATUS" = "success" ] || { echo "::error::deploy ended as $STATUS"; exit 1; }
