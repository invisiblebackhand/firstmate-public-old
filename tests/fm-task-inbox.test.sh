#!/usr/bin/env bash
# tests/fm-task-inbox.test.sh - the per-task steering inbox
# (bin/fm-task-inbox-lib.sh) and the watcher's re-ring ladder.
#
# The inbox+doorbell design replaces typed steer payloads with durable
# sequenced records acknowledged by an atomic mv into handled/; the terminal
# carries only a constant doorbell line, and the watcher re-rings an
# unacknowledged message before escalating once as an ordinary stale wake.
# These tests pin the semantics with real processes:
#   1. A message is written durably and appears in the inbox, byte-exact
#      including newlines, with a doorbell naming the inbox glob, numeric order,
#      and handled/.
#   2. Sequencing dedups per worker lifetime: the handled mv retires a record,
#      re-acking it is a no-op, and an acknowledged sequence is never reissued.
#      The idempotent enqueue (the remote steer leg's primitive) additionally
#      dedups an exact-body re-run onto the existing record, handled or not.
#   3. Concurrent writers serialize on the sequence lock: no clobbered records.
#   4. The re-ring ladder: within grace is quiet, past grace rings, ring
#      spacing holds, a spent budget escalates exactly once, and an
#      acknowledgement resets the ladder for the next message.
#   5. A real fm-watch.sh subprocess re-rings the doorbell for an unhandled
#      aged message on an idle pane WITHOUT waking firstmate, waits on a busy
#      pane, stays silent on a healthy/empty inbox, surfaces unwritable ladder
#      bookkeeping only while its record remains unhandled, and emits exactly
#      one stale wake once the ring budget is spent.
#   6. Dead panes: the doorbell line is a shell no-op when executed by a bare
#      shell, the ring skips an agent the backend classifies dead, and the
#      watcher surfaces such a record exactly once instead of re-ringing.
#   7. Claude's auto-mode setup dialog: a Claude pane showing the dialog (one of
#      its strings inside its own UI structure, in every layout) is never typed
#      into or sent Enter, whichever caller rings; Escape (Not now) goes through
#      fm-control only for an idle worker; the record stays durable and is
#      delivered once the dialog is gone; the watcher's stale wake names a
#      dialog it could not cancel; every other readable pane rings as before,
#      including one whose output merely quotes a dialog string, and a real
#      dialog is still held when a quote shares its screen.
#   8. A Claude pane whose screen cannot be read - the backend's capture fails
#      or comes back empty - is held the same way but is never sent Escape
#      either, since nothing shows what is on it; each held watcher attempt
#      spends ladder budget, the record is delivered once the screen reads
#      again, and the stale wake says the screen could not be read; the same
#      unreadable screen on another harness rings as before.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-inbox)
# The doorbell line canonicalizes its paths, so keep the fixture root
# canonical too (a trailing-slash TMPDIR otherwise yields a double slash).
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# Run one library function against a state dir through a subshell that sources
# the production library, so the tests exercise the executable surface rather
# than re-implementing any format knowledge here.
inbox_lib() {  # <state> <function> [args...]
  local state=$1
  shift
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fn=$2
    shift 2
    "$fn" "$@"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$@"
}

# A fake tmux for the watcher cases: capture-pane replays FM_FAKE_TMUX_CAPTURE,
# display-message yields a numeric cursor row, and every literal send-keys is
# logged to FM_SEND_LOG so a doorbell ring is observable. With
# FM_FAKE_TMUX_AGENT set, the inventory lists window fm-t1 and its
# #{pane_current_command} answers with that value, so `zsh` makes
# fm_backend_tmux_agent_state read the pane as a dead bare shell.
make_watch_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s\n' "${1:-}" >> "${FM_SEND_LOG:-/dev/null}"
      if [ -n "${FM_ACK_RECORD:-}" ] && [ -f "$FM_ACK_RECORD" ]; then
        mv "$FM_ACK_RECORD" "${FM_ACK_RECORD%/*}/handled/"
      fi
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) [ -z "${FM_FAKE_TMUX_AGENT:-}" ] || { printf '%s\n' "$FM_FAKE_TMUX_AGENT"; exit 0; } ;;
        *pane_tty*) [ -z "${FM_FAKE_TMUX_AGENT:-}" ] || { printf '\n'; exit 0; } ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    if [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && [ -f "$FM_FAKE_TMUX_CAPTURE" ]; then
      cat "$FM_FAKE_TMUX_CAPTURE"
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  list-windows) [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] || printf 'fm-t1\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  make_fake_crew_state "$fb" >/dev/null
  printf '%s\n' "$fb"
}

watch_bg() {  # <state> <fakebin> <out> [extra env assignments...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_TASK_INBOX_GRACE_SECS=1 \
    env "$@" "$WATCH" > "$out" 2>/dev/null &
}

wait_watcher_gone() {  # <pid> [limit-ticks]
  local pid=$1 limit=${2:-120} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

age_path() {  # <path>  (set mtime well past any grace under test)
  touch -t 202001010000 "$1"
}

test_write_is_durable_and_exact() {
  local state rec rec2 doorbell doorbell2 doorbell3 expected actual expected2 actual2 text
  state="$TMP_ROOT/write/state"; mkdir -p "$state"
  text=$'line one\nline two with  spaces\n/slash body\n\n'
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "$text") \
    || fail "inbox write failed"
  [ -f "$rec" ] || fail "inbox write printed a path that does not exist: $rec"
  case "$rec" in
    "$state/t1.inbox/001.msg") : ;;
    *) fail "first record should be 001.msg under the task inbox, got $rec" ;;
  esac
  expected="$state/expected.body"
  actual="$state/actual.body"
  printf '%s' "$text" > "$expected"
  inbox_lib "$state" fm_task_inbox_body "$rec" > "$actual" \
    || fail "record body could not be read"
  cmp -s "$expected" "$actual" \
    || fail "record body did not preserve trailing and blank-line bytes"
  rec2=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "no trailing newline") \
    || fail "second inbox write failed"
  expected2="$state/expected-no-newline.body"
  actual2="$state/actual-no-newline.body"
  printf '%s' "no trailing newline" > "$expected2"
  inbox_lib "$state" fm_task_inbox_body "$rec2" > "$actual2" \
    || fail "second record body could not be read"
  cmp -s "$expected2" "$actual2" \
    || fail "record body added a trailing newline"
  doorbell=$(inbox_lib "$state" fm_task_inbox_doorbell_line "$rec")
  doorbell2=$(inbox_lib "$state" fm_task_inbox_doorbell_line "$rec2")
  [ "$doorbell" = "$doorbell2" ] \
    || fail "every record in one inbox should ring the same drain-all doorbell"
  assert_contains "$doorbell" "'$state/t1.inbox'/*.msg" "doorbell should quote and name all unhandled records"
  assert_contains "$doorbell" "numeric order" "doorbell should require ordered processing"
  assert_contains "$doorbell" "'$state/t1.inbox'/handled/" "doorbell should quote and name the handled dir"
  assert_contains "$doorbell" "Firstmate instruction waiting" "doorbell should be self-describing"
  case "$doorbell" in
    *$'\n'*) fail "the doorbell must be a single line" ;;
  esac
  mkdir -p "$state/t1.inbox/handled"
  mv -f "$rec2" "$state/t1.inbox/handled/${rec2##*/}"
  doorbell3=$(inbox_lib "$state" fm_task_inbox_doorbell_line "$state/t1.inbox/handled/${rec2##*/}")
  [ "$doorbell3" = "$doorbell" ] \
    || fail "a record already acknowledged into handled/ must still ring its own inbox, got: $doorbell3"
  pass "inbox: a steer is written durably and round-trips byte-exact with a self-describing doorbell"
}

# The doorbell may land in a pane whose agent has exited, where it is a shell
# command line. Execute the real line in real shells and assert it is inert:
# exit 0, no output, and nothing in the inbox touched.
test_doorbell_is_a_shell_noop() {
  local state rec doorbell sh out before after marker
  state="$TMP_ROOT/noop/x; touch marker; #'s space/state"
  marker="$state/marker"
  mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  doorbell=$(inbox_lib "$state" fm_task_inbox_doorbell_line "$rec")
  case "$doorbell" in
    ': '*) ;;
    *) fail "the doorbell must start with the shell no-op prefix, got: $doorbell" ;;
  esac
  assert_contains "$doorbell" "'\\''s space/state/t1.inbox'" \
    "the doorbell should escape an embedded single quote in its quoted path"
  before=$(ls -R "$state/t1.inbox")
  for sh in sh bash zsh; do
    command -v "$sh" >/dev/null 2>&1 || continue
    out=$(cd "$state" && "$sh" -c "$doorbell" 2>&1) \
      || fail "$sh executed the hostile-path doorbell with a non-zero status: $out"
    [ -z "$out" ] || fail "$sh produced output while executing the hostile-path doorbell: $out"
    [ ! -e "$marker" ] || fail "$sh executed shell syntax embedded in the inbox path"
  done
  # An interactive-style zsh with the line fed on stdin, the closest portable
  # stand-in for a dead pane's login shell reading typed keystrokes.
  if command -v zsh >/dev/null 2>&1; then
    out=$(cd "$state" && printf '%s\n' "$doorbell" | zsh -s 2>&1) \
      || fail "zsh reading the hostile-path doorbell from stdin failed: $out"
    [ -z "$out" ] || fail "zsh printed while reading the hostile-path doorbell: $out"
    [ ! -e "$marker" ] || fail "zsh executed shell syntax from the stdin doorbell"
  fi
  after=$(ls -R "$state/t1.inbox")
  [ "$before" = "$after" ] || fail "executing the doorbell changed the inbox:"$'\n'"$after"
  [ -f "$rec" ] || fail "executing the doorbell removed the unhandled record"
  pass "inbox: a hostile-path doorbell executes as a no-op in bare shells"
}

