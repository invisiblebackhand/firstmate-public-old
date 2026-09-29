#!/usr/bin/env bash
# fm-jev-check.sh - report a Jev alias move or per-home resolver spend threshold.
#
# Usage:
#   fm-jev-check.sh [check]
#   fm-jev-check.sh arm
#   fm-jev-check.sh disarm
#
# `check` emits at most one line when jev-latest has a changed release date, this
# Firstmate home's resolver ledger reaches USD 10 in the current UTC month or
# USD 1 in the current UTC calendar day, or either check fails.
# A models request that errors, times out, or returns a non-200 reply fails the
# check only once two polls in a row fail, and any 200 reply resets that count.
# Every other failure is reported the first time it happens.
# The ledger is keyed by neither TypeSafe account nor API key and excludes other
# Jev consumers.
# TypeSafe's console is the account-wide USD 10/month authority; these are local
# estimates.
# `arm` writes and registers state/jev-monitor.check.sh for watcher polling.
# `disarm` removes that shim, its trust binding, and this check's records.
#
# The TypeSafe key is sent to curl only through a file descriptor header.
# The models listing is unmetered, and this script never makes an evaluation.
set -u

TYPESAFE_API_KEY_PRIVATE=${TYPESAFE_API_KEY:-}
export -n TYPESAFE_API_KEY_PRIVATE 2>/dev/null || true
unset TYPESAFE_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="$FM_HOME/state"
ALIAS_RECORD="$STATE/.jev-monitor-alias"
SPEND_RECORD="$STATE/.jev-monitor-spend"
FAILURE_RECORD="$STATE/.jev-monitor-failures"
CHECK_ID=jev-monitor
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
UNREGISTER_BIN="$SCRIPT_DIR/fm-check-unregister.sh"
TS_BASE=https://api.typesafe.ai
# One request must end well inside the watcher's FM_CHECK_TIMEOUT (default 30 seconds).
TS_TIMEOUT=10
FAILURES_BEFORE_ALERT=2
PRICE_PER_INPUT_TOKEN=0.000000042

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-jev-check.sh [check]  report an alias move or per-home resolver spend threshold
  fm-jev-check.sh arm      write and register state/jev-monitor.check.sh
  fm-jev-check.sh disarm   remove the check shim, trust binding, and records

See docs/configuration.md for the ledger scope, thresholds, and pin-bump procedure.
EOF
}

die_usage() {
  printf 'fm-jev-check: %s\n' "$1" >&2
  usage >&2
  exit 2
}

record_read() {  # <path>
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  IFS= read -r FM_JEV_RECORD < "$1" || return 1
  [ -n "$FM_JEV_RECORD" ]
}

record_write() {  # <path> <one line>
  local path=$1 value=$2 temp
  temp=$(umask 077; mktemp "$STATE/.fm-jev-check.XXXXXX") || return 1
  if ! printf '%s\n' "$value" > "$temp" || ! chmod 0600 "$temp" || ! mv -f -- "$temp" "$path"; then
    rm -f -- "$temp"
    return 1
  fi
}

append_finding() {
  if [ -z "${FINDINGS:-}" ]; then
    FINDINGS=$1
  else
    FINDINGS="$FINDINGS; $1"
  fi
}

request_failed() {  # <http code>
  local count=0 finding="Jev alias check failed: GET /v1/models returned $1"
  if [ -e "$FAILURE_RECORD" ] || [ -L "$FAILURE_RECORD" ]; then
    # A record that is not a count cannot vouch for earlier failures, so it alerts.
    count=$FAILURES_BEFORE_ALERT
    if record_read "$FAILURE_RECORD" && [[ $FM_JEV_RECORD =~ ^[1-9][0-9]{0,8}$ ]]; then
      count=$FM_JEV_RECORD
    fi
  fi
  count=$((count + 1))
  if ! record_write "$FAILURE_RECORD" "$count"; then
    # A failure that cannot be counted could never reach the threshold, so report it now.
    append_finding "$finding"
    append_finding 'Jev alias check failed: could not save request failure count'
  elif [ "$count" -ge "$FAILURES_BEFORE_ALERT" ]; then
    append_finding "$finding"
  fi
}

