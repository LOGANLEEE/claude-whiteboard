#!/usr/bin/env bash
# UserPromptSubmit hook.
# 1. Sniff a ticket id from the user's prompt; record it as THIS session's
#    current ticket (real-time: runs every prompt, so a session that moves
#    cashback -> rewards updates the whiteboard immediately).
# 2. If ANOTHER fresh session already holds that same ticket, warn and suggest
#    stopping. Otherwise stay SILENT (zero added context tokens).
#
# Input: JSON on stdin (session_id, prompt, ...). Output: stdout -> context.

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

input="$(cat)"
wb_have_jq || exit 0   # silently no-op without jq (already warned at start)

sid="$(printf '%s' "$input" | jq -r '.session_id // "unknown"')"
prompt="$(printf '%s' "$input" | jq -r '.prompt // ""')"
now="$(wb_now)"

# Sniff the first ticket-looking token from the prompt.
ticket="$(printf '%s' "$prompt" | grep -oE "$WB_TICKET_RE" | head -n1 || true)"

# Always refresh our heartbeat so we don't go stale mid-conversation.
if [ -n "$ticket" ]; then
  wb_update '.sessions[$sid] = ((.sessions[$sid] // {})
       + {ticket:$ticket, updated:($now|tonumber),
          started:(.sessions[$sid].started // ($now|tonumber))})' \
    --arg sid "$sid" --arg ticket "$ticket" --arg now "$now"
else
  wb_update '.sessions[$sid].updated = ($now|tonumber)' \
    --arg sid "$sid" --arg now "$now" 2>/dev/null || true
  exit 0   # no ticket in this prompt -> nothing to check -> silent
fi

# Conflict check: any OTHER fresh session on the same ticket?
holder="$(wb_read_fresh | jq -r --arg self "$sid" --arg t "$ticket" '
  .sessions | to_entries
  | map(select(.key != $self and .value.ticket == $t))
  | (.[0].key // "") + "|" + (.[0].value.branch // "")' 2>/dev/null)"

other_sid="${holder%%|*}"
other_branch="${holder#*|}"

if [ -n "$other_sid" ]; then
  msg="[claude-whiteboard] ⚠ CONFLICT: ticket $ticket is already being worked on by session ${other_sid:0:8}"
  [ -n "$other_branch" ] && msg="$msg (branch: $other_branch)"
  cat <<EOF
$msg
This is likely DOUBLE WORK. STOP before editing code: tell the user another
session already owns $ticket and ask whether to continue, coordinate, or switch
to a different ticket. Do not silently proceed.
EOF
fi

exit 0
