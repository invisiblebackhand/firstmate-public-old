#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-check.sh.
#
# The fake curl serves a fixture models listing, so these checks never contact
# TypeSafe and still exercise the public watcher-check interface end to end.
# FAKE_CURL_MODE=timeout makes it fail the way a timed-out curl does, and
# FAKE_CURL_MODE=http-<code> makes it answer with that status instead of 200.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-jev-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-jev-check)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
MODELS="$TMP_ROOT/models.json"
CALLS="$TMP_ROOT/curl.calls"
CURL_ARGS="$TMP_ROOT/curl.args"

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$@" > "${FAKE_CURL_ARGS:?}"
out=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -D) : > "$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'called\n' >> "${FAKE_CURL_CALLS:?}"
case "${FAKE_CURL_MODE:-ok}" in
  timeout) printf 000; exit 28 ;;
  http-*) printf '%s' "${FAKE_CURL_MODE#http-}"; exit 0 ;;
esac
cp "${FAKE_CURL_MODELS:?}" "$out"
printf 200
SH
chmod 0700 "$FAKEBIN/curl"

cat > "$FAKEBIN/date" <<'SH'
#!/usr/bin/env bash
set -u
[ "$#" -eq 1 ] && [ "$1" = +%s ] || exit 2
printf '%s\n' "${FAKE_DATE_EPOCH:?}"
SH
chmod 0700 "$FAKEBIN/date"

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name/home"
  mkdir -p "$home/state"
  printf 'TYPESAFE_API_KEY=fixture-key\n' > "$home/.env"
  printf '%s\n' "$home"
}

write_models() {  # <release date>
  cat > "$MODELS" <<JSON
{"models":[{"name":"jev-latest","description":"Current Jev alias.","release_date":"$1"}]}
JSON
}

run_check() {  # <home> <output> [<now-epoch>]
  local home=$1 out=$2 now=${3:-1760000000} status=0
  env PATH="$FAKEBIN:$PATH" FAKE_CURL_ARGS="$CURL_ARGS" FAKE_CURL_CALLS="$CALLS" FAKE_CURL_MODELS="$MODELS" \
    FAKE_CURL_MODE="${FAKE_CURL_MODE:-ok}" FAKE_DATE_EPOCH="$now" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    "$CHECK" check >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "Jev check exits"
}

curl_timeout() {  # the --max-time value of the last fixture request
  awk 'seen { print; exit } $0 == "--max-time" { seen = 1 }' "$CURL_ARGS"
}

test_alias_move_records_baseline_then_alerts_once() {
  local home out
  home=$(make_home alias)
  out="$TMP_ROOT/alias/out"
  write_models 2026-09-10
  : > "$CALLS"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "the first alias observation must establish a baseline, got: $(cat "$out")"
  assert_equals '2026-09-10' "$(cat "$home/state/.jev-monitor-alias")" "baseline release date was not stored"
  assert_equals '10' "$(curl_timeout)" "the watcher request did not use the hard ten-second timeout"
  assert_equals '1' "$(wc -l < "$CALLS" | tr -d '[:space:]')" "the alias check did not make exactly one fixture request"

  write_models 2026-10-01
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" 'Jev alias moved: jev-latest release_date 2026-09-10 -> 2026-10-01' "an alias move was not reported"
  assert_contains "$(cat "$out")" 'replay dispatch tests before any pin bump' "the alias report omitted the replay requirement"

  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "an unchanged alias move repeated: $(cat "$out")"
  pass "Jev alias move establishes a baseline and reports once with the replay gate"
}

test_failed_request_alerts_only_when_two_polls_in_a_row_fail() {
  local home out failures failure
  home=$(make_home request-failures)
  out="$TMP_ROOT/request-failures/out"
  failures="$home/state/.jev-monitor-failures"
  failure='Jev alias check failed: GET /v1/models returned 000'
  write_models 2026-09-10
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "the baseline poll alerted: $(cat "$out")"

  FAKE_CURL_MODE=timeout run_check "$home" "$out"
  [ ! -s "$out" ] || fail "the first failed request alerted: $(cat "$out")"
  assert_equals '1' "$(cat "$failures")" "the first failed request was not counted"

  FAKE_CURL_MODE=timeout run_check "$home" "$out"
  assert_equals "$failure" "$(cat "$out")" "the second consecutive failed request did not alert as a failure alerts today"
  FAKE_CURL_MODE=timeout run_check "$home" "$out"
  assert_equals "$failure" "$(cat "$out")" "a later consecutive failed request stopped alerting"
  assert_equals '2026-09-10' "$(cat "$home/state/.jev-monitor-alias")" "failed requests changed the alias baseline"
  pass "a failed models request alerts only when two polls in a row fail"
}

