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

# Clear crashed holders' rows and say so. Both `use` and `free` need it: a
# phantom row blocks an exclusive claim and would otherwise be reported to the
# user as somebody else's live hold. No-op when liveness is unknown.
report_sweep() {
  local swept; swept="$(wb_sweep_dead_holds "$1")"
  [ -n "$swept" ] || return 0
  echo "[claude-whiteboard] cleared \"$1\" from crashed session(s): $(printf '%s' "$swept" | tr '\n' ' ' | sed 's/ *$//')."
}

# Refusal body naming whoever else holds <res>. Prints nothing and returns 1 when
# no other session holds it. Shared by `use` and `free` so the two cannot drift
# into telling a blocked session different things about the same board.
#   refusal_for <res> <bare> <self>
refusal_for() {
  local res="$1" bare="$2" self="$3" other o_sid o_since o_name
  other="$(jq -r --arg s "$self" --arg r "$res" '
      .sessions | to_entries
      | map(select(.key != $s and ((.value.holds // {})[$r] // 0) > 0))
      | sort_by(.value.holds[$r]) | .[0] | select(. != null)
      | .key, (.value.holds[$r] | tostring)' <<< "$(wb_read_fresh)" 2>/dev/null)"
  [ -n "$other" ] || return 1
  # One field per line, as wb_holder_of does: "|" is legal in the strings a
  # session row carries and TAB is IFS whitespace.
  o_sid=""; o_since=""
  { IFS= read -r o_sid; IFS= read -r o_since; } <<< "$other" || true
  printf '"%s" is held by session %s since %s ago. Nothing was changed.\n' \
    "$res" "${o_sid:0:8}" "$(wb_ago "$o_since")"
  o_name="$(wb_peer_name "$o_sid")"
  if [ -n "$o_name" ]; then
    printf 'Ask that session:\n  SendMessage({to: "%s", message: "Are you still using %s? I need it."})\n' \
      "$o_name" "$bare"
  fi
  printf 'If you have verified that session is dead: /claude-whiteboard:force %s\n' "$bare"
}

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
    report_sweep "$res"
    # wb_hold, which this used to call, records a hold whoever else has one, and
    # the echo below was unconditional — so /use handed the same resource to two
    # sessions at once and told both they had it. That is exactly the collision
    # the PreToolUse hook refuses to allow, arrived at through the front door.
    # wb_hold_exclusive does the check and the write in ONE jq under ONE lock,
    # then re-reads, and returns false unless this session really holds it.
    if wb_hold_exclusive "$sid" "$res"; then
      echo "[claude-whiteboard] you now hold \"$res\"."
    else
      refusal="$(refusal_for "$res" "$arg" "$sid")" \
        || refusal="\"$res\" was not claimed, and no other holder is recorded — the registry write failed. Registry: $WB_REGISTRY"
      die "refused: $refusal"
    fi
    ;;
  free)
    res="$(wb_resource_name "$arg" "$PWD")"

    # Own hold is settled FIRST, before any liveness reasoning. A session whose
    # own row Claude Code never wrote reads "dead" to wb_session_alive, and
    # sweeping ahead of this check would delete the caller's own hold and then
    # report it had nothing to release.
    if [ "$(wb_read_fresh | jq -r --arg s "$sid" --arg r "$res" \
              '((.sessions[$s].holds // {}) | has($r))' 2>/dev/null)" != "true" ]; then
      # A crashed holder's row must not out-argue the user: without this sweep
      # the refusal below would name a session that no longer exists, and the
      # row would survive every /free forever. No-op when liveness is unknown,
      # so a machine with no session registry never loses a live hold.
      report_sweep "$res"
      # wb_unhold deletes from the CALLER's holds, so a non-holder deletes
      # nothing — and the old unconditional "released" reported that no-op as
      # success. A session then sat blocked behind a hold it believed it had
      # just cleared, twice, for 165 minutes. Refuse instead, and name the
      # holder, the peer to ask, and the escape hatch.
      if ! refusal="$(refusal_for "$res" "$arg" "$sid")"; then
        echo "[claude-whiteboard] \"$res\" is not held by this session, and nobody else holds it — nothing to release."
        exit 0
      fi
      die "refused: $refusal"
    fi

    wb_unhold "$sid" "$res"
    # wb_update reports nothing about whether its filter fired and swallows a jq
    # failure, so the write's success is not the resulting state. Re-read before
    # claiming anything — that claim is what the caller acts on.
    if [ "$(wb_read_fresh | jq -r --arg s "$sid" --arg r "$res" \
              '((.sessions[$s].holds // {}) | has($r))' 2>/dev/null)" = "true" ]; then
      die "\"$res\" is STILL recorded as held by this session — the registry write failed. Registry: $WB_REGISTRY"
    fi
    # Only after a real release: a window opened on a resource somebody else
    # still holds burns the waiters' head start while they cannot take it.
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