test_doorbell_rejects_terminal_controls() {
  local dir state rec doorbell control label log marker rc
  dir="$TMP_ROOT/control-path"
  marker="$dir/marker"
  mkdir -p "$dir"
  make_watch_stubs "$dir" >/dev/null
  for label in etx esc; do
    case "$label" in
      etx) control=$'\003' ;;
      esc) control=$'\033' ;;
    esac
    state="$dir/${control}touch marker; # $label/state"
    mkdir -p "$state"
    rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
    doorbell=
    rc=0
    doorbell=$(inbox_lib "$state" fm_task_inbox_doorbell_line "$rec") || rc=$?
    [ "$rc" -ne 0 ] || fail "a $label path should make doorbell construction fail"
    [ -z "$doorbell" ] || fail "a rejected $label path emitted doorbell bytes"
    log="$dir/$label.send.log"; : > "$log"
    rc=0
    PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$log" \
      inbox_lib "$state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 || rc=$?
    [ "$rc" = 2 ] || fail "a rejected $label path should return send-failed status 2, got $rc"
    [ ! -s "$log" ] || fail "a $label path reached send-keys:"$'\n'"$(cat "$log")"
    [ ! -e "$marker" ] || fail "a $label path executed its crafted command"
    [ -f "$rec" ] || fail "rejecting a $label path removed the durable record"
  done
  pass "inbox: terminal-control paths are rejected without typing"
}

# fm_task_inbox_ring against a backend whose agent classifies dead or missing:
# nothing is typed and the distinct return code lets callers route to recovery.
# An unreadable endpoint still rings, so a blind classifier never starves a
# live worker.
test_ring_skips_dead_agent() {
  local dir state rec log rc
  dir="$TMP_ROOT/ring-dead"
  state="$dir/state"
  mkdir -p "$state"
  make_watch_stubs "$dir" >/dev/null
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  log="$dir/send.log"; : > "$log"
  rc=0
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$log" FM_FAKE_TMUX_AGENT=zsh \
    inbox_lib "$state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 || rc=$?
  [ "$rc" = 3 ] || fail "a dead agent should return 3 from the ring, got $rc"
  [ ! -s "$log" ] || fail "a dead pane was typed into:"$'\n'"$(cat "$log")"
  [ -f "$rec" ] || fail "skipping the ring must leave the durable record in place"
  rc=0
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$log" FM_FAKE_TMUX_MISSING=1 \
    inbox_lib "$state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 || rc=$?
  [ "$rc" = 3 ] || fail "a missing endpoint should return 3 from the ring, got $rc"
  [ ! -s "$log" ] || fail "a missing endpoint was typed into:"$'\n'"$(cat "$log")"
  [ -f "$rec" ] || fail "skipping a missing endpoint must leave the durable record in place"
  rc=0
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$log" FM_FAKE_TMUX_AGENT=claude \
    inbox_lib "$state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 || rc=$?
  [ "$rc" = 0 ] || fail "a live agent should still be rung, got $rc"
  grep -qF 'Firstmate instruction waiting' "$log" || fail "a live agent did not receive the doorbell"
  : > "$log"
  rc=0
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$log" \
    inbox_lib "$state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 || rc=$?
  [ "$rc" = 0 ] || fail "an endpoint the classifier cannot see should still be rung, got $rc"
  grep -qF 'Firstmate instruction waiting' "$log" || fail "an unclassifiable endpoint did not receive the doorbell"
  pass "inbox: the ring skips dead or missing endpoints and still rings live or unclassifiable endpoints"
}

# A fake tmux whose pane is a Claude-style composer that keeps its content in
# FM_FAKE_COMPOSER: literal input appends to it, capture renders it wrapped
# between rules, and Enter submits it (logged as SUBMIT) unless
# FM_FAKE_DROP_ENTERS still holds a count of Enters to swallow.
make_composer_stub() {  # <dir>
  mkdir -p "$1/fakebin"
  cat > "$1/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "$1" >> "$FM_FAKE_COMPOSER"
    elif [ "${1:-}" = Enter ]; then
      drops=$(cat "$FM_FAKE_DROP_ENTERS" 2>/dev/null || echo 0)
      if [ "$drops" -gt 0 ]; then
        echo $((drops - 1)) > "$FM_FAKE_DROP_ENTERS"
      elif [ -s "$FM_FAKE_COMPOSER" ]; then
        printf 'SUBMIT: %s\n' "$(cat "$FM_FAKE_COMPOSER")" >> "$FM_SEND_LOG"
        : > "$FM_FAKE_COMPOSER"
      fi
    fi
    exit 0 ;;
  display-message)
    case "$*" in *cursor_y*) printf '2\n'; exit 0 ;; esac
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    rule=$(printf '─%.0s' $(seq 64))
    printf '● done\n%s\n' "$rule"
    if [ -s "$FM_FAKE_COMPOSER" ]; then
      fold -w 60 "$FM_FAKE_COMPOSER" | awk 'NR == 1 { print "❯ " $0; next } { print "  " $0 }'
    else
      printf '❯ \n'
    fi
    printf '%s\n  ? for shortcuts\n' "$rule"
    exit 0 ;;
  list-windows) printf 'fm-t1\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$1/fakebin/tmux"
}

# The stuck-doorbell deadlock: a doorbell whose Enter never landed sits in the
# composer, and a ring that skipped every pending composer blocked all later
# rings. Our own exact doorbell is submitted instead; any other pending text
# still skips untouched; and a lost Enter after typing gets one retry.
test_ring_submits_its_own_stuck_doorbell() {
  local dir state rec doorbell log composer drops rc other
  dir="$TMP_ROOT/ring-stuck"
  state="$dir/state"
  mkdir -p "$state"
  make_composer_stub "$dir"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  doorbell=$(inbox_lib "$state" fm_task_inbox_doorbell_line "$rec")
  log="$dir/send.log"; composer="$dir/composer"; drops="$dir/drops"
  ring() {
    PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$log" FM_FAKE_COMPOSER="$composer" \
      FM_FAKE_DROP_ENTERS="$drops" inbox_lib "$state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1
  }

  : > "$log"; printf '%s' "$doorbell" > "$composer"
  rc=0; ring || rc=$?
  [ "$rc" = 0 ] || fail "a composer holding our own stuck doorbell should be submitted, got rc $rc"
  [ "$(cat "$log")" = "SUBMIT: $doorbell" ] \
    || fail "the stuck doorbell should be submitted exactly once, not retyped:"$'\n'"$(cat "$log")"
  [ ! -s "$composer" ] || fail "the stuck doorbell was left in the composer"

  : > "$log"; printf '%s' "$doorbell" > "$composer"; echo 1 > "$drops"
  rc=0; ring || rc=$?
  [ "$rc" = 0 ] || fail "a stuck doorbell whose first Enter is lost should still report rung, got rc $rc"
  [ "$(cat "$log")" = "SUBMIT: $doorbell" ] \
    || fail "the retry Enter should submit the stuck doorbell once, not retype it:"$'\n'"$(cat "$log")"
  [ ! -s "$composer" ] || fail "a lost Enter left the stuck doorbell unsubmitted"

  for other in 'a half-typed draft' "$doorbell and a draft"; do
    : > "$log"; printf '%s' "$other" > "$composer"
    rc=0; ring || rc=$?
    [ "$rc" = 1 ] || fail "other pending text should skip the ring, got rc $rc for: $other"
    [ ! -s "$log" ] || fail "other pending text was submitted:"$'\n'"$(cat "$log")"
    [ "$(cat "$composer")" = "$other" ] || fail "other pending text was changed: $(cat "$composer")"
  done

  : > "$log"; : > "$composer"; echo 1 > "$drops"
  rc=0; ring || rc=$?
  [ "$rc" = 0 ] || fail "a ring whose first Enter is lost should still report rung, got rc $rc"
  [ "$(cat "$log")" = "SUBMIT: $doorbell" ] \
    || fail "the retry Enter should submit the doorbell once:"$'\n'"$(cat "$log")"
  [ ! -s "$composer" ] || fail "a lost Enter left the doorbell unsubmitted"
  pass "inbox: the ring submits its own stuck doorbell, skips other pending text, and retries a lost Enter once on both paths"
}

test_idempotent_write_dedups_exact_body() {
  local state r1 r2 r3 r4 count text
  state="$TMP_ROOT/idem/state"; mkdir -p "$state"
  text=$'re-runnable steer\nsecond line'
  r1=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "$text") \
    || fail "idempotent write failed"
  [ "$r1" = "$state/t1.inbox/001.msg" ] || fail "first idempotent write should create 001.msg, got $r1"
  # Re-running the same enqueue (the safe recovery after an ambiguous remote
  # transport failure) lands on the SAME record, never a duplicate.
  r2=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "$text") \
    || fail "idempotent re-run failed"
  [ "$r2" = "$r1" ] || fail "an identical re-run should return the existing record, got $r2"
  count=$(find "$state/t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "an identical re-run must not enqueue a duplicate, found $count records"
  # A different body - two logical requests differ at least by their embedded
  # correlation token - still enqueues normally.
  r3=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 $'re-runnable steer\nsecond line changed') \
    || fail "idempotent write of a different body failed"
  [ "$r3" = "$state/t1.inbox/002.msg" ] || fail "a different body should enqueue a new record, got $r3"
  # A body the worker already acknowledged still dedups: the re-run reports
  # the handled record rather than re-delivering an instruction that was
  # already acted on.
  mv "$r1" "$state/t1.inbox/handled/"
  r4=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "$text") \
    || fail "idempotent re-run after the ack failed"
  [ "$r4" = "$state/t1.inbox/handled/001.msg" ] \
    || fail "a re-run of an acknowledged steer should land on the handled record, got $r4"
  count=$(find "$state/t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "a re-run of an acknowledged steer must not re-enqueue it, found $count unhandled records"
  pass "inbox: the idempotent enqueue dedups an exact re-run onto the same record, handled or not"
}