test_a_successful_request_resets_the_failure_count() {
  local home out failures
  home=$(make_home request-reset)
  out="$TMP_ROOT/request-reset/out"
  failures="$home/state/.jev-monitor-failures"
  write_models 2026-09-10
  FAKE_CURL_MODE=timeout run_check "$home" "$out"
  [ ! -s "$out" ] || fail "the first failed request alerted: $(cat "$out")"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "a successful request alerted: $(cat "$out")"
  assert_absent "$failures" "a successful request left the failure count"

  FAKE_CURL_MODE=timeout run_check "$home" "$out"
  [ ! -s "$out" ] || fail "a failure after a success alerted as a second consecutive one: $(cat "$out")"
  FAKE_CURL_MODE=timeout run_check "$home" "$out"
  assert_contains "$(cat "$out")" 'GET /v1/models returned 000' "two failures in a row after a reset did not alert"

  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "recovery after an alerting run alerted: $(cat "$out")"
  assert_absent "$failures" "recovery after an alerting run left the failure count"
  FAKE_CURL_MODE=timeout run_check "$home" "$out"
  [ ! -s "$out" ] || fail "the first failure after recovery alerted: $(cat "$out")"
  pass "any successful request resets the consecutive failure count"
}

test_a_non_200_reply_counts_as_a_failed_request() {
  local home out
  home=$(make_home request-non-200)
  out="$TMP_ROOT/request-non-200/out"
  write_models 2026-09-10
  FAKE_CURL_MODE=http-503 run_check "$home" "$out"
  [ ! -s "$out" ] || fail "the first non-200 reply alerted: $(cat "$out")"
  FAKE_CURL_MODE=http-503 run_check "$home" "$out"
  assert_equals 'Jev alias check failed: GET /v1/models returned 503' "$(cat "$out")" "the second consecutive non-200 reply did not alert with its status"

  run_check "$home" "$out"
  FAKE_CURL_MODE=http-500 run_check "$home" "$out"
  [ ! -s "$out" ] || fail "the first failure after a reset alerted: $(cat "$out")"
  FAKE_CURL_MODE=timeout run_check "$home" "$out"
  assert_equals 'Jev alias check failed: GET /v1/models returned 000' "$(cat "$out")" "a non-200 reply and a timeout did not count together"
  pass "non-200 replies and timeouts count together as failed requests"
}

test_a_malformed_listing_alerts_at_once_and_ends_the_failure_run() {
  local home out failures
  home=$(make_home request-malformed)
  out="$TMP_ROOT/request-malformed/out"
  failures="$home/state/.jev-monitor-failures"
  write_models 2026-09-10
  FAKE_CURL_MODE=timeout run_check "$home" "$out"
  [ ! -s "$out" ] || fail "the first failed request alerted: $(cat "$out")"

  printf '%s\n' '{"models":[]}' > "$MODELS"
  run_check "$home" "$out"
  assert_equals 'Jev alias check failed: models response is malformed' "$(cat "$out")" "a malformed listing was held back"
  assert_absent "$failures" "a served reply did not end the failure run"
  FAKE_CURL_MODE=timeout run_check "$home" "$out"
  [ ! -s "$out" ] || fail "a failure after a served reply alerted as a second consecutive one: $(cat "$out")"
  pass "a served but malformed listing alerts immediately and ends the failure run"
}

test_local_failures_still_alert_on_their_first_occurrence() {
  local home out fake
  write_models 2026-09-10

  home=$(make_home local-ledger)
  out="$TMP_ROOT/local-ledger/out"
  printf '%s\n' '{"at":1760000000,"input_tokens":"25000000"}' > "$home/state/jev-usage.jsonl"
  FAKE_CURL_MODE=timeout run_check "$home" "$out"
  assert_equals 'Jev spend check failed: ledger is malformed' "$(cat "$out")" "a malformed ledger was held back or mixed with the silent failed request"
  assert_equals '1' "$(cat "$home/state/.jev-monitor-failures")" "the failed request beside a malformed ledger was not counted"

  home="$TMP_ROOT/local-state-link/home"
  out="$TMP_ROOT/local-state-link/out"
  mkdir -p "$home" "$TMP_ROOT/local-state-link/target"
  printf 'TYPESAFE_API_KEY=fixture-key\n' > "$home/.env"
  ln -s "$TMP_ROOT/local-state-link/target" "$home/state"
  : > "$CALLS"
  FAKE_CURL_MODE=timeout run_check "$home" "$out"
  assert_equals 'Jev monitor failed: state directory is unavailable' "$(cat "$out")" "an unusable state directory was held back"
  [ ! -s "$CALLS" ] || fail "an unusable state directory still reached the models endpoint"

  home=$(make_home local-mktemp)
  out="$TMP_ROOT/local-mktemp/out"
  fake="$TMP_ROOT/local-mktemp/fakebin"
  mkdir -p "$fake"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$fake/mktemp"
  chmod 0700 "$fake/mktemp"
  FAKE_CURL_MODE=timeout PATH="$fake:$PATH" run_check "$home" "$out"
  assert_equals 'Jev alias check failed: mktemp' "$(cat "$out")" "a local mktemp failure was held back"
  assert_absent "$home/state/.jev-monitor-failures" "a local mktemp failure was counted as a failed request"
  pass "local failures alert on their first occurrence beside the failure count"
}

