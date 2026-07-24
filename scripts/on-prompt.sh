#!/usr/bin/env bash
# UserPromptSubmit hook.
# 1. Sniff a ticket id AND/OR a claim marker from the user's prompt; record them
#    as THIS session's current ticket/label (real-time: runs every prompt, so a
#    session that moves cashback -> rewards updates the whiteboard immediately).
# 2. If ANOTHER fresh session already holds that same ticket OR the same label,
#    warn and suggest stopping. Otherwise stay SILENT (zero added context tokens).
#
# Claim markers (emitted by /claude-whiteboard:claim and :release):
#   @wb-claim: <label>   -> set this session's label
#   @wb-release          -> clear this session's label   (wins if both appear)
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

# --- Sniff ticket + claim markers -----------------------------------------

# First ticket-looking token in the prompt.
ticket="$(printf '%s' "$prompt" | grep -oE "$WB_TICKET_RE" | head -n1 || true)"

# Fallback: derive ticket from worktree dir / branch name (prompt may never
# mention it, e.g. session opened directly in an ethenapayf-1003-* worktree).
if [ -z "$ticket" ]; then
  cwd="$(printf '%s' "$input" | jq -r '.cwd // ""')"
  branch=""
  if [ -n "$cwd" ] && command -v git >/dev/null 2>&1; then
    branch="$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  fi
  dir=""
  [ -n "$cwd" ] && dir="$(basename "$cwd")"
  ticket="$(wb_ticket_from_names "$dir" "$branch" || true)"
fi

# Claim / release markers.
release=""
label=""
if printf '%s' "$prompt" | grep -qE '(^|[[:space:]])@wb-release([[:space:]]|$)'; then
  release=1
else
  # Everything after "@wb-claim:" on that line, trimmed. Empty -> no-op.
  label="$(printf '%s' "$prompt" \
    | grep -oE '@wb-claim:.*' | head -n1 \
    | sed -E 's/^@wb-claim:[[:space:]]*//; s/[[:space:]]+$//' || true)"
fi

# --- Record ticket / label + heartbeat ------------------------------------

# Ensure the session entry exists and refresh heartbeat unconditionally.
wb_update '.sessions[$sid] = ((.sessions[$sid] // {})
     + {updated:($now|tonumber),
        started:(.sessions[$sid].started // ($now|tonumber))})' \
  --arg sid "$sid" --arg now "$now" 2>/dev/null || true

[ -n "$ticket" ] && wb_update '.sessions[$sid].ticket = $ticket' \
  --arg sid "$sid" --arg ticket "$ticket" 2>/dev/null || true

if [ -n "$release" ]; then
  wb_update '.sessions[$sid].label = null' --arg sid "$sid" 2>/dev/null || true
  label=""   # released: nothing to conflict-check
elif [ -n "$label" ]; then
  wb_update '.sessions[$sid].label = $label' \
    --arg sid "$sid" --arg label "$label" 2>/dev/null || true
fi

# Nothing to check this prompt -> silent.
[ -z "$ticket" ] && [ -z "$label" ] && exit 0

# --- Conflict checks (ticket + label, independent) ------------------------

fresh="$(wb_read_fresh)"

emit_conflict() {
  # $1 = kind ("ticket"/"label"), $2 = value, $3 = other_sid, $4 = other_branch
  local msg="[claude-whiteboard] ⚠ CONFLICT: $1 \"$2\" is already being worked on by session ${3:0:8}"
  [ -n "$4" ] && msg="$msg (branch: $4)"
  cat <<EOF
$msg
This is likely DOUBLE WORK. STOP before editing code: tell the user another
session already owns this $1 and ask whether to continue, coordinate, or switch
to something else. Do not silently proceed.
EOF
}

if [ -n "$ticket" ]; then
  holder="$(printf '%s' "$fresh" | jq -r --arg self "$sid" --arg t "$ticket" '
    .sessions | to_entries
    | map(select(.key != $self and .value.ticket == $t))
    | (.[0].key // "") + "|" + (.[0].value.branch // "")' 2>/dev/null)"
  other_sid="${holder%%|*}"; other_branch="${holder#*|}"
  [ -n "$other_sid" ] && emit_conflict "ticket" "$ticket" "$other_sid" "$other_branch"
fi

if [ -n "$label" ]; then
  # Case-insensitive exact match on the trimmed label.
  holder="$(printf '%s' "$fresh" | jq -r --arg self "$sid" --arg l "$label" '
    ($l | ascii_downcase) as $ld
    | .sessions | to_entries
    | map(select(.key != $self
            and (.value.label // "" | ascii_downcase) == $ld))
    | (.[0].key // "") + "|" + (.[0].value.branch // "")' 2>/dev/null)"
  other_sid="${holder%%|*}"; other_branch="${holder#*|}"
  [ -n "$other_sid" ] && emit_conflict "label" "$label" "$other_sid" "$other_branch"
fi

exit 0
