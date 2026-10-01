#!/usr/bin/env bash
# Behavior tests for bin/fm-pre-push-guard.sh, the bundled guard for the
# config/pre-push-guard hook point.
#
# Every case drives a real `git push` through the real per-task hook wrapper
# that bin/fm-git-strip-ai-trailers.sh install writes, against a local bare
# remote, with a stand-in gitleaks on PATH. The stand-in records its arguments
# and the commit subjects its --log-opts selects, so "gitleaks scans exactly the
# commits being pushed" is asserted on what was scanned, never on the guard's
# source. The wiring (config/pre-push-guard, the wrapper, stdin passthrough) is
# covered by tests/fm-git-strip-ai-trailers.test.sh; this file covers the guard.
set -u

# A fleet pane already carries GIT_CONFIG core.hooksPath. These cases set that
# override themselves, so drop the inherited one before any git command.
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-pre-push-guard.sh"
STRIP="$ROOT/bin/fm-git-strip-ai-trailers.sh"
TMP_ROOT=$(fm_test_tmproot fm-pre-push-guard)

fm_git_identity 'Guard Tests' 'guard-tests@example.invalid'

# The stand-in is a real executable named gitleaks, so the guard finds it by
# PATH exactly as it finds the real one. It exits with $FM_FAKE_GITLEAKS_EXIT,
# and the guard treats 42 as "a secret was found" and any other non-zero code as
# a broken scan, the same split the real gitleaks makes with --exit-code.
write_fake_gitleaks() { # <dir>
  mkdir -p "$1"
  cat >"$1/gitleaks" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_GITLEAKS_LOG:-/dev/null}
{
  printf 'argv:'
  printf ' [%s]' "$@"
  printf '\n'
} >>"$log"
logopts=
for arg in "$@"; do
  case $arg in
  --log-opts=*) logopts=${arg#--log-opts=} ;;
  esac
done
repo=${!#}
# shellcheck disable=SC2086
git -C "$repo" log --format='scanned:%s' $logopts >>"$log" 2>&1
code=${FM_FAKE_GITLEAKS_EXIT:-0}
[ "$code" = 0 ] || printf 'fake gitleaks: exiting %s\n' "$code" >&2
exit "$code"
SH
  chmod +x "$1/gitleaks"
}

commit_file() { # <repo> <subject> [file]
  local file=${3:-file.txt}
  printf '%s\n' "$2" >>"$1/$file"
  git -C "$1" add "$file"
  git -C "$1" commit -q -m "$2"
}

# make_world <name> [default-branch]: a seed repository, a bare remote cloned
# from it, a working clone with the guard installed in its per-task hooks dir,
# and a stand-in gitleaks. The clone's origin/HEAD names the remote's default
# branch, the way a real clone's does.
make_world() {
  local name=$1 default=${2:-main}
  W="$TMP_ROOT/$name"
  ORIGIN="$W/origin.git"
  WORK="$W/work"
  HOME_DIR="$W/home"
  HOOKS="$W/hooks"
  FAKEBIN="$W/fakebin"
  GLOG="$W/gitleaks.log"
  mkdir -p "$W" "$HOME_DIR/config"
  fm_git_init_commit "$W/seed"
  git clone -q --bare "$W/seed" "$ORIGIN"
  if [ "$default" != main ]; then
    git -C "$ORIGIN" branch -m main "$default"
    git -C "$ORIGIN" symbolic-ref HEAD "refs/heads/$default"
  fi
  git clone -q "$ORIGIN" "$WORK" 2>/dev/null
  printf '%s\n' "$GUARD" >"$HOME_DIR/config/pre-push-guard"
  FM_HOME="$HOME_DIR" "$STRIP" install "$HOOKS" "$WORK" || fail "hook install should succeed"
  write_fake_gitleaks "$FAKEBIN"
  : >"$GLOG"
}

# gpush <git push args...>: push from WORK through the installed hooks with the
# stand-in gitleaks first on PATH. Sets OUT (stdout and stderr) and RC.
gpush() {
  OUT=$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=$HOOKS \
    PATH="$FAKEBIN:$PATH" FM_FAKE_GITLEAKS_LOG="$GLOG" FM_FAKE_GITLEAKS_EXIT="${GITLEAKS_EXIT:-0}" \
    git -C "$WORK" push "$@" 2>&1)
  RC=$?
}

remote_has() { # <ref>
  [ -n "$(git -C "$ORIGIN" for-each-ref "$1")" ]
}

remote_sha() { # <ref>
  git -C "$ORIGIN" rev-parse -q --verify "$1" 2>/dev/null || true
}