test_an_unusable_failure_count_record_alerts_instead_of_hiding_a_failure() {
  local kind home out failures target
  write_models 2026-09-10
  for kind in garbage zero padded symlink; do
    home=$(make_home "failure-record-$kind")
    out="$TMP_ROOT/failure-record-$kind/out"
    failures="$home/state/.jev-monitor-failures"
    target="$TMP_ROOT/failure-record-$kind/external"
    case "$kind" in
      garbage) printf '%s\n' 'many' > "$failures" ;;
      zero) printf '%s\n' '0' > "$failures" ;;
      padded) printf '%s\n' '01' > "$failures" ;;
      symlink) printf '%s\n' '1' > "$target"; ln -s "$target" "$failures" ;;
    esac
    FAKE_CURL_MODE=timeout run_check "$home" "$out"
    assert_equals 'Jev alias check failed: GET /v1/models returned 000' "$(cat "$out")" "a $kind failure count record hid a failed request"
    [ -f "$failures" ] && [ ! -L "$failures" ] || fail "a $kind failure count record was not replaced by a regular record"
    [[ $(cat "$failures") =~ ^[1-9][0-9]*$ ]] || fail "a $kind failure count record was not replaced by a valid count: $(cat "$failures")"
    [ "$kind" != symlink ] || assert_equals '1' "$(cat "$target")" "the symlinked failure count target was modified"
  done
  pass "a failure count record that is not a count alerts instead of hiding a failed request"
}

test_a_failed_request_that_cannot_be_counted_alerts_instead_of_being_held_back() {
  local home out fake
  home=$(make_home failure-unsaved)
  out="$TMP_ROOT/failure-unsaved/out"
  fake="$TMP_ROOT/failure-unsaved/fakebin"
  mkdir -p "$fake"
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case "${1:-}" in */.fm-jev-check.*) exit 1 ;; esac' \
    'exec "$REAL_MKTEMP" "$@"' > "$fake/mktemp"
  chmod 0700 "$fake/mktemp"
  write_models 2026-09-10
  FAKE_CURL_MODE=timeout REAL_MKTEMP="$(command -v mktemp)" PATH="$fake:$PATH" run_check "$home" "$out"
  assert_equals 'Jev alias check failed: GET /v1/models returned 000; Jev alias check failed: could not save request failure count' \
    "$(cat "$out")" "a failed request that could not be counted stayed silent"
  assert_absent "$home/state/.jev-monitor-failures" "an unwritable failure count left a record"
  pass "a failed request that cannot be counted alerts instead of being held back"
}

test_spend_thresholds_use_the_per_home_resolver_ledger() {
  local home out ledger
  home=$(make_home spend)
  out="$TMP_ROOT/spend/out"
  ledger="$home/state/jev-usage.jsonl"
  write_models 2026-09-10
  printf '%s\n' '{"at":1760000000,"task":"fixture","status":"error","reason":"response is not a rule Choice answer","rule":null,"confidence":null,"model":"jev-1.13.0","input_tokens":25000000,"x-typesafe-request-id":"req_fixture"}' > "$ledger"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" 'Jev spend alert: per-home resolver ledger UTC calendar day 1.05 USD reaches the 1 USD daily threshold' "the daily threshold did not count valid metering from a rejected response"
  assert_not_contains "$(cat "$out")" 'month-to-date' "the month threshold fired below 10 USD"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "an unchanged spend threshold repeated: $(cat "$out")"

  printf '%s\n' '{"at":1760000000,"task":"fixture","status":"clear","reason":null,"rule":"rule_1","confidence":0.9,"model":"jev-1.13.0","input_tokens":220000000,"x-typesafe-request-id":"req_fixture_2"}' >> "$ledger"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" 'per-home resolver ledger month-to-date 10.29 USD reaches the 10 USD local threshold' "the monthly threshold was not calculated from fixture tokens"
  printf '%s\n' '{"at":1760000000,"task":"fixture","status":"clear","reason":null,"rule":"rule_1","confidence":0.9,"model":"jev-1.13.0","input_tokens":1000000,"x-typesafe-request-id":"req_fixture_3"}' >> "$ledger"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "additional spend above an already-crossed threshold repeated: $(cat "$out")"
  pass "Jev spend thresholds read the per-home resolver ledger without repeating alerts"
}