check_alias() {
  local response headers http release previous
  response=$(mktemp) || { append_finding 'Jev alias check failed: mktemp'; return; }
  headers=$(mktemp) || { rm -f "$response"; append_finding 'Jev alias check failed: mktemp'; return; }
  http=$(curl -sS --max-time "$TS_TIMEOUT" -D "$headers" -o "$response" -w '%{http_code}' \
    -X GET "$TS_BASE/v1/models" -H @/dev/fd/3 \
    3< <(printf 'Authorization: Bearer %s\n' "$TYPESAFE_API_KEY_PRIVATE") 2>/dev/null) || http=000
  if [ "$http" != 200 ]; then
    rm -f "$response" "$headers"
    request_failed "$http"
    return
  fi
  rm -f -- "$FAILURE_RECORD"
  if ! jq -e '
      def leap($year):
        ($year % 4 == 0 and $year % 100 != 0) or ($year % 400 == 0);
      def calendar_date:
        (try capture("^(?<year>[0-9]{4})-(?<month>[0-9]{2})-(?<day>[0-9]{2})$") catch null) as $parts |
        if $parts == null then false
        else
          ($parts.year | tonumber) as $year |
          ($parts.month | tonumber) as $month |
          ($parts.day | tonumber) as $day |
          ([31, (if leap($year) then 29 else 28 end), 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]) as $days |
          $year >= 1 and $month >= 1 and $month <= 12 and $day >= 1 and $day <= $days[$month - 1]
        end;
      type == "object" and
      (.models | type) == "array" and
      all(.models[];
        type == "object" and
        (.name | type) == "string" and (.name | length) > 0 and
        (.description | type) == "string" and
        (.release_date | calendar_date)) and
      ([.models[] | select(.name == "jev-latest")] | length) == 1
    ' "$response" >/dev/null 2>&1; then
    rm -f "$response" "$headers"
    append_finding 'Jev alias check failed: models response is malformed'
    return
  fi
  release=$(jq -r '.models[] | select(.name == "jev-latest") | .release_date' "$response")
  rm -f "$response" "$headers"
  previous=
  record_read "$ALIAS_RECORD" && previous=$FM_JEV_RECORD
  if [ -n "$previous" ] && [ "$previous" != "$release" ]; then
    append_finding "Jev alias moved: jev-latest release_date $previous -> $release; replay dispatch tests before any pin bump"
  fi
  record_write "$ALIAS_RECORD" "$release" || append_finding 'Jev alias check failed: could not save release_date'
}

