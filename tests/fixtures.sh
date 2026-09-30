#!/usr/bin/env bash
# tests/fixtures.sh - shared fake-toolchain and spawn-world builders.
#
# Source this from a test file:
#   # shellcheck source=tests/fixtures.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
#
# Generic reporters, temp roots, git fixtures, and fail/pass/fm_test_cleanup
# come from tests/lib.sh, pulled in below. This file owns the shared fake
# no-mistakes, gh, gh-axi, tmux, ssh, and spawn-world helpers. Wake-queue mocks
# stay in wake-helpers.sh; secondmate-lifecycle mocks stay in
# secondmate-helpers.sh.
#
# FM_TEST_NO_MISTAKES_VERSION is the single default version for the shared fake
# no-mistakes banner. Override a single case with FM_FAKE_NO_MISTAKES_VERSION
# rather than editing a stub body.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -n "${FM_TEST_FIXTURES_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_FIXTURES_SOURCED=1

# Production floor lives in bin/fm-bootstrap.sh (NO_MISTAKES_MIN). Keep this
# equal to that floor so a bump is one constant here plus that production pin.
export FM_TEST_NO_MISTAKES_VERSION=1.46.0
export FM_TEST_NO_MISTAKES_FAKE_VERSION="no-mistakes version v${FM_TEST_NO_MISTAKES_VERSION} (fake)"
export FM_TEST_NO_MISTAKES_FAKE_VERSION_TS="${FM_TEST_NO_MISTAKES_FAKE_VERSION} 2026-06-27T00:02:18Z"
export FM_TEST_GH_AXI_VERSION=0.1.29

# --- fake no-mistakes -------------------------------------------------------

# fm_test_fake_no_mistakes <fakebin>
# Drops a no-mistakes stub that answers --version with
# FM_TEST_NO_MISTAKES_FAKE_VERSION (or FM_FAKE_NO_MISTAKES_VERSION when set)
# and exits 0 for every other invocation.
fm_test_fake_no_mistakes() {
  local fakebin=$1
  cat > "$fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\\n' "\${FM_FAKE_NO_MISTAKES_VERSION:-$FM_TEST_NO_MISTAKES_FAKE_VERSION}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
}

# fm_test_fake_no_mistakes_init_doctor <fakebin>
# Secondmate-lifecycle stub: init/doctor touch marker files; other verbs exit 2.
# Does not answer --version (those suites never probe the floor).
fm_test_fake_no_mistakes_init_doctor() {
  local fakebin=$1
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  init) touch .no-mistakes-init ;;
  doctor) touch .no-mistakes-doctor ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/no-mistakes"
}

# --- fake gh / gh-axi -------------------------------------------------------

# fm_test_fake_gh <fakebin>
# Authenticates (`gh auth status` exits 0) and otherwise exits 0.
fm_test_fake_gh() {
  local fakebin=$1
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh"
}

# fm_test_fake_gh_axi <fakebin>
# Answers --version with FM_FAKE_GH_AXI_VERSION or FM_TEST_GH_AXI_VERSION.
fm_test_fake_gh_axi() {
  local fakebin=$1
  fm_fake_version_tool "$fakebin" gh-axi FM_FAKE_GH_AXI_VERSION "$FM_TEST_GH_AXI_VERSION"
}

# --- fake tmux / ssh / sleep ------------------------------------------------

