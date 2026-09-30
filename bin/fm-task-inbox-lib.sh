#!/usr/bin/env bash
# fm-task-inbox-lib.sh - the per-task steering inbox: durable records plus a
# constant doorbell.
#
# ONE owner of the steering-inbox contract: the record format, sequence
# allocation, the idempotent re-enqueue dedup, the handled/ acknowledgement,
# the self-describing doorbell line, and the watcher's re-ring ladder policy.
# bin/fm-send.sh writes and rings locally, the host-local remote steer leg
# (bin/fm-remote-secondmate-control.sh cmd_send) writes idempotently and rings
# on the remote host, bin/fm-watch.sh polls and re-rings, and the brief
# scaffold (bin/fm-brief.sh) tells the worker how to read and acknowledge;
# none of them restates the format.
#
# Design (captain-adopted, data/fm-send-reliability-reframe-s1/report.md): the
# payload moves to the filesystem, which is reliable; the terminal carries only
# a short constant doorbell line. While the endpoint remains available, that
# line does not need to be reliable because ringing it again is free. A
# duplicated doorbell is a no-op by construction (the worker finds the inbox
# empty or already handled), and a swallowed doorbell is detected by the
# absence of the worker's acknowledgement and re-rung on a bounded schedule.
# A positively dead or missing endpoint bypasses that schedule without being
# typed into, and its unhandled record surfaces through the ordinary stale wake
# into stuck-crewmate-recovery.
#
# Layout under <state-dir>:
#   <task>.inbox/NNN.msg       one durable steer, numeric sequence, atomic rename
#   <task>.inbox/handled/      the worker's `mv` here IS the acknowledgement
#   <task>.inbox/.seq.lock     serializes sequence allocation across writers
#                              (the session and the away daemon)
#   <task>.inbox/.ring-state   watcher re-ring ladder: "<msg>\t<count>\t<epoch>"
#   <task>.inbox/.escalated    oldest-message name already surfaced as stale,
#                              so later polls suppress another escalation
#
# Record format (fm_task_inbox_write / fm_task_inbox_body):
#   schema=fm-task-inbox.v1
#   at=<utc timestamp>
#   delivery=fire-and-forget   present only when the re-ring ladder must ignore it
#   --
#   <exact message text; newlines are legal; a marked secondmate request keeps
#    its from-firstmate marker and corr token verbatim in this body>
#
# Sequence numbers are never reused within a task: allocation scans both the
# inbox root and handled/, so a message is processed at most once per worker
# lifetime even if every doorbell is duplicated. Concurrent writers serialize
# on .seq.lock; the worst racing outcome is ordering, never loss.
#
# Re-ring ladder (fm_task_inbox_due_action): an unhandled message older than
# FM_TASK_INBOX_GRACE_SECS is due one delivery attempt per grace period; an
# attempt may ring or be skipped to protect another draft in a proven pending
# composer or to hold a Claude pane the guard below will not type into; an
# unsubmitted copy of this doorbell is retried. After
# FM_TASK_INBOX_RING_MAX attempts without an acknowledgement it escalates. The
# caller owns the busy and recovery-grade endpoint checks: a busy pane waits,
# while a positively dead or missing endpoint skips delivery and the ladder and
# escalates directly. This library owns only the schedule and escalation marker.
# If attempt bookkeeping cannot be persisted while the record remains unhandled,
# the caller surfaces that failure instead of retrying silently; a concurrently
# removed inbox is a quiet no-op. Escalation deliberately queues the wake before
# writing the deduplication marker: normal polls surface a message once, while a
# crash or marker failure may produce a rare duplicate rather than silently lose
# a wake.
#
# Inbox paths containing bytes outside printable ASCII are unsupported. The
# doorbell refuses them rather than sending terminal control bytes to a pane.
#
# Claude pane guard (fm_task_inbox_claude_dialog_guard, run by every ring before
# it types): only a task whose own meta records a claude harness is checked, and
# the ring is held in two cases. Either way nothing is typed and no Enter is
# sent, the record stays durable for the ladder's next attempt,
# FM_TASK_INBOX_RING_NOTICE names the task and why, and the held attempt still
# spends ladder budget, so a pane that stays held escalates as the ordinary
# stale wake instead of retrying silently.
#   Dialog (the ring returns 4): Claude Code offers /auto-mode-setup at the end
#   of a turn to an auto-mode worker, with Yes as the first, focused option, so
#   a doorbell's Enter would accept an offer whose wizard then scans the
#   project's recent session transcripts for a model request. A visible screen
#   showing the dialog, or the wizard or scan screen that follows it, is
#   therefore never typed into; fm_task_inbox_claude_dialog_markers owns what
#   counts as showing it, and text that merely quotes the dialog does not.
#   Escape, the dialog's cancel key (Not now, never Yes), is delivered through
#   bin/fm-control.sh's interrupt verb only when the worker's semantic busy state
#   reads idle, because a busy turn must not be interrupted.
#   Unreadable screen (the ring returns 5): when the backend's own capture of
#   the screen fails or comes back empty, nothing shows whether that dialog is
#   up, so the ring holds the same way, and sends no Escape either because a key
#   sent blind could cancel a turn. Unreadable is decided from that capture
#   result alone, never from a string the vendor renders.
# bin/fm-spawn.sh's per-launch skillOverrides is the primary control for the
# dialog; this guard backstops a worker launched without it.
# docs/verification/runtime-backends.md "Claude auto-mode setup dialog markers"
# records the evidence for the dialog's strings and UI structure and the live
# guard that refreshes it.
#
# fm_task_inbox_ring requires bin/fm-backend.sh's dispatch (sourced below); the
# other helpers are dependency-light. Sourced by bin/fm-send.sh, bin/fm-watch.sh,
# and tests. No side effects on source beyond its sourced libraries.
#
# Tunables (env):
#   FM_TASK_INBOX_GRACE_SECS   default 90; delivery-attempt grace and spacing
#   FM_TASK_INBOX_RING_MAX     default 3; delivery attempts before escalation

