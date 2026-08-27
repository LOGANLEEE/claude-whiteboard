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

# Auto-detect ticket from worktree dir / branch name (e.g. ethenapayf-1003-*).
dir=""
[ -n "$cwd" ] && dir="$(basename "$cwd")"
ticket="$(wb_ticket_from_names "$dir" "$branch" || true)"

# Register / refresh self. A worktree-derived ticket is STRONG evidence: it wins
# over anything already recorded (including a value sniffed from a prompt) and
# is tagged as such, so only it can raise a conflict in another session.
wb_update \
  '.sessions[$sid] = ((.sessions[$sid] // {})
     + {cwd:$cwd, dir:$dir, branch:$branch,
        started:(.sessions[$sid].started // ($now|tonumber)),
        updated:($now|tonumber),
        ticket:(if $ticket != "" then $ticket else (.sessions[$sid].ticket // null) end),
        ticket_src:(if $ticket != "" then "worktree" else (.sessions[$sid].ticket_src // null) end)})' \
  --arg sid "$sid" --arg cwd "$cwd" --arg dir "$dir" --arg branch "$branch" \
  --arg ticket "$ticket" --arg now "$now"

# Native SendMessage addresses, joined in at render time (never stored).
peers="$(wb_peer_names)"

# Build the "others" view (fresh only, excluding self).
others="$(wb_read_fresh | jq -r --arg self "$sid" --argjson peers "$peers" '
  .sessions | to_entries
  | map(select(.key != $self))
  | map("- " + (.key[0:8])
        + (if .value.ticket
           then "  ticket: " + .value.ticket
                + (if (.value.ticket_src // "") == "worktree" then ""
                   else " (mentioned, not confirmed by a worktree)" end)
           else "  ticket: (none yet)" end)
        + (if .value.label  and .value.label != "" then "  label: " + .value.label else "" end)
        + (((.value.holds // {}) | keys) as $h
           | if ($h | length) > 0 then "  uses: " + ($h | join(", ")) else "" end)
        + (if .value.dir    and .value.dir    != "" then "  dir: " + .value.dir else "" end)
        + (if .value.branch and .value.branch != "" then "  branch: " + .value.branch else "" end)
        + (($peers[.key] // {}) as $p
           | if ($p.name // "") != ""
             then "  peer: " + $p.name
                  + (if ($p.status // "") != "" then " (" + $p.status + ")" else "" end)
             else "" end))
  | .[]' 2>/dev/null)"

if [ -n "$others" ]; then
  cat <<EOF
[claude-whiteboard] Other active Claude Code sessions right now:
$others

Before starting a ticket, avoid one already listed above (another session is on it).
If your work overlaps one of these, pause and tell the user rather than doing double-work.
EOF
  # A row with a peer name is directly reachable: Claude Code can message that
  # session itself, so coordinating does not have to go through the user.
  case "$others" in
    *"  peer: "*)
      echo 'A row with "peer:" can be messaged directly — SendMessage({to: "<peer>", message: "..."}) — to ask what it is doing, hand work over, or warn it off.'
      ;;
  esac
  # A shared singleton is not a double-work warning: taking it corrupts their
  # run rather than duplicating it, so the answer is to ask, not to work around.
  case "$others" in
    *"  uses: "*)
      echo 'A row with "uses:" holds that shared resource. A command that would take it is blocked until they release it — ask that session rather than working around the block.'
      ;;
  esac
else
  echo "[claude-whiteboard] No other active sessions. You're clear to pick any ticket."
fi

exit 0
