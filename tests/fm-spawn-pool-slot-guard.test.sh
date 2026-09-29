#!/usr/bin/env bash
# Regression tests for a pool slot that a live task record still names.
#
# Treehouse decides a slot is free from what it can observe: no lease, no live
# owner, no process in it, a clean tree and a HEAD already merged. A stopped
# task's slot meets all of that once its worker exits - its reservation was a
# process, and the process is gone - so a later `treehouse get` hands it to
# another task and resets it. The guard in bin/fm-spawn.sh keeps every slot a
# record still names out of that choice.
#
# Two halves. The real half drives the real fm-spawn.sh against the real
# Treehouse in a scratch pool, so it is the proof that the guard works against
# what the tool actually does (it skips where the tool is not installed, as
# tests/fm-treehouse-pool-isolation.test.sh does). The stand-in half runs
# everywhere: a stand-in Treehouse over a fixed pool, whose process detection is
# the operating system's, lets the guard's refusals be driven deliberately - a
# status that cannot show the hold, a status that cannot be read, a tool that
# hands out a slot it should not - where the real tool would not misbehave.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-pool-slot-guard)

# The guard's holder process runs `sleep 300`; the leak checks below match that
# command line and a working directory inside the case.
HOLD_SECONDS=300

# Real-Treehouse cases skip, as tests/fm-treehouse-pool-isolation.test.sh does,
# on a host without the tool: a stub could only confirm what it was written to say.
have_treehouse() {
  command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found (real-Treehouse pool cases)"; return 1; }
}