_FM_TASK_INBOX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# All dependencies are canonical lint roots in their own right. Keep them as
# analysis boundaries here so ShellCheck's external-source traversal does not
# recursively duplicate the full backend graph for every inbox consumer.
# shellcheck source=/dev/null
. "$_FM_TASK_INBOX_LIB_DIR/fm-wake-lib.sh"
# shellcheck source=/dev/null
. "$_FM_TASK_INBOX_LIB_DIR/fm-backend.sh"
# shellcheck source=/dev/null
. "$_FM_TASK_INBOX_LIB_DIR/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$_FM_TASK_INBOX_LIB_DIR/fm-busy-lib.sh"

FM_TASK_INBOX_SCHEMA='fm-task-inbox.v1'
# Set by every fm_task_inbox_ring call: empty unless the ring returned 4 or 5,
# when it is one sentence naming the task, why the guard held the ring, and what
# it did.
FM_TASK_INBOX_RING_NOTICE=''
FM_TASK_INBOX_GRACE_DEFAULT=90
FM_TASK_INBOX_RING_MAX_DEFAULT=3
FM_TASK_INBOX_LOCK_WAIT_DEFAULT=5

fm_task_inbox_grace_secs() {
  local g=${FM_TASK_INBOX_GRACE_SECS:-$FM_TASK_INBOX_GRACE_DEFAULT}
  case "$g" in ''|*[!0-9]*) g=$FM_TASK_INBOX_GRACE_DEFAULT ;; esac
  printf '%s' "$g"
}

fm_task_inbox_ring_max() {
  local m=${FM_TASK_INBOX_RING_MAX:-$FM_TASK_INBOX_RING_MAX_DEFAULT}
  case "$m" in ''|*[!0-9]*) m=$FM_TASK_INBOX_RING_MAX_DEFAULT ;; esac
  printf '%s' "$m"
}

fm_task_inbox_dir() {  # <state-dir> <task-id>
  printf '%s/%s.inbox' "$1" "$2"
}

fm_task_inbox_handled_dir() {  # <state-dir> <task-id>
  printf '%s/%s.inbox/handled' "$1" "$2"
}

# Numeric sequence of one record basename, or fail for a non-record name.
fm_task_inbox_seq_of() {  # <basename>
  local n=${1%.msg}
  [ "$n" != "$1" ] || return 1
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$((10#$n))"
}

# Next unused sequence, scanning the inbox root AND handled/ so an
# acknowledged sequence is never reissued. Caller must hold .seq.lock.
fm_task_inbox_next_seq() {  # <inbox-dir>
  local dir=$1 max=0 d f n
  for d in "$dir" "$dir/handled"; do
    for f in "$d"/*.msg; do
      [ -e "$f" ] || continue
      n=$(fm_task_inbox_seq_of "${f##*/}") || continue
      [ "$n" -le "$max" ] || max=$n
    done
  done
  printf '%03d' "$((max + 1))"
}

fm_task_inbox_lock_acquire() {  # <lock-path>
  local lock=$1 wait=${FM_TASK_INBOX_LOCK_WAIT_SECS:-$FM_TASK_INBOX_LOCK_WAIT_DEFAULT}
  local deadline probe
  case "$wait" in ''|*[!0-9]*) wait=$FM_TASK_INBOX_LOCK_WAIT_DEFAULT ;; esac
  probe=$(mktemp "${lock%/*}/.lock-probe.XXXXXX") || return 1
  rm -f "$probe" || return 1
  if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
    fm_lock_try_create "$lock" && return 0
  fi
  deadline=$(( $(date +%s) + wait ))
  while ! fm_lock_try_acquire "$lock"; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 0.1
  done
}

