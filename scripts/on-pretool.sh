#!/usr/bin/env bash
# PreToolUse hook (Bash).
#
# A ticket conflict wastes work. A RESOURCE conflict corrupts it: the second
# session to bring up a shared stack rewrites the database and the shared config
# rows the first session is running against, and the victim then debugs a bug
# that is not theirs. Prompt-time warnings are too late for that — by the time a
# prompt is submitted the damage is done. So this runs at the moment the command
# is about to execute.
#
# Decision table for a command matching a resource's `claim` pattern:
#   free                     -> record the hold, exit 0, silent
#   already held by SELF     -> exit 0, silent (and do NOT refresh `since`)
#   held by a live session   -> exit 2, block, record this session as a waiter
#   held but idle & unprobed -> take it, say so (see wb_holder_of "soft")
#   free but reserved        -> exit 2, block, name who is in line
# A command matching a `release` pattern drops the hold and opens the priority
# window on every waiter.
#
# Input: JSON on stdin. Exit 0 = allow. Exit 2 = block, stderr shown to Claude.

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

input="$(cat)"
wb_have_jq || exit 0

tool="$(printf '%s' "$input" | jq -r '.tool_name // ""')"
[ "$tool" = "Bash" ] || exit 0

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"
[ -n "$cmd" ] || exit 0

sid="$(printf '%s' "$input" | jq -r '.session_id // "unknown"')"
cwd="$(printf '%s' "$input" | jq -r '.cwd // ""')"
[ -n "$cwd" ] || cwd="$PWD"

releases="$(wb_match_resources "$cmd" release)"
claims="$(wb_match_resources "$cmd" claim)"
# Overwhelmingly the common path: an ordinary command touches no resource and
# this hook does nothing at all — no registry write, no lock, no output.
if [ -z "$releases" ] && [ -z "$claims" ]; then
  exit 0
fi

# Heartbeat before touching any hold or wait. wb_read_fresh drops an entry whose
# `updated` is missing or older than the TTL, so a hold written without one is
# invisible to every other session — the claim would silently fail to block
# anyone. A session that is executing commands is demonstrably alive, so this is
# also the honest value. Recorded here rather than on every Bash call so the
# common path above stays free of lock traffic.
dir=""; branch=""
[ -n "$cwd" ] && dir="$(basename "$cwd")"
if [ -n "$cwd" ] && command -v git >/dev/null 2>&1; then
  branch="$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
