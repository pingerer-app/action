#!/usr/bin/env bash
# Tests the action's work (`pingerer github-action`, in cli-rs/) against
# test/fake_api.py: bash test/run_tests.sh. PINGERER_BIN picks the binary.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
bin="${PINGERER_BIN:-$here/../../cli-rs/target/debug/pingerer}"
[[ -x "$bin" ]] || { echo "Build the CLI first (cargo build in cli-rs), or set PINGERER_BIN." >&2; exit 1; }
port="${PORT:-18765}"
log="$(mktemp)"
outputs="$(mktemp)"
failures=0

python3 "$here/fake_api.py" "$port" 2>"$log" &
server=$!
trap 'kill $server 2>/dev/null; wait $server 2>/dev/null; rm -f "$log" "$outputs"' EXIT
for _ in $(seq 1 50); do
  curl -s -o /dev/null "http://127.0.0.1:$port/" && break
  sleep 0.1
done

# run [VAR=value ...]: runs the action with those inputs; sets status and out.
run() {
  : >"$outputs"
  out="$(env -i PATH="$PATH" HOME="$HOME" GITHUB_OUTPUT="$outputs" PINGERER_BASE_URL="http://127.0.0.1:$port" \
    PINGERER_API_TOKEN=test-token PINGERER_INTERVAL=0s "$@" "$bin" github-action 2>&1)"
  status=$?
}

check() {
  local name="$1"
  shift
  if "$@"; then
    printf 'ok   %s\n' "$name"
  else
    printf 'FAIL %s\n%s\n' "$name" "$out"
    failures=$((failures + 1))
  fi
}

contains() { [[ "$1" == *"$2"* ]]; }
requested() { grep -qF -- "$1" "$log"; }

run PINGERER_ACTION=pause PINGERER_SITES="yourbakery.com, site_2" PINGERER_MONITORS=mon_3
check "pause pauses sites (retrying a 429) and monitors" test $status -eq 0
check "pause says what it paused" contains "$out" "Paused shop.yourbakery.com (site_2): paused"
check "pause posts to each" requested "POST /api/v1/monitors/mon_3/pause"

run PINGERER_ACTION=resume PINGERER_SITES=yourbakery.com
check "resume" contains "$out" "Resumed yourbakery.com (site_1): pending"

run PINGERER_ACTION=pause
check "pause needs a site or monitor" test $status -ne 0
check "and says so" contains "$out" "Which ones?"

run PINGERER_ACTION=pause PINGERER_SITES=nowhere.example
check "an unknown site fails" test $status -ne 0
check "with the API's message" contains "$out" "wasn't found"

run PINGERER_ACTION=maintenance-start PINGERER_SITES="yourbakery.com
shop.yourbakery.com" PINGERER_DURATION=20m PINGERER_MESSAGE="Deploying"
check "maintenance-start opens a window" test $status -eq 0
check "for the duration, quietly" requested '"duration":1200,"notify_subscribers_before":false,"message":"Deploying"'
check "and outputs its id" grep -q "^mw_1$" "$outputs"

run PINGERER_ACTION=maintenance-start PINGERER_MONITORS=mon_1
check "maintenance-start needs sites" contains "$out" "Which sites?"

run PINGERER_ACTION=maintenance-start PINGERER_SITES=yourbakery.com PINGERER_DURATION=soon
check "a bad duration fails" contains "$out" "isn't a duration"

run PINGERER_ACTION=maintenance-end PINGERER_MAINTENANCE_WINDOW_ID=mw_1
check "maintenance-end ends the window" contains "$out" "Ended maintenance Deploy (mw_1): done."

run PINGERER_ACTION=maintenance-start PINGERER_SITES=shop.yourbakery.com PINGERER_TITLE="Release 42"
run PINGERER_ACTION=maintenance-end PINGERER_SITES=shop.yourbakery.com PINGERER_TITLE="Release 42"
check "maintenance-end finds the window by site and title" contains "$out" "Ended maintenance Release 42 (mw_2)"

run PINGERER_ACTION=check-now PINGERER_SITES=yourbakery.com PINGERER_REGION=iad
check "check-now checks the site's uptime monitors" test $status -eq 0
check "only the uptime ones" bash -c "! grep -q 'mon_2/test' '$log'"
check "from the region" requested 'POST /api/v1/monitors/mon_1/test {"region":"iad"}'
check "and reports up" grep -q "^up$" "$outputs"

run PINGERER_ACTION=check-now PINGERER_MONITORS=mon_3
check "check-now fails when a check fails" test $status -ne 0
check "naming it" contains "$out" "mon_3 failed its check."
check "and outputs down" grep -q "^down$" "$outputs"

run PINGERER_ACTION=wait-until-up PINGERER_SITES=shop.yourbakery.com PINGERER_TIMEOUT=1m
check "wait-until-up skips paused monitors, and fails when nothing's left" contains "$out" "Nothing to check"

run PINGERER_ACTION=resume PINGERER_MONITORS=mon_3
run PINGERER_ACTION=wait-until-up PINGERER_SITES=shop.yourbakery.com PINGERER_TIMEOUT=1m
check "wait-until-up waits until the checks pass" test $status -eq 0
check "saying how long it took" contains "$out" "Up after 2 checks"

run PINGERER_ACTION=wait-until-up PINGERER_MONITORS=mon_1 PINGERER_TIMEOUT=0s
check "wait-until-up passes at once when up" test $status -eq 0

run PINGERER_ACTION=wait-until-up PINGERER_MONITORS=mon_1 PINGERER_TIMEOUT=0s PINGERER_INTERVAL=soon
check "a bad interval fails" contains "$out" "soon isn't a duration"

run PINGERER_ACTION=deploy
check "an unknown action fails" contains "$out" "deploy isn't an action"

run PINGERER_ACTION=pause PINGERER_SITES=yourbakery.com PINGERER_API_TOKEN=
check "the token is required" contains "$out" "api_token is required"

if ((failures > 0)); then
  printf '\n%d failed\n' "$failures"
  exit 1
fi
printf '\nAll passed\n'