check_spend() {
  local ledger now flags alert_state previous finding
  ledger="$FM_HOME/state/jev-usage.jsonl"
  [ -f "$ledger" ] && [ ! -L "$ledger" ] || return
  now=$(date +%s)
  flags=$(jq -cser --argjson now "$now" --argjson price "$PRICE_PER_INPUT_TOKEN" '
    def integer: type == "number" and floor == .;
    def nullable($kind): . == null or type == $kind;
    def valid:
      type == "object" and
      has("at") and has("task") and has("status") and has("reason") and has("rule") and has("confidence") and
      has("model") and has("input_tokens") and has("x-typesafe-request-id") and
      (.at | integer) and .at >= 0 and
      ((.task | type) == "string" and (.task | test("^[A-Za-z0-9_-][A-Za-z0-9._-]*$"))) and
      (.status | type) == "string" and
      (.reason | nullable("string")) and
      (.rule | nullable("string")) and
      (.confidence == null or ((.confidence | type) == "number" and .confidence >= 0 and .confidence <= 1)) and
      (.model | nullable("string")) and
      (.input_tokens == null or ((.input_tokens | integer) and .input_tokens >= 0)) and
      (."x-typesafe-request-id" | nullable("string"));
    if all(.[]; valid) then . else error("invalid ledger record") end |
    [ .[] | select((.input_tokens | type) == "number") ] as $calls |
    ($now | gmtime | .[0:2]) as $month |
    ($now | gmtime | .[0:3]) as $day |
    (([ $calls[] | select(.at <= $now and (.at | gmtime | .[0:2]) == $month) | .input_tokens ] | add // 0) * $price) as $monthly |
    (([ $calls[] | select(.at <= $now and (.at | gmtime | .[0:3]) == $day) | .input_tokens ] | add // 0) * $price) as $daily |
    {
      monthly: {period: ($now | strftime("%Y-%m")), usd: $monthly, alert: ($monthly >= 10)},
      daily: {period: ($now | strftime("%Y-%m-%d")), usd: $daily, alert: ($daily >= 1)}
    }
  ' "$ledger" 2>/dev/null) || { append_finding 'Jev spend check failed: ledger is malformed'; return; }
  previous='{}'
  record_read "$SPEND_RECORD" && previous=$FM_JEV_RECORD
  alert_state=$(jq -c '{
    monthly: {period: .monthly.period, alert: .monthly.alert},
    daily: {period: .daily.period, alert: .daily.alert}
  }' <<<"$flags") || { append_finding 'Jev spend check failed: threshold state is malformed'; return; }
  finding=$(jq -r --argjson previous "$previous" '
    [
      (if .monthly.alert and $previous.monthly != {period: .monthly.period, alert: .monthly.alert}
       then "per-home resolver ledger month-to-date \(.monthly.usd | . * 100 | floor / 100) USD reaches the 10 USD local threshold"
       else empty end),
      (if .daily.alert and $previous.daily != {period: .daily.period, alert: .daily.alert}
       then "per-home resolver ledger UTC calendar day \(.daily.usd | . * 100 | floor / 100) USD reaches the 1 USD daily threshold"
       else empty end)
    ] | join("; ")' <<<"$flags") \
    || { append_finding 'Jev spend check failed: threshold state is malformed'; return; }
  if [ -n "$finding" ]; then
    append_finding "Jev spend alert: $finding"
  fi
  record_write "$SPEND_RECORD" "$alert_state" || append_finding 'Jev spend check failed: could not save threshold state'
}

action_check() {
  if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
    TYPESAFE_API_KEY_PRIVATE=$(fmx_env_get TYPESAFE_API_KEY "$FM_HOME/.env")
  fi
  [ -n "$TYPESAFE_API_KEY_PRIVATE" ] || return 0
  command -v curl >/dev/null 2>&1 || { printf 'Jev monitor failed: curl is not installed\n'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf 'Jev monitor failed: jq is not installed\n'; return 0; }
  mkdir -p "$STATE" || { printf 'Jev monitor failed: state directory is unavailable\n'; return 0; }
  [ ! -L "$STATE" ] || { printf 'Jev monitor failed: state directory is unavailable\n'; return 0; }
  FINDINGS=
  check_alias
  check_spend
  [ -z "$FINDINGS" ] || printf '%s\n' "$FINDINGS"
}

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-jev-check.sh - Jev monitor poll shim.' \
    '# The watcher validates these bytes before it runs this trusted check.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-jev-check.sh") check"
}

action_arm() {
  local home want temp device shim_created=0
  mkdir -p "$STATE" || return 1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *) home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || return 1 ;;
  esac
  want=$(shim_content "$home")
  device=$(fm_pr_file_device "$STATE") || return 1
  if [ -e "$CHECK_SHIM" ] || [ -L "$CHECK_SHIM" ]; then
    [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
      && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ] || {
      printf 'fm-jev-check: refusing to replace %s\n' "$CHECK_SHIM" >&2
      return 1
    }
    if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
      printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
      return 0
    fi
  else
    temp=$(umask 077; mktemp "$STATE/.fm-jev-check.XXXXXX") || return 1
    if ! printf '%s\n' "$want" > "$temp" || ! chmod 0700 "$temp" \
      || ! fm_pr_private_file_valid "$temp" 700 "$device" || ! mv -f -- "$temp" "$CHECK_SHIM"; then
      rm -f -- "$temp"
      return 1
    fi
    shim_created=1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    [ "$shim_created" -eq 0 ] || rm -f -- "$CHECK_SHIM"
    printf 'fm-jev-check: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

action_disarm() {
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || {
    printf 'fm-jev-check: refusing to disarm with unavailable state directory: %s\n' "$STATE" >&2
    return 1
  }
  if ! FM_HOME="$FM_HOME" "$UNREGISTER_BIN" "$CHECK_ID" >/dev/null; then
    printf 'fm-jev-check: could not unregister %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  rm -f -- "$ALIAS_RECORD" "$SPEND_RECORD" "$FAILURE_RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
