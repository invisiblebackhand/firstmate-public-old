#!/usr/bin/env bash
# Regression tests for a pool slot that a live task record still names.
#
# Treehouse hands out - and resets - any slot it reads as free: no lease, no live
# owner, no process in it, a clean tree and a HEAD already merged. The interactive
# `treehouse get` a spawn used to take held its slot only through a process, so a
# stopped task's slot (its worker exited, or the machine restarted) met all of
# that and the next spawn received it and reset it. A spawn now takes a durable
# lease in the task's name, which no process and no restart lapses, and a slot is
# released only by a return that never cleans or resets.
#
# Every case drives the real bin/fm-spawn.sh, bin/fm-home-seed.sh or the release
# in bin/fm-wake-lib.sh against the real Treehouse in a scratch pool: a stand-in
# could only confirm what it was written to say about what Treehouse hands out and
# what its return drops. It skips where the tool is not installed, as
# tests/fm-treehouse-pool-isolation.test.sh does. The relaunch cases are in
# tests/fm-control-relaunch.test.sh and the teardown cases in
# tests/fm-teardown.test.sh.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found (real-Treehouse pool cases)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-spawn-pool-slot-guard)
REAL_TREEHOUSE=$(command -v treehouse)

# make_case <name> [root]: a home (non-root by default, the shape that gets an
# isolated pool root; "root" for the shape that uses Treehouse's default pool)
# under a local root home, a project clone with a reachable origin, a scratch
# XDG state directory so the pool lands under the case, and the fake terminal
# that runs the `treehouse get` line a spawn types. Echoes
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

  printf '%s\n' "$case_dir|$root_home|$home|$project|$xdg|$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR ROOT_HOME HOME_DIR PROJECT_DIR XDG_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

# run_spawn <id> [fm-spawn args...]: the real spawn, inside the case, with the
# `treehouse get` line it types run for real behind the fake terminal.
# TREEHOUSE_* is cleared so a developer shell that is itself inside a pool slot
# cannot steer the scratch pool, and HOME is the case's own (fm_test_run_spawn), so
# even Treehouse's default pool lands inside the case.
run_spawn() {
  local id=$1
  shift
  fm_test_spawn_brief "$HOME_DIR" "$id"
  (
    unset TREEHOUSE_DIR TREEHOUSE_ROOT TREEHOUSE_LEASE_HOLDER
    XDG_STATE_HOME="$XDG_DIR" FM_FAKE_PANE_CWD_FILE="$CASE_DIR/pane-cwd-$id" \
      FM_FAKE_SUBSHELL="$CASE_DIR/standin-shell" FM_FAKE_TREEHOUSE_LOG="$CASE_DIR/treehouse.log" \
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

# pool_status <slot>: Treehouse's own view of the pool <slot> belongs to.
pool_status() {
  ( cd "$PROJECT_DIR" && env -u TREEHOUSE_DIR -u TREEHOUSE_ROOT HOME="$HOME_DIR/user-home" \
      treehouse status --json --root "$(pool_root_of "$1")" 2>/dev/null )
}

# slot_row <slot>: "<status> <lease holder>" for the slot, as Treehouse reports it
# ("absent -" when its status does not list the slot; "-" for no holder).
slot_row() {
  pool_status "$1" | python3 -c '
import json, os, sys
slot = os.path.realpath(sys.argv[1])
for row in json.load(sys.stdin):
    if os.path.realpath(row.get("path", "")) == slot:
        print(row.get("status", "?"), row.get("lease_holder") or "-")
        break
else:
    print("absent -")' "$1"
}

# slot_leased_to <slot-in-the-pool> <holder>: the slot Treehouse has leased to
# <holder>, empty when it has leased none.
slot_leased_to() {
  pool_status "$1" | python3 -c '
import json, sys
for row in json.load(sys.stdin):
    if row.get("lease_holder") == sys.argv[1]:
        print(row["path"])
        break' "$2"
}

# The state a stopped ship task leaves behind: clean, on its own branch that
# holds nothing Treehouse could call unmerged, no process running in it.
leave_as_stopped_task() {  # <slot> <branch>
  git -C "$1" checkout -q -b "$2"
}

# make_status_blind_treehouse <fakebin>: the real treehouse for everything except a
# pool status, which it cannot report, as a Treehouse without `status --json` cannot.
make_status_blind_treehouse() {
  cat > "$1/treehouse" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = status ]; then
  echo 'Error: unknown flag: --json' >&2
  exit 1
fi
exec "$REAL_TREEHOUSE" "\$@"
SH
  chmod +x "$1/treehouse"
}

test_status_reader_recognizes_only_empty_array_as_empty_pool() {
  local shape out status
  read_case "$(make_case status-shapes)"
  cat > "$FAKEBIN_DIR/treehouse" <<'SH'
#!/usr/bin/env bash
case "$FM_TEST_STATUS_SHAPE" in
  array) printf ' [] \n' ;;
  empty) : ;;
  null) printf 'null\n' ;;
