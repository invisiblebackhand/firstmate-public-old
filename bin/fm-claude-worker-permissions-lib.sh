# shellcheck shell=bash
# The per-launch --settings JSON of every Claude launch bin/fm-spawn.sh makes
# (ship, scout, secondmate, and relaunch), built in one place.
#
# Usage: . bin/fm-claude-worker-permissions-lib.sh
#   fm_claude_launch_settings <kind> <mode> <branch> <forge> [<private-file>] [<config-dir>]
#       Prints the one-line JSON for --settings, or prints a diagnostic and
#       returns non-zero. <kind> is ship, scout, or secondmate; <mode> is the
#       ship's delivery mode; <forge> is none or gerrit.
#   fm_claude_worker_private_check <private-file>
#       Validates config/claude-worker-permissions.json alone.
#
# CONTRACT. Every launch carries the base controls: the feedbackDrafts switch,
# the attribution-off policy, and the /auto-mode-setup off switch (the comment in
# bin/fm-spawn.sh's launch_template() owns why each rides the launch). A
# secondmate's JSON is exactly those controls and nothing else, byte for byte.
# A task worker, ship or scout, adds a permissions object composed from
# bin/fm-claude-worker-permissions.json, so the rules reach only the workers this
# spawn starts: never the captain's own sessions, a firstmate primary, or a
# secondmate. They apply under either config/claude-permission-mode, because a
# deny rule blocks in every mode and an allow rule only saves a classifier pass.
#
#   worker                       allow                          deny
#   ship, no-mistakes            all_modes + no_mistakes        all_task_workers
#   ship, direct-PR              all_modes + direct_pr          all_task_workers
#   ship, local-only             all_modes                      all_task_workers + no_push
#   ship on a Gerrit forge       all_modes (+ no_mistakes)      all_task_workers + no_push
#   scout                        none                           all_task_workers + no_push
#
# The table's names are the arrays of that file without their prefix. An allow
# rule is an exact command, so it cannot widen to other arguments: direct_pr
# names this task's own branch, substituted only when the branch is plain
# (letters, digits, . _ - /); any other branch drops those allows with a notice
# and leaves the push to Claude's own classifier. A ship record with no
# recorded delivery mode takes no-mistakes, the default bin/fm-teardown.sh
# applies to the same record, and any other mode refuses.
#
# RULE SHAPES. A Bash rule is command text, not a security boundary: a form it
# does not match is decided as it is without these rules (the auto-mode
# classifier, or the permission mode), never allowed by them. The deny shapes
# are anchored so a commit message cannot trip them: "git <subcommand>..." for
# the plain form and "git -*" before the subcommand for a global option such as
# -C or -c, so "git commit -m 'clean up'" is untouched and "git -C dir push -f"
# is denied. A trailing ":*" is Claude's legacy prefix wildcard and silently
# matches nothing else, so the refspec-colon shape ends in ":**". Commit-flag
# shapes (--no-verify, -n, --amend) match anywhere in a commit command, so an
# inline -m message that names those flags is denied too: write such a message
# with -F, or a heredoc, whose body Claude does not match. The no-mistakes shapes
# (--yes, -y, and a repeated --action) match anywhere in the command text too:
# the step-scoped approve allow ends in a wildcard and the CLI keeps the last
# --action, so only a deny on the repeat stops a skip or fix from riding that
# allow. The version-scoped evidence for all of this, including what the shapes
# do not catch, is
# docs/verification/runtime-backends.md "Claude worker permission rules".
#
# PRIVATE PERIMETER. config/claude-worker-permissions.json is local, gitignored,
# inherited into secondmate homes (bin/fm-config-inherit-lib.sh), and holds
# exactly two keys, both deny-only, so a private file can narrow a worker and
# never widen it: permissions.deny (permission rules, appended after the tracked
# denies) and autoMode.hard_deny (classifier prose, which the spawn emits after
# "$defaults" so the built-in rules are kept; the literal "$defaults" is
# refused in the file). Any other key, an object or list of the wrong type
# (false and null included), a non-string or malformed rule, or an unreadable
# file refuses the launch: Claude skips an invalid rule silently, so accepting
# one would start a worker without the perimeter the file declares.