# fm_test_fake_tmux_spawn <fakebin>
# Spawn-world tmux: pane_current_path from FM_FAKE_PANE_PATH, session named
# firstmate, window ops succeed, send-keys succeed. When FM_FAKE_LAUNCH_LOG is
# set, each send-keys -l payload is appended one per line. When FM_FAKE_PANE_LOG
# is set, each send-keys TEXT-LINE payload (the pre-launch pane exports, which
# carry no -l) is appended there instead, one per line in send order. Optional
# FM_FAKE_DUPLICATE_WINDOW is printed from list-windows.
#
# The pane path defaults to empty when FM_FAKE_PANE_PATH is unset. Window
# cleanup and option operations are no-ops. Launch logging is env-gated, so
# suites that do not set FM_FAKE_LAUNCH_LOG keep a silent send-keys.
fm_test_fake_tmux_spawn() {
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    if [ -n "${FM_FAKE_DUPLICATE_WINDOW:-}" ]; then
      printf '%s\n' "$FM_FAKE_DUPLICATE_WINDOW"
    fi
    exit 0
    ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          # A spawn types a short line sourcing its staged launch file; log
          # the staged command itself so suites assert what the pane runs.
          # Direct literals past the terminal line buffer are truncated, so a
          # long launch only survives when it arrived through that short source.
          case "$a" in
            ". '"*"'")
              staged=${a#". '"}
              staged=${staged%"'"}
              if [ -f "$staged" ]; then
                a=$(cat "$staged")
              elif [ "${#a}" -gt 1024 ]; then
                a=${a:0:1024}
              fi
              ;;
            *)
              if [ "${#a}" -gt 1024 ]; then
                a=${a:0:1024}
              fi
              ;;
          esac
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    # The pre-launch pane exports ride the text-line form
    # (`send-keys -t <target> <text> Enter`), which carries no -l flag, so a
    # suite that asserts on what the pane shell received opts in with its own
    # log. Skip the flags, the target, and the trailing key so only the payload
    # is recorded, one per line, in send order.
    if [ -n "${FM_FAKE_PANE_LOG:-}" ]; then
      shift
      skip_next=
      literal=
      for a in "$@"; do
        if [ -n "$skip_next" ]; then skip_next=; continue; fi
        case "$a" in
          -t) skip_next=1; continue ;;
          -l) literal=1; continue ;;
          Enter|C-m) continue ;;
          *) [ -n "$literal" ] || printf '%s\n' "$a" >> "$FM_FAKE_PANE_LOG" ;;
        esac
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

# fm_test_fake_tmux_spawn_treehouse <fakebin>
# Spawn-world tmux for suites that need the REAL treehouse to choose the slot.
# It answers like fm_test_fake_tmux_spawn, except that the `treehouse get ...`
# text line typed at the pane is actually run: synchronously, from
# FM_FAKE_PANE_PATH (the directory the pane starts in), as the pane's shell would
# run it, with $SHELL set to FM_FAKE_SUBSHELL (fm_test_treehouse_standin_shell) so
# the shell that ends up in the slot is the stand-in. pane_current_path reports the
# directory that stand-in was entered in, as a real pane's cwd follows the shell
# it runs, and FM_FAKE_PANE_PATH until then. FM_FAKE_TREEHOUSE_LOG, when set,
# receives each line run and the treehouse output.
fm_test_fake_tmux_spawn_treehouse() {
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    if [ -s "${FM_FAKE_PANE_CWD_FILE:-/nonexistent}" ]; then
      cat "$FM_FAKE_PANE_CWD_FILE"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  send-keys)
    shift
    skip_next=
    literal=
    payload=
    for a in "$@"; do
      if [ -n "$skip_next" ]; then skip_next=; continue; fi
      case "$a" in
        -t) skip_next=1 ;;
        -l) literal=1 ;;
        Enter|C-m) ;;
        *) [ -n "$literal" ] || payload=$a ;;
      esac
    done
    case "$payload" in
      *"treehouse get"*)
        [ -z "${FM_FAKE_TREEHOUSE_LOG:-}" ] || printf 'run: %s\n' "$payload" >> "$FM_FAKE_TREEHOUSE_LOG"
        ( cd "$FM_FAKE_PANE_PATH" && SHELL="${FM_FAKE_SUBSHELL:?}" bash -c "$payload" ) \
          >> "${FM_FAKE_TREEHOUSE_LOG:-/dev/null}" 2>&1 || true
        ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