esac
SH
  chmod +x "$FAKEBIN_DIR/treehouse"
  for shape in array empty null; do
    out=$(FM_TEST_STATUS_SHAPE="$shape" PATH="$FAKEBIN_DIR:$PATH" bash -c '
      . "$1/bin/fm-wake-lib.sh"
      fm_treehouse_status_rows "$2" "$3"
    ' _ "$ROOT" "$PROJECT_DIR" "$CASE_DIR/pool")
    status=$?
    case "$shape" in
      array) expect_code 0 "$status" "[] should be a readable empty pool" ;;
      *) expect_code 1 "$status" "$shape should be unknown status" ;;
    esac
    assert_equals "" "$out" "$shape should produce no slot rows"
  done
  pass "only [] is a readable empty Treehouse pool"
}

# Safety: nothing here may touch a pool outside the case. A slot that is not
# under the case directory stops the test before it acts on that slot.
require_scratch_slot() {  # <slot>
  case "$1" in
    "$CASE_DIR"/*) ;;
    *) fail "fixture: slot '$1' is outside the scratch case '$CASE_DIR'; stopping before touching it" ;;
  esac
}

# --- a stopped task's slot stays out of a later spawn's reach ---------------

test_a_stopped_tasks_slot_is_not_handed_to_the_next_spawn() {
  local out status held new
  read_case "$(make_case stopped-slot)"

  out=$(run_spawn held-a --scout)
  status=$?
  expect_code 0 "$status" "the first spawn should launch"$'\n'"$out"
  held=$(meta_worktree held-a)
  require_scratch_slot "$held"
  [ -f "$(dirname "$(dirname "$held")")/treehouse-state.json" ] \
    || fail "fixture: task held-a did not get a real Treehouse pool slot ($held)"
  leave_as_stopped_task "$held" fm/held-a

  out=$(run_spawn new-b --scout)
  status=$?
  expect_code 0 "$status" "the second spawn should launch"$'\n'"$out"
  new=$(meta_worktree new-b)
  assert_not_equals "$held" "$new" \
    "the new task was handed the slot task held-a still records"
  assert_equals fm/held-a "$(slot_ref "$held")" \
    "the recorded slot was reset to a detached HEAD"
  assert_equals "leased held-a" "$(slot_row "$held")" \
    "Treehouse does not hold the recorded slot under the task's lease"
  assert_equals "leased new-b" "$(slot_row "$new")" \
    "Treehouse does not hold the new task's slot under its lease"
  pass "a stopped task's slot is leased to it, so the next spawn takes another and leaves it untouched"
}

test_a_root_homes_stopped_task_slot_is_not_handed_to_the_next_spawn() {
  local out status held new
  read_case "$(make_case stopped-slot-root root)"

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

  out=$(run_spawn new-b --scout)
  status=$?
  expect_code 0 "$status" "the second spawn should launch"$'\n'"$out"
  new=$(meta_worktree new-b)
  assert_not_equals "$held" "$new" \
    "the root home's new task was handed the slot task held-a still records"
  assert_equals fm/held-a "$(slot_ref "$held")" \
    "the recorded slot was reset to a detached HEAD"
  assert_equals "leased held-a" "$(slot_row "$held")" \
    "Treehouse does not hold the recorded slot under the task's lease"
  pass "a root home's stopped task keeps its slot from the next spawn as well"
}

test_a_slot_recorded_in_another_local_home_is_kept_from_a_spawn() {
  local out status held new
  read_case "$(make_case recorded-elsewhere)"

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
  pass "the lease keeps a slot from a spawn wherever the record that names it lives"
}

test_home_seeding_does_not_take_a_leased_task_slot() {
  local out status held seeded
  read_case "$(make_case seed-leased-slot root)"

  out=$(run_spawn held-a --scout)
  status=$?
  expect_code 0 "$status" "the task's spawn should launch"$'\n'"$out"
  held=$(meta_worktree held-a)
  require_scratch_slot "$held"
  leave_as_stopped_task "$held" fm/held-a

  # The seed leases a firstmate home from the same default pool
  # (bin/fm-home-seed.sh) and then refuses the fixture's project clone as a home;
  # reaching that refusal is what shows it was handed a slot. It returns the slot
  # again on the way out, so the slot it was handed is read from what get printed.
  cat > "$FAKEBIN_DIR/treehouse" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = get ]; then
  path=\$("$REAL_TREEHOUSE" "\$@") || exit \$?
  printf '%s\n' "\$path" | tee -a "$CASE_DIR/gets.log"
  exit 0
fi
exec "$REAL_TREEHOUSE" "\$@"
SH
  chmod +x "$FAKEBIN_DIR/treehouse"
  out=$(unset TREEHOUSE_DIR TREEHOUSE_ROOT TREEHOUSE_LEASE_HOLDER
    PATH="$FAKEBIN_DIR:$PATH" HOME="$HOME_DIR/user-home" XDG_STATE_HOME="$XDG_DIR" \
      FM_ROOT_OVERRIDE="$PROJECT_DIR" FM_HOME="$ROOT_HOME" FM_SECONDMATE_CHARTER='test charter' \
      "$ROOT/bin/fm-home-seed.sh" new-home - --no-projects 2>&1)
  status=$?
  expect_code 1 "$status" "the fixture's acquired home is not a Firstmate checkout"$'\n'"$out"
  assert_contains "$out" 'is not a firstmate home' "home seeding did not reach acquired-home validation"
  seeded=$(tail -n 1 "$CASE_DIR/gets.log" 2>/dev/null)
  [ -n "$seeded" ] || fail "home seeding leased no slot"$'\n'"$out"
  assert_not_equals "$held" "$seeded" "home seeding was handed the slot a task still records"
  assert_equals fm/held-a "$(slot_ref "$held")" "home seeding reset a recorded slot"
  assert_equals "leased held-a" "$(slot_row "$held")" "home seeding disturbed the recorded task's lease"
  pass "home seeding leases a free slot without resetting one a task still records"
}

# --- a spawn that aborts gives back the lease it took -----------------------

test_a_spawn_that_aborts_returns_the_lease_it_took() {
  local out status slot
  read_case "$(make_case abort-returns-lease)"
  # A treehouse that leases the slot for real and then puts a directory where the
  # spawn's slot claim goes, so the spawn refuses after it holds the lease.
  cat > "$FAKEBIN_DIR/treehouse" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = get ]; then
  path=\$("$REAL_TREEHOUSE" "\$@") || exit \$?
  printf '%s\n' "\$path"
  mkdir -p "\$(dirname "\$(printf '%s\n' "\$path" | tail -n 1)")/.fm-slot-owner"
  exit 0
fi
exec "$REAL_TREEHOUSE" "\$@"
SH
  chmod +x "$FAKEBIN_DIR/treehouse"

  out=$(run_spawn held-a --scout)
  status=$?
  expect_code 1 "$status" "a slot that cannot be claimed should refuse the spawn"$'\n'"$out"
  assert_contains "$out" "could not claim Treehouse pool slot" "the refusal should name the claim"
  assert_not_contains "$out" "lease in place" "the abort should have returned the lease, not left it"
  assert_absent "$HOME_DIR/state/held-a.meta" "a refused spawn left a task record"
  slot=$(find "$XDG_DIR" -type d -path '*/.treehouse/*/1/proj' | head -n 1)
  [ -n "$slot" ] || fail "fixture: the aborted spawn left no Treehouse slot to inspect"
  require_scratch_slot "$slot"
  assert_equals "available -" "$(slot_row "$slot")" \
    "the aborted spawn left its slot leased to a task that has no record"
  pass "a spawn that aborts after taking its lease returns the lease"
}

# --- teardown returns the slot the spawn leased -----------------------------

# run_teardown <id> [args...]: the real teardown of a task the real spawn started,
# inside the case, against the same real Treehouse and the same scratch pool.
run_teardown() {
  local id=$1
  shift
  (
    unset TREEHOUSE_DIR TREEHOUSE_ROOT TREEHOUSE_LEASE_HOLDER
    HOME="$HOME_DIR/user-home" XDG_STATE_HOME="$XDG_DIR" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
      PATH="$FAKEBIN_DIR:$PATH" "$ROOT/bin/fm-teardown.sh" "$id" "$@" 2>&1
  )
}

test_teardown_releases_the_lease_a_spawn_took() {
  local out status slot
  read_case "$(make_case teardown-releases)"

  out=$(run_spawn task-a --mode local-only --yolo off)
  status=$?
  expect_code 0 "$status" "the spawn should launch"$'\n'"$out"
  slot=$(meta_worktree task-a)
  require_scratch_slot "$slot"
  assert_equals "leased task-a" "$(slot_row "$slot")" "fixture: the spawn should have leased the slot"
  # Records what teardown asks Treehouse to do, then does it for real.
  cat > "$FAKEBIN_DIR/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CASE_DIR/treehouse-calls.log"
exec "$REAL_TREEHOUSE" "\$@"
SH
  chmod +x "$FAKEBIN_DIR/treehouse"

  # Work the worker left uncommitted is never dropped: teardown refuses and the
  # slot keeps both the work and its lease.
  printf 'precious\n' > "$slot/notes.txt"
  out=$(run_teardown task-a)
  status=$?
  expect_code 1 "$status" "teardown of a slot holding uncommitted work should refuse"$'\n'"$out"
  assert_equals precious "$(cat "$slot/notes.txt" 2>/dev/null)" "teardown dropped uncommitted work"
  assert_equals "leased task-a" "$(slot_row "$slot")" "the refused teardown released the slot"
  assert_present "$HOME_DIR/state/task-a.meta" "the refused teardown removed the task record"

  # Once nothing is uncommitted but Firstmate's own leftovers, the slot goes back
  # to the pool, released under its own lease and never forced.
  rm -f "$slot/notes.txt"
  mkdir -p "$slot/.claude"
  printf '{}\n' > "$slot/.claude/settings.local.json"
  out=$(run_teardown task-a)
  status=$?
  expect_code 0 "$status" "teardown of a task with nothing unlanded should succeed"$'\n'"$out"
  assert_equals "available -" "$(slot_row "$slot")" "teardown left the slot leased"
  assert_absent "$HOME_DIR/state/task-a.meta" "teardown left the task record"
  grep -q '^return --if-lease-holder task-a ' "$CASE_DIR/treehouse-calls.log" \
    || fail "teardown did not release the slot under the task's own lease: $(cat "$CASE_DIR/treehouse-calls.log")"
  ! grep -q -- '--force' "$CASE_DIR/treehouse-calls.log" \
    || fail "teardown returned the slot with --force, which cleans and resets"
  pass "a ship task's slot goes back to the pool under its own lease, and never with uncommitted work"
}

# --- the release never cleans or resets -------------------------------------

# lease_slot <holder>: a slot of a scratch pool leased to <holder>, as a spawn takes it.
lease_slot() {
  ( cd "$PROJECT_DIR" && env -u TREEHOUSE_DIR -u TREEHOUSE_ROOT -u TREEHOUSE_LEASE_HOLDER \
      HOME="$HOME_DIR/user-home" treehouse get --lease --lease-holder "$1" --no-fetch \
      --root "$CASE_DIR/pool" 2>/dev/null </dev/null )
}

# release_slot <slot> <task-id> [fakebin]: the release teardown performs, run as it
# runs it (from the project, with the case's own HOME, <fakebin> first on PATH when
# given); prints its output and returns its status.
release_slot() {
  (
    unset TREEHOUSE_DIR TREEHOUSE_ROOT TREEHOUSE_LEASE_HOLDER
    export HOME="$HOME_DIR/user-home"
    [ -z "${3:-}" ] || export PATH="$3:$PATH"
    # shellcheck source=bin/fm-wake-lib.sh
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_treehouse_slot_release "$PROJECT_DIR" "$1" "$2"
  ) 2>&1
}

# release_refused <label> <setup-command>: a leased slot whose tree was changed by
# <setup-command> is not released, and nothing in it is dropped.
release_refused() {
  local label=$1 setup=$2 slot out status before after
  slot=$(lease_slot "rel-$label")
  require_scratch_slot "$slot"
  ( cd "$slot" && eval "$setup" ) || fail "fixture: could not set up '$label' in $slot"
  before=$(git -C "$slot" status --porcelain=v1 --untracked-files=all; git -C "$slot" diff HEAD)
  out=$(release_slot "$slot" "rel-$label")
  status=$?
  expect_code 1 "$status" "a slot holding $label was released"$'\n'"$out"
  after=$(git -C "$slot" status --porcelain=v1 --untracked-files=all; git -C "$slot" diff HEAD)
  assert_equals "$before" "$after" "the release changed the slot holding $label"
  assert_equals "leased rel-$label" "$(slot_row "$slot")" "the slot holding $label lost its lease"
  assert_contains "$out" "uncommitted" "the refusal for $label should say why"
}

test_release_returns_a_clean_slot_and_drops_no_uncommitted_work() {
  local slot out status
  read_case "$(make_case release-matrix)"
  mkdir -p "$CASE_DIR/pool" "$HOME_DIR/user-home"

  slot=$(lease_slot rel-clean)
  require_scratch_slot "$slot"
  assert_equals "leased rel-clean" "$(slot_row "$slot")" "fixture: the slot should start out leased"
  out=$(release_slot "$slot" rel-clean)
  status=$?
  expect_code 0 "$status" "a clean slot should be released"$'\n'"$out"
  assert_equals "available -" "$(slot_row "$slot")" "the released slot is not back in the pool"
  out=$(release_slot "$slot" rel-clean)
  status=$?
  expect_code 0 "$status" "releasing a slot already back in the pool should succeed"$'\n'"$out"

  release_refused tracked-edit 'echo changed > README.md'
  release_refused staged-edit 'echo staged > README.md && git add README.md'
  release_refused untracked-file 'echo precious > notes.txt'
  release_refused untracked-dir 'mkdir -p scratch/deep && echo precious > scratch/deep/notes.txt'

  slot=$(lease_slot someone-else)
  require_scratch_slot "$slot"
  out=$(release_slot "$slot" rel-not-the-holder)
  status=$?
  expect_code 1 "$status" "a slot leased to another task was released"$'\n'"$out"
  assert_contains "$out" "someone-else" "the refusal should name the task that holds the slot"
  assert_equals "leased someone-else" "$(slot_row "$slot")" "another task's lease was released"
  pass "the release returns a clean slot and never drops uncommitted work or another task's lease"
}

test_release_without_a_pool_status_still_proves_the_tree_clean() {
  local slot out status
  read_case "$(make_case release-blind)"
  mkdir -p "$CASE_DIR/pool" "$HOME_DIR/user-home"
  make_status_blind_treehouse "$FAKEBIN_DIR"

  slot=$(lease_slot rel-blind-clean)
  require_scratch_slot "$slot"
  out=$(release_slot "$slot" rel-blind-clean "$FAKEBIN_DIR")
  status=$?
  expect_code 1 "$status" "a clean slot with an unprovable lease should not be returned"$'\n'"$out"
  assert_contains "$out" "task rel-blind-clean's slot $slot was not returned" "the refusal should name the task and slot"
  assert_equals "leased rel-blind-clean" "$(slot_row "$slot")" "the clean slot lost its lease"

  slot=$(lease_slot rel-blind-dirty)
  require_scratch_slot "$slot"
  echo precious > "$slot/notes.txt"
  out=$(release_slot "$slot" rel-blind-dirty "$FAKEBIN_DIR")
  status=$?
  expect_code 1 "$status" "a slot holding uncommitted work was released without a pool status"$'\n'"$out"
  assert_equals precious "$(cat "$slot/notes.txt" 2>/dev/null)" "the release dropped uncommitted work"
  assert_equals "leased rel-blind-dirty" "$(slot_row "$slot")" "the slot holding uncommitted work lost its lease"
  assert_contains "$out" "task rel-blind-dirty's slot $slot was not returned" "the dirty refusal should name the task and slot"
  pass "a release refuses clean and dirty slots when Treehouse cannot prove their leases"
}

test_a_spawn_continues_when_treehouse_cannot_report_leases() {
  local out status held
  read_case "$(make_case blind-spawn)"
  make_status_blind_treehouse "$FAKEBIN_DIR"

  out=$(run_spawn held-a --scout)
  status=$?
  expect_code 0 "$status" "a spawn should not refuse because leases cannot be read back"$'\n'"$out"
  assert_contains "$out" "could not confirm task held-a's lease" "the spawn should say it could not confirm the lease"
  held=$(meta_worktree held-a)
  require_scratch_slot "$held"
  assert_equals "leased held-a" "$(slot_row "$held")" "the lease the spawn took is not held"
  pass "a spawn warns, and carries on, when Treehouse cannot report the lease it just took"
}

test_a_stopped_tasks_slot_is_not_handed_to_the_next_spawn
test_a_root_homes_stopped_task_slot_is_not_handed_to_the_next_spawn
test_a_slot_recorded_in_another_local_home_is_kept_from_a_spawn
test_home_seeding_does_not_take_a_leased_task_slot
test_a_spawn_that_aborts_returns_the_lease_it_took
test_teardown_releases_the_lease_a_spawn_took
test_release_returns_a_clean_slot_and_drops_no_uncommitted_work
test_release_without_a_pool_status_still_proves_the_tree_clean
test_a_spawn_continues_when_treehouse_cannot_report_leases
test_status_reader_recognizes_only_empty_array_as_empty_pool