test_malformed_local_record_fails_closed() {
  local home out ledger fixture
  home=$(make_home malformed-ledger)
  out="$TMP_ROOT/malformed-ledger/out"
  ledger="$home/state/jev-usage.jsonl"
  write_models 2026-09-10
  for fixture in \
    '{"at":1760000000,"input_tokens":"25000000"}' \
    '{"at":1760000000,"task":"","status":"error","reason":null,"rule":null,"confidence":null,"model":null,"input_tokens":null,"x-typesafe-request-id":null}'; do
    printf '%s\n' "$fixture" > "$ledger"
    run_check "$home" "$out"
    assert_contains "$(cat "$out")" 'Jev spend check failed: ledger is malformed' "a malformed local record was silently omitted"
    assert_not_contains "$(cat "$out")" 'Jev spend alert:' "a malformed local record produced a spend total"
  done
  pass "malformed local records fail closed instead of undercounting spend"
}

test_models_response_requires_the_full_listing_schema() {
  local home out fixture
  home=$(make_home malformed-models)
  out="$TMP_ROOT/malformed-models/out"
  for fixture in \
    '{"debug":{"name":"jev-latest","release_date":7}}' \
    '{"models":[{"name":"jev-latest","description":"one","release_date":"2026-09-10"},{"name":"jev-latest","description":"two","release_date":"2026-10-01"}]}' \
    '{"models":[{"name":"jev-latest","description":"alias","release_date":7}]}' \
    '{"models":[{"name":"jev-latest","description":"alias","release_date":"2026-09-10"},{"name":"jev-1.13.0","release_date":"2026-09-10"}]}'; do
    printf '%s\n' "$fixture" > "$MODELS"
    run_check "$home" "$out"
    assert_contains "$(cat "$out")" 'Jev alias check failed: models response is malformed' "a malformed models listing was accepted"
    assert_absent "$home/state/.jev-monitor-alias" "a malformed models listing changed the alias baseline"
  done
  pass "Jev alias checks require one fully typed alias in a valid models listing"
}

test_impossible_release_dates_never_change_alias_state() {
  local home out invalid
  home=$(make_home impossible-dates)
  out="$TMP_ROOT/impossible-dates/out"
  printf '%s\n' '2026-09-10' > "$home/state/.jev-monitor-alias"
  for invalid in 2026-13-99 2026-02-30; do
    write_models "$invalid"
    run_check "$home" "$out"
    assert_contains "$(cat "$out")" 'Jev alias check failed: models response is malformed' "$invalid was accepted as a release date"
    assert_not_contains "$(cat "$out")" 'Jev alias moved:' "$invalid produced a false alias alert"
    assert_equals '2026-09-10' "$(cat "$home/state/.jev-monitor-alias")" "$invalid changed the alias baseline"
  done
  pass "impossible release dates cannot update or alert from alias state"
}

test_future_records_do_not_count_toward_spend() {
  local home out ledger
  home=$(make_home future)
  out="$TMP_ROOT/future/out"
  ledger="$home/state/jev-usage.jsonl"
  write_models 2026-09-10
  printf '%s\n' '{"at":1760000001,"task":"future","status":"clear","reason":null,"rule":"rule_1","confidence":0.9,"model":"jev-1.13.0","input_tokens":250000000,"x-typesafe-request-id":"req_future"}' > "$ledger"
  run_check "$home" "$out"
  assert_not_contains "$(cat "$out")" 'Jev spend alert:' "future-dated usage counted toward a spend window"
  pass "future-dated local records are excluded from daily and monthly spend"
}

test_local_homes_keep_separate_resolver_ledgers() {
  local root home out ledger
  root=$(make_home parent-home)
  home=$(make_home local-child)
  out="$TMP_ROOT/local-child/out"
  ledger="$root/state/jev-usage.jsonl"
  write_models 2026-09-10
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$root" > "$home/.fm-secondmate-parent"
  printf '%s\n' '{"at":1760000000,"task":"primary","status":"clear","reason":null,"rule":"rule_1","confidence":0.9,"model":"jev-1.13.0","input_tokens":25000000,"x-typesafe-request-id":"req_primary"}' > "$ledger"
  run_check "$home" "$out"
  assert_not_contains "$(cat "$out")" 'Jev spend alert:' "a local child counted its parent's resolver ledger"

  ledger="$home/state/jev-usage.jsonl"
  printf '%s\n' '{"at":1760000000,"task":"child","status":"clear","reason":null,"rule":"rule_1","confidence":0.9,"model":"jev-1.13.0","input_tokens":25000000,"x-typesafe-request-id":"req_child"}' > "$ledger"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" 'Jev spend alert: per-home resolver ledger UTC calendar day 1.05 USD reaches the 1 USD daily threshold' "a local child did not count its own resolver ledger"
  pass "local homes keep separate resolver ledgers"
}