FM_CLAUDE_WORKER_PERMISSIONS_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Override only in tests.
FM_CLAUDE_WORKER_RULES="${FM_CLAUDE_WORKER_RULES:-$FM_CLAUDE_WORKER_PERMISSIONS_LIB_DIR/fm-claude-worker-permissions.json}"

FM_CLAUDE_BASE_SETTINGS='{"feedbackDrafts":"off","attribution":{"commit":"","pr":"","sessionUrl":false},"skillOverrides":{"auto-mode-setup":"off"}}'

# Prints the first problem with the private file, or nothing when it is valid.
# shellcheck disable=SC2016  # the jq program is single-quoted on purpose
FM_CLAUDE_WORKER_PRIVATE_PROBLEM_JQ='
def rule_problem:
  if type != "string" then "is not a string"
  elif test("[\\x00-\\x1f\\x7f]") then "contains a control character"
  elif (test("^[A-Za-z][A-Za-z0-9_*-]*(\\(.+\\))?$") | not) then "is not a permission rule, a tool name optionally followed by (specifier)"
  elif startswith("mcp__") and contains("(") then "gives an MCP tool a specifier, which Claude refuses"
  else empty end;
def prose_problem:
  if type != "string" then "is not a string"
  elif length == 0 then "is empty"
  elif test("[\\x00-\\x1f\\x7f]") then "contains a control character"
  elif . == "$defaults" then "is \"$defaults\", which the spawn adds itself, first"
  else empty end;
def entries($path; f): to_entries[] | . as $e | ($e.value | f) | "\($path)[\($e.key)] \(.)";
# A key that is present keeps its value, even false or null, so the type checks below see it; only a missing key takes the default.
def member($k; $default): if has($k) then .[$k] else $default end;
if type != "object" then "must hold one JSON object"
elif (keys - ["permissions", "autoMode"] | length) > 0 then
  "has the key \((keys - ["permissions", "autoMode"])[0] | @json); only permissions.deny and autoMode.hard_deny are accepted"
elif (member("permissions"; {}) | type) != "object" then "has a permissions value that is not an object"
elif (member("permissions"; {}) | keys - ["deny"] | length) > 0 then
  "has permissions.\((.permissions | keys - ["deny"])[0]); only permissions.deny is accepted, so the file can narrow a worker and never widen it"
elif (member("autoMode"; {}) | type) != "object" then "has an autoMode value that is not an object"
elif (member("autoMode"; {}) | keys - ["hard_deny"] | length) > 0 then
  "has autoMode.\((.autoMode | keys - ["hard_deny"])[0]); only autoMode.hard_deny is accepted"
elif (member("permissions"; {}) | member("deny"; []) | type) != "array" then "has a permissions.deny that is not an array"
elif (member("autoMode"; {}) | member("hard_deny"; []) | type) != "array" then "has an autoMode.hard_deny that is not an array"
else
  ([member("permissions"; {}) | member("deny"; []) | entries("permissions.deny"; rule_problem)]
   + [member("autoMode"; {}) | member("hard_deny"; []) | entries("autoMode.hard_deny"; prose_problem)]) | first // empty
end
'

fm_claude_worker_private_check() { # <file>
  local file=$1 problem
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: config/claude-worker-permissions.json must be a readable regular file" >&2
    return 1
  fi
  if ! problem=$(jq -r "$FM_CLAUDE_WORKER_PRIVATE_PROBLEM_JQ" "$file" 2>/dev/null); then
    echo "error: config/claude-worker-permissions.json is not valid JSON" >&2
    return 1
  fi
  if [ -n "$problem" ]; then
    echo "error: config/claude-worker-permissions.json $problem" >&2
    return 1
  fi
}

# A tracked file that lost an array would compose a rule set nobody intended,
# silently dropping its denies, so the builder refuses it instead.
fm_claude_worker_rules_check() {
  if ! jq -e '
    type == "object" and
    all(["allow_ship_all_modes", "allow_ship_no_mistakes", "allow_ship_direct_pr", "deny_all_task_workers", "deny_no_push_workers"][] as $k | .[$k];
        type == "array" and all(.[]; type == "string" and length > 0)) and
    (.deny_all_task_workers | length) > 0 and (.deny_no_push_workers | length) > 0
  ' "$FM_CLAUDE_WORKER_RULES" >/dev/null 2>&1; then
    echo "error: $FM_CLAUDE_WORKER_RULES must be a JSON object whose allow_ship_all_modes, allow_ship_no_mistakes, allow_ship_direct_pr, deny_all_task_workers, and deny_no_push_workers are arrays of rule strings" >&2
    return 1
  fi
}