fi
wb_update '.sessions[$sid] = ((.sessions[$sid] // {})
     + {updated:($now|tonumber),
        started:(.sessions[$sid].started // ($now|tonumber))}
     + (if $cwd    != "" then {cwd:$cwd, dir:$dir} else {} end)
     + (if $branch != "" then {branch:$branch} else {} end))' \
  --arg sid "$sid" --arg now "$(wb_now)" \
  --arg cwd "$cwd" --arg dir "$dir" --arg branch "$branch" 2>/dev/null || true

# --- release first: "compose down && compose up" is a restart, not a claim --
while IFS= read -r bare; do
  [ -n "$bare" ] || continue
  res="$(wb_resource_name "$bare" "$cwd")"
  wb_unhold "$sid" "$res"
  wb_open_window "$res" "$WB_RESERVE"
done <<< "$releases"

[ -n "$claims" ] || exit 0

# Address of a session, for the "go ask them" line. Looked up lazily: an
# ordinary command never reaches here, so the join costs nothing in steady state.
peer_name() {
  wb_peer_names | jq -r --arg s "$1" '.[$s].name // ""' 2>/dev/null || true
}

ago() {  # ago <epoch> -> "12m"
  local d=$(( $(wb_now) - ${1:-0} ))
  if [ "$d" -lt 60 ]; then printf '%ds' "$d"; else printf '%dm' $(( d / 60 )); fi
}

# Pass 1: decide. A compound command must be all-or-nothing — a partial claim
# would leave a phantom on a resource that was not even the reason for the block.
blocked=""
notes=""
while IFS= read -r bare; do
  [ -n "$bare" ] || continue
  res="$(wb_resource_name "$bare" "$cwd")"

  # Sweep first: a crashed holder must not block, and its stale row must not
  # linger on the board. No-ops when liveness is unknown.
  dead="$(wb_sweep_dead_holds "$res")"
  if [ -n "$dead" ]; then
    notes="${notes}[claude-whiteboard] reclaimed \"$res\" from session $(printf '%s' "$dead" | tr '\n' ' ' | sed 's/ *$//') — its process is gone.
"
  fi

  holder="$(wb_holder_of "$res" "$sid" "$bare")"
  if [ -n "$holder" ]; then
    h_sid=""; h_dir=""; h_br=""; h_since=""; h_state=""
    { IFS= read -r h_sid; IFS= read -r h_dir; IFS= read -r h_br
      IFS= read -r h_since; IFS= read -r h_state; } <<< "$holder" || true
    if [ "$h_state" = "hard" ]; then
      name="$(peer_name "$h_sid")"
      blocked="${blocked}BLOCKED: \"$res\" is held by session ${h_sid:0:8}
  dir: ${h_dir:-?}   branch: ${h_br:-?}   since: $(ago "$h_since") ago

Do NOT start your own — a second instance rewrites the shared state the holder
is running against, and the failure will surface as a bug in THEIR work.

You are now recorded as WAITING for it.
"
      if [ -n "$name" ]; then
        blocked="${blocked}Ask the holder directly:
  SendMessage({to: \"$name\", message: \"I need $bare. When can I take it?\"})
"
      else
        blocked="${blocked}Claude Code has not named that session, so it cannot be messaged by name.
"
      fi
      blocked="${blocked}If you have verified that session is dead: /claude-whiteboard:force $bare

"
      wb_add_wait "$sid" "$res"
      continue
    fi
    # soft: the holder is alive but idle and unprobed. Take it, say so.
    wb_unhold "$h_sid" "$res"
    notes="${notes}[claude-whiteboard] took \"$res\" from session ${h_sid:0:8} — idle $(ago "$h_since"), no probe to prove it is still up.
"
  fi

  # The resource is up, but nobody on the board claims it. Only a probe can see
  # this: a non-Claude process, or a session that started before the plugin was
  # installed. WARN, do not block — an unattributable signal gives nobody to
  # ask, and blocking on it is exactly the noise that makes people stop trusting
  # the warning.
  if [ -z "$holder" ] && wb_probe "$bare"; then
    notes="${notes}[claude-whiteboard] \"$res\" appears to be UP but is unclaimed on the board — another process, or a session older than this plugin. Check before you rely on it.
"
  fi

  # Free, but is someone else first in line?
  reserved="$(wb_reserved_by "$res" "$sid")"
  if [ -n "$reserved" ]; then
    w_sid=""; w_for=""; w_until=""
    { IFS= read -r w_sid; IFS= read -r w_for; IFS= read -r w_until; } <<< "$reserved" || true
    name="$(peer_name "$w_sid")"
    blocked="${blocked}BLOCKED: \"$res\" is free but reserved for $(( (w_until - $(wb_now)) / 60 + 1 ))m more.
Session ${w_sid:0:8}${name:+ ($name)} has been waiting $(( w_for / 60 ))m. Ask before you take it:
"
    if [ -n "$name" ]; then
      blocked="${blocked}  SendMessage({to: \"$name\", message: \"taking $bare — ok?\"})

"
    else
      blocked="${blocked}  (that session has no SendMessage name)

"
    fi
    continue
  fi
done <<< "$claims"

if [ -n "$blocked" ]; then
  printf '%s' "$blocked" >&2
  exit 2
fi

# Pass 2: nothing blocked, so take every claim.
while IFS= read -r bare; do
  [ -n "$bare" ] || continue
  res="$(wb_resource_name "$bare" "$cwd")"
  wb_hold "$sid" "$res"
  wb_drop_wait "$sid" "$res"
done <<< "$claims"

[ -n "$notes" ] && printf '%s' "$notes" >&2
exit 0
