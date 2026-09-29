#!/usr/bin/env bash
# tests/fm-claude-automode-dialog-live-e2e.test.sh - default-on drift guard
# proving the INSTALLED Claude Code still carries every string the doorbell's
# auto-mode setup dialog guard matches on (fm_task_inbox_claude_dialog_markers
# in bin/fm-task-inbox-lib.sh), and still carries the settings key and skill
# name bin/fm-spawn.sh's per-launch off switch depends on.
#
# Why this file exists: the guard recognizes the dialog by text Claude Code
# renders, and the off switch is a vendor-defined settings key naming a
# vendor-defined skill. Both are surfaces the vendor changes without notice,
# and a stubbed pane can only confirm the assumption already written into the
# stub. Left unwatched, a reworded dialog would turn the guard blind and a
# renamed key would turn the off switch into a silent no-op, so the doorbell's
# Enter would once again accept an offer whose wizard scans the project's recent
# session transcripts for a model request.
#
# The dialog itself is never provoked. Opening it, or running /auto-mode-setup,
# is exactly the transcript scan this change exists to keep off, so this guard
# only READS strings out of the installed binary: it starts no session, submits
# no prompt, and spends no model tokens. It asks the binary for its version and
# nothing else. That is also its limit: it proves the strings a guard verdict
# rests on are still shipped, not that a given release still draws them on the
# screen the way it did, which is the part docs/verification/runtime-backends.md
# ("Claude auto-mode setup dialog markers") records as static evidence.
#
# The portable counterparts are tests/fm-task-inbox.test.sh and
# tests/fm-send-inbox.test.sh (the guard's behavior over a fake Claude pane) and
# tests/fm-spawn-dispatch-profile.test.sh (the launch settings). Run this guard
# after any Claude Code upgrade and before trusting the recorded result.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CLAUDE_AUTOMODE_DIALOG_LIVE claude

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

note() { printf '# %s\n' "$1"; }

# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-inbox-lib.sh"

CLAUDE=$(command -v claude) || fail "claude is not on PATH"
VERSION=$("$CLAUDE" --version 2>/dev/null | head -1 | tr -d '\r') || VERSION=
[ -n "$VERSION" ] || VERSION=unknown

# A launcher script in front of the real binary hides every string this reads,
# so the failure has to say that as well as naming what went missing.
LAUNCHER_HINT="If claude on PATH ($CLAUDE) is a launcher script rather than the Claude Code binary itself, these strings are read from the wrong file."

# in_binary <string>: whether the installed claude carries it. Fixed-string and
# byte-wise, so the multi-hundred-megabyte native binary reads in well under a
# second and no locale can reinterpret the bytes.
in_binary() {  # <string>
  LC_ALL=C grep -a -q -F -- "$1" "$CLAUDE"
}

CHECKED=0
MISSING=
while IFS= read -r marker; do
  CHECKED=$((CHECKED + 1))
  if in_binary "$marker"; then
    note "claude $VERSION carries: $marker"
  else
    MISSING="$MISSING"$'\n'"  $marker"
  fi
done < <(fm_task_inbox_claude_dialog_markers)

[ "$CHECKED" -gt 0 ] \
  || fail "the doorbell guard lists no auto-mode setup dialog strings, so this run proved nothing"

[ -z "$MISSING" ] || fail \
  "DIALOG STRING DRIFT: claude $VERSION no longer carries these auto-mode setup dialog strings the doorbell guard matches on:$MISSING"$'\n'"Re-verify the dialog against this release by reading its strings (never by opening the dialog: that scans session transcripts), then update fm_task_inbox_claude_dialog_markers in bin/fm-task-inbox-lib.sh and the dated record in docs/verification/runtime-backends.md. $LAUNCHER_HINT"
pass "claude $VERSION carries all $CHECKED auto-mode setup dialog strings the doorbell guard matches on"

# The off switch: skillOverrides is the settings key bin/fm-spawn.sh passes
# inline, and auto-mode-setup is the skill name it turns off. Either going
# missing makes the launch setting inert while everything else keeps working.
for switch in skillOverrides auto-mode-setup; do
  in_binary "$switch" || fail \
    "OFF SWITCH DRIFT: claude $VERSION no longer carries '$switch', which bin/fm-spawn.sh's inline skillOverrides setting relies on to turn the auto-mode setup offer off per launch. The doorbell guard is now the only protection. Re-verify the switch against https://code.claude.com/docs/en/auto-mode-config#turn-off-auto-mode-setup. $LAUNCHER_HINT"
done
pass "claude $VERSION carries the skillOverrides key and the auto-mode-setup skill name the per-launch off switch uses"