test_idempotent_write_follows_concurrent_ack() {
  local state rec result count text
  state="$TMP_ROOT/idem-ack-race/state"; mkdir -p "$state"
  text="acknowledge while dedup scans"
  rec=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "$text") \
    || fail "race fixture write failed"
  result=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    eval "$(declare -f fm_task_inbox_body | sed "1s/fm_task_inbox_body/_original_fm_task_inbox_body/")"
    fm_task_inbox_body() {
      candidate=$1
      case "$candidate" in
        */handled/*) ;;
        *) mv "$candidate" "${candidate%/*}/handled/" || return 1
           candidate="${candidate%/*}/handled/${candidate##*/}" ;;
      esac
      _original_fm_task_inbox_body "$candidate"
    }
    fm_task_inbox_write_idempotent "$2" t1 "$3"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$state" "$text") \
    || fail "idempotent enqueue failed while acknowledgement moved its candidate"
  [ "$result" = "$state/t1.inbox/handled/${rec##*/}" ] \
    || fail "dedup did not follow the concurrently acknowledged record: $result"
  count=$(find "$state/t1.inbox" -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "acknowledgement racing dedup created a duplicate record"
  pass "inbox: idempotent enqueue follows a record concurrently moved to handled"
}

test_handled_mv_dedups_by_sequence() {
  local state r1 r2 oldest r3
  state="$TMP_ROOT/dedup/state"; mkdir -p "$state"
  r1=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "first")
  r2=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "second")
  [ "$r2" = "$state/t1.inbox/002.msg" ] || fail "second record should be 002.msg, got $r2"
  oldest=$(inbox_lib "$state" fm_task_inbox_oldest_unhandled "$state" t1)
  [ "$oldest" = "$r1" ] || fail "oldest unhandled should be 001, got $oldest"
  mv "$r1" "$state/t1.inbox/handled/"
  oldest=$(inbox_lib "$state" fm_task_inbox_oldest_unhandled "$state" t1)
  [ "$oldest" = "$r2" ] || fail "after the ack mv the oldest should advance to 002, got $oldest"
  # Re-acking the same message is a no-op: the record is already retired and
  # nothing re-lists it as unhandled.
  mv "$state/t1.inbox/001.msg" "$state/t1.inbox/handled/" 2>/dev/null \
    && fail "a second mv of an acked record should find nothing to move"
  mv "$r2" "$state/t1.inbox/handled/"
  if inbox_lib "$state" fm_task_inbox_oldest_unhandled "$state" t1 >/dev/null; then
    fail "a fully handled inbox should report no unhandled record"
  fi
  # An acknowledged sequence is never reissued, so a message is processed at
  # most once per worker lifetime even if every doorbell is duplicated.
  r3=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "third")
  [ "$r3" = "$state/t1.inbox/003.msg" ] || fail "a handled sequence was reissued: $r3"
  pass "inbox: the handled mv is the idempotent ack and sequences are never reissued"
}

test_concurrent_writers_never_clobber() {
  local state i pids=() count
  state="$TMP_ROOT/race/state"; mkdir -p "$state"
  for i in 1 2 3 4 5 6; do
    inbox_lib "$state" fm_task_inbox_write "$state" t1 "steer number $i" >/dev/null &
    pids+=($!)
  done
  for i in "${pids[@]}"; do
    wait "$i" || fail "a concurrent inbox write failed"
  done
  count=$(find "$state/t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 6 ] || fail "6 concurrent writes should yield 6 records, got $count:"$'\n'"$(ls "$state/t1.inbox")"
  for i in 1 2 3 4 5 6; do
    grep -rqF "steer number $i" "$state/t1.inbox" \
      || fail "steer number $i was lost in the concurrent write race"
  done
  pass "inbox: concurrent writers serialize on the sequence lock and lose nothing"
}

test_writer_retries_after_a_vanished_lock_collision() {
  local state fakebin marker rec real_ln
  state="$TMP_ROOT/vanished-lock-race/state"
  fakebin="$TMP_ROOT/vanished-lock-race/fakebin"
  marker="$TMP_ROOT/vanished-lock-race/first-ln-failed"
  mkdir -p "$state" "$fakebin"
  real_ln=$(command -v ln)
  cat > "$fakebin/ln" <<'SH'
#!/usr/bin/env bash
set -u
if [ ! -e "$FM_FAKE_LN_MARKER" ]; then
  : > "$FM_FAKE_LN_MARKER"
  exit 1
fi
exec "$FM_REAL_LN" "$@"
SH
  chmod +x "$fakebin/ln"

  rec=$(PATH="$fakebin:$PATH" FM_REAL_LN="$real_ln" FM_FAKE_LN_MARKER="$marker" \
    inbox_lib "$state" fm_task_inbox_write "$state" t1 "steer after collision") \
    || fail "a writer abandoned an acquisition whose competing lock had already vanished"
  [ -f "$rec" ] || fail "the retry after a vanished lock collision did not write its record"
  pass "inbox: a writer retries when a competing lock vanishes after its failed claim"
}

test_ladder_writes_ignore_vanished_inbox() {
  local state rec
  state="$TMP_ROOT/vanished/state"; mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "retired task")
  rm -rf "$state/t1.inbox"
  inbox_lib "$state" fm_task_inbox_record_ring "$state" t1 "$rec" \
    || fail "ring bookkeeping should ignore a concurrently removed inbox"
  inbox_lib "$state" fm_task_inbox_record_escalated "$state" t1 "$rec" \
    || fail "escalation bookkeeping should ignore a concurrently removed inbox"
  [ ! -e "$state/t1.inbox" ] || fail "bookkeeping recreated a retired task inbox"
  pass "inbox: ladder bookkeeping ignores a concurrently removed inbox"
}

test_fire_and_forget_records_never_enter_the_ladder() {
  local state fire tracked action
  state="$TMP_ROOT/fire-and-forget/state"; mkdir -p "$state"
  fire=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "one-shot steer" fire-and-forget)
  age_path "$fire"
  action=$(FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_RING_MAX=0 \
    inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "a fire-and-forget record entered the re-ring ladder: $action"
  tracked=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "tracked steer")
  age_path "$tracked"
  action=$(FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_RING_MAX=0 \
    inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "escalate $tracked 0" ] \
    || fail "a fire-and-forget record hid the later tracked steer: $action"
  [ -f "$fire" ] || fail "excluding fire-and-forget from escalation removed its durable record"
  pass "inbox: fire-and-forget records stay durable and outside the ladder"
}

test_ring_ladder_policy() {
  local state rec action
  state="$TMP_ROOT/ladder/state"; mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "do the thing")
  # Within grace: quiet.
  action=$(FM_TASK_INBOX_GRACE_SECS=3600 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "a fresh unhandled message inside grace should be quiet, got: $action"
  # Past grace: one ring is due.
  age_path "$rec"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "ring $rec" ] || fail "an aged unhandled message should be due a ring, got: $action"
  # A just-recorded ring holds the spacing: quiet until another grace elapses.
  inbox_lib "$state" fm_task_inbox_record_ring "$state" t1 "$rec"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "a ring within the spacing window should be quiet, got: $action"
  # Backdate the ladder: the next ring becomes due, and at the budget the
  # action turns into a single escalation.
  printf '001.msg\t1\t100\n' > "$state/t1.inbox/.ring-state"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "ring $rec" ] || fail "an aged ladder should ring again, got: $action"
  printf '001.msg\t3\t100\n' > "$state/t1.inbox/.ring-state"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "escalate $rec 3" ] || fail "a spent ring budget should escalate, got: $action"
  # Escalation fires at most once per message.
  inbox_lib "$state" fm_task_inbox_record_escalated "$state" t1 "$rec"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "an escalated message should stay quiet for recovery, got: $action"
  # The acknowledgement resets the ladder: the next message starts fresh.
  mv "$rec" "$state/t1.inbox/handled/"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "a handled inbox should be quiet, got: $action"
  [ ! -e "$state/t1.inbox/.escalated" ] || fail "the ack should clear the escalation marker"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "next thing")
  age_path "$rec"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "ring $rec" ] || fail "the next message should start a fresh ladder, got: $action"
  pass "inbox: the re-ring ladder paces by grace, escalates once, and resets on ack"
}

setup_watch_case() {  # <name> -> echoes case dir; state in <dir>/state
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state"
  make_watch_stubs "$dir" >/dev/null
  fm_write_meta "$dir/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=grok"
  printf '%s\n' "$dir"
}

idle_capture() {  # <dir>
  printf '╭────╮\n│    │\n╰────╯\n' > "$1/idle.capture"
  printf '%s\n' "$1/idle.capture"
}