# make_sleepers <path>: writes `sleepers <seconds> <dir>`, which prints one
# "<pid> <cwd>" line per `sleep <seconds>` process (a glob, so '*' is any sleep)
# whose working directory is <dir> or below it. The operating system answers
# where a process is, as Treehouse does when it decides a slot is in use; the
# stand-in Treehouse and the leak checks below share this one reading.
make_sleepers() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
set -u
secs=$1
dir=$(cd "$2" && pwd -P)
ps -A -o pid= -o command= | while read -r pid cmd; do
  case "$cmd" in "sleep "$secs) ;; *) continue ;; esac
  if [ -d "/proc/$pid" ]; then
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || continue
  else
    cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p') || continue
  fi
  case "$cwd" in
    "$dir"|"$dir"/*) printf '%s %s\n' "$pid" "$cwd" ;;
  esac
done
SH
  chmod +x "$1"
}

# make_fake_treehouse <fakebin>: a stand-in for the treehouse CLI over the fixed
# pool FM_FAKE_TH_POOL (<pool>/<slot>/<repo>, each a git worktree). It models only
# what the guard consumes. `status --json` lists each slot with the processes
# running in it, found with FM_FAKE_TH_SLEEPERS as any `sleep` in the slot (the
# guard's holders, and the stand-ins for a running worker); `get` reads the same,
# takes the first slot with no process in it, resets it to a detached origin/main
# as Treehouse does, and runs $SHELL there. Every call is logged to
# FM_FAKE_TH_LOG. Knobs:
#   FM_FAKE_TH_STATUS=fail        status exits 1
#   FM_FAKE_TH_STATUS=odd         status prints a shape with no slot path in it
#   FM_FAKE_TH_BLIND=1            neither status nor get can see a process
#   FM_FAKE_TH_GET_IGNORES_HOLDS=1  get takes the first slot whatever runs in it
#   FM_FAKE_TH_EXIT_AFTER_STATUS=<pid-file>  the first status call, once it has
#                                 answered, stops the pid the file names: a worker
#                                 that exits before the get that follows
make_fake_treehouse() {
  cat > "$1/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
pool=${FM_FAKE_TH_POOL:?}
verb=${1:-}
shift || true
printf 'treehouse %s %s\n' "$verb" "$*" >> "${FM_FAKE_TH_LOG:-/dev/null}"

# slot_procs <real-slot>: "pid" lines for the processes inside a slot
slot_procs() {
  local real=$1 pid cwd
  [ -z "${FM_FAKE_TH_BLIND:-}" ] || return 0
  "$FM_FAKE_TH_SLEEPERS" '*' "$pool" | while read -r pid cwd; do
    case "$cwd" in
      "$real"|"$real"/*) printf '%s\n' "$pid" ;;
    esac
  done
}

# json_escape: what Go's encoding/json writes for a path
json_escape() {
  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/&/\\u0026/g' -e 's/</\\u003c/g' -e 's/>/\\u003e/g'
}

case "$verb" in
  status)
    [ "${FM_FAKE_TH_STATUS:-}" != fail ] || { echo 'treehouse: status failed' >&2; exit 1; }
    if [ "${FM_FAKE_TH_STATUS:-}" = odd ]; then
      printf '[{"name":"1","location":"unknown","state":"idle"}]\n'
      exit 0
    fi
    sep=
    printf '['
    for d in "$pool"/*/*; do
      [ -e "$d/.git" ] || continue
      real=$(cd "$d" && pwd -P)
      procs=
      for pid in $(slot_procs "$real"); do
        procs="$procs${procs:+,}{\"pid\":$pid,\"name\":\"sleep\"}"
      done
      state=available
      [ -z "$procs" ] || state=in-use
      esc=$(printf '%s' "$d" | json_escape)
      printf '%s{"name":"%s","path":"%s","status":"%s","flavor":"","processes":[%s]}' \
        "$sep" "$(basename "$(dirname "$d")")" "$esc" "$state" "$procs"
      sep=,
    done
    printf ']\n'
    if [ -s "${FM_FAKE_TH_EXIT_AFTER_STATUS:-/nonexistent}" ]; then
      kill "$(cat "$FM_FAKE_TH_EXIT_AFTER_STATUS")" 2>/dev/null || true
      rm -f "$FM_FAKE_TH_EXIT_AFTER_STATUS"
    fi
    ;;
  get)
    for d in "$pool"/*/*; do
      [ -e "$d/.git" ] || continue
      real=$(cd "$d" && pwd -P)
      if [ -z "${FM_FAKE_TH_GET_IGNORES_HOLDS:-}" ] && [ -n "$(slot_procs "$real")" ]; then
        continue
      fi
      git -C "$d" checkout -q --detach origin/main
      cd "$d" && exec "$SHELL"
    done
    echo 'treehouse: no available slot' >&2
    exit 1
    ;;
esac
SH
  chmod +x "$1/treehouse"
}

# make_case <name> [root]: a home (non-root by default, the shape that gets an
# isolated pool root; "root" for the shape that uses Treehouse's default pool)
# under a local root home, a project clone with a reachable origin, a scratch
# XDG state directory so the pool lands under the case, and the fake terminal
# that runs `treehouse get`. Echoes
# "<case>|<root-home>|<home>|<project>|<xdg>|<fakebin>".
make_case() {
  local name=$1 kind=${2:-linked} case_dir root_home home seed origin project xdg fakebin
  case_dir="$TMP_ROOT/$name"
  root_home="$case_dir/root-home"
  home="$case_dir/home"
  seed="$case_dir/seed"
  origin="$case_dir/origin.git"
  project="$home/projects/proj"
  xdg="$case_dir/xdg-state"
  fakebin=$(fm_fakebin "$case_dir/fake")

  mkdir -p "$root_home/state" "$root_home/data" "$home/data" "$home/state" "$home/config" "$home/projects" "$xdg"
  fm_git_init_commit "$seed"
  git clone --quiet --bare "$seed" "$origin"
  git clone --quiet "file://$origin" "$project"
  printf 'codex\n' > "$home/config/crew-harness"
  if [ "$kind" != root ]; then
    cat > "$home/.fm-secondmate-parent" <<EOF
schema=fm-secondmate-parent.v1
route=local
parent_home=$root_home
EOF
  fi
  touch "$home/state/.last-watcher-beat"
  fm_test_fake_tmux_spawn_treehouse "$fakebin"
  fm_test_treehouse_standin_shell "$case_dir/standin-shell"
  make_sleepers "$case_dir/sleepers"

  printf '%s\n' "$case_dir|$root_home|$home|$project|$xdg|$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR ROOT_HOME HOME_DIR PROJECT_DIR XDG_DIR FAKEBIN_DIR <<EOF
$1
EOF
  FAKE_POOL=
}

# make_fake_case <name> <slots>: a case whose `treehouse` is the stand-in over
# <slots> worktrees of the project, numbered from 1.
make_fake_case() {
  local i
  read_case "$(make_case "$1")"
  make_fake_treehouse "$FAKEBIN_DIR"
  FAKE_POOL="$CASE_DIR/fake-pool"
  mkdir -p "$FAKE_POOL"
  printf '{}\n' > "$FAKE_POOL/treehouse-state.json"
  for ((i = 1; i <= $2; i++)); do
    git -C "$PROJECT_DIR" worktree add --quiet --detach "$FAKE_POOL/$i/proj" HEAD
  done
}

# run_spawn <id> [fm-spawn args...]: the real spawn, inside the case, with
# `treehouse get` run for real behind the fake terminal. TREEHOUSE_* is cleared
# so a developer shell that is itself inside a pool slot cannot steer the scratch
# pool, and HOME is the case's own (fm_test_run_spawn), so even Treehouse's
# default pool lands inside the case.
run_spawn() {
  local id=$1
  shift
  fm_test_spawn_brief "$HOME_DIR" "$id"
  (
    unset TREEHOUSE_DIR TREEHOUSE_ROOT TREEHOUSE_LEASE_HOLDER
    export XDG_STATE_HOME="$XDG_DIR"
    export FM_FAKE_PANE_CWD_FILE="$CASE_DIR/pane-cwd-$id"
    export FM_FAKE_SUBSHELL="$CASE_DIR/standin-shell"
    export FM_FAKE_TREEHOUSE_LOG="$CASE_DIR/treehouse.log"
    export FM_FAKE_TH_POOL="$FAKE_POOL"
    export FM_FAKE_TH_LOG="$CASE_DIR/fake-treehouse.log"
    export FM_FAKE_TH_SLEEPERS="$CASE_DIR/sleepers"
    fm_test_run_spawn "$HOME_DIR" "$PROJECT_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" "$@"
  )
}

meta_worktree() {  # <id>
  sed -n 's/^worktree=//p' "$HOME_DIR/state/$1.meta" | tail -1
}

# pool_root_of <slot>: the --root that produced <slot>
# (<root>/.treehouse/<repo>-<hash>/<slot-name>/<repo>).
pool_root_of() {
  dirname "$(dirname "$(dirname "$(dirname "$1")")")"
}

slot_ref() {  # <slot>: the checked-out branch, or DETACHED
  git -C "$1" symbolic-ref -q --short HEAD || echo DETACHED
}

# pool_status <slot>: treehouse's own view of the pool <slot> belongs to.
pool_status() {
  ( cd "$PROJECT_DIR" && env -u TREEHOUSE_DIR -u TREEHOUSE_ROOT HOME="$HOME_DIR/user-home" \
      treehouse status --json --root "$(pool_root_of "$1")" 2>/dev/null )
}

# Give <slot> the shape a stopped ship task leaves behind: clean, on its own
# branch, no process running in it.
leave_as_stopped_task() {  # <slot> <branch>
  git -C "$1" checkout -q -b "$2"
}

# Safety: nothing here may touch a pool outside the case. A slot that is not
# under the case directory stops the test before it acts on that slot.
require_scratch_slot() {  # <slot>
  case "$1" in
    "$CASE_DIR"/*) ;;
    *) fail "fixture: slot '$1' is outside the scratch case '$CASE_DIR'; stopping before touching it" ;;
  esac
}

# held_sleepers: pids of any holder process still running inside the case.
held_sleepers() {
  "$CASE_DIR/sleepers" "$HOLD_SECONDS" "$CASE_DIR" | awk '{ print $1 }'
}

assert_no_holders_left() {  # <msg>
  local left
  left=$(held_sleepers)
  [ -z "$left" ] || fail "$1: a holder process is still running in the case (pid $left)"
}

fake_th_calls() {  # <verb>: how many times the stand-in was asked <verb>
  [ -f "$CASE_DIR/fake-treehouse.log" ] || { echo 0; return 0; }
  grep -c "^treehouse $1" "$CASE_DIR/fake-treehouse.log" || true
}

# Write the record a live task leaves: enough for the guard, which reads only the
# paths a record names.
record_task() {  # <id> <key=path>...
  local id=$1
  shift
  fm_write_meta "$HOME_DIR/state/$id.meta" "window=fmses:fm-$id" "endpoint_task_id=$id" "kind=ship" "$@"
}

# --- real Treehouse ---------------------------------------------------------

test_fresh_spawn_never_receives_a_recorded_slot() {
  have_treehouse || return 0
  local rec out status held new held_meta_before
  rec=$(make_case recorded-slot)
  read_case "$rec"

  out=$(run_spawn held-a --scout)
  status=$?
  expect_code 0 "$status" "the first spawn should launch"$'\n'"$out"
  held=$(meta_worktree held-a)
  require_scratch_slot "$held"
  [ -f "$(dirname "$(dirname "$held")")/treehouse-state.json" ] \
    || fail "fixture: task held-a did not get a real Treehouse pool slot ($held)"
  leave_as_stopped_task "$held" fm/held-a
  held_meta_before=$(cat "$HOME_DIR/state/held-a.meta")

  # The scenario must be the real one, or the assertions below prove nothing:
  # Treehouse itself reads the recorded, stopped task's slot as free.
  assert_contains "$(pool_status "$held")" '"status":"available"' \
    "fixture: Treehouse should read the stopped task's slot as available"

  out=$(run_spawn new-b --scout)
  status=$?
  expect_code 0 "$status" "the second spawn should launch"$'\n'"$out"
  new=$(meta_worktree new-b)
  assert_not_equals "$held" "$new" \
    "the new task was handed the slot task held-a still records"
  assert_equals fm/held-a "$(slot_ref "$held")" \
    "the recorded slot was reset to a detached HEAD"
  assert_equals "$held_meta_before" "$(cat "$HOME_DIR/state/held-a.meta")" \
    "the recorded task's record changed"
  assert_no_holders_left "after a launched spawn"
  pass "a fresh spawn takes a different slot and leaves the one a stopped task records untouched"
}

test_root_home_spawn_never_receives_a_recorded_slot() {
  have_treehouse || return 0
  local rec out status held new
  rec=$(make_case recorded-slot-root root)
  read_case "$rec"

  out=$(run_spawn held-a --scout)
  status=$?
  expect_code 0 "$status" "the first spawn should launch"$'\n'"$out"
  held=$(meta_worktree held-a)
  require_scratch_slot "$held"
  case "$held" in
    "$HOME_DIR/user-home/.treehouse/"*) ;;
    *) fail "fixture: a root home should allocate from Treehouse's default pool under HOME, got $held" ;;
  esac
  leave_as_stopped_task "$held" fm/held-a
  assert_contains "$(pool_status "$held")" '"status":"available"' \
    "fixture: Treehouse should read the stopped task's slot as available"

  out=$(run_spawn new-b --scout)
  status=$?
  expect_code 0 "$status" "the second spawn should launch"$'\n'"$out"
  new=$(meta_worktree new-b)
  assert_not_equals "$held" "$new" \
    "the root home's new task was handed the slot task held-a still records"
  assert_equals fm/held-a "$(slot_ref "$held")" \
    "the recorded slot was reset to a detached HEAD"
  assert_no_holders_left "after a launched root-home spawn"
  pass "a root home's fresh spawn also takes a different slot than the one a stopped task records"
}

test_a_record_in_another_local_home_protects_its_slot() {
  have_treehouse || return 0
  local rec out status held new
  rec=$(make_case recorded-elsewhere)
  read_case "$rec"

  out=$(run_spawn held-a --scout)
  status=$?
  expect_code 0 "$status" "the first spawn should launch"$'\n'"$out"
  held=$(meta_worktree held-a)
  require_scratch_slot "$held"
  leave_as_stopped_task "$held" fm/held-a
  # The record now lives in the local root home, not in the home that spawns.
  mv "$HOME_DIR/state/held-a.meta" "$ROOT_HOME/state/held-a.meta"

  out=$(run_spawn new-b --scout)
  status=$?
  expect_code 0 "$status" "the second spawn should launch"$'\n'"$out"
  new=$(meta_worktree new-b)
  assert_not_equals "$held" "$new" \
    "the new task was handed a slot that a record in the local root home names"
  assert_equals fm/held-a "$(slot_ref "$held")" \
    "the slot recorded in the root home was reset to a detached HEAD"
  pass "a slot named by a record in another local home is kept out of a spawn's reach too"
}

# --- stand-in Treehouse -----------------------------------------------------

test_stand_in_spawn_holds_every_recorded_slot_and_releases_them() {
  local out status held_a held_b new
  make_fake_case hold-many 3

  out=$(run_spawn held-a --scout)
  status=$?
  expect_code 0 "$status" "the first spawn should launch"$'\n'"$out"
  held_a=$(meta_worktree held-a)
  assert_equals "$(cd "$FAKE_POOL/1/proj" && pwd -P)" "$held_a" \
    "fixture: the stand-in should hand out its first free slot"
  out=$(run_spawn held-b --scout)
  status=$?
  expect_code 0 "$status" "the second spawn should launch"$'\n'"$out"
  held_b=$(meta_worktree held-b)
  assert_not_equals "$held_a" "$held_b" "the second task was handed the first task's slot"
  leave_as_stopped_task "$held_a" fm/held-a
  leave_as_stopped_task "$held_b" fm/held-b

  out=$(run_spawn new-c --scout)
  status=$?
  expect_code 0 "$status" "the third spawn should launch"$'\n'"$out"
  new=$(meta_worktree new-c)
  assert_equals "$(cd "$FAKE_POOL/3/proj" && pwd -P)" "$new" \
    "the new task should take the only slot no record names"
  assert_equals fm/held-a "$(slot_ref "$held_a")" "the first recorded slot was reset"
  assert_equals fm/held-b "$(slot_ref "$held_b")" "the second recorded slot was reset"
  assert_no_holders_left "after a launched spawn"
  pass "a spawn holds each recorded slot while Treehouse chooses, then lets them go"
}

test_stand_in_home_only_record_is_held() {
  local out status new
  make_fake_case hold-home 2
  record_task held-h "home=$FAKE_POOL/1/proj"
  git -C "$FAKE_POOL/1/proj" checkout -q -b fm/held-h

  out=$(run_spawn new-b --scout)
  status=$?
  expect_code 0 "$status" "the spawn should launch"$'\n'"$out"
  new=$(meta_worktree new-b)
  assert_equals "$(cd "$FAKE_POOL/2/proj" && pwd -P)" "$new" \
    "the new task was handed the slot a record names only as home="
  assert_equals fm/held-h "$(git -C "$FAKE_POOL/1/proj" symbolic-ref -q --short HEAD || echo DETACHED)" \
    "the slot named as home= was reset"
  pass "a slot a record names only as its home is held as well"
}

test_stand_in_live_claim_holds_a_slot_and_a_stale_claim_does_not() {
  local out status new stale_home
  make_fake_case hold-claim 3
  # A claim whose task's record lives in a home this machine does not register:
  # no scanned record names the slot, but the claim's own home still has the task.
  stale_home="$CASE_DIR/unregistered-home"
  mkdir -p "$stale_home/state"
  fm_write_meta "$stale_home/state/ghost.meta" "kind=ship"
  printf 'task=ghost\nhome=%s\n' "$stale_home" > "$FAKE_POOL/1/.fm-slot-owner"
  git -C "$FAKE_POOL/1/proj" checkout -q -b fm/ghost

  out=$(run_spawn new-b --scout)
  status=$?
  expect_code 0 "$status" "the spawn should launch"$'\n'"$out"
  new=$(meta_worktree new-b)
  assert_not_equals "$(cd "$FAKE_POOL/1/proj" && pwd -P)" "$new" \
    "the new task was handed a slot whose claim names a task that still has a record"
  assert_equals fm/ghost "$(git -C "$FAKE_POOL/1/proj" symbolic-ref -q --short HEAD || echo DETACHED)" \
    "the claimed slot was reset"

  # Once that task's record is gone the claim is stale, and the slot is the pool's
  # to reuse again: the guard must not turn every old claim into a lost slot.
  rm -f "$stale_home/state/ghost.meta"
  out=$(run_spawn new-c --scout)
  status=$?
  expect_code 0 "$status" "the next spawn should launch"$'\n'"$out"
  assert_equals "$(cd "$FAKE_POOL/1/proj" && pwd -P)" "$(meta_worktree new-c)" \
    "a claim whose task has no record left still kept its slot out of the pool"
  pass "a live claim holds its slot, and a claim with no record behind it does not"
}

test_stand_in_slot_no_record_names_is_still_reused() {
  local out status
  make_fake_case reuse-free 2
  record_task gone-a "worktree=$FAKE_POOL/9/proj"

  out=$(run_spawn new-b --scout)
  status=$?
  expect_code 0 "$status" "the spawn should launch"$'\n'"$out"
  assert_equals "$(cd "$FAKE_POOL/1/proj" && pwd -P)" "$(meta_worktree new-b)" \
    "a record naming a path that is not a slot changed which slot was handed out"
  pass "a record naming no existing slot leaves the pool's own choice alone"
}

test_stand_in_spawn_with_no_recorded_slot_allocates_as_before() {
  local out status
  make_fake_case no-records 2

  out=$(run_spawn new-a --scout)
  status=$?
  expect_code 0 "$status" "the spawn should launch"$'\n'"$out"
  assert_equals "$(cd "$FAKE_POOL/1/proj" && pwd -P)" "$(meta_worktree new-a)" \
    "a spawn with no recorded slot did not take the pool's first free slot"
  assert_equals 1 "$(fake_th_calls get)" "the spawn should run treehouse get once"
  assert_no_holders_left "after a spawn with nothing to hold"

  # Nothing recorded means nothing to protect, so a pool status that cannot be
  # read must not turn into a refusal for such a spawn.
  make_fake_case no-records-status-fails 2
  export FM_FAKE_TH_STATUS=fail
  out=$(run_spawn new-a --scout)
  status=$?
  unset FM_FAKE_TH_STATUS
  expect_code 0 "$status" "an unreadable pool status refused a spawn with no recorded slot"$'\n'"$out"
  assert_equals "$(cd "$FAKE_POOL/1/proj" && pwd -P)" "$(meta_worktree new-a)" \
    "a spawn with no recorded slot did not take the pool's first free slot"
  pass "a spawn with no recorded pool slot allocates as before, whether or not the pool status can be read"
}

test_stand_in_a_running_workers_slot_is_held_against_its_exit() {
  local out status worker new slot_a pidfile
  make_fake_case worker-exits 2
  slot_a=$(cd "$FAKE_POOL/1/proj" && pwd -P)
  record_task worker-a "worktree=$slot_a"
  git -C "$slot_a" checkout -q -b fm/worker-a

  # The worker is running in its recorded slot when the guard first reads the
  # pool, so Treehouse reports the slot in use; it exits right after that read,
  # before the get that follows. A slot held only while it read as free would be
  # handed out and reset here.
  ( cd "$slot_a" && exec sleep 299 ) </dev/null >/dev/null 2>&1 &
  worker=$!
  disown "$worker" 2>/dev/null || true
  pidfile="$CASE_DIR/worker.pid"
  printf '%s\n' "$worker" > "$pidfile"
  assert_contains "$(FM_FAKE_TH_POOL="$FAKE_POOL" FM_FAKE_TH_SLEEPERS="$CASE_DIR/sleepers" "$FAKEBIN_DIR/treehouse" status --json)" '"status":"in-use"' \
    "fixture: the running worker should read as in use"

  export FM_FAKE_TH_EXIT_AFTER_STATUS="$pidfile"
  out=$(run_spawn new-b --scout)
  status=$?
  unset FM_FAKE_TH_EXIT_AFTER_STATUS
  kill "$worker" 2>/dev/null || true
  expect_code 0 "$status" "the spawn should launch"$'\n'"$out"
  [ ! -s "$pidfile" ] || fail "fixture: the worker was never stopped after the first status read"
  new=$(meta_worktree new-b)
  assert_equals "$(cd "$FAKE_POOL/2/proj" && pwd -P)" "$new" \
    "the new task was handed the slot of a worker that exited while the spawn chose"
  assert_equals fm/worker-a "$(slot_ref "$slot_a")" "the worker's recorded slot was reset"
  assert_no_holders_left "after a launched spawn"
  pass "a recorded slot that is in use is held too, so its worker exiting mid-allocation cannot expose it"
}

test_stand_in_hold_that_status_cannot_show_refuses_the_spawn() {
  local out status meta_before
  make_fake_case blind 2
  record_task held-a "worktree=$FAKE_POOL/1/proj"
  git -C "$FAKE_POOL/1/proj" checkout -q -b fm/held-a
  meta_before=$(cat "$HOME_DIR/state/held-a.meta")

  export FM_FAKE_TH_BLIND=1
  out=$(run_spawn new-b --scout)
  status=$?
  unset FM_FAKE_TH_BLIND
  expect_code 1 "$status" "a hold Treehouse cannot see should refuse the spawn"
  assert_contains "$out" "$FAKE_POOL/1/proj" "the refusal should name the slot it could not hold"
  assert_contains "$out" "held-a" "the refusal should name the task that records the slot"
  assert_contains "$out" "refusing to run treehouse get" "the refusal should say Treehouse was never asked"
  assert_equals 0 "$(fake_th_calls get)" "treehouse get ran although the hold was not proven"
  assert_absent "$CASE_DIR/treehouse.log" "the terminal was sent treehouse get although the hold was not proven"
  assert_absent "$HOME_DIR/state/new-b.meta" "a refused spawn left a task record"
  assert_equals fm/held-a "$(git -C "$FAKE_POOL/1/proj" symbolic-ref -q --short HEAD || echo DETACHED)" \
    "the recorded slot changed"
  assert_equals "$meta_before" "$(cat "$HOME_DIR/state/held-a.meta")" "the recorded task's record changed"
  assert_no_holders_left "after a refused spawn"
  pass "a hold Treehouse's status cannot show refuses the spawn before treehouse get runs"
}

test_stand_in_unreadable_status_refuses_the_spawn() {
  local out status
  make_fake_case status-fails 2
  record_task held-a "worktree=$FAKE_POOL/1/proj"

  export FM_FAKE_TH_STATUS=fail
  out=$(run_spawn new-b --scout)
  status=$?
  unset FM_FAKE_TH_STATUS
  expect_code 1 "$status" "an unreadable pool status should refuse the spawn"
  assert_contains "$out" "treehouse status --json" "the refusal should name the failing read"
  assert_contains "$out" "refusing to run treehouse get" "the refusal should say Treehouse was never asked"
  assert_equals 0 "$(fake_th_calls get)" "treehouse get ran although the pool could not be read"
  assert_absent "$HOME_DIR/state/new-b.meta" "a refused spawn left a task record"
  assert_no_holders_left "after a refused spawn"
  pass "a pool status that cannot be read refuses the spawn rather than guessing"
}

test_stand_in_unrecognized_status_shape_refuses_the_spawn() {
  local out status
  make_fake_case odd-status 2
  record_task held-a "worktree=$FAKE_POOL/1/proj"

  # A status that lists something but no slot must not read as a pool with no
  # slot in it: that would let the spawn through with every recorded slot open.
  export FM_FAKE_TH_STATUS=odd
  out=$(run_spawn new-b --scout)
  status=$?
  unset FM_FAKE_TH_STATUS
  expect_code 1 "$status" "a status shape the guard cannot read should refuse the spawn"
  assert_contains "$out" "treehouse status --json" "the refusal should name the unreadable status"
  assert_equals 0 "$(fake_th_calls get)" "treehouse get ran although the pool could not be read"
  assert_absent "$HOME_DIR/state/new-b.meta" "a refused spawn left a task record"
  pass "a pool status in a shape the guard does not know refuses the spawn instead of reading as empty"
}

test_stand_in_a_recorded_slot_handed_out_anyway_is_caught_after_get() {
  local out status
  make_fake_case tripwire 2
  record_task held-a "worktree=$FAKE_POOL/1/proj"
  git -C "$FAKE_POOL/1/proj" checkout -q -b fm/held-a

  # Status shows the hold, so the proof passes; the tool then ignores it.
  export FM_FAKE_TH_GET_IGNORES_HOLDS=1
  out=$(run_spawn new-b --scout)
  status=$?
  unset FM_FAKE_TH_GET_IGNORES_HOLDS
  expect_code 1 "$status" "a spawn handed a recorded slot should refuse"
  assert_contains "$out" "which task held-a still records" \
    "the refusal should name the task whose slot was handed out"
  assert_absent "$FAKE_POOL/1/.fm-slot-owner" "the refused spawn claimed the recorded task's slot"
  assert_absent "$HOME_DIR/state/new-b.meta" "a refused spawn left a task record"
  assert_no_holders_left "after a refused spawn"
  pass "a recorded slot Treehouse hands out despite the hold stops the spawn before it claims or launches"
}

test_stand_in_status_paths_are_read_as_the_tool_writes_them() {
  local out status new
  make_fake_case 'hold&escape' 2
  record_task held-a "worktree=$FAKE_POOL/1/proj"
  git -C "$FAKE_POOL/1/proj" checkout -q -b fm/held-a
  assert_contains "$(FM_FAKE_TH_POOL="$FAKE_POOL" FM_FAKE_TH_SLEEPERS="$CASE_DIR/sleepers" "$FAKEBIN_DIR/treehouse" status --json)" "\\u0026" \
    "fixture: the stand-in should write the ampersand in the pool path the way Go's JSON encoder does"

  out=$(run_spawn new-b --scout)
  status=$?
  expect_code 0 "$status" "the spawn should launch"$'\n'"$out"
  new=$(meta_worktree new-b)
  assert_equals "$(cd "$FAKE_POOL/2/proj" && pwd -P)" "$new" \
    "a recorded slot whose path holds an ampersand was not recognized"
  assert_equals fm/held-a "$(git -C "$FAKE_POOL/1/proj" symbolic-ref -q --short HEAD || echo DETACHED)" \
    "the recorded slot was reset"
  pass "a pool path the tool writes with JSON escapes still matches the record that names it"
}

test_fresh_spawn_never_receives_a_recorded_slot
test_root_home_spawn_never_receives_a_recorded_slot
test_a_record_in_another_local_home_protects_its_slot
test_stand_in_spawn_holds_every_recorded_slot_and_releases_them
test_stand_in_home_only_record_is_held
test_stand_in_live_claim_holds_a_slot_and_a_stale_claim_does_not
test_stand_in_slot_no_record_names_is_still_reused
test_stand_in_spawn_with_no_recorded_slot_allocates_as_before
test_stand_in_a_running_workers_slot_is_held_against_its_exit
test_stand_in_hold_that_status_cannot_show_refuses_the_spawn
test_stand_in_unreadable_status_refuses_the_spawn
test_stand_in_unrecognized_status_shape_refuses_the_spawn
test_stand_in_a_recorded_slot_handed_out_anyway_is_caught_after_get
test_stand_in_status_paths_are_read_as_the_tool_writes_them