# fm_test_treehouse_standin_shell <path>
# Writes the script FM_FAKE_SUBSHELL names for fm_test_fake_tmux_spawn_treehouse:
# the shell a pane runs inside the slot Treehouse handed it. The stand-in only
# records where it was entered and exits at once, so the slot is left exactly as
# it is once the worker that held it has stopped running - the state a recorded
# slot is in after a reboot.
fm_test_treehouse_standin_shell() {
  local path=$1
  cat > "$path" <<'SH'
#!/usr/bin/env bash
pwd -P > "$FM_FAKE_PANE_CWD_FILE"
SH
  chmod +x "$path"
}

# fm_test_fake_tmux_send <fakebin>
# Send-world tmux: logs send-keys -l payloads to FM_SEND_LOG, reports a numeric
# cursor_y, and renders an empty bordered composer so the submit path reads
# empty. Env knobs:
#   FM_FAKE_TMUX_SEND_FAIL=1  send-keys exits 1
#   FM_FAKE_TMUX_COMPOSER=pending  capture-pane shows leftover composer text
fm_test_fake_tmux_send() {
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    [ "${FM_FAKE_TMUX_SEND_FAIL:-0}" = 1 ] && exit 1
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
      printf '%s' "${1:-}" >> "${FM_SEND_LOG:-/dev/null}"
    fi
    exit 0
    ;;
  display-message)
    for a in "$@"; do
      case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac
    done
    printf 'fakepane\n'
    exit 0
    ;;
  capture-pane)
    if [ "${FM_FAKE_TMUX_COMPOSER:-}" = pending ]; then
      printf '╭──────────────╮\n│ leftover txt │\n╰──────────────╯\n'
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0
    ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

# fm_test_fake_tmux_claude_pane <fakebin>
# Doorbell-world tmux: one Claude worker pane whose whole model is the files
# under $FM_FAKE_PANE_DIR, so a test can drive the real fm-send, fm-control, and
# fm_task_inbox_ring against a screen it chooses and read back exactly which
# bytes reached the pane:
#   command            the pane's foreground process name, the agent-state
#                      classifier's input (default claude)
#   pane               a static screen capture-pane prints verbatim; absent, the
#                      pane renders an idle Claude composer holding `composer`
#   composer           the composer's text: send-keys -l appends to it and Enter
#                      submits it
#   literal            every send-keys -l payload, one per line
#   keys               every named key sent, one per line (Enter included)
#   submits            `SUBMIT: <text>` for every Enter that submitted text
#   scrollback         rows above the viewport, returned only by a capture that
#                      starts above it (-S below -0), as tmux does
#   dismiss-on-escape  when present, Escape deletes `pane`, so the screen falls
#                      back to the idle composer as a cancelled dialog does
#   fail-key           a key name whose send-keys exits 1
#   capture-fail       when present, capture-pane exits 1
#   windows            list-windows output (default fm-t1)
fm_test_fake_tmux_claude_pane() {
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=${FM_FAKE_PANE_DIR:?FM_FAKE_PANE_DIR is required}
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
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$payload" >> "$D/literal"
      printf '%s' "$payload" >> "$D/composer"
    else
      if [ -f "$D/fail-key" ] && [ "$(cat "$D/fail-key")" = "$payload" ]; then
        exit 1
      fi
      printf '%s\n' "$payload" >> "$D/keys"
      case "$payload" in
        Enter)
          if [ -s "$D/composer" ]; then
            printf 'SUBMIT: %s\n' "$(cat "$D/composer")" >> "$D/submits"
            : > "$D/composer"
          fi
          ;;
        Escape)
          [ ! -f "$D/dismiss-on-escape" ] || rm -f "$D/pane"
          ;;
      esac
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '2\n'; exit 0 ;;
        *pane_current_command*) if [ -f "$D/command" ]; then cat "$D/command"; else printf claude; fi; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    [ ! -f "$D/capture-fail" ] || exit 1
    shift
    start=
    while [ $# -gt 0 ]; do
      [ "$1" != -S ] || start=${2:-}
      shift
    done
    if [ -f "$D/scrollback" ] && [ -n "$start" ] && [ "$start" != -0 ]; then
      cat "$D/scrollback"
    fi
    if [ -f "$D/pane" ]; then
      cat "$D/pane"
      exit 0
    fi
    rule=$(printf '─%.0s' $(seq 64))
    printf '● done\n%s\n' "$rule"
    if [ -s "$D/composer" ]; then
      fold -w 60 "$D/composer" | awk 'NR == 1 { print "❯ " $0; next } { print "  " $0 }'
    else
      printf '❯ \n'
    fi
    printf '%s\n  ? for shortcuts\n' "$rule"
    exit 0 ;;
  list-windows)
    if [ -f "$D/windows" ]; then cat "$D/windows"; else printf 'fm-t1\n'; fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

