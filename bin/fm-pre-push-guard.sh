#!/usr/bin/env bash
# Generic pre-push guard for fleet panes: the bundled implementation of the
# config/pre-push-guard hook point (docs/configuration.md "Pre-push guard").
#
# Usage: fm-pre-push-guard.sh <remote-name> <remote-url>  < <ref lines>
#   Git's own pre-push arguments and standard input, passed through unchanged by
#   the wrapper that bin/fm-git-strip-ai-trailers.sh install writes. A home opts
#   in by putting this script's absolute path on the first line of its
#   config/pre-push-guard; nothing else runs it.
#
# CONTRACT. Git supplies one line per ref being pushed:
#   <local ref> <local sha> <remote ref> <remote sha>
# and for each line this guard decides, in this order:
#   1. a push that changes nothing (the two shas match) is skipped;
#   2. a delete (local ref "(delete)", all-zero local sha) is refused;
#   3. a push to the remote's default branch is refused, creation included: the
#      branch is main or master, or the one the remote's recorded HEAD names
#      (refs/remotes/<remote-name>/HEAD) when this repository knows it;
#   4. a non-fast-forward update is refused: the remote's current commit must be
#      an ancestor of the pushed one, and when that commit is not in this
#      repository the update is refused rather than guessed at, because there
#      is nothing to compare against. A ref the remote does not have yet has
#      nothing to compare and passes this step;
#   5. gitleaks scans commits reachable from the pushed commit but not from
#      the destination ref's advertised remote SHA; a new ref scans everything
#      reachable from the pushed commit. The ref is refused on a finding,
#      on a gitleaks failure, and, for every ref
#      that reaches this step, when gitleaks is not on PATH.
# Every refused ref is named with its reason on stderr and the guard then exits
# 1, which makes git abort the push; a push with no refused ref exits 0. A
# gitleaks finding exits it with a code of its own so a finding and a broken scan
# read differently; the scan needs gitleaks 8.19 or newer for the `git`
# subcommand and honors the repository's own gitleaks configuration.
#
# Default-branch protection is limited to main, master, and the remote's
# recorded HEAD when known; an unknown or stale recorded HEAD can leave other
# default-branch names unprotected.
#
# What never reaches this guard: a push made with --no-verify, because git then
# runs no hook at all. no-mistakes pushes its own gate-trigger pushes that way, so a
# worker's pipeline start is unaffected (docs/verification/runtime-backends.md
# "Pre-push guard and no-mistakes pushes" records the evidence), and the
# pipeline's delivery pushes run inside the no-mistakes daemon, outside every
# fleet pane. Private path, file-type, and size rules are deliberately not here:
# a private guard that wants them calls this one first with the same arguments
# and standard input, then adds its own checks.
set -u
unset CDPATH

GITLEAKS_FINDING_EXIT=42

usage() {
  cat <<'EOF'
usage: fm-pre-push-guard.sh <remote-name> <remote-url> < ref-lines
  Run by git's pre-push hook through the fleet wrapper; see the script header.
EOF
}

case "${1:-}" in
-h | --help)
  usage
  exit 0
  ;;
esac
if [ "$#" -lt 1 ] || [ -t 0 ]; then
  usage >&2
  exit 2
fi

REMOTE=$1
refused=0

refuse() { # <remote-ref> <reason>
  printf 'fm-pre-push-guard: refusing %s: %s\n' "$1" "$2" >&2
  refused=1
}

# Git writes the all-zero object name for "no such object", at whatever width
# the repository's hash is, so any run of zeros stands for it.
is_zero_sha() { # <sha>
  case $1 in
  '' | *[!0]*) return 1 ;;
  *) return 0 ;;
  esac
}

short_sha() { # <sha>
  printf '%s' "${1:0:12}"
}

recorded_default=
if sym=$(git symbolic-ref -q "refs/remotes/$REMOTE/HEAD" 2>/dev/null </dev/null); then
  recorded_default=${sym#"refs/remotes/$REMOTE/"}
fi

is_default_branch() { # <branch name without refs/heads/>
  case $1 in
  main | master) return 0 ;;
  esac
  [ -n "$recorded_default" ] && [ "$1" = "$recorded_default" ]
}

# Read every ref line before running anything that could consume stdin.
input=$(cat)
to_scan=