# Write one record into the next sequence slot: temp-write, then atomic
# rename. Prints the record path. Caller must hold .seq.lock.
_fm_task_inbox_write_record_locked() {  # <inbox-dir> <text> [delivery-mode]
  local dir=$1 text=$2 delivery_mode=${3:-} seq tmp rec status=0
  seq=$(fm_task_inbox_next_seq "$dir")
  rec="$dir/$seq.msg"
  tmp=$(mktemp "$dir/.staging.XXXXXX") || return 1
  {
    printf 'schema=%s\n' "$FM_TASK_INBOX_SCHEMA"
    printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [ "$delivery_mode" != fire-and-forget ] || printf 'delivery=fire-and-forget\n'
    printf -- '--\n'
    printf '%s' "$text"
  } > "$tmp" && mv "$tmp" "$rec" || status=1
  [ "$status" -eq 0 ] || { rm -f "$tmp"; return 1; }
  printf '%s' "$rec"
}

# Durably enqueue one steer: temp-write, then atomic rename into the next
# sequence slot. Prints the record path. Fails without a partial record.
fm_task_inbox_write() {  # <state-dir> <task-id> <text> [delivery-mode]
  local state=$1 task=$2 text=$3 delivery_mode=${4:-} dir lock rec status=0
  dir=$(fm_task_inbox_dir "$state" "$task")
  mkdir -p "$dir/handled" || return 1
  lock="$dir/.seq.lock"
  fm_task_inbox_lock_acquire "$lock" || return 1
  rec=$(_fm_task_inbox_write_record_locked "$dir" "$text" "$delivery_mode") || status=1
  fm_lock_release "$lock"
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$rec"
}

# Durably enqueue one steer at most once: when a record with the exact same
# body already exists - unhandled or already acknowledged in handled/ - no new
# record is written and the existing record's path is printed instead.
# This is the enqueue primitive for a transport that can fail with completion
# unknown (the remote steer leg over ssh): the caller's safe recovery is to run
# the same enqueue again, and this dedup is what makes the re-run land on the
# same record instead of a duplicate the worker would act on twice. Two
# distinct logical requests never collapse in practice because a marked
# secondmate request embeds a per-request correlation token in its body. The
# local plane keeps plain fm_task_inbox_write: its outcome is synchronous, so
# a repeated identical local steer is a deliberate new instruction.
fm_task_inbox_write_idempotent() {  # <state-dir> <task-id> <text> [delivery-mode]
  local state=$1 task=$2 text=$3 delivery_mode=${4:-} dir lock want have f rec='' status=0
  dir=$(fm_task_inbox_dir "$state" "$task")
  mkdir -p "$dir/handled" || return 1
  lock="$dir/.seq.lock"
  fm_task_inbox_lock_acquire "$lock" || return 1
  if want=$(mktemp "$dir/.dedup.XXXXXX") && have=$(mktemp "$dir/.dedup.XXXXXX"); then
    if printf '%s' "$text" > "$want"; then
      for f in "$dir"/*.msg "$dir/handled"/*.msg; do
        if [ ! -e "$f" ]; then
          case "$f" in
            "$dir"/*.msg)
              f="$dir/handled/${f##*/}"
              [ -e "$f" ] || continue
              ;;
            *) continue ;;
          esac
        fi
        if [ "$delivery_mode" = fire-and-forget ]; then
          fm_task_inbox_is_fire_and_forget "$f" || continue
        elif fm_task_inbox_is_fire_and_forget "$f"; then
          continue
        fi
        if ! fm_task_inbox_body "$f" > "$have" 2>/dev/null; then
          case "$f" in
            "$dir"/*.msg)
              f="$dir/handled/${f##*/}"
              fm_task_inbox_body "$f" > "$have" 2>/dev/null || continue
              ;;
            *) continue ;;
          esac
        fi
        cmp -s "$want" "$have" || continue
        [ ! -e "$dir/handled/${f##*/}" ] || f="$dir/handled/${f##*/}"
        rec=$f
        break
      done
    else
      status=1
    fi
    rm -f "$want" "$have"
  else
    rm -f "${want:-}" 2>/dev/null || true
    status=1
  fi
  if [ "$status" -eq 0 ] && [ -z "$rec" ]; then
    rec=$(_fm_task_inbox_write_record_locked "$dir" "$text" "$delivery_mode") || status=1
  fi
  fm_lock_release "$lock"
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$rec"
}

