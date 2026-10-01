#!/usr/bin/env bash
# tests/fm-claude-worker-permissions.test.sh - the per-launch Claude --settings
# builder (bin/fm-claude-worker-permissions-lib.sh) and the tracked rule data it
# composes (bin/fm-claude-worker-permissions.json). Portable: no Claude Code, no
# backend. The shared command table (tests/fixtures/claude-worker-permissions)
# is applied through a simulated matcher here; the live guard
# tests/fm-claude-worker-permissions-live-e2e.test.sh applies the same table to
# the real installed Claude Code, which is the authority when the two differ.
# shellcheck disable=SC2016  # single-quoted JSON and jq programs are deliberate
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-claude-worker-permissions-lib.sh
. "$ROOT/bin/fm-claude-worker-permissions-lib.sh"

FIXTURES="$ROOT/tests/fixtures/claude-worker-permissions"
ROWS="$FIXTURES/rows.tsv"
# shellcheck source=tests/fixtures/claude-worker-permissions/scopes.sh
. "$FIXTURES/scopes.sh"
BRANCH=$FM_CPW_BRANCH
TMP_ROOT=$(fm_test_tmproot fm-claude-worker-permissions)
BASE='{"feedbackDrafts":"off","attribution":{"commit":"","pr":"","sessionUrl":false},"skillOverrides":{"auto-mode-setup":"off"}}'

# The builder's own status is the answer: a refusal must reach the caller.
scope_settings() {  # <scope> [<private-file>]
  fm_cpw_scope_settings "$@"
}

# --- the base controls and the secondmate's byte-identical JSON ----------------

sm=$(fm_claude_launch_settings secondmate '' '' none "$TMP_ROOT/not-read.json")
[ "$sm" = "$BASE" ] || fail "a secondmate launch must carry exactly the base controls, got: $sm"
pass "a secondmate's --settings JSON is the base controls, byte for byte, and never reads the private file"

for scope in nm pr lo gerrit scout; do
  json=$(scope_settings "$scope") || fail "$scope: the builder refused"
  [ "$(printf '%s\n' "$json" | wc -l | tr -d ' ')" = 1 ] || fail "$scope: the JSON must be one line"
  printf '%s' "$json" | jq -e . >/dev/null 2>&1 || fail "$scope: the JSON does not parse: $json"
  # The base controls lead the object in their historical order, unchanged.
  case "$json" in
  "${BASE%\}},"*) ;;
  *) fail "$scope: the base controls must lead the JSON unchanged: $json" ;;
  esac
  [ "$(printf '%s' "$json" | jq -r '.autoMode // "absent"')" = absent ] || fail "$scope: no private file, so no autoMode"
done
pass "every task worker's JSON is one line of valid JSON led by the unchanged base controls, with no autoMode and no private file"

# --- composition by kind, mode, and forge --------------------------------------

has_allow() { printf '%s' "$1" | jq -e --arg r "$2" '(.permissions.allow // []) | index($r) != null' >/dev/null; }
has_deny() { printf '%s' "$1" | jq -e --arg r "$2" '(.permissions.deny // []) | index($r) != null' >/dev/null; }

nm=$(scope_settings nm)
has_allow "$nm" 'Bash(git commit *)' || fail "ship/no-mistakes lost the commit allow"
has_allow "$nm" 'Bash(no-mistakes axi respond --action approve)' || fail "ship/no-mistakes lost the gate approval allow"
printf '%s' "$nm" | jq -e '[(.permissions.allow // [])[] | select(startswith("Bash(git push"))] | length == 0' >/dev/null \
  || fail "ship/no-mistakes must carry no push allow, the pipeline pushes"
pass "ship/no-mistakes allows commit, rebase, and gate approval, and no push"