# The four strings the auto-mode setup dialog guard matches on, written out here
# independently of bin/fm-task-inbox-lib.sh so a change to either side fails a
# test instead of passing quietly.
FM_TEST_DIALOG_TITLE='Teach auto mode about your environment?'
FM_TEST_DIALOG_OFFER_BODY='Auto mode works better when it knows your environment'
FM_TEST_DIALOG_CONFIRM_BODY='Claude Code reads this project, your recent Claude sessions'
FM_TEST_DIALOG_SCAN_ROW='Scanning your repo and recent sessions'

# fm_test_claude_dialog_screen <name>
# One Claude screen on stdout, for the fake Claude pane's `pane` file. The
# dialog screens follow the UI structure docs/verification/runtime-backends.md
# "Claude auto-mode setup dialog markers" derives from Claude Code's own
# component code: a frame rule, the title and body, numbered option rows with
# the focus pointer, and a footer hint row. The real dialog is never opened to
# get them, because opening it sends transcript-derived material to a model.
# Every screen that shows a dialog carries exactly ONE of the four strings
# above and rewords the rest, as a vendor rewording would leave them, so a
# verdict on it can only have come from that string; `offer` is the whole
# dialog and carries two. The confirm step's form rows, the status view's
# elapsed-time subtitle, and the quoted notes are stand-ins, not claims about
# Claude's exact text.
#   real dialog, classic layout:    title offer-body confirm-body scan-row
#                                   scan-row-wrapped scan-status wrapped-title offer
#   real dialog, other layouts:     title-fullscreen title-no-frame title-no-footer
#                                   scan-status-fullscreen scan-status-no-frame
#   a string quoted in ordinary output, no dialog on the screen:
#                                   quoted-title quoted-title-at-row-start
#                                   quoted-offer-body quoted-confirm-body
#                                   quoted-scan-row quoted-scan-row-at-row-start
#                                   quoted-scan-row-bullet rule-then-title
#                                   rule-then-scan-status status-then-scan-status
#                                   mock-in-output quoted-in-other-dialog
#   a quote above a real dialog:    quote-above-dialog
#   nothing to match:               auto-mode-footer near-miss bare-prompt blank empty
fm_test_claude_dialog_screen() {
  local rule full idle opts foot reworded note dash status1 status2 statusfoot
  rule=$(printf '─%.0s' $(seq 64))
  full=$(printf '▔%.0s' $(seq 64))
  idle=$(printf '%s\n❯ \n%s\n  ? for shortcuts' "$rule" "$rule")
  opts=$'  ❯ 1. Yes\n    2. Not now\n    3. Don\'t show again'
  foot='  Enter to confirm · Esc to cancel'
  reworded='  Set up auto mode for this project. Takes about a minute.'
  note=$'  Learnings\n  - Claude Code can offer the auto-mode setup dialog ("'"$FM_TEST_DIALOG_TITLE"$'")\n    at the end of a turn; the launch setting turns that offer off for workers.'
  dash=$(printf '\342\200\224')
  status1="  $FM_TEST_DIALOG_SCAN_ROW, then drafting an auto-mode"
  status2="  proposal. The review will pop up when it’s ready."
  statusfoot='  ← to go back · Esc/Enter/Space to close · x to stop'
  case "$1" in
    title)
      printf '● done\n\n%s\n  %s\n\n%s\n\n%s\n\n%s\n' "$rule" "$FM_TEST_DIALOG_TITLE" "$reworded" "$opts" "$foot" ;;
    offer)
      printf '● done\n\n%s\n  %s\n\n  %s. Takes about a minute.\n\n%s\n\n%s\n' \
        "$rule" "$FM_TEST_DIALOG_TITLE" "$FM_TEST_DIALOG_OFFER_BODY" "$opts" "$foot" ;;
    offer-body)
      printf '● done\n\n%s\n  Teach auto mode about your setup?\n\n  %s. Takes about a minute.\n\n%s\n\n%s\n' \
        "$rule" "$FM_TEST_DIALOG_OFFER_BODY" "$opts" "$foot" ;;
    wrapped-title)
      printf '● done\n\n%s\n  Teach auto mode about\n  your environment?\n\n%s\n\n%s\n\n%s\n' "$rule" "$reworded" "$opts" "$foot" ;;
    confirm-body)
      printf '● done\n\n%s\n  Set up auto mode for this project?\n\n  %s, and optionally\n  your shell history and other repositories. Claude analyzes this data and\n  customizes auto mode to make better decisions.\n\n  How you use Claude here   Mixed\n  Also scan shell history   on\n  Also scan your other repos   off\n\n  Continue\n\n  ←/→ to change usage · Enter to continue · Esc to cancel\n' \
        "$rule" "$FM_TEST_DIALOG_CONFIRM_BODY" ;;
    scan-row)
      printf '● done\n\n✻  %s…\nthen drafting a proposal %s this can take a moment (Esc to cancel)\n' "$FM_TEST_DIALOG_SCAN_ROW" "$dash" ;;
    scan-row-wrapped)
      printf '● done\n\n✻  %s…\nthen drafting a proposal %s this can take\na moment (Esc to cancel)\n' "$FM_TEST_DIALOG_SCAN_ROW" "$dash" ;;
    scan-status)
      printf '● done\n\n%s\n  Auto-mode setup scan\n  1m 12s\n\n  Status: running\n\n%s\n%s\n\n%s\n' "$rule" "$status1" "$status2" "$statusfoot" ;;
    scan-status-fullscreen)
      printf '● done\n\n%s\n Auto-mode setup scan\n 0m 40s\n\n Status: running\n\n%s\n%s\n\n Esc/Enter/Space to close · x to stop\n' "$full" "$status1" "$status2" ;;
    scan-status-no-frame)
      printf '● done\n\n Auto-mode setup scan\n 0m 40s\n\n Status: running\n\n%s\n%s\n\n Esc/Enter/Space to close · x to stop\n' "$status1" "$status2" ;;
    title-fullscreen)
      printf '● done\n\n%s\n Teach auto mode about your environment?\n\n Set up auto mode for this project. Takes about a minute.\n\n ❯ 1. Yes\n   2. Not now\n   3. Don\x27t show again\n\n Enter to confirm · Esc to cancel\n' "$full" ;;
    title-no-frame)
      printf '● done\n\n Teach auto mode about your environment?\n\n Set up auto mode for this project. Takes about a minute.\n\n ❯ 1. Yes\n   2. Not now\n   3. Don\x27t show again\n\n Enter to confirm · Esc to cancel\n' ;;
    title-no-footer)
      printf '● done\n\n%s\n  %s\n\n%s\n\n%s\n\n  Press Ctrl-C again to cancel\n' "$rule" "$FM_TEST_DIALOG_TITLE" "$reworded" "$opts" ;;
    quoted-title)
      printf '● done\n\n%s\n\n%s\n' "$note" "$idle" ;;
    quoted-title-at-row-start)
      printf '● done\n\n%s is the title of the offer that the launch setting turns off.\n\n%s\n' "$FM_TEST_DIALOG_TITLE" "$idle" ;;
    quoted-offer-body)
      printf '● done\n\n  - The offer reads "%s. Takes about a minute."\n\n%s\n' "$FM_TEST_DIALOG_OFFER_BODY" "$idle" ;;
    quoted-confirm-body)
      printf '● done\n\n  - The wizard says: %s, and optionally\n    your shell history.\n\n%s\n' "$FM_TEST_DIALOG_CONFIRM_BODY" "$idle" ;;
    quoted-scan-row)
      printf '● done\n\n  - While it runs the status row shows "%s…" until it ends.\n\n%s\n' "$FM_TEST_DIALOG_SCAN_ROW" "$idle" ;;
    quoted-scan-row-at-row-start)
      printf '● done\n\n  - %s… appears while it runs.\n  - It stops when the proposal is ready.\n\n%s\n' "$FM_TEST_DIALOG_SCAN_ROW" "$idle" ;;
    quoted-scan-row-bullet)
      printf '● done\n\n  - %s…\n  - Esc to cancel stops it.\n\n%s\n' "$FM_TEST_DIALOG_SCAN_ROW" "$idle" ;;
    rule-then-scan-status)
      printf '● done\n\n%s\n%s, then drafting an auto-mode proposal is what the dialog says.\n\n%s\n' "$rule" "$FM_TEST_DIALOG_SCAN_ROW" "$idle" ;;
    status-then-scan-status)
      printf '● done\n\n  Status: running\n\n%s, then drafting an auto-mode proposal.\n\n%s\n' "$FM_TEST_DIALOG_SCAN_ROW" "$idle" ;;
    rule-then-title)
      printf '● done\n\n%s\n%s is covered in docs/configuration.md.\n\n%s\n' "$rule" "$FM_TEST_DIALOG_TITLE" "$idle" ;;
    mock-in-output)
      printf '● done\n\n  Here is what the offer looks like:\n\n  %s\n  ❯ 1. Yes\n    2. Not now\n    3. Don\x27t show again\n\n%s\n' "$FM_TEST_DIALOG_TITLE" "$idle" ;;
    quoted-in-other-dialog)
      printf '● done\n\n%s\n  Bash command\n\n    grep -rn "%s" docs\n\n  Do you want to proceed?\n  ❯ 1. Yes\n    2. Yes, and don\x27t ask again for grep commands\n    3. No, and tell Claude what to do differently (esc)\n' \
        "$rule" "$FM_TEST_DIALOG_TITLE" ;;
    quote-above-dialog)
      printf '● done\n\n%s\n\n%s\n  %s\n\n%s\n\n%s\n\n%s\n' "$note" "$rule" "$FM_TEST_DIALOG_TITLE" "$reworded" "$opts" "$foot" ;;
    auto-mode-footer) printf '● done\n%s\n❯ \n%s\n  ⏵⏵ auto mode on (shift+tab to cycle)\n' "$rule" "$rule" ;;
    near-miss) printf '● done\n%s\n❯ \n%s\n  Teach auto mode about your\n' "$rule" "$rule" ;;
    bare-prompt) printf '\n\n  ❯\n' ;;
    blank) printf '\n   \n\n \t\n' ;;
    empty) ;;
  esac
}