# The exact enqueued text back out of a record.
fm_task_inbox_body() {  # <record-path>
  local line
  [ -f "$1" ] || return 1
  while IFS= read -r line; do
    if [ "$line" = -- ]; then
      cat
      return 0
    fi
  done < "$1"
  return 1
}

# The constant self-describing doorbell line for the inbox containing a record.
# Self-describing on purpose: a worker whose brief predates the inbox contract
# still receives the complete instruction in the line itself. The leading `: `
# is the POSIX shell no-op, so the same line typed into a pane whose agent has
# exited (a bare shell) runs nothing; see the dead-pane note in the header.
# A non-printable path fails without output so terminal controls never reach
# the pane's line discipline.
fm_task_inbox_doorbell_line() {  # <record-path>
  local dir=${1%/*} abs quoted LC_ALL=C
  abs=$(cd "$dir" 2>/dev/null && pwd) || abs=$dir
  abs=${abs%/handled}
  case "$abs" in
    *[![:print:]]*) return 1 ;;
  esac
  quoted=$(printf '%s' "$abs" | sed "s/'/'\\\\''/g")
  printf ": Firstmate instruction waiting: list '%s'/*.msg and, in numeric order, read and act on each, then mv each handled file to '%s'/handled/." \
    "$quoted" "$quoted"
}

# What counts as Claude's auto-mode setup dialog being shown: the one statement
# of this contract, which the header above, bin/fm-send.sh, bin/fm-watch.sh, and
# the docs only point at. The guard must never type into the dialog, but a screen
# that merely quotes its words without enough matching structure - a printed
# learnings note or another dialog's command text - is not the dialog, and
# holding the ring for one blocks a steer and makes the watcher's stale wake
# name a dialog that is not there. So a string counts only inside the dialog's own UI structure, read
# from the visible rows with whitespace folded, so a string the pane wrapped
# still matches:
#   head strings (the offer's title and body, the wizard confirm step's body)
#     must BEGIN a row, and two of three structural signals must go with them: a
#     frame rule (a row opening with eight or more `─` or `▔`) within eight rows
#     above; two or more consecutive option rows with consecutive numbers and
#     a focus pointer on any one (`❯ `, or `> ` where the terminal is not unicode)
#     within 24 rows below, before any other rule; a footer hint row within the
#     same bound (a row opening with a key hint, `<keys> to <action>`, that names
#     Enter: `Enter to confirm`, `Enter to continue`
#     after `←/→ to change usage`, `Esc/Enter/Space to close`) below, before any
#     other rule.
#   the scan string is read on the scan's two screens. In the wizard's spinner it
#     must BEGIN a row, after at most one leading space-delimited spinner token
#     (a token with no printable ASCII, or a lone `*`, never a list bullet),
#     folding up to three following rows until the glyph-stripped message
#     reaches the marker length. `Esc to cancel` must appear in up to four
#     folded rows after the last consumed message row;
#     both folds stop at a blank row or frame rule, so the message and the hint
#     itself may wrap on a narrow pane. In the background-task status view it
#     opens the body under a `Status: <state>` row, so it must BEGIN a row and
#     two of three signals must go with it: a
#     frame rule within eight rows above, a `Status: <state>` row within three
#     rows above, a footer hint row within eight rows below, before any other
#     rule.
# Any one string that passes is a positive verdict, so a vendor rewording of
# another cannot blind the guard. Two of the three signals, not all three,
# because the shared dialog component draws its frame as `─` in the classic
# layout and `▔` in the fullscreen modal, can be told to hide its frame or its
# footer, and swaps the footer while an exit is pending: one absent signal must
# not blind the guard. Quotes with insufficient structure do not match; a
# pasted copy with enough matching structure is indistinguishable from the
# dialog and holds the ring. The shapes come from Claude Code's own component
# code, never from provoking the dialog: opening it, or running /auto-mode-setup,
# would send transcript-derived
# material to a model.
# docs/verification/runtime-backends.md "Claude auto-mode setup dialog markers"
# records what was derived, from which version, and what it leaves unchecked,
# and tests/fm-claude-automode-dialog-live-e2e.test.sh fails, naming the
# installed version, when the binary stops carrying these strings or shapes.
#
# One `<kind><TAB><string>` line each: `head` strings are the offer's title (the
# wizard's confirm step reuses it), the offer's body, and the confirm step's
# body; `scan` is the start of the running scan's message, on both its screens.
fm_task_inbox_claude_dialog_markers() {
  printf '%s\t%s\n' \
    head 'Teach auto mode about your environment?' \
    head 'Auto mode works better when it knows your environment' \
    head 'Claude Code reads this project, your recent Claude sessions' \
    scan 'Scanning your repo and recent sessions'
}

# Print the first marker the screen on stdin shows inside its own UI structure
# (the contract above), or fail. LC_ALL=C makes awk walk bytes, so the multibyte
# glyphs match as literal byte strings in every locale.
_fm_task_inbox_claude_dialog_match() {
  FM_TASK_INBOX_DIALOG_MARKERS=$(fm_task_inbox_claude_dialog_markers) LC_ALL=C awk '
    # Row t with up to three following rows folded in while the marker of length
    # len is not yet whole, so a string the pane wrapped still matches.
    function fold(t, len,   s, k) {
      s = txt[t]
      for (k = 1; k <= 3 && length(s) < len && t + k <= n; k++) {
        if (txt[t + k] == "" || isrule[t + k]) break
        s = s " " txt[t + k]
      }
      return s
    }
    # Whether a frame rule sits within eight rows above row t.
    function ruleabove(t,   r) {
      for (r = t - 1; r >= 1 && r >= t - 8; r--) if (isrule[r]) return 1
      return 0
    }
    BEGIN {
      nm = split(ENVIRON["FM_TASK_INBOX_DIALOG_MARKERS"], line, "\n")
      for (i = 1; i <= nm; i++) {
        tab = index(line[i], "\t")
        kind[i] = substr(line[i], 1, tab - 1)
        mark[i] = substr(line[i], tab + 1)
      }
      n = 0
    }
    {
      row = $0
      gsub(/\r/, "", row)
      gsub("\302\240", " ", row)
      gsub(/[ \t]+/, " ", row)
      sub(/^ /, "", row)
      sub(/ $/, "", row)
      txt[++n] = row
    }
    END {
      for (i = 1; i <= n; i++) {
        row = txt[i]
        run = 0
        rest = row
        while (substr(rest, 1, 3) == "─" || substr(rest, 1, 3) == "▔") { run++; rest = substr(rest, 4) }
        isrule[i] = (run >= 8)
        rest = row
        ptr[i] = 0
        if (substr(rest, 1, 4) == "❯ ") { ptr[i] = 1; rest = substr(rest, 5) }
        else if (substr(rest, 1, 2) == "> ") { ptr[i] = 1; rest = substr(rest, 3) }
        isopt[i] = (rest ~ /^[0-9]+\. [^ ]/)
        if (isopt[i]) num[i] = rest + 0
        isfoot[i] = (row ~ /^[^ ]+ to [a-z]/ && row ~ /(^|[ \/])Enter([ \/]|$)/)
        isstatus[i] = (row ~ /^Status: [A-Za-z]/)
      }
      # Option rows count only as a run of two or more consecutive numbers that
      # carries the focus pointer on one of them.
      runs = 0
      for (i = 1; i <= n; i++) {
        if (!isopt[i]) continue
        if (i > 1 && isopt[i - 1] && num[i - 1] + 1 == num[i]) rid[i] = rid[i - 1]
        else rid[i] = ++runs
        runlen[rid[i]]++
        if (ptr[i]) runptr[rid[i]] = 1
      }
      for (i = 1; i <= n; i++) isselect[i] = (isopt[i] && runlen[rid[i]] >= 2 && runptr[rid[i]])
      for (m = 1; m <= nm; m++) {
        len = length(mark[m])
        if (kind[m] == "head") {
          for (t = 1; t <= n; t++) {
            if (substr(fold(t, len), 1, len) != mark[m]) continue
            options = 0
            footer = 0
            for (r = t + 1; r <= n && r <= t + 24; r++) {
              if (isrule[r]) break
              if (isselect[r]) options = 1
              if (isfoot[r]) footer = 1
            }
            if (ruleabove(t) + options + footer >= 2) { print mark[m]; exit 0 }
          }
        } else if (kind[m] == "scan") {
          for (t = 1; t <= n; t++) {
            rest = txt[t]
            if (match(rest, /^[^ ]+ /)) {
              tok = substr(rest, 1, RLENGTH - 1)
              if (tok == "*" || tok !~ /[!-~]/) rest = substr(rest, RLENGTH + 1)
            }
            last = t
            for (k = 1; k <= 3 && length(rest) < len && t + k <= n; k++) {
              if (txt[t + k] == "" || isrule[t + k]) break
              rest = rest " " txt[t + k]
              last = t + k
            }
            if (substr(rest, 1, len) == mark[m]) {
              subtitle = ""
              for (r = last + 1; r <= n && r <= last + 4; r++) {
                if (txt[r] == "" || isrule[r]) break
                subtitle = subtitle (subtitle == "" ? "" : " ") txt[r]
              }
              if (index(subtitle, "Esc to cancel") > 0) { print mark[m]; exit 0 }
            }
            if (substr(fold(t, len), 1, len) != mark[m]) continue
            status = 0
            for (r = t - 1; r >= 1 && r >= t - 3; r--) if (isstatus[r]) status = 1
            footer = 0
            for (r = t + 1; r <= n && r <= t + 8; r++) {
              if (isrule[r]) break
              if (isfoot[r]) footer = 1
            }
            if (ruleabove(t) + status + footer >= 2) { print mark[m]; exit 0 }
          }
        }
      }
      exit 1
    }'
}

# Print the first marker on <target>'s visible screen when task <id> in
# <state-dir> records a claude harness and the screen shows it inside its own UI
# structure. Returns 0 with the marker printed, 1 when the task is not a Claude
# task or its screen shows no marker in that structure, and 2 when it is a Claude
# task whose screen cannot be read: the backend's capture failed, or came back
# with nothing on it once whitespace is folded away. Only a Claude target is
# checked: the harness comes from the task's own meta, so a task with no meta or
# another harness is never blamed for a dialog it cannot show, or for a screen
# it cannot read. The viewport is read where the backend has a verified
# viewport-only capture, so a dialog that was dismissed and scrolled away is
# never mistaken for a live one; the others fall back to the composer
# pre-check's bounded capture.
fm_task_inbox_claude_dialog_shown() {  # <state-dir> <task-id> <backend> <target> [expected-label]
  local meta=$1/$2.meta screen flat marker
  [ -f "$meta" ] || return 1
  [ "$(fm_control_harness_family "$(fm_meta_get "$meta" harness)" 2>/dev/null)" = claude ] || return 1
  fm_backend_source "$3" || return 2
  if fm_backend_visible_capture_supported "$3"; then
    screen=$(fm_backend_visible_capture "$3" "$4" "${5:-}" 2>/dev/null) || return 2
  else
    screen=$(fm_backend_capture "$3" "$4" "$FM_COMPOSER_CAPTURE_LINES" "${5:-}" 2>/dev/null) || return 2
  fi
  flat=$(printf '%s' "$screen" | LC_ALL=C tr -s '[:space:]' ' ')
  case "$flat" in
    ''|' ') return 2 ;;
  esac
  marker=$(printf '%s\n' "$screen" | _fm_task_inbox_claude_dialog_match) || return 1
  printf '%s' "$marker"
}

# The pre-typing guard behind fm_task_inbox_ring's returns 4 and 5 (see the
# header). Returns 0 when the record's task records a claude harness and its
# screen shows a marker, and 2 when it records one but the screen cannot be
# read, setting FM_TASK_INBOX_RING_NOTICE for either; 1 leaves the ring exactly
# as it was. The task comes from the record's own inbox directory, so a record
# outside a <task>.inbox rings as before.
# A busy or unclassified worker is not sent Escape: the offer is made between
# turns, but matching screen structure does not prove the worker is idle, and
# Escape during a working turn would cancel it. Nothing is typed in either
# case, so a worker whose screen shows the dialog but does not read idle is
# deferred, spends ring budget, and
# surfaces through the ladder's ordinary escalation rather than being
# interrupted.
fm_task_inbox_claude_dialog_guard() {  # <backend> <target> <record-path> [expected-label]
  local backend=$1 target=$2 rec=$3 label=${4:-} dir id state marker verdict out action shown_rc=0
  dir=$(cd "${rec%/*}" 2>/dev/null && pwd) || return 1
  dir=${dir%/handled}
  case "${dir##*/}" in
    ?*.inbox) ;;
    *) return 1 ;;
  esac
  id=${dir##*/}
  id=${id%.inbox}
  state=${dir%/*}
  marker=$(fm_task_inbox_claude_dialog_shown "$state" "$id" "$backend" "$target" "$label") || shown_rc=$?
  case "$shown_rc" in
    0) ;;
    2)
      FM_TASK_INBOX_RING_NOTICE="task $id is a Claude worker whose screen could not be read (the backend's capture failed or came back empty), so no text, no Enter, and no Escape were sent"
      return 2
      ;;
    *) return 1 ;;
  esac
  verdict=$(fm_busy_classify_meta "$state/$id.meta" "$id" "$state" 2>/dev/null) || verdict=
  verdict=${verdict%% *}
  if [ "$verdict" != idle ]; then
    action="Escape was not sent because the worker reads ${verdict:-unclassified} rather than idle"
  elif out=$(FM_HOME="${FM_HOME:-${state%/*}}" FM_STATE_OVERRIDE="$state" \
      "$_FM_TASK_INBOX_LIB_DIR/fm-control.sh" "$id" interrupt 2>&1 < /dev/null); then
    action="Escape, the dialog's cancel key, was delivered through fm-control interrupt"
  else
    action="fm-control interrupt failed (${out##*$'\n'}), so the dialog may still be open"
  fi
  FM_TASK_INBOX_RING_NOTICE="task $id is showing Claude Code's auto-mode setup dialog (matched \"$marker\"), so no text and no Enter were sent; $action"
}

# Ring the doorbell, best-effort: one endpoint-liveness pre-check, the Claude
# pane guard, one advisory composer pre-check, then the backend's submit
# machinery with a minimal retry budget, verdict discarded.
# Returns 0 rang, 1 skipped because the composer PROVENLY holds pending text
# other than our own doorbell (the watcher re-rings later), 2 the backend send
# failed, 3 skipped because the endpoint is positively dead or missing (nothing
# typed; recovery owns the record), 4 held because a Claude target's screen
# shows its auto-mode setup dialog, 5 held because a Claude target's screen
# could not be read. Both holds type nothing and send no Enter; the watcher
# re-rings later, FM_TASK_INBOX_RING_NOTICE says what the guard did, and the
# guard paragraph in the header owns the contract. No return value
# is delivery proof; the acknowledgement move is the only delivery signal.
# The composer skip is narrow: only an exact `pending` verdict can defer,
# because there our Enter could submit someone's real half-typed content.
# After the Claude pane guard permits typing, `pending-unproven` and `unknown`
# still ring - the worst outcome is a garbled
# CONSTANT line the worker recovers semantically, while skipping on ambiguous
# verdicts would starve a harness whose idle screen the classifier cannot
# positively identify (that classifier is advisory here by design).
# A pending composer holding exactly our own doorbell line is a previous ring
# whose Enter never landed, so on an agent not reported busy it is submitted
# rather than skipped; skipping it would block every later ring. On both paths
# a lost first Enter gets one confirmed retry.
fm_task_inbox_ring() {  # <backend> <target> <record-path> [expected-label]
  local backend=$1 target=$2 rec=$3 label=${4:-} line cstate verdict guard_rc=0
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_TASK_INBOX_RING_NOTICE=''
  case "$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || true)" in
    dead|missing) return 3 ;;
  esac
  if ! line=$(fm_task_inbox_doorbell_line "$rec"); then
    return 2
  fi
  # The guard's own codes: 0 held for the dialog, 2 held for an unreadable screen.
  fm_task_inbox_claude_dialog_guard "$backend" "$target" "$rec" "$label" || guard_rc=$?
  case "$guard_rc" in
    0) return 4 ;;
    2) return 5 ;;
  esac
  cstate=$(fm_backend_composer_state "$backend" "$target" "$label" 2>/dev/null) || cstate=unknown
  case "$cstate" in
    pending)
      fm_task_inbox_composer_holds "$backend" "$target" "$line" "$label" \
        && [ "$(fm_backend_busy_state "$backend" "$target" 2>/dev/null)" != busy ] \
        || return 1
      fm_backend_send_key "$backend" "$target" Enter "$label" >/dev/null 2>&1 || return 2
      sleep 0.3
      fm_task_inbox_composer_holds "$backend" "$target" "$line" "$label" || return 0
      fm_backend_send_key "$backend" "$target" Enter "$label" >/dev/null 2>&1 || return 2
      return 0
      ;;
  esac
  # Accepted residual race: terminal input and Enter are separate delivery
  # steps, so an agent exiting after the liveness check could leave a bare
  # shell only a suffix; the `: ` prefix protects complete lines only. Do not
  # add process-bound atomic delivery here unless an incident reopens this.
  if ! verdict=$(fm_backend_send_text_submit "$backend" "$target" "$line" 2 0.4 0.3 "$label" 2>/dev/null); then
    return 2
  fi
  # The verdict is read only to report a failed keystroke; every other value
  # (empty, pending, unknown, ...) is deliberately ignored, never proof.
  [ "$verdict" != send-failed ] || return 2
  return 0
}

# Whether the composer's content, ignoring line wrapping, is exactly <line>.
fm_task_inbox_composer_holds() {  # <backend> <target> <line> [expected-label]
  local cap held
  fm_backend_source "$1" || return 1
  cap=$(fm_backend_capture "$1" "$2" "$FM_COMPOSER_CAPTURE_LINES" "${4:-}" 2>/dev/null) || return 1
  held=$(fm_composer_extract_selected_content styled=0 "$cap") || return 1
  [ -n "$held" ] && [ "$(printf '%s' "$held" | tr -d '[:space:]')" = "$(printf '%s' "$3" | tr -d '[:space:]')" ]
}

fm_task_inbox_is_fire_and_forget() {  # <record-path>
  local rec=$1
  if [ ! -f "$rec" ]; then
    rec="${rec%/*}/handled/${rec##*/}"
    [ -f "$rec" ] || return 1
  fi
  awk '
    $0 == "--" { exit }
    $0 == "delivery=fire-and-forget" { found=1 }
    END { exit(found ? 0 : 1) }
  ' "$rec"
}

