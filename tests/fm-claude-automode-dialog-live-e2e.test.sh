#!/usr/bin/env bash
# tests/fm-claude-automode-dialog-live-e2e.test.sh - default-on drift guard
# proving the INSTALLED Claude Code still carries every string and every piece
# of UI structure the doorbell's auto-mode setup dialog guard recognizes the
# dialog by (fm_task_inbox_claude_dialog_markers in bin/fm-task-inbox-lib.sh,
# which owns that contract), and still carries the settings key and skill name
# bin/fm-spawn.sh's per-launch off switch depends on.
#
# Why this file exists: the guard recognizes the dialog by text Claude Code
# renders and by the frame, option rows, and footer it draws around that text,
# and the off switch is a vendor-defined settings key naming a vendor-defined
# skill. All of them are surfaces the vendor changes without notice, and a
# stubbed pane can only confirm the assumption already written into the stub.
# Left unwatched, a reworded or redrawn dialog would turn the guard blind and a
# renamed key would turn the off switch into a silent no-op, so the doorbell's
# Enter would once again accept an offer whose wizard scans the project's recent
# session transcripts for a model request.
#
# The dialog itself is never provoked. Opening it, or running /auto-mode-setup,
# is exactly the transcript scan this change exists to keep off, so this guard
# only READS strings and component code out of the installed binary: it starts
# no session, submits no prompt, and spends no model tokens. It asks the binary
# for its version and nothing else. That is also its limit: it proves the
# strings and the component code a guard verdict rests on are still shipped, not
# that a given release still draws them on the screen the way it did, which is
# the part docs/verification/runtime-backends.md ("Claude auto-mode setup dialog
# markers") records as static evidence, along with what each structure check
# below stands for.
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
# byte-wise, so no locale can reinterpret the bytes. Every check in this file is
# one pass over the multi-hundred-megabyte native binary, about a second each
# with BSD grep, so the whole guard takes a quarter of a minute there.
in_binary() {  # <string>
  LC_ALL=C grep -a -q -F -- "$1" "$CLAUDE"
}

CHECKED=0
MISSING=
while IFS=$'\t' read -r _kind marker; do
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

# The UI structure the guard's verdict reads around those strings, as the
# component code in the installed binary spells it. Each check stands for one
# fact the matcher relies on; docs/verification/runtime-backends.md records what
# they were derived from and what they leave unchecked. The bundler renames
# every identifier, so a check pins only the strings and property names the
# bundle keeps: a fixed string where that is enough, and an extended regex with
# @ID@ standing for an identifier where the fact is a call's shape. A regex with
# a leading wildcard costs seconds on this binary, so every one starts on a
# literal. The bundle spells a glyph as an escape sequence, a backslash then u
# and its code point, so the fixed strings that name one are built from BS.
ID='[A-Za-z_$][A-Za-z0-9_$]*'
BS=\\

SHAPES=0
SHAPE_MISSING=
shape() {  # <what the guard relies on> <-F|-E> <pattern>
  local pattern=${3//@ID@/$ID}
  SHAPES=$((SHAPES + 1))
  if LC_ALL=C grep -a -q "$2" -- "$pattern" "$CLAUDE"; then
    note "claude $VERSION carries: $1"
  else
    SHAPE_MISSING="$SHAPE_MISSING"$'\n'"  $1"
  fi
}

shape "the offer drawn as a dialog titled with the matched string" -F \
  'title:"Teach auto mode about your environment?",onCancel:'
shape "the offer's numbered options, Yes first" -F \
  '{label:"Yes",value:"accept"},{label:"Not now",value:"later"},{label:"Don'"'"'t show again",value:"dismiss"}'
shape "an option's number drawn as \"<n>.\"" -F \
  '}.`.padEnd('
shape "the focus pointer on an option" -F \
  "pointer:\"${BS}u276F\""
shape "a dialog's default footer, Enter to confirm and Esc to cancel, in the dialog component" -E \
  '\{children:\[@ID@\(@ID@,\{chord:"enter",action:"confirm"\}\),@ID@\(@ID@,\{action:"confirm:no",context:"Confirmation",fallback:"Esc",description:"cancel"\}\)\]\}\);function @ID@\(@ID@\)\{let @ID@=@ID@\([0-9]+\),\{title:@ID@,'
shape "a key hint drawn as \"<key> to <action>\"" -E \
  'children:\[@ID@," to ",@ID@\]'
shape "the classic frame rule glyph" -F \
  "=\"${BS}u2500\""
shape "the fullscreen frame rule glyph" -F \
  "{color:\"permission\",char:\"${BS}u2594\"}"
shape "the scan's subtitle row carrying Esc to cancel" -F \
  'this can take a moment (Esc to cancel)'
shape "the scan's status view drawn as a dialog titled \"Auto-mode setup scan\"" -F \
  'title:"Auto-mode setup scan",subtitle:'
shape "the status view's Status row" -F \
  '{bold:!0,children:"Status:"}'
shape "the status view's footer, Esc/Enter/Space to close" -F \
  '{chord:["escape","enter","space"],action:"close"}'
shape "the scan string opening the status view's body sentence" -F \
  'Scanning your repo and recent sessions, then drafting an auto-mode proposal.'
shape "the spinner glyphs, each non-ASCII" -F \
  "[\"${BS}xB7\",\"${BS}u2722\",\"${BS}u2733\",\"${BS}u2736\",\"${BS}u273B\",\"${BS}u273D\"]"
shape "the spinner glyphs of a terminal without unicode, a lone *" -F \
  "[\"${BS}xB7\",\"${BS}u2722\",\"*\",\"${BS}u2736\",\"${BS}u273B\",\"${BS}u273D\"]"

[ -z "$SHAPE_MISSING" ] || fail \
  "DIALOG STRUCTURE DRIFT: claude $VERSION no longer carries these pieces of the auto-mode setup dialog's UI structure, which the doorbell guard's verdict reads around its strings:$SHAPE_MISSING"$'\n'"Re-verify the dialog's frame, option rows, and footer against this release by reading its component code (never by opening the dialog: that scans session transcripts), then update the contract and matcher at fm_task_inbox_claude_dialog_markers in bin/fm-task-inbox-lib.sh, the screens in tests/fixtures.sh, and the dated record in docs/verification/runtime-backends.md. $LAUNCHER_HINT"
pass "claude $VERSION carries all $SHAPES pieces of the auto-mode setup dialog's UI structure the doorbell guard reads"

# The off switch: skillOverrides is the settings key bin/fm-spawn.sh passes
# inline, and auto-mode-setup is the skill name it turns off. Either going
# missing makes the launch setting inert while everything else keeps working.
for switch in skillOverrides auto-mode-setup; do
  in_binary "$switch" || fail \
    "OFF SWITCH DRIFT: claude $VERSION no longer carries '$switch', which bin/fm-spawn.sh's inline skillOverrides setting relies on to turn the auto-mode setup offer off per launch. The doorbell guard is now the only protection. Re-verify the switch against https://code.claude.com/docs/en/auto-mode-config#turn-off-auto-mode-setup. $LAUNCHER_HINT"
done
pass "claude $VERSION carries the skillOverrides key and the auto-mode-setup skill name the per-launch off switch uses"
