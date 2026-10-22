#!/usr/bin/env bash
# The Pingerer GitHub Action (action.yml): pauses and resumes sites and
# monitors, opens and ends maintenance windows, runs checks now, and waits
# until sites are up, through Pingerer's API (https://pingerer.com/docs/api).
# Needs bash, curl and jq, which GitHub's runners have.
#
# Reads its inputs from the environment (action.yml sets them):
#   PINGERER_API_TOKEN, PINGERER_ACTION, PINGERER_SITES, PINGERER_MONITORS,
#   PINGERER_DURATION, PINGERER_TITLE, PINGERER_MESSAGE,
#   PINGERER_MAINTENANCE_WINDOW_ID, PINGERER_TIMEOUT, PINGERER_INTERVAL,
#   PINGERER_REGION, PINGERER_ACCOUNT, PINGERER_BASE_URL
# and writes its outputs to $GITHUB_OUTPUT when it's set.
set -euo pipefail
# Errors inside $(...) stop the script too (bash 4.4 and later; the
# functions below also exit on a failed call for older ones).
shopt -s inherit_errexit 2>/dev/null || true

BASE_URL="${PINGERER_BASE_URL:-https://pingerer.com}"
BASE_URL="${BASE_URL%/}"
ACTION="${PINGERER_ACTION:-}"
TOKEN="${PINGERER_API_TOKEN:-}"
AVAILABILITY_KINDS='["http","tcp","ping","smtp"]'

log() { printf '%s\n' "$*" >&2; }
fail() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then printf '::error title=Pingerer::%s\n' "$*" >&2; else log "Error: $*"; fi
  exit 1
}
output() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      printf '%s<<PINGERER_EOF\n' "$1"
      printf '%s\n' "$2"
      printf 'PINGERER_EOF\n'
    } >>"$GITHUB_OUTPUT"
  fi
  printf '%s=%s\n' "$1" "$2"
}

command -v curl >/dev/null || fail "curl isn't installed."
command -v jq >/dev/null || fail "jq isn't installed."
[[ -n "$TOKEN" ]] || fail "api_token is required: a Pingerer API token with read and write access (from a secret)."
[[ -n "${GITHUB_ACTIONS:-}" ]] && printf '::add-mask::%s\n' "$TOKEN"

# "a.com, b.com" or one per line, as a JSON array.
list() { jq -nc --arg value "${1:-}" '$value | gsub("[,\\s]+"; " ") | split(" ") | map(select(length > 0))'; }
SITES="$(list "${PINGERER_SITES:-}")"
MONITORS="$(list "${PINGERER_MONITORS:-}")"

# "30s", "15m", "2h", "1d" or seconds, as seconds.
seconds() {
  local value="${1// /}"
  case "$value" in
    *[0-9]s) echo $((${value%s})) ;;
    *[0-9]m) echo $((${value%m} * 60)) ;;
    *[0-9]h) echo $((${value%h} * 3600)) ;;
    *[0-9]d) echo $((${value%d} * 86400)) ;;
    *[!0-9]* | "") fail "$1 isn't a duration like 30s, 15m or 2h." ;;
    *) echo $((value)) ;;
  esac
}

urlencode() { jq -rn --arg value "$1" '$value | @uri'; }