test_watcher_rerings_idle_pane_quietly() {
  local dir state out log pid rec
  dir=$(setup_watch_case rering)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=99
  pid=$!
  local i=0
  while [ "$i" -lt 100 ]; do
    grep -qF 'Firstmate instruction waiting' "$log" 2>/dev/null && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "Firstmate instruction waiting: list '$state/t1.inbox'/*.msg" "$log" \
    || { kill "$pid" 2>/dev/null; fail "the watcher never re-rang the doorbell:"$'\n'"$(cat "$log")"; }
  kill -0 "$pid" 2>/dev/null \
    || fail "a healthy re-ring must not wake firstmate (watcher exited):"$'\n'"$(cat "$out")"
  [ ! -s "$state/.wake-queue" ] \
    || { kill "$pid" 2>/dev/null; fail "a healthy re-ring queued a wake:"$'\n'"$(cat "$state/.wake-queue")"; }
  # The acknowledgement silences the ladder: no further doorbells after the mv.
  mv "$rec" "$state/t1.inbox/handled/"
  sleep 2.5
  : > "$log"
  sleep 2.5
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  [ ! -s "$log" ] || fail "the watcher kept ringing after the ack:"$'\n'"$(cat "$log")"
  pass "watcher: an unhandled aged message on an idle pane re-rings without waking firstmate, and the ack silences it"
}

test_watcher_waits_on_busy_pane() {
  local dir state out log pid rec
  dir=$(setup_watch_case busywait)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  printf 'some output\nBUSYTOKEN active\n' > "$dir/busy.capture"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$dir/busy.capture" \
    FM_BUSY_REGEX=BUSYTOKEN FM_TASK_INBOX_RING_MAX=99
  pid=$!
  sleep 4
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  [ ! -s "$log" ] || fail "a busy pane should wait, not ring:"$'\n'"$(cat "$log")"
  [ ! -s "$state/.wake-queue" ] || fail "a busy wait queued a wake:"$'\n'"$(cat "$state/.wake-queue")"
  pass "watcher: a busy pane just waits - the record is durable and no doorbell is typed"
}

test_watcher_quiet_on_healthy_inbox() {
  local dir state out log pid
  dir=$(setup_watch_case healthy)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  mkdir -p "$state/t1.inbox/handled"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=99
  pid=$!
  sleep 4
  kill -0 "$pid" 2>/dev/null || fail "the watcher exited on a healthy empty inbox:"$'\n'"$(cat "$out")"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  [ ! -s "$log" ] || fail "an empty inbox rang a doorbell:"$'\n'"$(cat "$log")"
  [ ! -s "$state/.wake-queue" ] || fail "an empty inbox queued a wake:"$'\n'"$(cat "$state/.wake-queue")"
  pass "watcher: a healthy or empty inbox stays completely silent"
}

test_watcher_ack_silences_unwritable_ladder() {
  local dir state out log pid rec rings i=0
  dir=$(setup_watch_case ack-unwritable-ladder)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  mkdir "$state/t1.inbox/.ring-state"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_ACK_RECORD="$rec" FM_TASK_INBOX_RING_MAX=99
  pid=$!
  while [ "$i" -lt 100 ]; do
    [ -f "$state/t1.inbox/handled/001.msg" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  [ -f "$state/t1.inbox/handled/001.msg" ] \
    || { kill "$pid" 2>/dev/null; fail "the doorbell stub did not acknowledge the record"; }
  sleep 2
  kill -0 "$pid" 2>/dev/null \
    || fail "the watcher escalated ladder failure after the record was acknowledged:"$'\n'"$(cat "$out")"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  rings=$(grep -cF 'Firstmate instruction waiting' "$log" || true)
  [ "$rings" = 1 ] || fail "acknowledgement should silence retries, got $rings doorbells:"$'\n'"$(cat "$log")"
  [ ! -s "$state/.wake-queue" ] \
    || fail "an acknowledged record queued a bookkeeping wake:"$'\n'"$(cat "$state/.wake-queue")"
  pass "watcher: acknowledgement silences an unwritable ladder without a stale wake"
}

test_watcher_surfaces_unwritable_ladder() {
  local dir state out log pid rec rings wakes
  dir=$(setup_watch_case unwritable-ladder)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  mkdir "$state/t1.inbox/.ring-state"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=99
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "the watcher silently retried with unwritable ladder bookkeeping"; }
  rings=$(grep -cF 'Firstmate instruction waiting' "$log" || true)
  [ "$rings" = 1 ] || fail "expected one doorbell before the bookkeeping wake, got $rings:"$'\n'"$(cat "$log")"
  wakes=$(grep -cF 'steering-inbox ladder bookkeeping unwritable' "$state/.wake-queue" || true)
  [ "$wakes" = 1 ] \
    || fail "expected exactly one bookkeeping-unwritable stale wake, got $wakes:"$'\n'"$(cat "$state/.wake-queue" 2>/dev/null)"
  grep -qF "$state/t1.inbox/.ring-state cannot be written" "$state/.wake-queue" \
    || fail "the stale wake did not identify the unwritable ladder:"$'\n'"$(cat "$state/.wake-queue")"
  [ -f "$rec" ] || fail "the unhandled record disappeared during bookkeeping failure"
  grep -qF 'stale:' "$out" \
    || fail "the watcher should exit through the ordinary stale wake:"$'\n'"$(cat "$out")"
  pass "watcher: unwritable ladder bookkeeping surfaces a stale wake after the doorbell"
}

test_watcher_escalates_once_after_budget() {
  local dir state out log pid rec rings
  dir=$(setup_watch_case escalate)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=1
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "the watcher never escalated a spent ring budget"; }
  rings=$(grep -cF 'Firstmate instruction waiting' "$log" || true)
  [ "$rings" = 1 ] || fail "expected exactly 1 doorbell before escalation, got $rings:"$'\n'"$(cat "$log")"
  grep -qF 'unread firstmate instruction' "$state/.wake-queue" \
    || fail "the escalation should queue a stale wake naming the unread instruction:"$'\n'"$(cat "$state/.wake-queue" 2>/dev/null)"
  grep -qF "$rec" "$state/.wake-queue" \
    || fail "the stale wake should name the record path:"$'\n'"$(cat "$state/.wake-queue")"
  [ "$(grep -cF 'unread firstmate instruction' "$state/.wake-queue")" = 1 ] \
    || fail "the escalation must fire exactly once:"$'\n'"$(cat "$state/.wake-queue")"
  grep -qF 'stale:' "$out" || fail "the watcher should exit through the ordinary stale wake:"$'\n'"$(cat "$out")"
  pass "watcher: a spent ring budget emits exactly one ordinary stale wake for recovery"
}

test_watcher_dead_pane_escalates_once_without_ringing() {
  local dir state out log pid rec
  dir=$(setup_watch_case dead-pane)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_FAKE_TMUX_AGENT=zsh FM_TASK_INBOX_RING_MAX=99
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "the watcher never surfaced a dead pane's unhandled instruction"; }
  [ ! -s "$log" ] || fail "a dead pane was typed into:"$'\n'"$(cat "$log")"
  [ "$(grep -cF 'unread firstmate instruction' "$state/.wake-queue" 2>/dev/null || true)" = 1 ] \
    || fail "a dead pane should surface exactly one stale wake:"$'\n'"$(cat "$state/.wake-queue" 2>/dev/null)"
  grep -qF "agent has exited" "$state/.wake-queue" \
    || fail "the stale wake should say the agent has exited:"$'\n'"$(cat "$state/.wake-queue")"
  grep -qF "$rec" "$state/.wake-queue" || fail "the stale wake should name the record path"
  [ -f "$rec" ] || fail "the durable record must survive for recovery"
  [ "$(cat "$state/t1.inbox/.escalated")" = "${rec##*/}" ] \
    || fail "the escalation marker should suppress further surfacing of this record"
  [ ! -e "$state/t1.inbox/.ring-state" ] || fail "a dead pane must not enter the re-ring ladder"
  # The ladder is capped: nothing further is due for this record, so no later
  # poll rings the dead pane or queues a second wake.
  [ "$(inbox_lib "$state" fm_task_inbox_due_action "$state" t1)" = quiet ] \
    || fail "a dead pane already surfaced must be quiet on later polls"
  pass "watcher: a positively dead pane is never typed into and surfaces exactly one stale wake"
}

test_watcher_dead_pane_ignores_stale_busy_state() {
  local dir state out log pid rec
  dir=$(setup_watch_case dead-pane-busy)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  printf 'some output\nBUSYTOKEN active\n' > "$dir/busy.capture"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$dir/busy.capture" \
    FM_FAKE_TMUX_AGENT=zsh FM_BUSY_REGEX=BUSYTOKEN FM_TASK_INBOX_RING_MAX=99
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "stale busy state hid a dead pane's unhandled instruction"; }
  [ ! -s "$log" ] || fail "a busy-marked dead pane was typed into:"$'\n'"$(cat "$log")"
  [ "$(grep -cF 'unread firstmate instruction' "$state/.wake-queue" 2>/dev/null || true)" = 1 ] \
    || fail "a busy-marked dead pane should surface exactly once:"$'\n'"$(cat "$state/.wake-queue" 2>/dev/null)"
  [ -f "$rec" ] || fail "the durable record must survive stale busy-state recovery"
  [ "$(cat "$state/t1.inbox/.escalated")" = "${rec##*/}" ] \
    || fail "stale busy-state recovery should suppress repeated surfacing"
  pass "watcher: dead-pane recovery overrides stale busy state"
}

# --- Claude auto-mode setup dialog guard ------------------------------------
#
# Claude Code offers /auto-mode-setup between turns with Yes focused, so a
# doorbell's Enter would accept an offer whose wizard scans the project's recent
# session transcripts. These cases drive the real ring, the real fm-control
# interrupt it calls, and a real watcher over the shared fake Claude pane
# (tests/fixtures.sh), which records every typed byte and every named key. The
# screens come from fm_test_claude_dialog_screen, which draws them from the UI
# structure Claude Code's own component code gives the dialog; the real dialog
# is never opened, because opening it sends transcript-derived material to a
# model. The contract under test is owned by bin/fm-task-inbox-lib.sh: a string
# counts only inside the dialog's own UI structure, so the same words quoted in
# ordinary output never hold a ring.