# A branch is substituted into an allow rule only when nothing in it could be
# read as rule syntax.
fm_claude_worker_branch_plain() { # <branch>
  case $1 in
  '' | -* | */ | *..* | *//* | *[!A-Za-z0-9._/-]*) return 1 ;;
  esac
  return 0
}

fm_claude_launch_settings() { # <kind> <mode> <branch> <forge> [<private-file>] [<config-dir>]
  local kind=$1 mode=${2:-} branch=${3:-} forge=${4:-none} private=${5:-}
  local branch_ok=false priv_json='{}' config_dir=${6:-}
  case "$kind" in
  secondmate)
    printf '%s' "$FM_CLAUDE_BASE_SETTINGS"
    return 0
    ;;
  ship)
    case "$mode" in
    '') mode=no-mistakes ;;
    no-mistakes | direct-PR | local-only) ;;
    *)
      echo "error: no Claude worker permission rules for delivery mode '$mode'" >&2
      return 1
      ;;
    esac
    ;;
  scout) mode= ;;
  *)
    echo "error: no Claude worker permission rules for task kind '$kind'" >&2
    return 1
    ;;
  esac
  case "$config_dir" in
  '' | /*) ;;
  *)
    echo "error: Claude configuration directory must be an absolute path: $config_dir" >&2
    return 1
    ;;
  esac
  if [ "${config_dir%/}" = "${HOME:-}/.claude" ]; then
    config_dir=
  fi
  fm_claude_worker_rules_check || return 1
  if [ -n "$private" ]; then
    fm_claude_worker_private_check "$private" || return 1
    priv_json=$(jq -c . "$private") || return 1
  fi
  if [ "$kind" = ship ] && [ "$mode" = direct-PR ] && [ "$forge" != gerrit ]; then
    if fm_claude_worker_branch_plain "$branch"; then
      branch_ok=true
    else
      echo "notice: ship branch '$branch' has characters outside letters, digits, . _ - /, so its push allow rules are left out and Claude decides its pushes" >&2
    fi
  fi
  jq -cn --argjson base "$FM_CLAUDE_BASE_SETTINGS" --slurpfile rules "$FM_CLAUDE_WORKER_RULES" \
    --argjson priv "$priv_json" --arg kind "$kind" --arg mode "$mode" --arg forge "$forge" \
    --arg config_dir "$config_dir" --arg branch "$branch" --argjson branch_ok "$branch_ok" '
    $rules[0] as $r
    | ($kind == "ship") as $ship
    | ($ship and $mode == "no-mistakes") as $approve
    | ($ship and $mode == "direct-PR" and $forge != "gerrit" and $branch_ok) as $own_push
    | (($kind == "scout") or ($ship and ($mode == "local-only" or $forge == "gerrit"))) as $no_push
    | (  (if $ship then $r.allow_ship_all_modes else [] end)
       + (if $approve then $r.allow_ship_no_mistakes else [] end)
       + (if $own_push then ($r.allow_ship_direct_pr | map(split("__BRANCH__") | join($branch))) else [] end)
      ) as $allow
    | (  $r.deny_all_task_workers
       + (if $no_push then $r.deny_no_push_workers else [] end)
       + (if $config_dir != "" then
            ($config_dir | rtrimstr("/") | explode
              | map(if . == 92 or . == 42 or . == 63 or . == 91 or . == 93 then [92, .] else [.] end)
              | add // [] | implode) as $dir
            | ["Edit(/\($dir)/settings.json)", "Edit(/\($dir)/settings.local.json)"]
          else [] end)
       + ($priv.permissions.deny // [])
      ) as $deny
    | ($priv.autoMode.hard_deny // []) as $hard
    | $base
      + {permissions: ({allow: $allow, deny: $deny} | with_entries(select(.value | length > 0)))}
      + (if ($hard | length) > 0 then {autoMode: {hard_deny: (["$defaults"] + $hard)}} else {} end)
  '
}
