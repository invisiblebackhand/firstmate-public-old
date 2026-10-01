# shellcheck shell=bash
# The launches the scopes of rows.tsv stand for, built by the real builder.
# Sourced after bin/fm-claude-worker-permissions-lib.sh by
# tests/fm-claude-worker-permissions.test.sh and by the live guard
# tests/fm-claude-worker-permissions-live-e2e.test.sh, so both apply the table to
# the same rules.

# The branch the table names, and the task branch of every scope but scout.
FM_CPW_BRANCH=fm/example-task

fm_cpw_scope_settings() { # <scope> [<private-file>]
  case "$1" in
  nm) fm_claude_launch_settings ship no-mistakes "$FM_CPW_BRANCH" none "${2:-}" ;;
  pr) fm_claude_launch_settings ship direct-PR "$FM_CPW_BRANCH" none "${2:-}" ;;
  lo) fm_claude_launch_settings ship local-only "$FM_CPW_BRANCH" none "${2:-}" ;;
  gerrit) fm_claude_launch_settings ship direct-PR "$FM_CPW_BRANCH" gerrit "${2:-}" ;;
  scout) fm_claude_launch_settings scout '' '' none "${2:-}" ;;
  *)
    echo "error: unknown scope '$1'" >&2
    return 1
    ;;
  esac
}