while IFS=' ' read -r local_ref local_sha remote_ref remote_sha extra; do
  [ -n "$local_ref$local_sha$remote_ref$remote_sha$extra" ] || continue
  if [ -z "$remote_sha" ] || [ -n "$extra" ]; then
    refuse "${remote_ref:-<unnamed ref>}" "git sent a ref line this guard cannot read"
    continue
  fi
  [ "$local_sha" != "$remote_sha" ] || continue

  if [ "$local_ref" = "(delete)" ] || is_zero_sha "$local_sha"; then
    refuse "$remote_ref" "deleting a remote ref is not allowed"
    continue
  fi

  case $remote_ref in
  refs/heads/*)
    if is_default_branch "${remote_ref#refs/heads/}"; then
      refuse "$remote_ref" "pushing to the remote's default branch is not allowed"
      continue
    fi
    ;;
  esac

  if ! is_zero_sha "$remote_sha"; then
    if ! git cat-file -e "$remote_sha^{commit}" 2>/dev/null </dev/null; then
      refuse "$remote_ref" "the remote is at $(short_sha "$remote_sha"), which this repository does not have, so the update cannot be shown to be a fast-forward; fetch it first"
      continue
    fi
    git merge-base --is-ancestor "$remote_sha" "$local_sha" 2>/dev/null </dev/null
    case $? in
    0) ;;
    1)
      refuse "$remote_ref" "non-fast-forward update: the remote's $(short_sha "$remote_sha") is not an ancestor of the pushed $(short_sha "$local_sha")"
      continue
      ;;
    *)
      refuse "$remote_ref" "git could not compare the remote's $(short_sha "$remote_sha") with the pushed $(short_sha "$local_sha")"
      continue
      ;;
    esac
  fi

  to_scan="$to_scan$remote_ref $local_sha $remote_sha"$'\n'
done <<EOF
$input
EOF

# scan_ref <remote-ref> <local-sha> <remote-sha>: one gitleaks pass over the
# commits this ref adds, refusing the ref on a finding or a failed scan.
scan_ref() {
  local remote_ref=$1 local_sha=$2 remote_sha=$3 repo count rc
  local -a revs
  revs=("$local_sha")
  is_zero_sha "$remote_sha" || revs+=(--not "$remote_sha")
  if ! count=$(git rev-list --count "${revs[@]}" 2>/dev/null </dev/null); then
    refuse "$remote_ref" "git could not list the commits being pushed, so they cannot be scanned for secrets"
    return
  fi
  [ "$count" != 0 ] || return 0
  repo=$(git rev-parse --show-toplevel 2>/dev/null </dev/null) ||
    repo=$(git rev-parse --absolute-git-dir 2>/dev/null </dev/null) || repo=.
  gitleaks git --no-banner --redact --verbose --exit-code "$GITLEAKS_FINDING_EXIT" \
    "--log-opts=${revs[*]}" "$repo" </dev/null >&2
  rc=$?
  case $rc in
  0) ;;
  "$GITLEAKS_FINDING_EXIT")
    refuse "$remote_ref" "gitleaks found a secret in the commits being pushed (details above); remove it from those commits, or allowlist it in the repository's gitleaks configuration if it is a false positive"
    ;;
  *)
    refuse "$remote_ref" "gitleaks failed with exit $rc, so the commits being pushed could not be scanned for secrets (it needs gitleaks 8.19 or newer)"
    ;;
  esac
}

if [ -n "$to_scan" ]; then
  if command -v gitleaks >/dev/null 2>&1; then
    while IFS=' ' read -r remote_ref local_sha remote_sha; do
      [ -n "$remote_ref" ] || continue
      scan_ref "$remote_ref" "$local_sha" "$remote_sha"
    done <<EOF
$to_scan
EOF
  else
    while IFS=' ' read -r remote_ref _; do
      [ -n "$remote_ref" ] || continue
      refuse "$remote_ref" "gitleaks is not on PATH, so the commits being pushed cannot be scanned for secrets; install gitleaks, or remove this guard from config/pre-push-guard"
    done <<EOF
$to_scan
EOF
  fi
fi

if [ "$refused" -ne 0 ]; then
  printf 'fm-pre-push-guard: push refused\n' >&2
  exit 1
fi
exit 0