# How many of the four strings a screen carries after the whitespace folding a
# wrapped pane needs. Asserting it is 1 for every dialog screen keeps the cases
# from going quietly vacuous: the verdict has to rest on the one string shown.
dialog_strings_on() {  # <screen-text>
  local flat n=0 str
  flat=$(printf '%s' "$1" | LC_ALL=C tr -s '[:space:]' ' ')
  for str in "$FM_TEST_DIALOG_TITLE" "$FM_TEST_DIALOG_OFFER_BODY" "$FM_TEST_DIALOG_CONFIRM_BODY" "$FM_TEST_DIALOG_SCAN_ROW"; do
    case "$flat" in
      *"$str"*) n=$((n + 1)) ;;
    esac
  done
  printf '%s' "$n"
}

# One Claude task (t1) in <dir>: a state dir with the endpoint identity
# fm-control validates before it will press a key, a semantic busy record, and
# the shared fake tmux whose pane files live in <dir>/pane. <screen> is a
# fm_test_claude_dialog_screen name, or `composer` for the fake's own idle Claude composer.
dialog_case() {  # <name> <screen> [harness] [busy: idle|busy|unknown|none] -> echoes case dir
  local name=$1 screen=$2 harness=${3:-claude} busy=${4:-idle} dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state" "$dir/fakebin" "$dir/pane" "$dir/proj" "$dir/wt"
  fm_test_fake_tmux_claude_pane "$dir/fakebin"
  make_fake_crew_state "$dir/fakebin" >/dev/null
  fm_write_meta "$dir/state/t1.meta" "window=fmses:fm-t1" "endpoint_task_id=t1" \
    "worktree=$dir/wt" "project=$dir/proj" "harness=$harness" "kind=ship" \
    "mode=no-mistakes" "yolo=off"
  [ "$busy" = none ] || "$ROOT/bin/fm-busy-event.sh" arm "$dir/state" t1 \
    --state "$busy" --source claude-hook --event stop > /dev/null
  [ "$screen" = composer ] || fm_test_claude_dialog_screen "$screen" > "$dir/pane/pane"
  inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue" > /dev/null
  printf '%s\n' "$dir"
}

# Ring the case's record once through the production ring and print its return
# code. The notice the ring left in FM_TASK_INBOX_RING_NOTICE goes to
# <dir>/notice, and FM_HOME is left unset so the guard has to find the home
# itself, as the watcher does. `bounded` makes the guard read the screen the way
# a backend with no viewport-only capture does (cmux and orca), by emptying the
# list of backends that have one once the library is sourced.
dialog_ring() {  # <dir> [viewport|bounded]
  local dir=$1 view=${2:-viewport} rc=0
  (
    unset FM_HOME
    PATH="$dir/fakebin:$PATH" FM_FAKE_PANE_DIR="$dir/pane" \
      FM_STATE_OVERRIDE="$dir/state" FM_CONTROL_POLL=0.01 FM_CONTROL_SETTLE_WAIT=0.05 \
      bash -c '
        . "$1"
        [ "$4" != bounded ] || FM_BACKEND_VISIBLE_CAPTURE=
        fm_task_inbox_ring tmux fmses:fm-t1 "$2" fm-t1
        rc=$?
        printf "%s" "$FM_TASK_INBOX_RING_NOTICE" > "$3"
        exit "$rc"
      ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$dir/state/t1.inbox/001.msg" "$dir/notice" "$view"
  ) || rc=$?
  printf '%s' "$rc"
}

# What reached the pane, one file each: text typed, named keys, submitted text.
pane_file() {  # <dir> <literal|keys|submits>
  cat "$1/pane/$2" 2>/dev/null || true
}

test_dialog_guard_blocks_the_ring_on_each_string_alone() {
  local screen dir rc notice want
  for screen in title offer-body confirm-body scan-row scan-row-wrapped scan-status scan-status-fullscreen scan-status-no-frame \
    wrapped-title title-fullscreen title-no-frame title-no-footer; do
    dir=$(dialog_case "dialog-$screen" "$screen")
    [ "$(dialog_strings_on "$(fm_test_claude_dialog_screen "$screen")")" = 1 ] \
      || fail "the $screen screen must carry exactly one dialog string, or its verdict proves nothing"
    rc=$(dialog_ring "$dir")
    [ "$rc" = 4 ] || fail "$screen: a Claude auto-mode setup dialog should skip the ring with 4, got $rc"
    [ -z "$(pane_file "$dir" literal)" ] \
      || fail "$screen: text was typed into the dialog:"$'\n'"$(pane_file "$dir" literal)"
    [ -z "$(pane_file "$dir" submits)" ] || fail "$screen: something was submitted into the dialog"
    [ "$(pane_file "$dir" keys)" = Escape ] \
      || fail "$screen: only Escape, Not now, may reach the dialog, got: $(pane_file "$dir" keys | tr '\n' ' ')"
    [ -f "$dir/state/t1.inbox/001.msg" ] || fail "$screen: skipping the ring must leave the durable record in place"
    case "$screen" in
      title|wrapped-title|title-fullscreen|title-no-frame|title-no-footer) want=$FM_TEST_DIALOG_TITLE ;;
      offer-body) want=$FM_TEST_DIALOG_OFFER_BODY ;;
      confirm-body) want=$FM_TEST_DIALOG_CONFIRM_BODY ;;
      scan-row|scan-row-wrapped|scan-status|scan-status-fullscreen|scan-status-no-frame) want=$FM_TEST_DIALOG_SCAN_ROW ;;
    esac
    notice=$(cat "$dir/notice")
    assert_contains "$notice" "task t1" "$screen: the notice must name the task"
    assert_contains "$notice" "auto-mode setup dialog" "$screen: the notice must name the dialog"
    assert_contains "$notice" "\"$want\"" "$screen: the notice must name the string that matched"
    assert_contains "$notice" "no text and no Enter were sent" "$screen: the notice must say nothing was typed"
    assert_contains "$notice" "Escape, the dialog's cancel key, was delivered" "$screen: the notice must say what was pressed"
  done
  pass "inbox: a Claude pane showing the dialog is never typed into, and only Escape reaches it, whichever one string it shows and in every layout"
}

test_dialog_guard_sends_no_escape_to_a_worker_that_is_not_idle() {
  local busy dir rc notice
  for busy in busy unknown none; do
    dir=$(dialog_case "dialog-notidle-$busy" title claude "$busy")
    rc=$(dialog_ring "$dir")
    [ "$rc" = 4 ] || fail "$busy: a dialog on a not-idle worker should still skip the ring with 4, got $rc"
    [ -z "$(pane_file "$dir" literal)" ] || fail "$busy: text was typed onto the dialog"
    [ -z "$(pane_file "$dir" keys)" ] \
      || fail "$busy: a worker that does not read idle must not be sent any key, got: $(pane_file "$dir" keys | tr '\n' ' ')"
    notice=$(cat "$dir/notice")
    assert_contains "$notice" "Escape was not sent" "$busy: the notice must say no Escape went out"
    assert_contains "$notice" "rather than idle" "$busy: the notice must say why"
    [ -f "$dir/state/t1.inbox/001.msg" ] || fail "$busy: the record must stay durable"
  done
  pass "inbox: the dialog guard defers without pressing anything when the worker does not read idle"
}

test_dialog_guard_defers_then_delivers_once_the_dialog_is_gone() {
  local dir rc
  dir=$(dialog_case dialog-dismissed title)
  touch "$dir/pane/dismiss-on-escape"
  rc=$(dialog_ring "$dir")
  [ "$rc" = 4 ] || fail "the first ring should defer on the dialog, got $rc"
  [ ! -e "$dir/pane/pane" ] || fail "the fake dialog should be gone after Escape, or this case proves nothing"
  rc=$(dialog_ring "$dir")
  [ "$rc" = 0 ] || fail "the next ring, with the dialog gone, should deliver, got $rc"
  [ "$(pane_file "$dir" literal | grep -cF 'Firstmate instruction waiting')" = 1 ] \
    || fail "the doorbell should be typed exactly once, after the dialog:"$'\n'"$(pane_file "$dir" literal)"
  [ "$(pane_file "$dir" keys | tr '\n' ' ')" = 'Escape Enter ' ] \
    || fail "expected Escape, then Enter only after the dialog was gone, got: $(pane_file "$dir" keys | tr '\n' ' ')"
  case "$(pane_file "$dir" submits)" in
    *'Firstmate instruction waiting'*) ;;
    *) fail "the deferred steer's doorbell was never submitted" ;;
  esac
  [ -f "$dir/state/t1.inbox/001.msg" ] || fail "the record is the worker's to acknowledge, not the ring's"
  [ -z "$(cat "$dir/notice")" ] || fail "a ring that delivers must leave no dialog notice"
  pass "inbox: a deferred steer is delivered by the next ring once the dialog is gone"
}

test_dialog_guard_reports_a_failed_escape() {
  local dir rc notice
  dir=$(dialog_case dialog-escape-fails title)
  printf 'Escape' > "$dir/pane/fail-key"
  rc=$(dialog_ring "$dir")
  [ "$rc" = 4 ] || fail "a dialog whose Escape failed should still skip the ring with 4, got $rc"
  [ -z "$(pane_file "$dir" literal)" ] || fail "text was typed onto a dialog Escape could not close"
  [ -z "$(pane_file "$dir" keys)" ] || fail "no key should have landed: $(pane_file "$dir" keys | tr '\n' ' ')"
  notice=$(cat "$dir/notice")
  assert_contains "$notice" "fm-control interrupt failed" "the notice must say Escape did not go through"
  assert_contains "$notice" "may still be open" "the notice must say the dialog may still be up"
  [ -f "$dir/state/t1.inbox/001.msg" ] || fail "the record must stay durable"
  pass "inbox: a failed Escape is reported, and nothing is typed onto the dialog"
}

