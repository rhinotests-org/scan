#!/usr/bin/env bash
# Starts a RhinoTests scan, waits for it and decides whether the job passes.
# Everything is read from RT_* variables set by action.yml; nothing here is specific to GitHub
# except the optional GITHUB_OUTPUT and GITHUB_STEP_SUMMARY files.
#
# Exit codes: 0 passed · 1 open findings at or above `fail-on` · 2 the scan could not run or failed.
set -euo pipefail

API_URL="${RT_API_URL:-https://app.rhinotests.com/ci/v1}"
DOMAIN="${RT_DOMAIN:-}"
TOKEN="${RT_TOKEN:-}"
PROFILE="${RT_PROFILE:-quick}"
FAIL_ON="${RT_FAIL_ON:-high}"
TIMEOUT_MINUTES="${RT_TIMEOUT_MINUTES:-75}"
POLL_SECONDS="${RT_POLL_SECONDS:-10}"
RETRY_SECONDS="${RT_RETRY_SECONDS:-5}"
MAX_RETRIES=5
USER_AGENT="rhinotests-scan-action/1"

fail() {
  echo "::error::$1"
  exit 2
}

command -v curl >/dev/null || fail "curl is required on the runner."
command -v jq >/dev/null || fail "jq is required on the runner."

[ -n "$DOMAIN" ] || fail "The 'domain' input is empty."
[ -n "$TOKEN" ] || fail "The 'token' input is empty. Save your API token as a repository secret and pass it as token: \${{ secrets.RHINOTESTS_TOKEN }}."
case "$PROFILE" in quick | standard | full) ;; *) fail "profile must be quick, standard or full (got '$PROFILE')." ;; esac
case "$FAIL_ON" in none | low | medium | high) ;; *) fail "fail-on must be none, low, medium or high (got '$FAIL_ON')." ;; esac
case "$TIMEOUT_MINUTES" in '' | *[!0-9]*) fail "timeout-minutes must be a whole number (got '$TIMEOUT_MINUTES')." ;; esac

# The token never appears in the log, even if a later command echoes it.
echo "::add-mask::$TOKEN"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
status=""
body=""

# request METHOD PATH [JSON]: sets $status and $body. Retries what is worth retrying: no answer,
# rate limits, server errors, and a 403 that did not come from the API itself (the firewall in front
# of it answers 403 without our error format).
request() {
  local method=$1 path=$2 data=${3:-} attempt=0 wait retry_after
  while :; do
    local args=(-sS -X "$method" -o "$work/body" -D "$work/headers" -w '%{http_code}'
      --max-time 30 -A "$USER_AGENT" -H "Authorization: Bearer $TOKEN" -H "Accept: application/json")
    [ -n "$data" ] && args+=(-H "Content-Type: application/json" --data "$data")
    status=$(curl "${args[@]}" "$API_URL$path" 2>"$work/error" || true)
    [ -n "$status" ] || status=000
    body=$(cat "$work/body" 2>/dev/null || true)

    local transient=false
    case "$status" in
      000 | 429 | 5??) transient=true ;;
      403) [ -n "$(jq -r '.code // empty' <<<"$body" 2>/dev/null || true)" ] || transient=true ;;
    esac
    $transient || return 0
    attempt=$((attempt + 1))
    [ "$attempt" -le "$MAX_RETRIES" ] || return 0
    wait=$((RETRY_SECONDS * attempt))
    retry_after=$(awk 'tolower($1)=="retry-after:" {gsub("\r",""); print $2}' "$work/headers" 2>/dev/null | tail -1)
    case "$retry_after" in '' | *[!0-9]*) ;; *) [ "$retry_after" -le 120 ] && wait=$retry_after ;; esac
    echo "No usable answer (HTTP $status); retrying in ${wait}s ($attempt/$MAX_RETRIES)."
    sleep "$wait"
  done
}

field() { jq -r "$1 // empty" <<<"$body" 2>/dev/null || true; }