scanned() { # commit subjects the stand-in was asked to scan, one per line
  grep '^scanned:' "$GLOG" | sed 's/^scanned://' || true
}

test_new_branch_push_passes_and_scans_only_the_new_commits() {
  make_world new-branch
  git -C "$WORK" checkout -q -b fm/task
  commit_file "$WORK" 'task one'
  commit_file "$WORK" 'task two'
  gpush -q -u origin fm/task
  expect_code 0 "$RC" "a direct-PR worker's first push of its own branch must pass the guard"$'\n'"$OUT"
  remote_has refs/heads/fm/task || fail "the pushed branch did not reach the remote"
  assert_equals $'task two\ntask one' "$(scanned)" "gitleaks must scan exactly the new commits and not the history the remote holds"
  assert_contains "$(grep '^argv:' "$GLOG")" '[git]' "the scan must use gitleaks' git subcommand"
  assert_contains "$(grep '^argv:' "$GLOG")" '[--redact]' "findings must be redacted so a secret is never echoed into a pane"
  pass "a new branch push passes and gitleaks scans exactly its new commits"
}

test_fast_forward_push_scans_only_the_added_commit() {
  make_world fast-forward
  git -C "$WORK" checkout -q -b fm/task
  commit_file "$WORK" 'task one'
  gpush -q -u origin fm/task
  expect_code 0 "$RC" "first push should pass"$'\n'"$OUT"
  : >"$GLOG"
  commit_file "$WORK" 'task two'
  gpush -q origin fm/task
  expect_code 0 "$RC" "a fast-forward update of the worker's own branch must pass the guard"$'\n'"$OUT"
  assert_equals 'task two' "$(scanned)" "a fast-forward must scan only the added commit"
  pass "a fast-forward update passes and gitleaks scans only the added commit"
}

test_merging_published_history_scans_only_the_unpublished_commits() {
  make_world merge-main
  git -C "$WORK" checkout -q -b fm/task
  commit_file "$WORK" 'task one'
  gpush -q -u origin fm/task
  expect_code 0 "$RC" "first push should pass"$'\n'"$OUT"
  # main moves on and is published without the guard, as an owner or CI would.
  git -C "$WORK" checkout -q main
  commit_file "$WORK" 'main moved on' main-file.txt
  git -C "$WORK" push -q --no-verify origin main
  git -C "$WORK" checkout -q fm/task
  git -C "$WORK" merge -q --no-ff -m 'merge main into task' main
  commit_file "$WORK" 'task two'
  : >"$GLOG"
  gpush -q origin fm/task
  expect_code 0 "$RC" "pushing a branch that merged published history must pass"$'\n'"$OUT"
  assert_not_contains "$(scanned)" 'main moved on' "history the remote already holds must not be scanned again"
  assert_contains "$(scanned)" 'task two' "the worker's own new commit must be scanned"
  assert_contains "$(scanned)" 'merge main into task' "the merge commit being pushed must be scanned"
  pass "published history merged into a branch is not scanned again"
}

test_a_first_push_to_a_remote_with_no_tracking_branches_does_not_rescan_other_remotes() {
  make_world fresh-remote
  git init -q --bare "$W/fresh.git"
  git -C "$WORK" remote add fresh "$W/fresh.git"
  git -C "$WORK" checkout -q -b fm/task
  commit_file "$WORK" 'task one'
  gpush -q fresh HEAD:refs/heads/fm/task
  expect_code 0 "$RC" "a first push to a remote this clone has never fetched must pass"$'\n'"$OUT"
  assert_equals 'task one' "$(scanned)" "history other remotes already hold must not be scanned again"
  pass "a remote with no tracking branches falls back to the history every remote already holds"
}

test_a_repository_with_nothing_published_scans_everything_it_pushes() {
  make_world nothing-published
  fm_git_init_commit "$W/fresh-work"
  commit_file "$W/fresh-work" 'second'
  git init -q --bare "$W/fresh.git"
  git -C "$W/fresh-work" remote add origin "$W/fresh.git"
  WORK="$W/fresh-work"
  git -C "$WORK" checkout -q -b fm/task
  gpush -q -u origin fm/task
  expect_code 0 "$RC" "the first push of a repository must pass"$'\n'"$OUT"
  assert_equals $'second\ninitial' "$(scanned)" "with nothing published every commit being pushed must be scanned"
  pass "a repository with no published history has every pushed commit scanned"
}