# api METHOD PATH [JSON]: prints the response body; exits on an error
# unless ALLOW_STATUS lists the status. Sets API_STATUS.
API_STATUS=""
api() {
  local method="$1" path="$2" body="${3:-}" response attempt
  local args=(-sS -X "$method" -H "Authorization: Bearer $TOKEN" -H "Accept: application/json"
    -H "User-Agent: pingerer-github-action/1" --max-time 120 -w '\n%{http_code}')
  [[ -n "${PINGERER_ACCOUNT:-}" ]] && args+=(-H "Pingerer-Account: $PINGERER_ACCOUNT")
  [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" --data "$body")
  for attempt in 1 2 3 4; do
    response="$(curl "${args[@]}" "$BASE_URL$path")" || fail "Couldn't reach $BASE_URL ($method $path)."
    API_STATUS="${response##*$'\n'}"
    response="${response%$'\n'*}"
    if [[ "$API_STATUS" == 429 && $attempt -lt 4 ]]; then
      log "Rate limited; waiting $((attempt * 5))s."
      sleep $((attempt * 5))
      continue
    fi
    break
  done
  if [[ "$API_STATUS" -ge 400 && " ${ALLOW_STATUS:-} " != *" $API_STATUS "* ]]; then
    local message
    message="$(printf '%s' "$response" | jq -r '.message // empty' 2>/dev/null || true)"
    fail "$method $path: ${message:-HTTP $API_STATUS}"
  fi
  printf '%s' "$response"
}

need_targets() {
  if [[ "$SITES" == "[]" && "$MONITORS" == "[]" ]]; then
    fail "Which ones? Set site (ids like site_8xKq2, or hosts like yourbakery.com) or monitor (ids like mon_8xKq2)."
  fi
}

need_sites() {
  [[ "$SITES" != "[]" ]] || fail "Which sites? Set site (ids or hosts). Maintenance windows cover sites, not single monitors."
}

# The uptime monitors (http, tcp, ping) to check: those named, and each
# named site's active ones.
check_targets() {
  local targets="$MONITORS" site monitors
  for site in $(jq -r '.[]' <<<"$SITES"); do
    monitors="$(api GET "/api/v1/monitors?site_id=$(urlencode "$site")&per_page=100")" || exit 1
    targets="$(jq -c --argjson kinds "$AVAILABILITY_KINDS" --argjson have "$targets" \
      '$have + [.data[] | select((.kind as $k | $kinds | index($k)) and (.paused | not)) | .id] | unique' <<<"$monitors")"
    if ! jq -e --argjson kinds "$AVAILABILITY_KINDS" '[.data[] | select(.kind as $k | $kinds | index($k))] | length > 0' <<<"$monitors" >/dev/null; then
      fail "$site has no uptime monitors (http, tcp or ping) to check."
    fi
  done
  [[ "$targets" != "[]" ]] || fail "Nothing to check: the uptime monitors are paused. Resume them first."
  printf '%s' "$targets"
}

# Runs one check of each monitor now; prints [{id, ok, ...}].
run_checks() {
  local targets="$1" results="[]" id body response
  body="{}"
  [[ -n "${PINGERER_REGION:-}" ]] && body="$(jq -nc --arg region "$PINGERER_REGION" '{region: $region}')"
  for id in $(jq -r '.[]' <<<"$targets"); do
    response="$(ALLOW_STATUS="501" api POST "/api/v1/monitors/$(urlencode "$id")/test" "$body")" || exit 1
    if [[ "$API_STATUS" == 501 ]]; then
      # No test runs on this server: go by the monitor's last status.
      response="$(api GET "/api/v1/monitors/$(urlencode "$id")")" || exit 1
      response="$(jq -c '{data: {ok: (.data.status == "up"), error: (if .data.status == "up" then null else "status is \(.data.status)" end), status_code: null, latency_ms: null, region: null}}' <<<"$response")"
    fi
    results="$(jq -c --arg id "$id" --argjson have "$results" '$have + [.data + {id: $id}]' <<<"$response")"
  done
  printf '%s' "$results"
}

report() {
  jq -r '.[] | "  \(if .ok then "up  " else "DOWN" end) \(.id)\(if .region then " from \(.region)" else "" end)\(if .status_code then ": \(.status_code)" else "" end)\(if .latency_ms then " in \(.latency_ms)ms" else "" end)\(if .error then " (\(.error))" else "" end)"' <<<"$1" >&2
}

case "$ACTION" in
  pause | resume)
    need_targets
    for site in $(jq -r '.[]' <<<"$SITES"); do
      response="$(api POST "/api/v1/sites/$(urlencode "$site")/$ACTION")"
      log "$(jq -r --arg action "$ACTION" '"\(if $action == "pause" then "Paused" else "Resumed" end) \(.data.host) (\(.data.id)): \(.data.status)"' <<<"$response")"
    done
    for monitor in $(jq -r '.[]' <<<"$MONITORS"); do
      response="$(api POST "/api/v1/monitors/$(urlencode "$monitor")/$ACTION")"
      log "$(jq -r --arg action "$ACTION" '"\(if $action == "pause" then "Paused" else "Resumed" end) \(.data.name) (\(.data.id)): \(.data.status)"' <<<"$response")"
    done
    ;;

  maintenance-start)
    need_sites
    duration="$(seconds "${PINGERER_DURATION:-15m}")"
    body="$(jq -nc --argjson sites "$SITES" --arg title "${PINGERER_TITLE:-Deploy}" --arg message "${PINGERER_MESSAGE:-}" --argjson duration "$duration" \
      '{sites: $sites, title: $title, duration: $duration, notify_subscribers_before: false} + (if $message == "" then {} else {message: $message} end)')"
    response="$(api POST /api/v1/maintenance_windows "$body")"
    log "$(jq -r '"Maintenance \(.data.title) (\(.data.id)) is on until \(.data.ends_at): checks keep running, but nothing alerts."' <<<"$response")"
    output maintenance_window_id "$(jq -r '.data.id' <<<"$response")"
    ;;

  maintenance-end)
    ids="[]"
    if [[ -n "${PINGERER_MAINTENANCE_WINDOW_ID:-}" ]]; then
      ids="$(jq -nc --arg id "$PINGERER_MAINTENANCE_WINDOW_ID" '[$id]')"
    else
      need_sites
      # The in-progress windows with this title that cover any of the sites.
      windows="$(api GET "/api/v1/maintenance_windows?state=upcoming&per_page=100")"
      ids="$(jq -c --argjson sites "$SITES" --arg title "${PINGERER_TITLE:-Deploy}" \
        '[.data[] | select(.state == "in_progress" and .title == $title and (.all_sites or ([.sites[] | .id, .host] as $covered | any($sites[]; . as $s | $covered | index($s))))) | .id]' <<<"$windows")"
      [[ "$ids" != "[]" ]] || log "No maintenance window titled \"${PINGERER_TITLE:-Deploy}\" is in progress for those sites."
    fi
    for id in $(jq -r '.[]' <<<"$ids"); do
      response="$(api POST "/api/v1/maintenance_windows/$(urlencode "$id")/end")"
      log "$(jq -r '"Ended maintenance \(.data.title) (\(.data.id)): \(.data.state)."' <<<"$response")"
    done
    output maintenance_window_id "$(jq -r 'join(",")' <<<"$ids")"
    ;;

  check-now)
    need_targets
    targets="$(check_targets)"
    results="$(run_checks "$targets")"
    report "$results"
    output results "$results"
    if jq -e 'all(.ok)' <<<"$results" >/dev/null; then
      output status up
    else
      output status down
      fail "$(jq -r '[.[] | select(.ok | not) | .id] | join(", ")' <<<"$results") failed its check."
    fi
    ;;

  wait-until-up)
    need_targets
    timeout="$(seconds "${PINGERER_TIMEOUT:-5m}")"
    interval="$(seconds "${PINGERER_INTERVAL:-15s}")"
    targets="$(check_targets)"
    started="$(date +%s)"
    attempt=0
    while :; do
      attempt=$((attempt + 1))
      results="$(run_checks "$targets")"
      if jq -e 'all(.ok)' <<<"$results" >/dev/null; then
        log "Up after $attempt check$([[ $attempt == 1 ]] || echo s) ($(($(date +%s) - started))s):"
        report "$results"
        output results "$results"
        output status up
        exit 0
      fi
      elapsed=$(($(date +%s) - started))
      if ((elapsed + interval > timeout)); then
        report "$results"
        output results "$results"
        output status down
        fail "Still down after $((timeout))s: $(jq -r '[.[] | select(.ok | not) | .id] | join(", ")' <<<"$results")."
      fi
      log "Not up yet ($(jq -r '[.[] | select(.ok | not) | .id] | join(", ")' <<<"$results")); checking again in ${interval}s."
      sleep "$interval"
    done
    ;;

  "") fail "action is required: pause, resume, maintenance-start, maintenance-end, check-now or wait-until-up." ;;
  *) fail "$ACTION isn't an action: use pause, resume, maintenance-start, maintenance-end, check-now or wait-until-up." ;;
esac
