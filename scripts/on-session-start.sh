#!/usr/bin/env bash
# SessionStart hook.
# 1. Register this session in the shared whiteboard.
# 2. Inject the list of OTHER active sessions into context so this session
#    knows what is already being worked on (double-work avoidance at boot).
#
# Input: JSON on stdin (session_id, cwd, source, ...). Output: stdout -> context.

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

input="$(cat)"

if ! wb_have_jq; then
  echo "claude-whiteboard: 'jq' not found — plugin disabled. Install jq to enable." >&2
  exit 0
fi

sid="$(printf '%s' "$input" | jq -r '.session_id // "unknown"')"
cwd="$(printf '%s' "$input" | jq -r '.cwd // ""')"
now="$(wb_now)"

# Derive a branch label from cwd if it's a git worktree (nice for display).
branch=""
if [ -n "$cwd" ] && command -v git >/dev/null 2>&1; then
  branch="$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
fi

# Register / refresh self. Preserve an existing ticket if we've seen this sid.
wb_update \
  '.sessions[$sid] = ((.sessions[$sid] // {})
     + {cwd:$cwd, branch:$branch, started:(.sessions[$sid].started // ($now|tonumber)),
        updated:($now|tonumber), ticket:(.sessions[$sid].ticket // null)})' \
  --arg sid "$sid" --arg cwd "$cwd" --arg branch "$branch" --arg now "$now"

# Build the "others" view (fresh only, excluding self).
others="$(wb_read_fresh | jq -r --arg self "$sid" '
  .sessions | to_entries
  | map(select(.key != $self))
  | map("- " + (.key[0:8])
        + (if .value.ticket then "  ticket: " + .value.ticket else "  ticket: (none yet)" end)
        + (if .value.label  and .value.label != "" then "  label: " + .value.label else "" end)
        + (if .value.branch and .value.branch != "" then "  branch: " + .value.branch else "" end))
  | .[]' 2>/dev/null)"

if [ -n "$others" ]; then
  cat <<EOF
[claude-whiteboard] Other active Claude Code sessions right now:
$others

Before starting a ticket, avoid one already listed above (another session is on it).
If your work overlaps one of these, pause and tell the user rather than doing double-work.
EOF
else
  echo "[claude-whiteboard] No other active sessions. You're clear to pick any ticket."
fi

exit 0
