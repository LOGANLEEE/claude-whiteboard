#!/usr/bin/env bash
# UserPromptSubmit hook.
# 1. Record what THIS session is working on (ticket and/or claimed label) so the
#    whiteboard stays current in real time — a session that moves from one ticket
#    to another updates the board on its very next prompt.
# 2. If ANOTHER fresh session demonstrably owns that same ticket OR the same
#    label, warn and suggest stopping. Otherwise stay SILENT (zero added tokens).
#
# Ticket evidence, strongest first — mention is NOT work:
#   worktree dir / branch name   STRONG ("worktree"). Always wins; may overwrite
#                                a value that was previously sniffed from a prompt.
#   ticket id inside the prompt  WEAK   ("prompt").  Used only when the session
#                                has no worktree evidence AND no ticket recorded
#                                yet. Never overwrites an existing ticket.
# Only a STRONG holder raises ⚠ CONFLICT; a holder that merely mentioned the
# ticket gets a one-line note, so pasted coordination text can't hijack someone's
# ticket. Each distinct conflict is announced ONCE per session (see `warned`) —
# a real overlap should stop work, not repeat on every prompt for hours.
#
# Markers (whitespace-delimited token anywhere in the prompt):
#   @wb-ignore           -> this prompt is not work: no sniffing, no writes at all
#   @wb-claim: <label>   -> set this session's label
#   @wb-release          -> clear this session's label   (wins if both appear)
#
# Input: JSON on stdin (session_id, prompt, cwd, ...). Output: stdout -> context.

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

input="$(cat)"
wb_have_jq || exit 0   # silently no-op without jq (already warned at start)

sid="$(printf '%s' "$input" | jq -r '.session_id // "unknown"')"
prompt="$(printf '%s' "$input" | jq -r '.prompt // ""')"
now="$(wb_now)"

# @wb-ignore: pasted coordination / cross-check text. Full no-op — the prompt
# says nothing about what this session is working on.
# Here-strings, not `printf | grep`: `grep -q` exits on the first match, which
# kills printf with SIGPIPE, and under `pipefail` that turns a MATCH into a
# non-zero status on any prompt bigger than the pipe buffer (~64 KiB) — silently
# disabling the marker on exactly the giant pasted dumps it exists for.
if grep -qE '(^|[[:space:]])@wb-ignore([[:space:]]|$)' <<< "$prompt"; then
  exit 0
fi

# --- Gather evidence -------------------------------------------------------

cwd="$(printf '%s' "$input" | jq -r '.cwd // ""')"
dir=""
[ -n "$cwd" ] && dir="$(basename "$cwd")"
branch=""
if [ -n "$cwd" ] && command -v git >/dev/null 2>&1; then
  branch="$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
fi

# STRONG: the worktree / branch this session actually sits in.
wt_ticket="$(wb_ticket_from_names "$dir" "$branch" || true)"

# WEAK: first ticket-looking token in the prompt. Only consulted when there is
# no worktree evidence — a prompt that merely mentions a ticket is not work.
prompt_ticket=""
if [ -z "$wt_ticket" ]; then
  prompt_ticket="$(grep -oE "$WB_TICKET_RE" <<< "$prompt" | head -n1 || true)"
fi

# Claim / release markers.
release=""
label=""
if grep -qE '(^|[[:space:]])@wb-release([[:space:]]|$)' <<< "$prompt"; then
  release=1
else
  # Everything after "@wb-claim:" on that line, trimmed. Empty -> no-op.
  label="$(grep -oE '@wb-claim:.*' <<< "$prompt" | head -n1 \
    | sed -E 's/^@wb-claim:[[:space:]]*//; s/[[:space:]]+$//' || true)"
fi

# --- Record ticket / label + heartbeat ------------------------------------

# Ensure the session entry exists; refresh heartbeat and location unconditionally.
wb_update '.sessions[$sid] = ((.sessions[$sid] // {})
     + {updated:($now|tonumber),
        started:(.sessions[$sid].started // ($now|tonumber))}
     + (if $cwd    != "" then {cwd:$cwd, dir:$dir} else {} end)
     + (if $branch != "" then {branch:$branch} else {} end))' \
  --arg sid "$sid" --arg now "$now" \
  --arg cwd "$cwd" --arg dir "$dir" --arg branch "$branch" 2>/dev/null || true

if [ -n "$wt_ticket" ]; then
  # Strong: wins over anything already recorded, including a prompt-sniffed value.
  wb_update '.sessions[$sid] += {ticket:$ticket, ticket_src:"worktree"}' \
    --arg sid "$sid" --arg ticket "$wt_ticket" 2>/dev/null || true
elif [ -n "$prompt_ticket" ]; then
  # Weak: fills an empty slot only. Decided inside jq so it stays atomic.
  wb_update '.sessions[$sid] |= (if (.ticket // "") == ""
       then . + {ticket:$ticket, ticket_src:"prompt"} else . end)' \
    --arg sid "$sid" --arg ticket "$prompt_ticket" 2>/dev/null || true
fi

if [ -n "$release" ]; then
  wb_update '.sessions[$sid].label = null' --arg sid "$sid" 2>/dev/null || true
  label=""   # released: nothing to conflict-check
elif [ -n "$label" ]; then
  wb_update '.sessions[$sid].label = $label' \
    --arg sid "$sid" --arg label "$label" 2>/dev/null || true
fi

# No ticket evidence and no label this prompt -> silent.
if [ -z "$wt_ticket" ] && [ -z "$prompt_ticket" ] && [ -z "$label" ]; then
  exit 0