test_dialog_guard_leaves_every_other_pane_alone() {
  local view screen dir rc
  for view in viewport bounded; do
    for screen in composer auto-mode-footer near-miss bare-prompt; do
      dir=$(dialog_case "dialog-quiet-$view-$screen" "$screen")
      [ "$(dialog_strings_on "$(fm_test_claude_dialog_screen "$screen")")" = 0 ] \
        || fail "the $screen screen must carry none of the dialog strings"
      rc=$(dialog_ring "$dir" "$view")
      [ "$rc" = 0 ] || fail "$view/$screen: an ordinary Claude pane should still be rung, got $rc"
      [ "$(pane_file "$dir" literal | grep -cF 'Firstmate instruction waiting')" = 1 ] \
        || fail "$view/$screen: the doorbell was not typed:"$'\n'"$(pane_file "$dir" literal)"
      case "$(pane_file "$dir" keys)" in
        *Escape*) fail "$view/$screen: an ordinary pane must never be sent Escape" ;;
      esac
      [ -z "$(cat "$dir/notice")" ] || fail "$view/$screen: an ordinary ring must leave no notice"
    done
  done
  pass "inbox: readable Claude panes, including auto mode's own status row, a near-miss, and a lone prompt glyph, ring as before"
}

test_dialog_guard_holds_the_whole_offer_and_names_its_title() {
  local dir rc notice
  dir=$(dialog_case dialog-offer offer)
  [ "$(dialog_strings_on "$(fm_test_claude_dialog_screen offer)")" = 2 ] \
    || fail "the offer screen must carry both the title and the body, or it is not the whole dialog"
  rc=$(dialog_ring "$dir")
  [ "$rc" = 4 ] || fail "the whole offer should skip the ring with 4, got $rc"
  [ -z "$(pane_file "$dir" literal)" ] || fail "text was typed into the offer"
  [ "$(pane_file "$dir" keys)" = Escape ] \
    || fail "only Escape, Not now, may reach the offer, got: $(pane_file "$dir" keys | tr '\n' ' ')"
  notice=$(cat "$dir/notice")
  assert_contains "$notice" "\"$FM_TEST_DIALOG_TITLE\"" "the notice should name the title, the first string that matched"
  pass "inbox: the whole offer is held and the notice names its title"
}

# The reported bug: an idle, ready Claude pane whose ordinary output quotes one
# of the dialog's strings has no dialog on it, so the ring must go through. Each
# screen is asserted to carry a string, or the case would pass vacuously; the
# last five quote the string where the structure alone is not the dialog: a
# frame rule over a row that merely starts with the title or the scan string, a
# status row over a row that starts with the scan string, the dialog's shape
# pasted into a reply, and another select dialog whose text quotes the title.
test_dialog_guard_ignores_a_string_quoted_outside_the_dialog() {
  local view screen dir rc
  for view in viewport bounded; do
    for screen in quoted-title quoted-title-at-row-start quoted-offer-body quoted-confirm-body \
      quoted-scan-row quoted-scan-row-at-row-start quoted-scan-row-bullet rule-then-title rule-then-scan-status \
      status-then-scan-status mock-in-output quoted-in-other-dialog; do
      dir=$(dialog_case "dialog-quoted-$view-$screen" "$screen")
      [ "$(dialog_strings_on "$(fm_test_claude_dialog_screen "$screen")")" -ge 1 ] \
        || fail "the $screen screen must carry a dialog string, or it proves nothing about the guard"
      rc=$(dialog_ring "$dir" "$view")
      [ "$rc" = 0 ] || fail "$view/$screen: a string quoted with no dialog on the screen must not hold the ring, got $rc"
      [ "$(pane_file "$dir" literal | grep -cF 'Firstmate instruction waiting')" = 1 ] \
        || fail "$view/$screen: the doorbell was not typed:"$'\n'"$(pane_file "$dir" literal)"
      case "$(pane_file "$dir" keys)" in
        *Escape*) fail "$view/$screen: a pane with no dialog on it must never be sent Escape" ;;
      esac
      [ -z "$(cat "$dir/notice")" ] || fail "$view/$screen: a ring that goes through must leave no notice"
    done
  done
  pass "inbox: a dialog string quoted in ordinary output, with no dialog on the screen, rings as before"
}

test_dialog_guard_still_holds_when_a_quote_shares_the_screen_with_the_dialog() {
  local view dir rc notice
  for view in viewport bounded; do
    dir=$(dialog_case "dialog-quote-and-dialog-$view" quote-above-dialog)
    [ "$(dialog_strings_on "$(fm_test_claude_dialog_screen quote-above-dialog)")" = 1 ] \
      || fail "the quote-above-dialog screen must carry the title, quoted and as the dialog's own title"
    rc=$(dialog_ring "$dir" "$view")
    [ "$rc" = 4 ] || fail "$view: a real dialog under a quote of its title should skip the ring with 4, got $rc"
    [ -z "$(pane_file "$dir" literal)" ] || fail "$view: text was typed into the dialog"
    [ "$(pane_file "$dir" keys)" = Escape ] \
      || fail "$view: only Escape, Not now, may reach the dialog, got: $(pane_file "$dir" keys | tr '\n' ' ')"
    notice=$(cat "$dir/notice")
    assert_contains "$notice" "\"$FM_TEST_DIALOG_TITLE\"" "$view: the notice should name the string that matched"
    [ -f "$dir/state/t1.inbox/001.msg" ] || fail "$view: skipping the ring must leave the durable record in place"
  done
  pass "inbox: a real dialog is still held when the same words are also quoted elsewhere on the screen"
}

test_dialog_guard_reads_only_the_viewport() {
  local dir rc deep shallow
  dir=$(dialog_case dialog-scrollback composer)
  fm_test_claude_dialog_screen offer-body > "$dir/pane/scrollback"
  deep=$(PATH="$dir/fakebin:$PATH" FM_FAKE_PANE_DIR="$dir/pane" tmux capture-pane -p -t x -S -50)
  shallow=$(PATH="$dir/fakebin:$PATH" FM_FAKE_PANE_DIR="$dir/pane" tmux capture-pane -p -t x -S -0)
  [ "$(dialog_strings_on "$deep")" = 1 ] && [ "$(dialog_strings_on "$shallow")" = 0 ] \
    || fail "only the capture that reaches into scrollback should carry the string, or this case proves nothing"
  rc=$(dialog_ring "$dir")
  [ "$rc" = 0 ] || fail "a dialog that already scrolled out of view is not on screen, got $rc"
  [ "$(pane_file "$dir" literal | grep -cF 'Firstmate instruction waiting')" = 1 ] \
    || fail "the doorbell was not typed below a dismissed dialog:"$'\n'"$(pane_file "$dir" literal)"
  case "$(pane_file "$dir" keys)" in
    *Escape*) fail "Escape was pressed for a dialog that is no longer on screen" ;;
  esac
  [ -z "$(cat "$dir/notice")" ] || fail "a dismissed dialog must leave no notice"
  pass "inbox: the dialog guard reads only the visible viewport, so a dismissed dialog left in scrollback cannot block delivery"
}

test_dialog_guard_covers_only_claude_targets() {
  local dir rc
  dir=$(dialog_case dialog-codex offer-body codex)
  rc=$(dialog_ring "$dir")
  [ "$rc" = 0 ] || fail "a non-Claude harness must never be blamed for Claude's dialog, got $rc"
  [ "$(pane_file "$dir" literal | grep -cF 'Firstmate instruction waiting')" = 1 ] \
    || fail "the non-Claude harness's doorbell was not typed"
  case "$(pane_file "$dir" keys)" in
    *Escape*) fail "a non-Claude harness was sent Escape" ;;
  esac
  pass "inbox: the dialog guard reads the task's harness and leaves every non-Claude target alone"
}

# One task in <dir> whose screen the ring cannot read, in the two ways a backend
# can fail to give one. `fail` is the capture command exiting nonzero with the
# dialog really on the pane, the hazard the hold exists for; `empty` and `blank`
# are a capture that succeeds with nothing on it, and with only whitespace.
unreadable_case() {  # <name> <fail|empty|blank> [harness] [busy] -> echoes case dir
  local name=$1 mode=$2 harness=${3:-claude} busy=${4:-idle} dir
  case "$mode" in
    fail)
      dir=$(dialog_case "$name" title "$harness" "$busy")
      touch "$dir/pane/capture-fail"
      ;;
    *) dir=$(dialog_case "$name" "$mode" "$harness" "$busy") ;;
  esac
  printf '%s\n' "$dir"
}

# Run the fake pane's capture as the ring does and check it is the kind of
# unreadable the case claims, so a failing capture and a capture with nothing on
# it stay two distinct signals and neither case goes quietly vacuous.
assert_unreadable_capture() {  # <dir> <fail|empty|blank>
  local dir=$1 mode=$2 out rc=0
  out=$(PATH="$dir/fakebin:$PATH" FM_FAKE_PANE_DIR="$dir/pane" tmux capture-pane -p -t x -S -0) || rc=$?
  case "$mode" in
    fail)
      [ "$rc" != 0 ] || fail "the $mode case must be a capture that fails, or it proves nothing"
      [ "$(dialog_strings_on "$(cat "$dir/pane/pane")")" = 1 ] \
        || fail "the $mode case must leave the dialog on a pane the capture cannot read, or it proves nothing"
      ;;
    *)
      [ "$rc" = 0 ] || fail "the $mode case must be a capture that succeeds, or it proves nothing"
      [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ] \
        || fail "the $mode case must be a capture with nothing on it, or it proves nothing"
      ;;
  esac
}