test_daily_threshold_does_not_cross_utc_midnight() {
  local home out ledger state
  home=$(make_home daily-midnight)
  out="$TMP_ROOT/daily-midnight/out"
  ledger="$home/state/jev-usage.jsonl"
  state="$home/state/.jev-monitor-spend"
  write_models 2026-09-10

  printf '%s\n' '{"at":1767225540,"task":"december-close","status":"clear","reason":null,"rule":"rule_1","confidence":0.9,"model":"jev-1.13.0","input_tokens":25000000,"x-typesafe-request-id":"req_december_close"}' > "$ledger"
  run_check "$home" "$out" 1767225540
  assert_contains "$(cat "$out")" 'per-home resolver ledger UTC calendar day 1.05 USD reaches the 1 USD daily threshold' "the 23:59 UTC call did not alert on its own day"
  assert_equals '2025-12-31' "$(jq -r '.daily.period' "$state")" "the first daily alert used the wrong UTC date"

  run_check "$home" "$out" 1767225660
  [ ! -s "$out" ] || fail "the prior-day call alerted again after UTC midnight: $(cat "$out")"
  assert_equals '2026-01-01' "$(jq -r '.daily.period' "$state")" "the daily state did not advance at UTC midnight"
  assert_equals 'false' "$(jq -r '.daily.alert' "$state")" "the prior-day call counted in the new UTC day"
  pass "daily spend is counted and deduplicated within one UTC calendar day"
}

test_threshold_state_is_period_aware() {
  local home out ledger state
  home=$(make_home periods)
  out="$TMP_ROOT/periods/out"
  ledger="$home/state/jev-usage.jsonl"
  state="$home/state/.jev-monitor-spend"
  write_models 2026-09-10

  printf '%s\n' '{"at":1764547200,"task":"december","status":"clear","reason":null,"rule":"rule_1","confidence":0.9,"model":"jev-1.13.0","input_tokens":240000000,"x-typesafe-request-id":"req_december"}' > "$ledger"
  run_check "$home" "$out" 1767139200
  assert_contains "$(cat "$out")" 'per-home resolver ledger month-to-date 10.08 USD reaches the 10 USD local threshold' "December did not raise its monthly alert"
  assert_equals '2025-12' "$(jq -r '.monthly.period' "$state")" "December monthly state omitted its period"
  assert_equals 'false' "$(jq -r '.daily.alert' "$state")" "old December usage incorrectly raised the daily flag"

  printf '%s\n' '{"at":1767225600,"task":"january","status":"clear","reason":null,"rule":"rule_1","confidence":0.9,"model":"jev-1.13.0","input_tokens":240000000,"x-typesafe-request-id":"req_january"}' > "$ledger"
  run_check "$home" "$out" 1769817600
  assert_contains "$(cat "$out")" 'per-home resolver ledger month-to-date 10.08 USD reaches the 10 USD local threshold' "January reused December's monthly dedupe state"
  assert_equals '2026-01' "$(jq -r '.monthly.period' "$state")" "January monthly state omitted its period"
  assert_equals '2026-01-31' "$(jq -r '.daily.period' "$state")" "January daily state omitted its period"
  pass "monthly and daily alert state carries independent UTC periods"
}

test_absent_key_never_calls_the_models_endpoint() {
  local home out status
  home="$TMP_ROOT/off/home"
  mkdir -p "$home/state"
  out="$TMP_ROOT/off/out"
  : > "$CALLS"
  status=0
  env PATH="$FAKEBIN:$PATH" FAKE_CURL_CALLS="$CALLS" FAKE_CURL_MODELS="$MODELS" FM_HOME="$home" "$CHECK" check >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "absent-key check exit"
  [ ! -s "$out" ] || fail "absent-key check wrote output: $(cat "$out")"
  [ ! -s "$CALLS" ] || fail "absent-key check called the TypeSafe fixture"
  pass "Jev monitor is inert without a key"
}