# Oldest escalation-tracked unhandled record, or fail when none is due.
fm_task_inbox_oldest_unhandled() {  # <state-dir> <task-id>
  local dir best='' best_n=0 f n
  dir=$(fm_task_inbox_dir "$1" "$2")
  for f in "$dir"/*.msg; do
    [ -e "$f" ] || continue
    fm_task_inbox_is_fire_and_forget "$f" && continue
    n=$(fm_task_inbox_seq_of "${f##*/}") || continue
    if [ -z "$best" ] || [ "$n" -lt "$best_n" ]; then
      best=$f
      best_n=$n
    fi
  done
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

# The re-ring ladder decision for one task. Prints exactly one of:
#   quiet                     nothing due (healthy, within grace or spacing,
#                             or already escalated for the current oldest)
#   ring <record-path>        one doorbell re-ring is due
#   escalate <record-path> <count>   attempt budget spent; surface as stale
# An empty inbox also resets the ladder bookkeeping so the next message starts
# a fresh ladder.
fm_task_inbox_due_action() {  # <state-dir> <task-id>
  local dir oldest base now grace max ladder rec_base count last
  dir=$(fm_task_inbox_dir "$1" "$2")
  if ! oldest=$(fm_task_inbox_oldest_unhandled "$1" "$2"); then
    rm -f "$dir/.ring-state" "$dir/.escalated" 2>/dev/null || true
    printf 'quiet'
    return 0
  fi
  base=${oldest##*/}
  grace=$(fm_task_inbox_grace_secs)
  if [ "$(fm_path_age "$oldest")" -lt "$grace" ]; then
    printf 'quiet'
    return 0
  fi
  count=0
  last=0
  ladder=$(cat "$dir/.ring-state" 2>/dev/null || true)
  IFS=$(printf '\t') read -r rec_base count last <<EOF
$ladder
EOF
  if [ -n "$rec_base" ] && [ "$rec_base" != "$base" ]; then
    # A different oldest message: the previous ladder is stale. An absent
    # ladder is left alone so a dead-pane escalation, which never rings and so
    # never writes one, keeps its marker (the marker check below still ignores
    # a marker naming some other message).
    count=0
    last=0
    rm -f "$dir/.escalated" 2>/dev/null || true
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ "$(cat "$dir/.escalated" 2>/dev/null || true)" = "$base" ]; then
    printf 'quiet'
    return 0
  fi
  max=$(fm_task_inbox_ring_max)
  if [ "$count" -ge "$max" ]; then
    printf 'escalate %s %s' "$oldest" "$count"
    return 0
  fi
  now=$(date +%s)
  if [ "$((now - last))" -lt "$grace" ]; then
    printf 'quiet'
    return 0
  fi
  printf 'ring %s' "$oldest"
}