# fm_test_fake_ssh <fakebin> [name]
# Records argv to FM_SSH_LOG, consumes stdin, exits FM_FAKE_SSH_RC (default 0).
# Default name is fake-ssh so tests can point FM_SSH_BIN at it without
# shadowing a real ssh on PATH.
fm_test_fake_ssh() {
  local fakebin=$1 name=${2:-fake-ssh}
  cat > "$fakebin/$name" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' "$*" >> "${FM_SSH_LOG:-/dev/null}"
exit "${FM_FAKE_SSH_RC:-0}"
SH
  chmod +x "$fakebin/$name"
}

# fm_test_fake_sleep_noop <fakebin>
fm_test_fake_sleep_noop() {
  local fakebin=$1
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/sleep"
}

# fm_test_fake_sleep_log <fakebin>
# Records each requested duration to FM_SLEEP_LOG instead of sleeping.
fm_test_fake_sleep_log() {
  local fakebin=$1
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "${FM_SLEEP_LOG:-/dev/null}"
exit 0
SH
  chmod +x "$fakebin/sleep"
}

# --- spawn-world ------------------------------------------------------------

# fm_test_spawn_home <home> [harness]
# Minimal firstmate home layout plus watcher-liveness beat. Optional harness
# pin is written to config/crew-harness.
fm_test_spawn_home() {
  local home=$1 harness=${2-}
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  touch "$home/state/.last-watcher-beat"
  if [ -n "$harness" ]; then
    printf '%s\n' "$harness" > "$home/config/crew-harness"
  fi
}