pr=$(scope_settings pr)
printf '%s' "$pr" | jq -e --arg b "$BRANCH" '
  [(.permissions.allow // [])[] | select(startswith("Bash(git push"))]
  | sort == (["Bash(git push -u origin \($b))", "Bash(git push --set-upstream origin \($b))", "Bash(git push origin \($b))"] | sort)' >/dev/null \
  || fail "ship/direct-PR must allow exactly the three pushes of its own branch: $pr"
has_allow "$pr" 'Bash(no-mistakes axi respond --action approve)' && fail "ship/direct-PR must not allow gate approval"
pass "ship/direct-PR allows exactly the three pushes of its own branch and no gate approval"

for scope in lo gerrit scout; do
  json=$(scope_settings "$scope")
  printf '%s' "$json" | jq -e '[(.permissions.allow // [])[] | select(startswith("Bash(git push"))] | length == 0' >/dev/null \
    || fail "$scope must carry no push allow"
  has_deny "$json" 'Bash(git push *)' || fail "$scope must deny every push"
done
scout=$(scope_settings scout)
printf '%s' "$scout" | jq -e '.permissions | has("allow") | not' >/dev/null || fail "a scout must carry no allow rules at all"
has_deny "$scout" 'Bash(git merge *)' || fail "a scout carries the base denies too"
pass "local-only, Gerrit, and scout workers deny every push; a scout carries no allows"

gnm=$(fm_claude_launch_settings ship no-mistakes "$BRANCH" gerrit)
has_allow "$gnm" 'Bash(no-mistakes axi respond --action approve)' || fail "a Gerrit ship in no-mistakes mode keeps gate approval"
has_deny "$gnm" 'Bash(git push *)' || fail "a Gerrit ship publishes through gerrit-axi and never pushes"
pass "a Gerrit ship keeps the mode's allows and loses every push"

legacy=$(fm_claude_launch_settings ship '' "$BRANCH" none)
[ "$legacy" = "$nm" ] || fail "a ship record with no recorded mode must compose as no-mistakes, the default teardown applies"
pass "a ship with no recorded delivery mode composes as no-mistakes"

fm_claude_launch_settings ship bogus "$BRANCH" none >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" && fail "an unknown delivery mode must refuse"
[ ! -s "$TMP_ROOT/out" ] || fail "a refusal must print no JSON"
assert_contains "$(cat "$TMP_ROOT/err")" "bogus" "the refusal must name the mode"
fm_claude_launch_settings crew "$BRANCH" x none >"$TMP_ROOT/out" 2>/dev/null && fail "an unknown task kind must refuse"
pass "an unknown delivery mode or task kind refuses without printing JSON"

# --- a branch is substituted only when nothing in it reads as rule syntax -------

for ok in fm/task-1 dev/feature_x.y fm/a.b-c; do
  json=$(fm_claude_launch_settings ship direct-PR "$ok" none 2>/dev/null)
  has_allow "$json" "Bash(git push origin $ok)" || fail "plain branch $ok must reach its push allow"
done
for odd in 'fm/a b' 'fm/a*' 'fm/a(b)' '-fm/a' 'fm/..x' 'fm//x' 'fm/x/' 'fm/é' 'fm/a;b' "fm/a'b" ''; do
  json=$(fm_claude_launch_settings ship direct-PR "$odd" none 2>"$TMP_ROOT/err") || fail "an odd branch must not refuse the launch: '$odd'"
  printf '%s' "$json" | jq -e '[(.permissions.allow // [])[] | select(startswith("Bash(git push"))] | length == 0' >/dev/null \
    || fail "branch '$odd' must carry no push allow"
  has_allow "$json" 'Bash(git commit *)' || fail "branch '$odd' must keep the other allows"
  assert_contains "$(cat "$TMP_ROOT/err")" "notice:" "branch '$odd' must be announced"
done
pass "a branch with anything beyond letters, digits, . _ - / loses its push allows with a notice and keeps the rest"

# --- the shared command table through a simulated matcher ----------------------

SIM='
def esc: gsub("(?<c>[\\[\\]\\\\.^$(){}|+?])"; "\\" + .c);
def rx: esc | gsub("\\*"; ".*") | "^" + . + "$";
def hit($cmd):
  select(startswith("Bash("))
  | ltrimstr("Bash(") | rtrimstr(")") as $s
  | (($cmd | test($s | rx))
     or (($s | endswith(" *")) and (($s | [match("\\*"; "g")] | length) == 1) and ($cmd == ($s | .[0:-2]))));
(any((.permissions.deny // [])[]; hit($cmd) // false)) as $d
| (any((.permissions.allow // [])[]; hit($cmd) // false)) as $a
| if $d then "deny" elif $a then "allow" else "none" end
'
rows=0 denies=0
while IFS=$'\t' read -r scope expected via cmd; do
  case "$scope" in '' | '#'*) continue ;; esac
  [ "$via" = both ] || continue
  json=$(scope_settings "$scope")
  got=$(jq -rn --argjson s "$json" --arg cmd "$cmd" '$s | '"$SIM") || fail "the simulated matcher failed on: $cmd"
  want=$expected
  [ "$want" != readonly ] || want=none
  [ "$got" = "$want" ] || fail "[$scope] expected $expected, the rules say $got: $cmd"
  rows=$((rows + 1))
  [ "$got" != deny ] || denies=$((denies + 1))
done <"$ROWS"
[ "$rows" -ge 70 ] && [ "$denies" -ge 45 ] || fail "the command table checked too little ($rows rows, $denies denies)"
pass "the shared command table holds for every scope through the simulated matcher ($rows rows, $denies denied)"

# The matcher can fail: with the deny set removed, a force push is no longer denied.
none_json=$(jq -c 'del(.permissions.deny)' <<<"$nm")
[ "$(jq -rn --argjson s "$none_json" --arg cmd 'git push --force origin x' '$s | '"$SIM")" = none ] \
  || fail "the simulated matcher must stop denying once the deny set is gone"
pass "the simulated matcher is not vacuous: it stops denying when the deny rules are removed"

owner_replacement='{"permissions":{"allow":["Bash(no-mistakes axi respond --action approve)","Bash(no-mistakes axi respond --action approve --step *)"],"deny":["Bash(no-mistakes*--action*--action*)"]}}'
for pair in \
  'no-mistakes axi respond --action approve|allow' \
  'no-mistakes axi respond --action approve --step review|allow' \
  'no-mistakes axi respond --action fix --findings F1 --instructions tighten|none' \
  'no-mistakes axi respond --action skip --step review|none' \
  'no-mistakes axi respond --step review --action approve|none' \
  'no-mistakes axi respond --action approve --step review --action skip|deny' \
  'no-mistakes axi respond --action approve --step review --action=fix|deny'; do
  cmd=${pair%|*}
  want=${pair#*|}
  got=$(jq -rn --argjson s "$owner_replacement" --arg cmd "$cmd" '$s | '"$SIM") || fail "the owner replacement matcher failed: $cmd"
  [ "$got" = "$want" ] || fail "owner replacement expected $want, got $got: $cmd"
done
pass "the paired owner replacement allows approvals and denies repeated actions through the simulated matcher"

for spec in 'ship no-mistakes none' 'ship direct-PR none' 'ship local-only none' 'ship direct-PR gerrit' 'scout none none'; do
  read -r kind mode forge <<<"$spec"
  ordinary=$(fm_claude_launch_settings "$kind" "$mode" "$BRANCH" "$forge") || fail "ordinary settings failed: $spec"
  explicit_default=$(fm_claude_launch_settings "$kind" "$mode" "$BRANCH" "$forge" '' "$HOME/.claude/") || fail "default directory failed: $spec"
  [ "$ordinary" = "$explicit_default" ] || fail "the default directory must add no rules: $spec"
  custom=$(fm_claude_launch_settings "$kind" "$mode" "$BRANCH" "$forge" '' "$TMP_ROOT/claude-work/") || fail "custom directory failed: $spec"
  jq -en --argjson ordinary "$ordinary" --argjson custom "$custom" --arg dir "$TMP_ROOT/claude-work" '
    ($custom.permissions.deny - $ordinary.permissions.deny | sort)
      == (["Edit(/\($dir)/settings.json)", "Edit(/\($dir)/settings.local.json)"] | sort)
    and ($ordinary.permissions.deny - $custom.permissions.deny | length) == 0
    and $custom.permissions.allow == $ordinary.permissions.allow
  ' >/dev/null || fail "a custom directory must add exactly two settings denies and retain the ordinary rules: $spec"
done
custom_sm=$(fm_claude_launch_settings secondmate '' '' none '' "$TMP_ROOT/claude-work")
[ "$custom_sm" = "$BASE" ] || fail "a custom directory must not change secondmate settings"
pass "custom configuration directories protect both settings files across task scopes; default and secondmate settings remain unchanged"

# --- the private perimeter -----------------------------------------------------

priv() { printf '%s' "$2" >"$TMP_ROOT/$1.json"; printf '%s' "$TMP_ROOT/$1.json"; }

good=$(priv good '{"permissions":{"deny":["Read(~/.ssh/**)","Bash(security *)"]},"autoMode":{"hard_deny":["Never open a connection to the broker.","Never read credentials."]}}')
json=$(scope_settings nm "$good") || fail "a valid private file must be accepted"
printf '%s' "$json" | jq -e '.permissions.deny[-2:] == ["Read(~/.ssh/**)","Bash(security *)"]' >/dev/null \
  || fail "private denies must follow the tracked denies"
printf '%s' "$json" | jq -e '.autoMode.hard_deny == ["$defaults","Never open a connection to the broker.","Never read credentials."]' >/dev/null \
  || fail "hard_deny must keep the built-in rules first: $json"
tracked=$(jq '.deny_all_task_workers | length' "$ROOT/bin/fm-claude-worker-permissions.json")
printf '%s' "$json" | jq -e --argjson n "$tracked" '.permissions.deny | length == $n + 2' >/dev/null || fail "private denies must be appended, not substituted"
pass "a private file's denies follow the tracked denies and its hard_deny follows \"\$defaults\""

sm_with_priv=$(fm_claude_launch_settings secondmate '' '' none "$good")
[ "$sm_with_priv" = "$BASE" ] || fail "a secondmate must ignore the private file"
scout_priv=$(scope_settings scout "$good")
printf '%s' "$scout_priv" | jq -e '.autoMode.hard_deny[0] == "$defaults"' >/dev/null || fail "a scout carries the private prose too"
pass "the private file reaches every task worker and no secondmate"

# An MCP server name may carry hyphens, and a rule may deny a whole server.
mcp=$(priv mcp '{"permissions":{"deny":["mcp__example-server__*","mcp__example-server__a_tool","WebFetch(domain:example.test)"]}}')
json=$(scope_settings nm "$mcp") || fail "an MCP rule with a hyphenated server name must be accepted"
printf '%s' "$json" | jq -e '.permissions.deny[-3:] == ["mcp__example-server__*","mcp__example-server__a_tool","WebFetch(domain:example.test)"]' >/dev/null \
  || fail "MCP and WebFetch rules must reach the launch unchanged: $json"
pass "an MCP rule naming a hyphenated server, and a WebFetch domain rule, are accepted"

empty=$(priv empty '{}')
[ "$(scope_settings nm "$empty")" = "$nm" ] || fail "an empty private file must change nothing"
empty_lists=$(priv empty-lists '{"permissions":{"deny":[]},"autoMode":{"hard_deny":[]}}')
[ "$(scope_settings nm "$empty_lists")" = "$nm" ] || fail "empty private lists must change nothing, and emit no autoMode"
pass "an empty private file, or empty lists, change nothing"

refuse() {  # <name> <content> <message fragment>
  local file
  file=$(priv "$1" "$2")
  scope_settings nm "$file" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" && fail "$1: a malformed private file must refuse the launch"
  [ ! -s "$TMP_ROOT/out" ] || fail "$1: a refusal must print no JSON"
  assert_contains "$(cat "$TMP_ROOT/err")" "config/claude-worker-permissions.json" "$1: the refusal must name the file"
  assert_contains "$(cat "$TMP_ROOT/err")" "$3" "$1: the refusal must say why"
}
refuse allow '{"permissions":{"allow":["Bash(git status)"]}}' 'only permissions.deny is accepted'
refuse ask '{"permissions":{"ask":["Bash(git push *)"]}}' 'only permissions.deny is accepted'
refuse default-mode '{"permissions":{"deny":[],"defaultMode":"acceptEdits"}}' 'only permissions.deny is accepted'
refuse soft '{"autoMode":{"soft_deny":["x"]}}' 'only autoMode.hard_deny is accepted'
refuse environment '{"autoMode":{"environment":["x"]}}' 'only autoMode.hard_deny is accepted'
refuse auto-allow '{"autoMode":{"allow":["x"]}}' 'only autoMode.hard_deny is accepted'
refuse hooks '{"hooks":{}}' 'only permissions.deny and autoMode.hard_deny are accepted'
refuse defaults '{"autoMode":{"hard_deny":["$defaults","x"]}}' '"$defaults"'
refuse unbalanced '{"permissions":{"deny":["Bash(foo"]}}' 'permissions.deny[0]'
refuse empty-parens '{"permissions":{"deny":["Bash(git push *)","Bash()"]}}' 'permissions.deny[1]'
refuse blank-rule '{"permissions":{"deny":[""]}}' 'permissions.deny[0]'
refuse number-rule '{"permissions":{"deny":[5]}}' 'is not a string'
refuse newline-rule '{"permissions":{"deny":["Bash(a)\nBash(b)"]}}' 'control character'
refuse mcp-specifier '{"permissions":{"deny":["mcp__srv__tool(x)"]}}' 'MCP'
refuse blank-prose '{"autoMode":{"hard_deny":[""]}}' 'autoMode.hard_deny[0]'
refuse prose-not-array '{"autoMode":{"hard_deny":"never"}}' 'array'
refuse deny-not-array '{"permissions":{"deny":"Bash(x)"}}' 'array'
# A false or null where a list or object belongs declares nothing, so it is refused rather than read as absent.
refuse deny-false '{"permissions":{"deny":false}}' 'array'
refuse deny-null '{"permissions":{"deny":null}}' 'array'
refuse prose-false '{"autoMode":{"hard_deny":false}}' 'array'
refuse prose-null '{"autoMode":{"hard_deny":null}}' 'array'
refuse permissions-false '{"permissions":false}' 'not an object'
refuse permissions-null '{"permissions":null}' 'not an object'
refuse automode-false '{"autoMode":false}' 'not an object'
refuse automode-null '{"autoMode":null}' 'not an object'
refuse top-array '[]' 'one JSON object'
refuse not-json 'permissions: deny' 'not valid JSON'
pass "a private file with any other key, or a malformed rule, refuses the launch and names the file and the reason"

scope_settings nm "$TMP_ROOT" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" && fail "an unreadable private path must refuse"
assert_contains "$(cat "$TMP_ROOT/err")" "readable regular file" "an unreadable path must say so"
scope_settings nm "$TMP_ROOT/absent.json" >/dev/null 2>"$TMP_ROOT/err" && fail "a missing private file path must refuse"
pass "a private path that is not a readable regular file refuses the launch"

# --- a damaged tracked rule file is refused, never composed from what is left ----

damaged="$TMP_ROOT/damaged.json"
jq 'del(.deny_no_push_workers)' "$ROOT/bin/fm-claude-worker-permissions.json" >"$damaged"
(FM_CLAUDE_WORKER_RULES=$damaged fm_claude_launch_settings ship no-mistakes "$BRANCH" none) >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" \
  && fail "a tracked rule file missing an array must refuse"
assert_contains "$(cat "$TMP_ROOT/err")" "arrays of rule strings" "the refusal must say what the file needs"
jq '.deny_all_task_workers = []' "$ROOT/bin/fm-claude-worker-permissions.json" >"$damaged"
(FM_CLAUDE_WORKER_RULES=$damaged fm_claude_launch_settings ship no-mistakes "$BRANCH" none) >/dev/null 2>&1 \
  && fail "a tracked rule file with no base denies must refuse"
printf 'not json\n' >"$damaged"
(FM_CLAUDE_WORKER_RULES=$damaged fm_claude_launch_settings ship no-mistakes "$BRANCH" none) >/dev/null 2>&1 \
  && fail "an unparseable tracked rule file must refuse"
pass "a tracked rule file that lost an array, its base denies, or its JSON is refused instead of composing weaker rules"

printf '# all fm-claude-worker-permissions tests passed\n'