test_delete_is_refused() {
  local sha
  make_world delete
  git -C "$WORK" checkout -q -b fm/task
  commit_file "$WORK" 'task one'
  gpush -q -u origin fm/task
  expect_code 0 "$RC" "first push should pass"$'\n'"$OUT"
  sha=$(remote_sha refs/heads/fm/task)
  gpush origin --delete fm/task
  [ "$RC" -ne 0 ] || fail "deleting a remote branch must be refused"$'\n'"$OUT"
  assert_contains "$OUT" 'refusing refs/heads/fm/task' "the refusal must name the ref"
  assert_contains "$OUT" 'deleting a remote ref' "the refusal must say why"
  assert_equals "$sha" "$(remote_sha refs/heads/fm/task)" "a refused delete must leave the remote branch alone"
  gpush origin :fm/task
  [ "$RC" -ne 0 ] || fail "the colon spelling of a delete must be refused too"$'\n'"$OUT"
  pass "branch deletes are refused, naming the ref, in both spellings"
}

test_default_branch_pushes_are_refused() {
  local before
  make_world default-branch
  before=$(remote_sha refs/heads/main)
  commit_file "$WORK" 'direct to main'
  gpush origin main
  [ "$RC" -ne 0 ] || fail "a push to the default branch must be refused"$'\n'"$OUT"
  assert_contains "$OUT" 'refusing refs/heads/main' "the refusal must name the ref"
  assert_contains "$OUT" "default branch" "the refusal must say why"
  assert_equals "$before" "$(remote_sha refs/heads/main)" "a refused push must leave the default branch alone"
  git -C "$WORK" checkout -q -b fm/task
  gpush origin HEAD:main
  [ "$RC" -ne 0 ] || fail "pushing another branch's commits onto main must be refused"$'\n'"$OUT"
  gpush origin HEAD:refs/heads/master
  [ "$RC" -ne 0 ] || fail "creating master on the remote must be refused: it would be a default branch"$'\n'"$OUT"
  assert_contains "$OUT" 'refusing refs/heads/master' "the refusal must name the ref"
  pass "pushes to main and master are refused, creation included"
}

test_the_remotes_recorded_default_branch_is_protected() {
  make_world recorded-default trunk
  git -C "$WORK" checkout -q -b fm/task
  commit_file "$WORK" 'task one'
  gpush -q origin HEAD:refs/heads/trunk
  [ "$RC" -ne 0 ] || fail "a push to the branch the remote's HEAD names must be refused"$'\n'"$OUT"
  assert_contains "$OUT" 'refusing refs/heads/trunk' "the refusal must name the ref"
  gpush -q -u origin fm/task
  expect_code 0 "$RC" "a branch that is not the default must still pass"$'\n'"$OUT"
  pass "the remote's recorded default branch is protected without being named main or master"
}

test_non_fast_forward_updates_are_refused() {
  local before
  make_world non-ff
  git -C "$WORK" checkout -q -b fm/task
  commit_file "$WORK" 'task one'
  commit_file "$WORK" 'task two'
  gpush -q -u origin fm/task
  expect_code 0 "$RC" "first push should pass"$'\n'"$OUT"
  before=$(remote_sha refs/heads/fm/task)
  git -C "$WORK" commit -q --amend -m 'task two rewritten'
  gpush --force origin fm/task
  [ "$RC" -ne 0 ] || fail "a forced non-fast-forward push must be refused"$'\n'"$OUT"
  assert_contains "$OUT" 'refusing refs/heads/fm/task' "the refusal must name the ref"
  assert_contains "$OUT" 'non-fast-forward' "the refusal must say why"
  assert_equals "$before" "$(remote_sha refs/heads/fm/task)" "a refused push must leave the remote branch alone"
  gpush --force-with-lease origin fm/task
  [ "$RC" -ne 0 ] || fail "a force-with-lease rewrite must be refused too"$'\n'"$OUT"
  pass "history rewrites are refused as non-fast-forward, forced or leased"
}

test_a_remote_commit_this_repository_lacks_is_refused_not_guessed() {
  local before
  make_world unknown-remote
  git -C "$WORK" checkout -q -b fm/task
  commit_file "$WORK" 'task one'
  gpush -q -u origin fm/task
  expect_code 0 "$RC" "first push should pass"$'\n'"$OUT"
  # Someone else advances the branch; this clone never fetches it.
  git clone -q "$ORIGIN" "$W/other" 2>/dev/null
  git -C "$W/other" checkout -q fm/task
  commit_file "$W/other" 'someone else'
  git -C "$W/other" push -q origin fm/task
  before=$(remote_sha refs/heads/fm/task)
  git -C "$WORK" commit -q --amend -m 'task one rewritten'
  gpush --force origin fm/task
  [ "$RC" -ne 0 ] || fail "forcing over a commit this repository has never seen must be refused"$'\n'"$OUT"
  assert_contains "$OUT" 'refusing refs/heads/fm/task' "the refusal must name the ref"
  assert_contains "$OUT" 'fetch it first' "the refusal must say what is missing"
  assert_equals "$before" "$(remote_sha refs/heads/fm/task)" "a refused push must leave the remote branch alone"
  pass "an update whose remote commit is not available locally is refused rather than guessed"
}