test_dialog_guard_holds_a_claude_screen_it_cannot_read() {
  local view mode dir rc notice
  for view in viewport bounded; do
    for mode in fail empty blank; do
      dir=$(unreadable_case "unreadable-$view-$mode" "$mode")
      assert_unreadable_capture "$dir" "$mode"
      rc=$(dialog_ring "$dir" "$view")
      [ "$rc" = 5 ] || fail "$view/$mode: a Claude screen that cannot be read should hold the ring with 5, got $rc"
      [ -z "$(pane_file "$dir" literal)" ] \
        || fail "$view/$mode: text was typed onto a screen nothing could read:"$'\n'"$(pane_file "$dir" literal)"
      [ -z "$(pane_file "$dir" submits)" ] || fail "$view/$mode: something was submitted onto a screen nothing could read"
      [ -z "$(pane_file "$dir" keys)" ] \
        || fail "$view/$mode: no key, Enter and Escape included, may reach a screen nothing could read, got: $(pane_file "$dir" keys | tr '\n' ' ')"
      [ -f "$dir/state/t1.inbox/001.msg" ] || fail "$view/$mode: holding the ring must leave the durable record in place"
      notice=$(cat "$dir/notice")
      assert_contains "$notice" "task t1" "$view/$mode: the notice must name the task"
      assert_contains "$notice" "screen could not be read" "$view/$mode: the notice must say the screen could not be read"
      assert_contains "$notice" "no text, no Enter, and no Escape were sent" "$view/$mode: the notice must say nothing was sent"
      assert_not_contains "$notice" "auto-mode setup dialog" "$view/$mode: nobody saw a dialog, so the notice must not name one"
    done
  done
  pass "inbox: a Claude pane whose screen cannot be read, failed or empty, is never typed into, sent Enter, or sent Escape"
}

test_dialog_guard_defers_an_unreadable_screen_then_delivers_once_it_reads() {
  local dir rc
  dir=$(dialog_case unreadable-recovers composer)
  touch "$dir/pane/capture-fail"
  rc=$(dialog_ring "$dir")
  [ "$rc" = 5 ] || fail "the first ring should hold on the unreadable screen, got $rc"
  [ -z "$(pane_file "$dir" literal)" ] || fail "text was typed before the screen could be read"
  rm -f "$dir/pane/capture-fail"
  rc=$(dialog_ring "$dir")
  [ "$rc" = 0 ] || fail "the next ring, with the screen readable again, should deliver, got $rc"
  [ "$(pane_file "$dir" literal | grep -cF 'Firstmate instruction waiting')" = 1 ] \
    || fail "the doorbell should be typed exactly once, after the screen read again:"$'\n'"$(pane_file "$dir" literal)"
  [ "$(pane_file "$dir" keys | tr '\n' ' ')" = 'Enter ' ] \
    || fail "expected only the doorbell's Enter and never Escape, got: $(pane_file "$dir" keys | tr '\n' ' ')"
  case "$(pane_file "$dir" submits)" in
    *'Firstmate instruction waiting'*) ;;
    *) fail "the deferred steer's doorbell was never submitted" ;;
  esac
  [ -f "$dir/state/t1.inbox/001.msg" ] || fail "the record is the worker's to acknowledge, not the ring's"
  [ -z "$(cat "$dir/notice")" ] || fail "a ring that delivers must leave no notice"
  pass "inbox: a steer held on an unreadable screen is delivered by the next ring once the screen reads again"
}

test_dialog_guard_rings_an_unreadable_screen_as_before_on_non_claude_targets() {
  local mode dir rc
  for mode in fail empty blank; do
    dir=$(unreadable_case "unreadable-codex-$mode" "$mode" codex)
    assert_unreadable_capture "$dir" "$mode"
    rc=$(dialog_ring "$dir")
    [ "$rc" = 0 ] || fail "$mode: a non-Claude harness's unreadable screen should still be rung, got $rc"
    [ "$(pane_file "$dir" literal | grep -cF 'Firstmate instruction waiting')" = 1 ] \
      || fail "$mode: the non-Claude harness's doorbell was not typed:"$'\n'"$(pane_file "$dir" literal)"
    case "$(pane_file "$dir" keys)" in
      *Escape*) fail "$mode: a non-Claude harness was sent Escape" ;;
    esac
    [ -z "$(cat "$dir/notice")" ] || fail "$mode: a non-Claude harness's ring must leave no notice"
  done
  pass "inbox: an unreadable screen on a non-Claude harness is rung as before"
}

# A real watcher subprocess over the same fake pane. The pane is Claude at a
# dialog with a spendable ring budget, so every due attempt reaches the guard.
dialog_watch() {  # <dir> <out> [extra env assignments...]
  local dir=$1 out=$2
  shift 2
  watch_bg "$dir/state" "$dir/fakebin" "$out" \
    FM_FAKE_PANE_DIR="$dir/pane" FM_CONTROL_POLL=0.01 FM_CONTROL_SETTLE_WAIT=0.05 "$@"
}

test_watcher_never_rings_a_claude_dialog() {
  local dir out pid i=0
  dir=$(dialog_case dialog-watch-stuck title)
  out="$dir/watch.out"
  age_path "$dir/state/t1.inbox/001.msg"
  dialog_watch "$dir" "$out" FM_TASK_INBOX_RING_MAX=99
  pid=$!
  while [ "$i" -lt 100 ]; do
    [ -s "$dir/pane/keys" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  sleep 2.5
  kill -0 "$pid" 2>/dev/null \
    || fail "an ordinary re-ring attempt must not wake firstmate (watcher exited):"$'\n'"$(cat "$out")"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  [ -n "$(pane_file "$dir" keys)" ] || fail "the watcher never attempted a delivery to an aged steer"
  [ -z "$(pane_file "$dir" literal)" ] \
    || fail "the watcher typed into a Claude dialog:"$'\n'"$(pane_file "$dir" literal)"
  case "$(pane_file "$dir" keys)" in
    *Enter*) fail "the watcher pressed Enter on a Claude dialog:"$'\n'"$(pane_file "$dir" keys)" ;;
  esac
  [ ! -s "$dir/state/.wake-queue" ] \
    || fail "a guarded attempt queued a wake:"$'\n'"$(cat "$dir/state/.wake-queue")"
  [ -f "$dir/state/t1.inbox/001.msg" ] || fail "the record must stay durable"
  grep -qF 'auto-mode setup dialog' "$dir/state/.watch-triage.log" \
    || fail "the watcher's triage log should name the dialog it skipped:"$'\n'"$(cat "$dir/state/.watch-triage.log" 2>/dev/null)"
  pass "watcher: a Claude dialog on an aged steer's pane gets Escape and never text or Enter, without waking firstmate"
}

test_watcher_delivers_after_the_dialog_is_dismissed() {
  local dir out pid i=0
  dir=$(dialog_case dialog-watch-dismissed title)
  out="$dir/watch.out"
  touch "$dir/pane/dismiss-on-escape"
  age_path "$dir/state/t1.inbox/001.msg"
  dialog_watch "$dir" "$out" FM_TASK_INBOX_RING_MAX=99
  pid=$!
  while [ "$i" -lt 150 ]; do
    grep -qF 'Firstmate instruction waiting' "$dir/pane/submits" 2>/dev/null && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null \
    || fail "delivering a deferred steer must not wake firstmate (watcher exited):"$'\n'"$(cat "$out")"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  grep -qF 'Firstmate instruction waiting' "$dir/pane/submits" 2>/dev/null \
    || fail "the deferred steer's doorbell never reached the pane after the dialog was dismissed:"$'\n'"keys: $(pane_file "$dir" keys | tr '\n' ' ')"
  [ "$(pane_file "$dir" keys | sed -n 1p)" = Escape ] \
    || fail "the first thing the pane received must be Escape, got: $(pane_file "$dir" keys | tr '\n' ' ')"
  [ ! -s "$dir/state/.wake-queue" ] || fail "delivery queued a wake:"$'\n'"$(cat "$dir/state/.wake-queue")"
  pass "watcher: the re-ring after a cancelled dialog delivers the deferred steer once"
}

test_watcher_escalation_names_a_dialog_it_could_not_cancel() {
  local dir out pid rec
  dir=$(dialog_case dialog-watch-escalate title claude none)
  out="$dir/watch.out"
  rec="$dir/state/t1.inbox/001.msg"
  age_path "$rec"
  dialog_watch "$dir" "$out" FM_TASK_INBOX_RING_MAX=1
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "the watcher never escalated a steer stuck behind a dialog"; }
  [ -z "$(pane_file "$dir" literal)" ] || fail "the watcher typed into a Claude dialog"
  [ -z "$(pane_file "$dir" keys)" ] \
    || fail "a worker that does not read idle must not be sent a key, got: $(pane_file "$dir" keys | tr '\n' ' ')"
  [ "$(grep -cF 'unread firstmate instruction' "$dir/state/.wake-queue")" = 1 ] \
    || fail "the escalation must fire exactly once:"$'\n'"$(cat "$dir/state/.wake-queue" 2>/dev/null)"
  grep -qF "$rec" "$dir/state/.wake-queue" || fail "the stale wake should name the record path"
  grep -qF "auto-mode setup dialog (matched \"$FM_TEST_DIALOG_TITLE\")" "$dir/state/.wake-queue" \
    || fail "the stale wake should name the dialog and the string that matched:"$'\n'"$(cat "$dir/state/.wake-queue")"
  grep -qF 'cancel the dialog with Escape, never Enter' "$dir/state/.wake-queue" \
    || fail "the stale wake should say how to clear the dialog safely:"$'\n'"$(cat "$dir/state/.wake-queue")"
  pass "watcher: a stale wake for a steer stuck behind a Claude dialog names the dialog and the safe key"
}

