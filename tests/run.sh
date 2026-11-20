#!/usr/bin/env bash
# Runs scan.sh against tests/mock_server.py and checks the exit code and the messages.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

PORT="${PORT:-18765}"
python3 tests/mock_server.py "$PORT" &
server=$!
out=$(mktemp -d)
trap 'kill "$server" 2>/dev/null; rm -rf "$out"' EXIT
for _ in $(seq 1 50); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/scans/x" && break
  sleep 0.1
done

failures=0
# check NAME EXPECTED_EXIT EXPECTED_TEXT [VAR=value …]
check() {
  local name=$1 want=$2 text=$3
  shift 3
  : >"$out/output"
  : >"$out/summary"
  env RT_API_URL="http://127.0.0.1:$PORT" RT_DOMAIN=app.example.com RT_TOKEN="rt_$name" \
    RT_POLL_SECONDS=0 RT_RETRY_SECONDS=0 GITHUB_OUTPUT="$out/output" GITHUB_STEP_SUMMARY="$out/summary" \
    "$@" bash scan.sh >"$out/log" 2>&1
  local got=$?
  if [ "$got" = "$want" ] && grep -qF -- "$text" "$out/log" "$out/output" "$out/summary"; then
    echo "ok   $name ${*:-}"
  else
    echo "FAIL $name ${*:-}: exit $got (want $want), looking for: $text"
    sed 's/^/     /' "$out/log"
    failures=$((failures + 1))
  fi
}

check clean 0 "Passed: no open findings"
check clean 0 "grade=A"
check clean 0 "| **A** | 0 | 0 | 0 | 0 |"
check high 1 "2 open finding(s) at severity medium or higher" RT_FAIL_ON=medium
check high 1 "1 open finding(s) at severity high or higher"
check medium 0 "Passed" RT_FAIL_ON=high
check medium 1 "1 open finding(s) at severity medium" RT_FAIL_ON=medium
check low 0 "Passed" RT_FAIL_ON=medium
check low 1 "2 open finding(s) at severity low" RT_FAIL_ON=low
check high 0 "Passed" RT_FAIL_ON=none
# One run: the mock fails once per kind (403 without our format, 429 with Retry-After, 502).
check flaky 0 "retrying in"
check failed 2 "The scan failed (unreachable): The site did not answer"
check slow 2 "did not finish in 0 minutes" RT_TIMEOUT_MINUTES=0
check revoked 2 "missing, revoked or expired"
check poor 2 "not have enough credits"
check plan 2 "Equipo and Auditoría"
check unverified 2 "is not verified yet"
check busy 2 "already running"
check unknown 2 "does not know the domain"
check down 2 "Unexpected answer from RhinoTests (HTTP 503"
check clean 2 "profile must be" RT_PROFILE=deep
check clean 2 "fail-on must be" RT_FAIL_ON=critical
check clean 2 "timeout-minutes must be" RT_TIMEOUT_MINUTES=soon
check clean 2 "'domain' input is empty" RT_DOMAIN=
check clean 2 "'token' input is empty" RT_TOKEN=

# The token must never reach the log (the add-mask line is the one allowed mention).
env RT_API_URL="http://127.0.0.1:$PORT" RT_DOMAIN=app.example.com RT_TOKEN=rt_clean RT_POLL_SECONDS=0 \
  bash scan.sh 2>&1 | grep -v '^::add-mask::' | grep -q 'rt_clean' && {
  echo "FAIL the token appears in the log"
  failures=$((failures + 1))
}

[ "$failures" = 0 ] && echo "All checks passed." || echo "$failures check(s) failed."
exit "$failures"