test_one_refused_ref_stops_the_whole_push_and_each_is_named() {
  make_world multi-ref
  git -C "$WORK" checkout -q -b fm/a
  commit_file "$WORK" 'a one'
  gpush origin fm/a fm/a:refs/heads/main
  [ "$RC" -ne 0 ] || fail "a push carrying a default-branch update must be refused"$'\n'"$OUT"
  assert_contains "$OUT" 'refusing refs/heads/main' "the refused ref must be named"
  assert_not_contains "$OUT" 'refusing refs/heads/fm/a' "an acceptable ref must not be named as refused"
  remote_has refs/heads/fm/a && fail "the acceptable ref must not land when another ref in the same push is refused"
  pass "one refused ref stops the whole push and only the refused ref is named"
}

test_tags_pass_when_new_and_are_refused_when_deleted() {
  make_world tags
  git -C "$WORK" checkout -q -b fm/task
  commit_file "$WORK" 'tagged work'
  git -C "$WORK" tag -a v1 -m v1
  gpush -q origin v1
  expect_code 0 "$RC" "a new annotated tag must pass"$'\n'"$OUT"
  remote_has refs/tags/v1 || fail "the tag did not reach the remote"
  assert_contains "$(scanned)" 'tagged work' "the commits a tag push adds must be scanned"
  gpush origin --delete v1
  [ "$RC" -ne 0 ] || fail "deleting a remote tag must be refused"$'\n'"$OUT"
  pass "a new tag passes and a tag delete is refused"
}

test_a_push_that_adds_nothing_runs_nothing() {
  local nogitleaks
  make_world up-to-date
  git -C "$WORK" checkout -q -b fm/task
  commit_file "$WORK" 'task one'
  gpush -q -u origin fm/task
  expect_code 0 "$RC" "first push should pass"$'\n'"$OUT"
  : >"$GLOG"
  nogitleaks=$(fm_test_base_path_sans "$PATH" gitleaks)
  OUT=$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=$HOOKS PATH="$nogitleaks" \
    git -C "$WORK" push origin fm/task 2>&1)
  expect_code 0 $? "an up-to-date push must pass even with no gitleaks, since nothing is being pushed"$'\n'"$OUT"
  assert_equals '' "$(cat "$GLOG")" "an up-to-date push must not run gitleaks"
  pass "a push that adds nothing neither refuses nor scans"
}

test_a_missing_gitleaks_refuses_and_names_the_tool() {
  local nogitleaks
  make_world no-gitleaks
  git -C "$WORK" checkout -q -b fm/task
  commit_file "$WORK" 'task one'
  nogitleaks=$(fm_test_base_path_sans "$PATH" gitleaks)
  OUT=$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=$HOOKS PATH="$nogitleaks" \
    git -C "$WORK" push -q -u origin fm/task 2>&1)
  RC=$?
  [ "$RC" -ne 0 ] || fail "a push must be refused when gitleaks is not on PATH"$'\n'"$OUT"
  assert_contains "$OUT" 'refusing refs/heads/fm/task' "the refusal must name the ref"
  assert_contains "$OUT" 'gitleaks is not on PATH' "the refusal must name the missing tool"
  remote_has refs/heads/fm/task && fail "a refused push must not land"
  pass "a push is refused when gitleaks is not installed, naming the tool"
}

test_a_gitleaks_finding_refuses() {
  make_world finding
  git -C "$WORK" checkout -q -b fm/task
  commit_file "$WORK" 'task one'
  GITLEAKS_EXIT=42 gpush -q -u origin fm/task
  [ "$RC" -ne 0 ] || fail "a gitleaks finding must refuse the push"$'\n'"$OUT"
  assert_contains "$OUT" 'refusing refs/heads/fm/task' "the refusal must name the ref"
  assert_contains "$OUT" 'gitleaks found a secret' "a finding must read as a finding"
  remote_has refs/heads/fm/task && fail "a refused push must not land"
  pass "a gitleaks finding refuses the push"
}