# The reported path: fm-market's idle pane printed a note quoting the title, the
# watcher's attempts were held three times, and its stale wake said the dialog
# was up. With the quote and no dialog, the watcher delivers the doorbell and
# never names a dialog.
test_watcher_rings_a_pane_that_only_quotes_the_dialog() {
  local dir out pid i=0
  dir=$(dialog_case dialog-watch-quoted quoted-title)
  out="$dir/watch.out"
  age_path "$dir/state/t1.inbox/001.msg"
  dialog_watch "$dir" "$out" FM_TASK_INBOX_RING_MAX=99
  pid=$!
  while [ "$i" -lt 150 ]; do
    grep -qF 'Firstmate instruction waiting' "$dir/pane/submits" 2>/dev/null && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null \
    || fail "delivering a steer must not wake firstmate (watcher exited):"$'\n'"$(cat "$out")"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  grep -qF 'Firstmate instruction waiting' "$dir/pane/submits" 2>/dev/null \
    || fail "the doorbell never reached a pane that only quotes the dialog:"$'\n'"keys: $(pane_file "$dir" keys | tr '\n' ' ')"
  case "$(pane_file "$dir" keys)" in
    *Escape*) fail "a pane with no dialog on it was sent Escape: $(pane_file "$dir" keys | tr '\n' ' ')" ;;
  esac
  [ ! -s "$dir/state/.wake-queue" ] || fail "delivery queued a wake:"$'\n'"$(cat "$dir/state/.wake-queue")"
  if grep -qF 'auto-mode setup dialog' "$dir/state/.watch-triage.log" 2>/dev/null; then
    fail "the triage log blamed a dialog on a pane that only quotes one:"$'\n'"$(cat "$dir/state/.watch-triage.log")"
  fi
  pass "watcher: a pane that only quotes the dialog's title gets the doorbell, never Escape, and is not blamed on a dialog"
}

test_watcher_escalation_does_not_name_a_dialog_the_pane_only_quotes() {
  local dir out pid rec
  dir=$(dialog_case dialog-watch-quoted-escalate quoted-title)
  out="$dir/watch.out"
  rec="$dir/state/t1.inbox/001.msg"
  age_path "$rec"
  dialog_watch "$dir" "$out" FM_TASK_INBOX_RING_MAX=1
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "the watcher never escalated a steer nobody acknowledged"; }
  grep -qF 'Firstmate instruction waiting' "$dir/pane/submits" 2>/dev/null \
    || fail "the watcher should have rung the pane before it escalated"
  [ "$(grep -cF 'unread firstmate instruction' "$dir/state/.wake-queue")" = 1 ] \
    || fail "the escalation must fire exactly once:"$'\n'"$(cat "$dir/state/.wake-queue" 2>/dev/null)"
  grep -qF "$rec" "$dir/state/.wake-queue" || fail "the stale wake should name the record path"
  assert_not_contains "$(cat "$dir/state/.wake-queue")" "auto-mode setup dialog" \
    "the stale wake must not claim a dialog is up on a pane that only quotes one"
  pass "watcher: a stale wake for a steer on a pane that only quotes the dialog does not name a dialog"
}

test_watcher_holds_an_unreadable_claude_screen_without_waking_firstmate() {
  local dir out pid i=0 ladder
  dir=$(unreadable_case unreadable-watch-stuck fail)
  out="$dir/watch.out"
  age_path "$dir/state/t1.inbox/001.msg"
  dialog_watch "$dir" "$out" FM_TASK_INBOX_RING_MAX=99
  pid=$!
  while [ "$i" -lt 300 ]; do
    [ -s "$dir/state/t1.inbox/.ring-state" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  sleep 2.5
  kill -0 "$pid" 2>/dev/null \
    || fail "a held re-ring attempt must not wake firstmate (watcher exited):"$'\n'"$(cat "$out")"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  ladder=$(cat "$dir/state/t1.inbox/.ring-state" 2>/dev/null || true)
  [ -n "$ladder" ] || fail "the watcher never attempted a delivery to an aged steer"
  [ "$(printf '%s' "$ladder" | cut -f2)" -ge 1 ] \
    || fail "a held attempt must spend ladder budget, got: $ladder"
  [ -z "$(pane_file "$dir" literal)" ] \
    || fail "the watcher typed onto a screen nothing could read:"$'\n'"$(pane_file "$dir" literal)"
  [ -z "$(pane_file "$dir" keys)" ] \
    || fail "the watcher pressed a key on a screen nothing could read, got: $(pane_file "$dir" keys | tr '\n' ' ')"
  [ ! -s "$dir/state/.wake-queue" ] \
    || fail "a held attempt queued a wake:"$'\n'"$(cat "$dir/state/.wake-queue")"
  [ -f "$dir/state/t1.inbox/001.msg" ] || fail "the record must stay durable"
  grep -qF 'screen could not be read' "$dir/state/.watch-triage.log" \
    || fail "the watcher's triage log should say the screen could not be read:"$'\n'"$(cat "$dir/state/.watch-triage.log" 2>/dev/null)"
  pass "watcher: an aged steer on a Claude screen nothing could read spends ring budget and is never typed, without waking firstmate"
}

test_watcher_escalation_names_a_screen_it_could_not_read() {
  local dir out pid rec ladder
  dir=$(unreadable_case unreadable-watch-escalate fail)
  out="$dir/watch.out"
  rec="$dir/state/t1.inbox/001.msg"
  age_path "$rec"
  dialog_watch "$dir" "$out" FM_TASK_INBOX_RING_MAX=1
  pid=$!
  wait_watcher_gone "$pid" 300 \
    || { kill "$pid" 2>/dev/null; fail "the watcher never escalated a steer held on a screen it could not read"; }
  ladder=$(cat "$dir/state/t1.inbox/.ring-state" 2>/dev/null || true)
  [ "$(printf '%s' "$ladder" | cut -f2)" = 1 ] \
    || fail "the single held attempt should have spent the whole budget, got: $ladder"
  [ -z "$(pane_file "$dir" literal)" ] || fail "the watcher typed onto a screen nothing could read"
  [ -z "$(pane_file "$dir" keys)" ] \
    || fail "the watcher pressed a key on a screen nothing could read, got: $(pane_file "$dir" keys | tr '\n' ' ')"
  [ "$(grep -cF 'unread firstmate instruction' "$dir/state/.wake-queue")" = 1 ] \
    || fail "the escalation must fire exactly once:"$'\n'"$(cat "$dir/state/.wake-queue" 2>/dev/null)"
  grep -qF "$rec" "$dir/state/.wake-queue" || fail "the stale wake should name the record path"
  grep -qF 'screen could not be read' "$dir/state/.wake-queue" \
    || fail "the stale wake should say the screen could not be read:"$'\n'"$(cat "$dir/state/.wake-queue")"
  assert_no_grep 'auto-mode setup dialog' "$dir/state/.wake-queue" "the stale wake must not name a dialog nobody saw"
  grep -qF 'stale:' "$out" || fail "the watcher should exit through the ordinary stale wake:"$'\n'"$(cat "$out")"
  pass "watcher: a steer held on a Claude screen nothing could read escalates once as an ordinary stale wake that says so"
}

test_write_is_durable_and_exact
test_doorbell_is_a_shell_noop
test_doorbell_rejects_terminal_controls
test_ring_skips_dead_agent
test_ring_submits_its_own_stuck_doorbell
test_idempotent_write_dedups_exact_body
test_idempotent_write_follows_concurrent_ack
test_handled_mv_dedups_by_sequence
test_concurrent_writers_never_clobber
test_writer_retries_after_a_vanished_lock_collision
test_ladder_writes_ignore_vanished_inbox
test_fire_and_forget_records_never_enter_the_ladder
test_ring_ladder_policy
test_watcher_rerings_idle_pane_quietly
test_watcher_waits_on_busy_pane
test_watcher_quiet_on_healthy_inbox
test_watcher_ack_silences_unwritable_ladder
test_watcher_surfaces_unwritable_ladder
test_watcher_escalates_once_after_budget
test_watcher_dead_pane_escalates_once_without_ringing
test_watcher_dead_pane_ignores_stale_busy_state
test_dialog_guard_blocks_the_ring_on_each_string_alone
test_dialog_guard_sends_no_escape_to_a_worker_that_is_not_idle
test_dialog_guard_defers_then_delivers_once_the_dialog_is_gone
test_dialog_guard_reports_a_failed_escape
test_dialog_guard_holds_the_whole_offer_and_names_its_title
test_dialog_guard_ignores_a_string_quoted_outside_the_dialog
test_dialog_guard_still_holds_when_a_quote_shares_the_screen_with_the_dialog
test_dialog_guard_leaves_every_other_pane_alone
test_dialog_guard_reads_only_the_viewport
test_dialog_guard_covers_only_claude_targets
test_dialog_guard_rings_an_unreadable_screen_as_before_on_non_claude_targets
test_dialog_guard_holds_a_claude_screen_it_cannot_read
test_dialog_guard_defers_an_unreadable_screen_then_delivers_once_it_reads
test_watcher_never_rings_a_claude_dialog
test_watcher_delivers_after_the_dialog_is_dismissed
test_watcher_escalation_names_a_dialog_it_could_not_cancel
test_watcher_rings_a_pane_that_only_quotes_the_dialog
test_watcher_escalation_does_not_name_a_dialog_the_pane_only_quotes
test_watcher_holds_an_unreadable_claude_screen_without_waking_firstmate
test_watcher_escalation_names_a_screen_it_could_not_read