test_arm_registers_a_watcher_shim_without_running_the_check() {
  local home status
  home=$(make_home arm)
  status=0
  FM_HOME="$home" "$CHECK" arm >/dev/null || status=$?
  expect_code 0 "$status" "arm exit"
  assert_present "$home/state/jev-monitor.check.sh" "arm did not write the watcher shim"
  assert_present "$home/state/jev-monitor.check-trust" "arm did not bind the watcher shim"
  [ "$(stat -c %a "$home/state/jev-monitor.check.sh" 2>/dev/null || stat -f %Lp "$home/state/jev-monitor.check.sh")" = 700 ] \
    || fail "the watcher shim has the wrong mode"
  pass "Jev monitor arms through the registered custom-check contract"
}

test_rearm_preserves_the_existing_registration_without_rewriting() {
  local home fake marker out status shim_before trust_before
  home=$(make_home rearm-register-fail)
  fake="$TMP_ROOT/rearm-register-fail/fakebin"
  marker="$TMP_ROOT/rearm-register-fail/mktemp-called"
  out="$TMP_ROOT/rearm-register-fail/out"
  mkdir -p "$fake"
  FM_HOME="$home" "$CHECK" arm >/dev/null || fail "could not create the existing registration fixture"
  shim_before=$(cat "$home/state/jev-monitor.check.sh")
  trust_before=$(cat "$home/state/jev-monitor.check-trust")
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' 'printf called > "${FAKE_MKTEMP_CALL:?}"' 'exit 1' > "$fake/mktemp"
  chmod 0700 "$fake/mktemp"

  status=0
  env PATH="$fake:$PATH" FAKE_MKTEMP_CALL="$marker" FM_HOME="$home" "$CHECK" arm >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "idempotent rearm exit"
  assert_contains "$(cat "$out")" 'armed: state/jev-monitor.check.sh' "idempotent rearm was not reported"
  assert_absent "$marker" "rearm rewrote an already valid registration"
  assert_equals "$shim_before" "$(cat "$home/state/jev-monitor.check.sh")" "rearm changed the existing shim"
  assert_equals "$trust_before" "$(cat "$home/state/jev-monitor.check-trust")" "rearm changed the existing trust binding"
  pass "rearm leaves an existing valid registration unchanged"
}

test_pre_replacement_registration_failure_restores_the_existing_registration() {
  local home fake count out status real_shasum shim_before trust_before
  home=$(make_home rearm-pre-replacement-fail)
  fake="$TMP_ROOT/rearm-pre-replacement-fail/fakebin"
  count="$TMP_ROOT/rearm-pre-replacement-fail/shasum-count"
  out="$TMP_ROOT/rearm-pre-replacement-fail/out"
  mkdir -p "$fake"
  FM_HOME="$home" "$CHECK" arm >/dev/null || fail "could not create the pre-replacement fixture"
  shim_before=$(cat "$home/state/jev-monitor.check.sh")
  trust_before=$(cat "$home/state/jev-monitor.check-trust")
  real_shasum=$(command -v shasum)
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'count=0' \
    '[ ! -f "$FAKE_SHASUM_COUNT" ] || read -r count < "$FAKE_SHASUM_COUNT"' \
    'count=$((count + 1))' \
    'printf "%s\n" "$count" > "$FAKE_SHASUM_COUNT"' \
    '[ "$count" -ne 1 ] || exit 1' \
    'exec "$REAL_SHASUM" "$@"' > "$fake/shasum"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$fake/mktemp"
  chmod 0700 "$fake/shasum" "$fake/mktemp"

  status=0
  env PATH="$fake:$PATH" REAL_SHASUM="$real_shasum" FAKE_SHASUM_COUNT="$count" \
    FM_HOME="$home" "$CHECK" arm >"$out" 2>&1 || status=$?
  expect_code 1 "$status" "pre-replacement registration failure exit"
  assert_contains "$(cat "$out")" 'could not register' "pre-replacement failure was not reported"
  assert_equals '2' "$(cat "$count")" "fixture did not reach registration before replacement"
  assert_equals "$shim_before" "$(cat "$home/state/jev-monitor.check.sh")" "pre-replacement failure changed the existing shim"
  assert_equals "$trust_before" "$(cat "$home/state/jev-monitor.check-trust")" "pre-replacement failure changed the existing trust binding"
  pass "pre-replacement registration failure preserves the existing registration"
}