fi

# --- Conflict checks (ticket + label, independent) ------------------------

fresh="$(wb_read_fresh)"

# The ticket actually on the board for us — a weak sniff may have been rejected.
ticket=""
if [ -n "$wt_ticket" ] || [ -n "$prompt_ticket" ]; then
  ticket="$(jq -r --arg sid "$sid" '.sessions[$sid].ticket // ""' <<< "$fresh" 2>/dev/null)"
fi

# Conflicts already announced to this session, as "|"-joined signatures.
warned_before="$(jq -r --arg sid "$sid" '.sessions[$sid].warned // ""' <<< "$fresh" 2>/dev/null)"
warned_now="$warned_before"

# True (and records it) the first time this session sees a given signature.
first_time() {
  case "|$warned_now|" in
    *"|$1|"*) return 1 ;;
  esac
  warned_now="${warned_now:+$warned_now|}$1"
  return 0
}

emit_conflict() {
  # $1 = kind ("ticket"/"label"), $2 = value, $3 = other_sid,
  # $4 = other_dir, $5 = other_branch
  local msg="[claude-whiteboard] ⚠ CONFLICT: $1 \"$2\" is already being worked on by session ${3:0:8}"
  local where=""
  [ -n "$4" ] && where="dir: $4"
  [ -n "$5" ] && where="${where:+$where, }branch: $5"
  [ -n "$where" ] && msg="$msg ($where)"
  cat <<EOF
$msg
This is likely DOUBLE WORK. STOP before editing code: tell the user another
session already owns this $1 and ask whether to continue, coordinate, or switch
to something else. Do not silently proceed.
EOF
}

emit_note() {
  # $1 = ticket, $2 = other_sid, $3 = other_dir. Weak holder: FYI, not a stop.
  local where=""
  [ -n "$3" ] && where=" (dir: $3)"
  echo "[claude-whiteboard] note: session ${2:0:8}$where also mentioned $1."
}

# Native SendMessage address for a session, when Claude Code knows one. Emitted
# as a follow-up to a hard conflict so the session that just found the overlap
# can settle it directly instead of asking the user to relay. Looked up lazily —
# the common prompt never reaches here, so it costs nothing in steady state.
emit_peer_hint() {
  local name
  name="$(wb_peer_names | jq -r --arg s "$1" '.[$s].name // ""' 2>/dev/null || true)"
  [ -n "$name" ] && printf 'That session is reachable: SendMessage({to: "%s", message: "..."}) — ask what it has already done before you touch anything.\n' "$name"
  return 0
}

# Read a holder emitted by jq (see WB_HOLDER): one field per line. A single
# delimited line does not work — "|" is legal in a directory and a branch name,
# and TAB is IFS whitespace, so bash collapses an empty field and shifts the rest.
read_holder() {
  other_sid=""; other_dir=""; other_branch=""; other_src=""
  { IFS= read -r other_sid; IFS= read -r other_dir
    IFS= read -r other_branch; IFS= read -r other_src; } <<< "$1" || true
}

# jq tail shared by both holder queries: emit sid / dir / branch / ticket_src one
# per line, flattening any embedded newline or tab so the lines stay aligned.
WB_HOLDER='
  | def clean: (. // "") | tostring | gsub("[\n\t\r]"; " ");
  (.[0].key | clean), (.[0].value.dir | clean),
  (.[0].value.branch | clean), (.[0].value.ticket_src | clean)'

if [ -n "$ticket" ]; then
  # A worktree-backed holder is doing the work -> hard conflict. A holder that
  # only ever mentioned the ticket (or a pre-0.2.2 entry with no ticket_src)
  # gets a one-line note instead. Strong holders sort first.
  holder="$(jq -r --arg self "$sid" --arg t "$ticket" '
    .sessions | to_entries
    | map(select(.key != $self and .value.ticket == $t))
    | sort_by(if (.value.ticket_src // "") == "worktree" then 0 else 1 end)'"$WB_HOLDER" \
    <<< "$fresh" 2>/dev/null)"
  read_holder "$holder"
  if [ -n "$other_sid" ]; then
    if [ "$other_src" = "worktree" ]; then
      if first_time "T:$ticket:$other_sid:hard"; then
        emit_conflict "ticket" "$ticket" "$other_sid" "$other_dir" "$other_branch"
        emit_peer_hint "$other_sid"
      fi
    else
      first_time "T:$ticket:$other_sid:soft" \
        && emit_note "$ticket" "$other_sid" "$other_dir"
    fi
  fi
fi

if [ -n "$label" ]; then
  # Case-insensitive exact match on the trimmed label. A label is always an
  # explicit claim, so any holder is a hard conflict.
  holder="$(jq -r --arg self "$sid" --arg l "$label" '
    ($l | ascii_downcase) as $ld
    | .sessions | to_entries
    | map(select(.key != $self
            and (.value.label // "" | ascii_downcase) == $ld))'"$WB_HOLDER" \
    <<< "$fresh" 2>/dev/null)"
  read_holder "$holder"
  if [ -n "$other_sid" ]; then
    if first_time "L:$label:$other_sid"; then
      emit_conflict "label" "$label" "$other_sid" "$other_dir" "$other_branch"
      emit_peer_hint "$other_sid"
    fi
  fi
fi

if [ "$warned_now" != "$warned_before" ]; then
  wb_update '.sessions[$sid].warned = $w' \
    --arg sid "$sid" --arg w "$warned_now" 2>/dev/null || true
fi

exit 0
