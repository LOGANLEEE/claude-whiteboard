#!/usr/bin/env bash
# Direct entry point for the /claude-whiteboard slash commands.
#
# Until 0.4.2 each command asked the MODEL to emit an `@wb-*` marker and left
# the UserPromptSubmit hook to pick it up. That could never work. A slash
# command body is expanded into a user message the hook does not receive — the
# hook sees the text the user typed, which is `/claude-whiteboard:free xcode`,
# with no marker in it. So /use, /free, /force, /claim and /release were all
# silent no-ops: the command reported success and the board never changed.
#
# A Bash tool call DOES carry CLAUDE_CODE_SESSION_ID, and it is the same id the
# hooks receive on stdin, so the command body calls this script and the write
# happens for real. The markers stay supported in on-prompt.sh for anyone who
# types one by hand; that path was always fine.
#
# Usage: board.sh use|free|force <resource>
#        board.sh claim <label>
#        board.sh release
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

die() { echo "[claude-whiteboard] $*" >&2; exit 2; }

wb_have_jq || die "'jq' is not installed, so nothing was recorded on the board."

action="${1:-}"
[ -n "$action" ] || die "usage: board.sh use|free|force <resource> | claim <label> | release"
shift
arg="$*"

# Without the session id there is no way to know whose row this is. Writing
# anything would either corrupt another session's entry or invent a ghost one,
# so refuse loudly instead — a visible failure is recoverable, a wrong hold is
# what this whole plugin exists to prevent.
sid="${CLAUDE_CODE_SESSION_ID:-}"
[ -n "$sid" ] || die "CLAUDE_CODE_SESSION_ID is not set, so this session cannot be identified. Nothing was written."

# Validate before touching the registry: a rejected command must leave no trace.
case "$action" in
  use|free|force) [ -n "$arg" ] || die "$action needs a resource name." ;;
  claim)          [ -n "$arg" ] || die "claim needs a label." ;;
  release)        ;;
  *)              die "unknown action \"$action\" — expected use, free, force, claim or release." ;;
esac

wb_touch "$sid"

case "$action" in
  use)
    res="$(wb_resource_name "$arg" "$PWD")"
    wb_hold "$sid" "$res"
    echo "[claude-whiteboard] you now hold \"$res\"."
    ;;
  free)
    res="$(wb_resource_name "$arg" "$PWD")"
    wb_unhold "$sid" "$res"
    wb_open_window "$res" "$WB_RESERVE"
    echo "[claude-whiteboard] released \"$res\"."
    ;;
  force)
    wb_force "$(wb_resource_name "$arg" "$PWD")" "$sid"
    ;;
  claim)
    wb_set_label "$sid" "$arg"
    echo "[claude-whiteboard] label claimed: \"$arg\"."
    ;;
  release)
    wb_clear_label "$sid"
    echo "[claude-whiteboard] label released."
    ;;
esac