explain() {
  local code message
  code=$(field .code)
  message=$(field .message)
  case "$status:$code" in
    401:*) echo "The API token is missing, revoked or expired. Create a new one in RhinoTests (Account → API tokens) and update the RHINOTESTS_TOKEN secret." ;;
    402:*) echo "Your organization does not have enough credits for a $PROFILE scan." ;;
    403:plan_required) echo "Your plan does not include CI scans. They are part of the Equipo and Auditoría plans." ;;
    403:*) echo "The request was blocked before reaching RhinoTests (HTTP 403). Try again later; if it keeps happening, contact support." ;;
    404:*) echo "RhinoTests does not know this scan any more." ;;
    409:domain_unverified) echo "The domain $DOMAIN is not verified yet. Verify it in RhinoTests (Domains) first." ;;
    409:scan_in_progress) echo "A scan of $DOMAIN is already running. Wait for it to finish, or avoid running two pipelines for the same domain at once." ;;
    422:profile_not_allowed) echo "The $PROFILE profile is not allowed for $DOMAIN (the full profile needs active tests authorized for the domain)." ;;
    422:*) echo "RhinoTests does not know the domain $DOMAIN in your organization, or the request is invalid${message:+ ($message)}." ;;
    429:*) echo "Too many requests with this token. Try again in a minute." ;;
    000:*) echo "RhinoTests could not be reached: $(tr -d '\n' <"$work/error" 2>/dev/null)" ;;
    *) echo "Unexpected answer from RhinoTests (HTTP $status${code:+, $code})${message:+: $message}." ;;
  esac
}

output() { [ -z "${GITHUB_OUTPUT:-}" ] || echo "$1=$2" >>"$GITHUB_OUTPUT"; }
summary() { [ -z "${GITHUB_STEP_SUMMARY:-}" ] || echo "$1" >>"$GITHUB_STEP_SUMMARY"; }

echo "Starting a $PROFILE scan of $DOMAIN."
request POST /scans "$(jq -nc --arg d "$DOMAIN" --arg p "$PROFILE" '{domain: $d, profile: $p}')"
[ "$status" = 201 ] || fail "$(explain)"

scan_id=$(field .id)
report_url=$(field .reportUrl)
[ -n "$scan_id" ] || fail "RhinoTests answered without a scan id."
output scan-id "$scan_id"
output report-url "$report_url"
echo "Scan $scan_id started. Report: $report_url"

deadline=$(($(date +%s) + TIMEOUT_MINUTES * 60))
last=""
while :; do
  request GET "/scans/$scan_id"
  [ "$status" = 200 ] || fail "$(explain)"
  scan_status=$(field .status)
  case "$scan_status" in done | failed) break ;; esac
  now="$scan_status · $(field .phase) · $(field .percent)%"
  [ "$now" = "$last" ] || echo "$now"
  last=$now
  if [ "$(date +%s)" -ge "$deadline" ]; then
    summary "### RhinoTests · $DOMAIN"
    summary "The scan did not finish in $TIMEOUT_MINUTES minutes. It keeps running: [open the report]($report_url)."
    fail "The scan did not finish in $TIMEOUT_MINUTES minutes. It keeps running in RhinoTests: $report_url"
  fi
  sleep "$POLL_SECONDS"
done
output status "$scan_status"

if [ "$scan_status" = failed ]; then
  reason="$(field .failure.message)"
  code="$(field .failure.code)"
  summary "### RhinoTests · $DOMAIN"
  summary "The scan failed${code:+ (\`$code\`)}${reason:+: $reason}. [Open it in RhinoTests]($report_url)."
  fail "The scan failed${code:+ ($code)}${reason:+: $reason}"
fi

grade=$(field .result.grade)
open=$(field .result.open)
high=$(field .result.bySeverity.high)
medium=$(field .result.bySeverity.medium)
low=$(field .result.bySeverity.low)
: "${open:=0}" "${high:=0}" "${medium:=0}" "${low:=0}"
output grade "$grade"
output open "$open"
output high "$high"
output medium "$medium"
output low "$low"

case "$FAIL_ON" in
  none) blocking=0 ;;
  high) blocking=$high ;;
  medium) blocking=$((high + medium)) ;;
  low) blocking=$((high + medium + low)) ;;
esac

echo "Grade $grade · $open open findings (high $high, medium $medium, low $low)."
summary "### RhinoTests · $DOMAIN"
summary ""
summary "| Grade | Open | High | Medium | Low |"
summary "| :-: | :-: | :-: | :-: | :-: |"
summary "| **$grade** | $open | $high | $medium | $low |"
summary ""
summary "[Open the report]($report_url) · profile \`$PROFILE\` · fail-on \`$FAIL_ON\`"

if [ "$blocking" -gt 0 ]; then
  echo "::error::$blocking open finding(s) at severity $FAIL_ON or higher. Report: $report_url"
  exit 1
fi
echo "Passed: no open findings at severity $FAIL_ON or higher."