# fm_test_spawn_brief <home> <id> [captain-intent]
fm_test_spawn_brief() {
  local home=$1 id=$2 intent=${3:-brief for $2}
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
$intent

## Firstmate spec
Exercise the spawn behavior under test.
EOF
}

# fm_test_make_spawn_fakebin <dir> [extra-exit0-tool...]
# Creates <dir>/fakebin with the spawn tmux stub, a no-op treehouse, and any
# extra exit-0 tools. Echoes the fakebin path.
fm_test_make_spawn_fakebin() {
  local dir=$1 fakebin
  shift
  fakebin=$(fm_fakebin "$dir")
  fm_test_fake_tmux_spawn "$fakebin"
  fm_fake_exit0 "$fakebin" treehouse "$@"
  printf '%s\n' "$fakebin"
}

# Drop-in name used by the spawn suites. Extra args are additional exit-0 tools
# (gh, gh-axi, pi, ...).
make_spawn_fakebin() {
  fm_test_make_spawn_fakebin "$@"
}

# fm_test_run_spawn <home> <pane-path> <fakebin> [fm-spawn args...]
# Common spawn env. Extra variables in the caller (GROK_HOME, FM_FAKE_LAUNCH_LOG,
# CLAUDE_CONFIG_DIR, ...) are inherited. Does not add --mode/--yolo; ship tests
# that need a delivery contract pass those flags themselves.
fm_test_run_spawn() {
  local home=$1 pane=$2 fakebin=$3
  shift 3
  # A claude spawn pre-registers workspace trust in the launching user's own
  # store (bin/fm-claude-trust.sh), so every spawn here runs against a throwaway
  # HOME; without it the suite would write the developer's real ~/.claude.json.
  # CLAUDE_CONFIG_DIR must be pinned too, and pinned EMPTY: the script resolves
  # the store as ${CLAUDE_CONFIG_DIR:-${HOME:-}}, so a value inherited from the
  # developer's shell would beat the throwaway HOME and the sandbox would not
  # hold, while an empty value falls through to it. Empty rather than a path
  # because bin/fm-spawn.sh prefixes the launch only when the value is non-empty,
  # so every launch-shape assertion in the suite keeps reading the same command.
  # A test that needs the set case opts in through FM_TEST_CLAUDE_CONFIG_DIR.
  local spawn_home=$home/user-home
  mkdir -p "$spawn_home"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$spawn_home" \
    CLAUDE_CONFIG_DIR="${FM_TEST_CLAUDE_CONFIG_DIR:-}" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="${TMUX:-fake,1,0}" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$@" 2>&1
}

# --- send-world stubs -------------------------------------------------------

# make_stubs <dir>
# Send-world fakebin: send tmux + no-op sleep. Echoes the fakebin path.
# Suites that need recording sleep, herdr, or ssh add those on top of this
# fakebin (or replace sleep via fm_test_fake_sleep_log).
make_stubs() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_test_fake_tmux_send "$fakebin"
  fm_test_fake_sleep_noop "$fakebin"
  printf '%s\n' "$fakebin"
}