test_post_replacement_registration_failure_restores_the_existing_registration() {
  local home fake count out status real_shasum shim_before trust_before
  home=$(make_home rearm-post-replacement-fail)
  fake="$TMP_ROOT/rearm-post-replacement-fail/fakebin"
  count="$TMP_ROOT/rearm-post-replacement-fail/shasum-count"
  out="$TMP_ROOT/rearm-post-replacement-fail/out"
  mkdir -p "$fake"
  FM_HOME="$home" "$CHECK" arm >/dev/null || fail "could not create the post-replacement fixture"
  shim_before=$(cat "$home/state/jev-monitor.check.sh")
  trust_before=$(cat "$home/state/jev-monitor.check-trust")
  real_shasum=$(command -v shasum)
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'count=0' \
    '[ ! -f "$FAKE_SHASUM_COUNT" ] || read -r count < "$FAKE_SHASUM_COUNT"' \
    'count=$((count + 1))' \
    'printf "%s\n" "$count" > "$FAKE_SHASUM_COUNT"' \
    '[ "$count" -ne 1 ] || exit 1' \
    '[ "$count" -ne 2 ] || exec "$REAL_SHASUM" "$@"' \
    'exit 1' > "$fake/shasum"
  chmod 0700 "$fake/shasum"

  status=0
  env PATH="$fake:$PATH" REAL_SHASUM="$real_shasum" FAKE_SHASUM_COUNT="$count" \
    FM_HOME="$home" "$CHECK" arm >"$out" 2>&1 || status=$?
  expect_code 1 "$status" "post-replacement registration failure exit"
  assert_contains "$(cat "$out")" 'could not register' "post-replacement failure was not reported"
  assert_equals '3' "$(cat "$count")" "fixture did not reach post-replacement validation"
  assert_equals "$shim_before" "$(cat "$home/state/jev-monitor.check.sh")" "post-replacement failure changed the existing shim"
  assert_equals "$trust_before" "$(cat "$home/state/jev-monitor.check-trust")" "post-replacement failure did not restore the existing trust binding"
  pass "post-replacement registration failure restores the existing registration"
}

test_failed_first_arm_removes_only_the_created_shim() {
  local home target out status
  home=$(make_home first-arm-register-fail)
  target="$TMP_ROOT/first-arm-register-fail/external"
  out="$TMP_ROOT/first-arm-register-fail/out"
  printf '%s\n' 'external' > "$target"
  ln -s "$target" "$home/state/jev-monitor.check-trust"

  status=0
  FM_HOME="$home" "$CHECK" arm >"$out" 2>&1 || status=$?
  expect_code 1 "$status" "failed first arm exit"
  assert_contains "$(cat "$out")" 'could not register' "failed first arm did not report registration failure"
  assert_absent "$home/state/jev-monitor.check.sh" "failed first arm left its newly created shim"
  [ -L "$home/state/jev-monitor.check-trust" ] || fail "failed first arm removed the pre-existing trust path"
  assert_equals 'external' "$(cat "$target")" "failed first arm changed the trust symlink target"
  pass "a failed first arm removes only the shim it created"
}

test_disarm_refuses_a_symlinked_state_directory() {
  local home target out status
  home="$TMP_ROOT/disarm-symlink/home"
  target="$TMP_ROOT/disarm-symlink/target"
  out="$TMP_ROOT/disarm-symlink/out"
  mkdir -p "$home" "$target"
  printf '%s\n' '2026-09-10' > "$target/.jev-monitor-alias"
  printf '%s\n' '{"monthly":{"period":"2026-09","alert":false},"daily":{"period":"2026-09-23","alert":false}}' > "$target/.jev-monitor-spend"
  printf '%s\n' '1' > "$target/.jev-monitor-failures"
  ln -s "$target" "$home/state"

  status=0
  FM_HOME="$home" "$CHECK" disarm >"$out" 2>&1 || status=$?
  expect_code 1 "$status" "symlinked-state disarm exit"
  assert_contains "$(cat "$out")" 'refusing to disarm with unavailable state directory' "disarm did not report the unsafe state directory"
  assert_equals '2026-09-10' "$(cat "$target/.jev-monitor-alias")" "disarm followed the state symlink and removed alias state"
  assert_present "$target/.jev-monitor-spend" "disarm followed the state symlink and removed spend state"
  assert_present "$target/.jev-monitor-failures" "disarm followed the state symlink and removed the failure count"
  pass "Jev monitor disarm refuses symlinked state before cleanup"
}