# Advance the ladder after a delivery attempt. A failed ring, a composer-
# protected skip, or a Claude pane guard hold (a dialog or an unreadable screen)
# still consumes budget so no permanently blocked pane can retry silently
# forever. A positively dead or missing endpoint never enters the
# ladder: the watcher escalates it directly.
# A concurrently removed inbox is a successful no-op; otherwise failure means
# the caller must surface the unwritable ladder while the record remains
# unhandled.
fm_task_inbox_record_ring() {  # <state-dir> <task-id> <record-path>
  local dir base ladder rec_base count last
  dir=$(fm_task_inbox_dir "$1" "$2")
  base=${3##*/}
  count=0
  ladder=$(cat "$dir/.ring-state" 2>/dev/null || true)
  IFS=$(printf '\t') read -r rec_base count last <<EOF
$ladder
EOF
  [ "$rec_base" = "$base" ] || count=0
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  [ -d "$dir" ] || return 0
  if ! { printf '%s\t%s\t%s\n' "$base" "$((count + 1))" "$(date +%s)" > "$dir/.ring-state"; } 2>/dev/null; then
    [ -d "$dir" ] || return 0
    return 1
  fi
}

# Mark the current oldest as escalated after its stale wake is durably queued,
# suppressing another wake on later polls. Wake-before-marker ordering favors
# at-least-once recovery: a crash or marker failure can cause a rare duplicate;
# stuck-crewmate-recovery owns the message from here.
fm_task_inbox_record_escalated() {  # <state-dir> <task-id> <record-path>
  local dir
  dir=$(fm_task_inbox_dir "$1" "$2")
  [ -d "$dir" ] || return 0
  if ! { printf '%s\n' "${3##*/}" > "$dir/.escalated"; } 2>/dev/null; then
    [ -d "$dir" ] || return 0
    return 1
  fi
}