test_a_failed_gitleaks_scan_refuses() {
  make_world scan-failure
  git -C "$WORK" checkout -q -b fm/task
  commit_file "$WORK" 'task one'
  GITLEAKS_EXIT=1 gpush -q -u origin fm/task
  [ "$RC" -ne 0 ] || fail "a failed scan must refuse the push"$'\n'"$OUT"
  assert_contains "$OUT" 'gitleaks failed with exit 1' "a broken scan must read differently from a finding"
  assert_not_contains "$OUT" 'gitleaks found a secret' "a broken scan must not be reported as a finding"
  remote_has refs/heads/fm/task && fail "a refused push must not land"
  pass "a failed gitleaks scan refuses the push and is not reported as a finding"
}

# The no-mistakes CLI starts a pipeline by pushing the branch to its local gate
# remote with --no-verify, so git runs no hook for it. This case makes that
# push in the same environment as the refused ones above, with a gitleaks that
# would refuse everything, and proves both halves: the hook skip lets the gate
# push through, and the same push without --no-verify is refused, so the pass
# cannot be a guard that was never wired.
test_a_hook_skipping_gate_push_never_reaches_the_guard() {
  make_world gate-trigger
  git init -q --bare "$W/gate.git"
  git -C "$WORK" remote add no-mistakes "$W/gate.git"
  git -C "$WORK" checkout -q -b fm/task
  commit_file "$WORK" 'task one'
  GITLEAKS_EXIT=42 gpush --no-verify no-mistakes HEAD:refs/heads/fm/task
  expect_code 0 "$RC" "a hook-skipping gate-trigger push must not be touched by the guard"$'\n'"$OUT"
  [ -n "$(git -C "$W/gate.git" for-each-ref refs/heads/fm/task)" ] || fail "the gate did not receive the push"
  assert_equals '' "$(cat "$GLOG")" "the guard must not have run for a hook-skipping push"
  commit_file "$WORK" 'task two'
  GITLEAKS_EXIT=42 gpush no-mistakes HEAD:refs/heads/fm/other
  [ "$RC" -ne 0 ] || fail "the same push with hooks enabled must reach the guard and be refused"$'\n'"$OUT"
  pass "a no-verify gate-trigger push passes untouched while the same push with hooks is guarded"
}

test_unreadable_and_unchanged_ref_lines() {
  local out rc
  make_world direct-lines
  out=$(cd "$WORK" && "$GUARD" origin file:///unused 2>&1 <<'EOF'
nonsense
EOF
)
  rc=$?
  [ "$rc" -eq 1 ] || fail "a ref line the guard cannot read must refuse (got $rc)"$'\n'"$out"
  assert_contains "$out" 'cannot read' "the refusal must say the line was unreadable"
  out=$(cd "$WORK" && "$GUARD" origin file:///unused 2>&1 <<'EOF'
refs/heads/fm/task 1111111111111111111111111111111111111111 refs/heads/fm/task 1111111111111111111111111111111111111111

EOF
)
  rc=$?
  [ "$rc" -eq 0 ] || fail "a ref line that changes nothing, and blank lines, must be skipped (got $rc)"$'\n'"$out"
  pass "an unreadable ref line refuses, while an unchanged ref and blank lines are skipped"
}

test_usage() {
  local out rc
  out=$("$GUARD" --help 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "--help must succeed (got $rc)"
  assert_contains "$out" 'usage: fm-pre-push-guard.sh' "--help must print usage"
  out=$("$GUARD" 2>&1 </dev/null)
  rc=$?
  [ "$rc" -eq 2 ] || fail "running with no arguments must be a usage error (got $rc)"
  pass "the guard prints usage for --help and refuses to run without git's arguments"
}

test_new_branch_push_passes_and_scans_only_the_new_commits
test_fast_forward_push_scans_only_the_added_commit
test_merging_published_history_scans_only_the_unpublished_commits
test_a_first_push_to_a_remote_with_no_tracking_branches_does_not_rescan_other_remotes
test_a_repository_with_nothing_published_scans_everything_it_pushes
test_delete_is_refused
test_default_branch_pushes_are_refused
test_the_remotes_recorded_default_branch_is_protected
test_non_fast_forward_updates_are_refused
test_a_remote_commit_this_repository_lacks_is_refused_not_guessed
test_one_refused_ref_stops_the_whole_push_and_each_is_named
test_tags_pass_when_new_and_are_refused_when_deleted
test_a_push_that_adds_nothing_runs_nothing
test_a_missing_gitleaks_refuses_and_names_the_tool
test_a_gitleaks_finding_refuses
test_a_failed_gitleaks_scan_refuses
test_a_hook_skipping_gate_push_never_reaches_the_guard
test_unreadable_and_unchanged_ref_lines
test_usage

echo "# all fm-pre-push-guard tests passed"