test_disarm_preserves_state_when_a_child_artifact_is_unsafe() {
  local kind home out status target
  for kind in shim trust; do
    home=$(make_home "disarm-unsafe-$kind")
    out="$TMP_ROOT/disarm-unsafe-$kind/out"
    target="$TMP_ROOT/disarm-unsafe-$kind/external"
    printf '%s\n' '2026-09-10' > "$home/state/.jev-monitor-alias"
    printf '%s\n' '{"monthly":{"period":"2026-09","alert":false},"daily":{"period":"2026-09-23","alert":false}}' > "$home/state/.jev-monitor-spend"
    printf '%s\n' '1' > "$home/state/.jev-monitor-failures"
    printf '%s\n' 'external' > "$target"
    if [ "$kind" = shim ]; then
      ln -s "$target" "$home/state/jev-monitor.check.sh"
      printf '%s\n' 'trust' > "$home/state/jev-monitor.check-trust"
    else
      printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$home/state/jev-monitor.check.sh"
      chmod 0700 "$home/state/jev-monitor.check.sh"
      ln -s "$target" "$home/state/jev-monitor.check-trust"
    fi

    status=0
    FM_HOME="$home" "$CHECK" disarm >"$out" 2>&1 || status=$?
    expect_code 1 "$status" "unsafe-$kind disarm exit"
    assert_contains "$(cat "$out")" 'custom check is unsafe to remove' "unsafe-$kind disarm hid the unregister refusal"
    assert_not_contains "$(cat "$out")" 'disarmed:' "unsafe-$kind disarm reported success"
    assert_present "$home/state/.jev-monitor-alias" "unsafe-$kind disarm removed alias state"
    assert_present "$home/state/.jev-monitor-spend" "unsafe-$kind disarm removed spend state"
    assert_present "$home/state/.jev-monitor-failures" "unsafe-$kind disarm removed the failure count"
    assert_present "$home/state/jev-monitor.check.sh" "unsafe-$kind disarm removed the shim"
    assert_present "$home/state/jev-monitor.check-trust" "unsafe-$kind disarm removed the trust binding"
    assert_equals 'external' "$(cat "$target")" "unsafe-$kind disarm changed the symlink target"
  done
  pass "Jev monitor disarm preserves all state when either child artifact is unsafe"
}

test_disarm_removes_registered_monitor_state() {
  local home out status
  home=$(make_home disarm-success)
  out="$TMP_ROOT/disarm-success/out"
  FM_HOME="$home" "$CHECK" arm >/dev/null || fail "could not arm the successful disarm fixture"
  printf '%s\n' '2026-09-10' > "$home/state/.jev-monitor-alias"
  printf '%s\n' '{"monthly":{"period":"2026-09","alert":false},"daily":{"period":"2026-09-23","alert":false}}' > "$home/state/.jev-monitor-spend"
  printf '%s\n' '1' > "$home/state/.jev-monitor-failures"

  status=0
  FM_HOME="$home" "$CHECK" disarm >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "registered monitor disarm exit"
  assert_contains "$(cat "$out")" 'disarmed: state/jev-monitor.check.sh' "successful disarm was not reported"
  assert_absent "$home/state/jev-monitor.check.sh" "successful disarm left the shim"
  assert_absent "$home/state/jev-monitor.check-trust" "successful disarm left the trust binding"
  assert_absent "$home/state/.jev-monitor-alias" "successful disarm left alias state"
  assert_absent "$home/state/.jev-monitor-spend" "successful disarm left spend state"
  assert_absent "$home/state/.jev-monitor-failures" "successful disarm left the failure count"
  pass "Jev monitor disarm removes the registration before its records"
}

test_alias_move_records_baseline_then_alerts_once
test_failed_request_alerts_only_when_two_polls_in_a_row_fail
test_a_successful_request_resets_the_failure_count
test_a_non_200_reply_counts_as_a_failed_request
test_a_malformed_listing_alerts_at_once_and_ends_the_failure_run
test_local_failures_still_alert_on_their_first_occurrence
test_an_unusable_failure_count_record_alerts_instead_of_hiding_a_failure
test_a_failed_request_that_cannot_be_counted_alerts_instead_of_being_held_back
test_spend_thresholds_use_the_per_home_resolver_ledger
test_malformed_local_record_fails_closed
test_models_response_requires_the_full_listing_schema
test_impossible_release_dates_never_change_alias_state
test_future_records_do_not_count_toward_spend
test_local_homes_keep_separate_resolver_ledgers
test_daily_threshold_does_not_cross_utc_midnight
test_threshold_state_is_period_aware
test_absent_key_never_calls_the_models_endpoint
test_arm_registers_a_watcher_shim_without_running_the_check
test_rearm_preserves_the_existing_registration_without_rewriting
test_pre_replacement_registration_failure_restores_the_existing_registration
test_post_replacement_registration_failure_restores_the_existing_registration
test_failed_first_arm_removes_only_the_created_shim
test_disarm_refuses_a_symlinked_state_directory
test_disarm_preserves_state_when_a_child_artifact_is_unsafe
test_disarm_removes_registered_monitor_state

printf '# all fm-jev-check tests passed\n'
