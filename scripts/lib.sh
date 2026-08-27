#!/usr/bin/env bash
# claude-whiteboard shared library — registry location, config, atomic read/write.
# Sourced by every hook script. No output here.

# --- Config (all overridable via env) -------------------------------------

# Registry file. Default: per-user, shared across ALL sessions & worktrees.
# CLAUDE_PLUGIN_DATA persists across plugin updates, but Claude Code sets it for
# HOOKS only — a plain Bash tool call (`scripts/status.sh`, `scripts/board.sh`)
# runs without it. Falling straight through to ~/.claude therefore split the
# board in two: hooks wrote one registry and every hand-run script read another,
# empty one, and `status.sh` reported "No active sessions" against a live board.
# So when the variable is absent, find the plugin's own data directory by name
# before giving up on ~/.claude.
# Plain branches, not a $(...) helper: this file is sourced on every Bash tool
# call in every session, and the hook path must not pay a fork to learn nothing.
if [ -n "${CC_WHITEBOARD_REGISTRY:-}" ]; then
  WB_REGISTRY="$CC_WHITEBOARD_REGISTRY"
elif [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then
  WB_REGISTRY="$CLAUDE_PLUGIN_DATA/whiteboard/registry.json"
else
  WB_REGISTRY="$HOME/.claude/whiteboard/registry.json"
  for _wb_d in "$HOME"/.claude/plugins/data/*claude-whiteboard*; do
    [ -f "$_wb_d/whiteboard/registry.json" ] || continue
    WB_REGISTRY="$_wb_d/whiteboard/registry.json"; break
  done
  unset _wb_d
fi

# Regex used to sniff a ticket id from a prompt (grep -oE). Generic by default:
# matches ETHEN-447, ETHENAPAYF-375, JIRA-12, ABC-9 ...
WB_TICKET_RE="${CC_WHITEBOARD_TICKET_RE:-[A-Z][A-Z0-9]+-[0-9]+}"

# A session entry older than this many seconds is treated as stale (crash safety).
WB_TTL="${CC_WHITEBOARD_TTL:-14400}"   # 4h

# Native peer registry, written by Claude Code itself: one <pid>.json per live
# session carrying the SAME session id hooks receive, plus the `name` that
# SendMessage({to: ...}) addresses. Read-only join target — we never write here.
WB_SESSIONS_DIR="${CC_WHITEBOARD_SESSIONS_DIR:-$HOME/.claude/sessions}"

WB_LOCK="${WB_REGISTRY}.lock"

# --- Helpers ---------------------------------------------------------------

wb_have_jq() { command -v jq >/dev/null 2>&1; }

wb_now() { date +%s; }

# Ensure registry dir + a valid empty JSON doc exist.
wb_init() {
  local dir; dir="$(dirname "$WB_REGISTRY")"
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null
  if [ ! -s "$WB_REGISTRY" ]; then
    printf '{"sessions":{}}' > "$WB_REGISTRY" 2>/dev/null
  fi
}

# Portable atomic lock via mkdir (works on macOS + Linux; no flock dependency).
# Spins up to ~2s, then proceeds anyway (a lock this old is almost certainly stale).
wb_lock() {
  local i=0
  while ! mkdir "$WB_LOCK" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -ge 40 ]; then
      # Stale lock guard: if the lockdir is old, steal it.
      rm -rf "$WB_LOCK" 2>/dev/null
      mkdir "$WB_LOCK" 2>/dev/null && break
    fi
    sleep 0.05
  done
}
wb_unlock() { rm -rf "$WB_LOCK" 2>/dev/null; }

# Run a jq filter atomically under the lock, writing result back to the registry.
# Usage: wb_update '<jq filter>' [--arg name val ...]
# The filter operates on the whole {"sessions":{...}} document.
wb_update() {
  local filter="$1"; shift
  wb_init
  wb_lock
  local tmp; tmp="$(mktemp "${WB_REGISTRY}.XXXXXX")"
  if jq "$@" "$filter" "$WB_REGISTRY" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$WB_REGISTRY"
  else
    rm -f "$tmp"
  fi
  wb_unlock
}

# Print the registry with stale entries (> WB_TTL) filtered out.
wb_read_fresh() {
  wb_init
  local cutoff; cutoff=$(( $(wb_now) - WB_TTL ))
  jq -c --argjson cutoff "$cutoff" \
    '.sessions |= with_entries(select(.value.updated >= $cutoff))' \
    "$WB_REGISTRY" 2>/dev/null || printf '{"sessions":{}}'
}

# Lookup of native SendMessage addresses, keyed by session id:
#   {"07a7860e-...":{"name":"1276","status":"busy"}, ...}
# Joined at render time and never stored, so a renamed session stays reachable
# and the whiteboard keeps owning only its own data. Prints {} when the directory
# is absent (older Claude Code, another machine) — every caller then renders
# exactly what it rendered before peers existed.
# ponytail: one `jq -s` over the whole directory. A single half-written session
# file drops peer names for that one render; per-file jq would isolate it at the
# cost of ~60x the process spawns.
wb_peer_names() {
  local out
  # Positional params, not a bash array: `${arr[0]}` is empty under zsh, and this
  # file gets sourced by hand often enough that the difference bites.
  set -- "$WB_SESSIONS_DIR"/*.json
  # Unmatched glob stays literal, so this covers "no files" and "no directory".
  # Checking it up front matters: `jq -s` over zero readable inputs still prints
  # {} AND exits non-zero, so a bare `|| printf '{}'` would emit "{}{}".
  [ -e "$1" ] || { printf '{}'; return 0; }
  out="$(jq -s 'map(select((.sessionId // "") != "" and (.name // "") != ""))
         | sort_by(.updatedAt // 0)
         | map({key: .sessionId, value: {name: .name, status: (.status // "")}})
         | from_entries' "$@" 2>/dev/null)" || out=""
  case "$out" in
    '{'*) printf '%s' "$out" ;;
    *)    printf '{}' ;;
  esac
}

# Short session id for display.
wb_short() { printf '%s' "${1:0:8}"; }

# Derive a ticket id from worktree dir / branch names passed as args, using the
# same id shape as prompt sniffing so every tracker works, not just one project:
#   "ethenapayf-1003-history-window" -> ETHENAPAYF-1003
#   "jira-12-login-fix"              -> JIRA-12
#   "feature/ETHEN-447"              -> ETHEN-447
# Prints nothing if no match. Tighten CC_WHITEBOARD_TICKET_RE if a directory
# naming scheme produces false hits (e.g. "portfolio-2024" -> PORTFOLIO-2024).
wb_ticket_from_names() {
  local name up m
  for name in "$@"; do
    [ -n "$name" ] || continue
    up="$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')"
    m="$(grep -oE "$WB_TICKET_RE" <<< "$up" | head -n1 || true)"
    # Fallback: hyphenless project ids ("ethenapayf1003").
    if [ -z "$m" ]; then
      m="$(grep -oE '(ETHENAPAYF|ETHEN)[0-9]+' <<< "$up" | head -n1 \
           | sed -E 's/^(ETHENAPAYF|ETHEN)/\1-/' || true)"
    fi
    if [ -n "$m" ]; then
      printf '%s' "$m"
      return 0
    fi
  done
  return 1
}

# --- Resource claims -------------------------------------------------------

# Repo key for scoping a resource name. Uses --git-common-dir, NOT
# --show-toplevel: a linked worktree's toplevel is its OWN directory, so
# --show-toplevel gives every worktree a different key and defeats the whole
# point. --git-common-dir returns the MAIN repo's .git from inside a worktree,
# which is the real collision domain (shared DB, shared ports).
wb_repo_key() {
  local d="${1:-$PWD}" g
  [ -d "$d" ] || return 1
  g="$(git -C "$d" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [ -n "$g" ] || return 1
  basename "$(dirname "$g")"
}

# "<bare>@<repo>", or bare when the directory is not a git repo. The registry is
# shared by every repo on the machine, so an unscoped name would let one
# project's local-stack block an unrelated project's.
wb_resource_name() {
  local repo
  repo="$(wb_repo_key "${2:-$PWD}" 2>/dev/null || true)"
  if [ -n "$repo" ]; then printf '%s@%s' "$1" "$repo"; else printf '%s' "$1"; fi
}

# {sessionId: {pid, procStart, updatedAt}} from Claude Code's own session
# registry. Unlike wb_peer_names this does NOT filter on `name`: liveness does
# not need an address, and filtering on one would report an unnamed session as
# dead and let another session steal its hold.
wb_live_pids() {
  local out
  set -- "$WB_SESSIONS_DIR"/*.json
  [ -e "$1" ] || { printf '{}'; return 0; }
  out="$(jq -s 'map(select((.sessionId // "") != "" and (.pid // 0) > 0))
         | map({key: .sessionId,
                value: {pid: .pid,
                        procStart: (.procStart // ""),
                        updatedAt: (.updatedAt // 0)}})
         | from_entries' "$@" 2>/dev/null)" || out=""
  case "$out" in '{'*) printf '%s' "$out" ;; *) printf '{}' ;; esac
}

# Can we see liveness at all? An empty or absent session registry means the
# INSTRUMENT is blind, not that every session is dead. Without this guard the
# feature inverts on such a machine: every holder reads dead, every hold is
# reclaimed, and locking silently stops working while reporting success.
wb_liveness_known() { [ "$(wb_live_pids)" != "{}" ]; }

# Is <pid> the same process <procStart> was recorded for?
# Errs SAFE: anything undeterminable returns "alive", so an unclear signal
# leaves a phantom (clearable with /force) instead of stealing a live hold.
wb_pid_alive() {
  local pid="$1" want="${2:-}" got
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  [ -n "$want" ] || return 0
  # procStart is stored in UTC; a bare `ps -o lstart=` prints LOCAL time, so on
  # a +04 machine the two differ by four hours and a naive compare always fails.
  got="$(TZ=UTC ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//; s/ *$//')"
  [ -n "$got" ] || return 0
  [ "$got" = "$want" ]
}

# Exit 0 when the session is alive OR liveness is unknown; 1 only for a
# positively dead session.
wb_session_alive() {
  local sid="$1" lp="${2:-}" pid ps
  [ -n "$lp" ] || lp="$(wb_live_pids)"
  [ "$lp" != "{}" ] || return 0          # blind instrument -> not dead
  pid="$(jq -r --arg s "$sid" '.[$s].pid // ""' <<< "$lp" 2>/dev/null)"
  ps="$(jq -r --arg s "$sid" '.[$s].procStart // ""' <<< "$lp" 2>/dev/null)"
  [ -n "$pid" ] || return 1
  wb_pid_alive "$pid" "$ps"
}

# Resource pattern map. Shipped defaults stay GENERIC: this plugin is public, so
# project-specific recipes (just stack::up, just db::migrate) belong in a user's
# CC_WHITEBOARD_RESOURCES override, not here.
#   claim   ERE -> running this takes the resource
#   release ERE -> running this gives it back
#   probe   shell command, exit 0 = the resource is really up ("" = no probe)
#
# Every pattern is anchored to COMMAND POSITION — start of the command line, or
# just after a `;`, `&`, `|` or `(`. A bare word-boundary match claimed on the
# mere APPEARANCE of the name: a sed writing the literal string
# `your-tunnel.ngrok-free.dev` into a config file took the local-stack hold and
# queued a second session behind it for half an hour with no stack running.
# A claim is recorded BEFORE the command runs and blocks every other session, so
# a false positive costs a peer its whole run, while a false negative costs only
# the protection this plugin adds on top of having no plugin at all.
WB_RESOURCES_DEFAULT='{
  "local-stack": {
    "claim":   "(^|[;&|(])[[:space:]]*(docker[- ]compose\\b.*\\bup\\b|ngrok\\b)",
    "release": "(^|[;&|(])[[:space:]]*docker[- ]compose\\b.*\\bdown\\b",
    "probe":   ""
  },
  "xcode": {
    "claim":   "(^|[;&|(])[[:space:]]*(xcodebuild\\b|xcrun +simctl +(boot|install|launch))",
    "release": "(^|[;&|(])[[:space:]]*xcrun +simctl +shutdown",
    "probe":   ""
  }
}'
WB_HOLD_IDLE="${CC_WHITEBOARD_HOLD_IDLE:-3600}"
WB_RESERVE="${CC_WHITEBOARD_RESERVE:-300}"
WB_WAIT_TTL="${CC_WHITEBOARD_WAIT_TTL:-7200}"
WB_PROBE_TIMEOUT="${CC_WHITEBOARD_PROBE_TIMEOUT:-2}"
# A claim is recorded BEFORE the command runs, so a just-claimed stack is not up
# yet. Without this, a probe reporting DOWN during boot declares the holder a
# phantom and lets a second session claim — reintroducing the exact collision the
# feature prevents. A probe cannot contradict a hold that has not had time to
# become true.
WB_PROBE_GRACE="${CC_WHITEBOARD_PROBE_GRACE:-300}"

wb_resources() { printf '%s' "${CC_WHITEBOARD_RESOURCES:-$WB_RESOURCES_DEFAULT}"; }

# Bare resource names whose <action> pattern matches <command>, one per line.
# One command can match several resources; the caller must treat that as an
# all-or-nothing set, never as independent claims.
#
# One jq call emits every (name, pattern) pair, name and pattern on alternating
# lines. Reading the map key-by-key cost 1 + N spawns instead of 1, and this runs
# twice on every Bash tool call in every session — ~7 ms per jq process, paid
# thousands of times a day.
#
# NOT @tsv, and not any other jq escaping format: @tsv doubles backslashes, so
# `\b` arrives as a literal backslash-then-b and every word-boundary pattern
# silently stops matching. Verified at byte level (`\ b` -> `\ \ b`), which took
# 26 assertions red to notice. Plain `jq -r` emits the string as-is; a pattern
# containing a newline would break the pairing, but a newline is meaningless in
# an ERE and `grep -E` could not use one anyway.
wb_match_resources() {
  local cmd="$1" action="${2:-claim}" name re
  while IFS= read -r name && IFS= read -r re; do
    [ -n "$name" ] && [ -n "$re" ] || continue
    # Here-string, not printf|grep: grep -q exits at the first match and SIGPIPEs
    # the writer, which under pipefail turns a MATCH into a failure on long input.
    if grep -qE "$re" <<< "$cmd" 2>/dev/null; then printf '%s\n' "$name"; fi
  done <<< "$(wb_resources | jq -r --arg a "$action" '
      to_entries[] | select((.value[$a] // "") != "") | .key, .value[$a]' 2>/dev/null)"
  return 0
}

# 0 = up, 1 = down, 2 = unknown. Unknown must never release a hold: a probe we
# could not run is silence from a blind instrument, not evidence of absence.
wb_probe() {
  local cmd rc
  cmd="$(wb_resources | jq -r --arg n "$1" '.[$n].probe // ""' 2>/dev/null)"
  [ -n "$cmd" ] || return 2
  if command -v timeout >/dev/null 2>&1; then
    timeout "$WB_PROBE_TIMEOUT" sh -c "$cmd" >/dev/null 2>&1
  else
    sh -c "$cmd" >/dev/null 2>&1
  fi
  rc=$?
  case "$rc" in
    0)   return 0 ;;
    127) return 2 ;;   # command not found -> we learned nothing
    124) return 2 ;;   # timeout(1) killed it -> we learned nothing
    *)   return 1 ;;
  esac
}

# Claim. Idempotent: re-running the same command must NOT refresh `since`, or an
# idle holder could hold a resource forever by repeating its own command.
wb_hold() {
  wb_update '.sessions[$s] = ((.sessions[$s] // {})
      + {holds: ((.sessions[$s].holds // {})
                 | if has($r) then . else . + {($r): ($n|tonumber)} end)})' \
    --arg s "$1" --arg r "$2" --arg n "$(wb_now)" 2>/dev/null || true
}

wb_unhold() {
  wb_update 'if .sessions[$s] then .sessions[$s].holds |= (. // {} | del(.[$r])) else . end' \
    --arg s "$1" --arg r "$2" 2>/dev/null || true
}

wb_add_wait() {
  wb_update '.sessions[$s] = ((.sessions[$s] // {})
      + {waits: ((.sessions[$s].waits // {})
                 | if has($r) then . else . + {($r): {since:($n|tonumber), until:0}} end)})' \
    --arg s "$1" --arg r "$2" --arg n "$(wb_now)" 2>/dev/null || true
}

wb_drop_wait() {
  wb_update 'if .sessions[$s] then .sessions[$s].waits |= (. // {} | del(.[$r])) else . end' \
    --arg s "$1" --arg r "$2" 2>/dev/null || true
}

# Give every current waiter a head start over sessions that never waited. This
# is the whole of "auto-grant": a timestamp, not a state machine. Nobody is
# assigned ownership, so nobody ends up holding what they no longer want.
wb_open_window() {
  local secs="${2:-$WB_RESERVE}"
  [ "$secs" -gt 0 ] 2>/dev/null || return 0
  wb_update '.sessions |= with_entries(
      if (.value.waits // {}) | has($r)
      then .value.waits[$r].until = (($n|tonumber) + ($s|tonumber))
      else . end)' \
    --arg r "$1" --arg n "$(wb_now)" --arg s "$secs" 2>/dev/null || true
}

# Ensure this session has a row and refresh its heartbeat. A write from a slash
# command must not land on a session the board has never seen, and must not
# leave a row without `updated` — status.sh does arithmetic on it.
wb_touch() {
  wb_update '.sessions[$s] = ((.sessions[$s] // {})
      + {updated:($n|tonumber), started:((.sessions[$s].started) // ($n|tonumber))})' \
    --arg s "$1" --arg n "$(wb_now)" 2>/dev/null || true
}

wb_set_label() {
  wb_update '.sessions[$s] = ((.sessions[$s] // {}) + {label:$l})' \
    --arg s "$1" --arg l "$2" 2>/dev/null || true
}

wb_clear_label() {
  wb_update 'if .sessions[$s] then .sessions[$s].label = null else . end' \
    --arg s "$1" 2>/dev/null || true
}

# Take <resource> from whoever holds it and give it to <self>. Prints one line
# naming the previous holders, or saying it was already free. Shared by the
# @wb-force marker and scripts/board.sh so the two entry points cannot drift.
wb_force() {
  local res="$1" self="$2" prev p
  prev="$(jq -r --arg r "$res" --arg self "$self" '
      .sessions | to_entries
      | map(select(.key != $self and ((.value.holds // {}) | has($r))))
      | .[].key' <<< "$(wb_read_fresh)" 2>/dev/null)"
  for p in $prev; do wb_unhold "$p" "$res"; done
  wb_hold "$self" "$res"
  if [ -n "$prev" ]; then
    echo "[claude-whiteboard] forced \"$res\" — taken from session(s): $(printf '%s' "$prev" | tr '\n' ' ' | sed 's/ *$//')."
  else
    echo "[claude-whiteboard] \"$res\" was already free; you hold it now."
  fi
}

# Holder of <resource>, excluding <self>, or nothing when free.
# Prints 5 lines: sid, dir, branch, since, state(hard|soft). One field per line
# because "|" is legal in a branch name and TAB is IFS whitespace, either of
# which would shift the fields on a single delimited line.
wb_holder_of() {
  local r="$1" self="$2" bare="${3:-}" fresh lp now line
  local sid dir br since updated pstate
  fresh="$(wb_read_fresh)"; lp="$(wb_live_pids)"; now="$(wb_now)"

  pstate=2
  if [ -n "$bare" ]; then wb_probe "$bare"; pstate=$?; fi

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    sid="$(cut -f1 <<< "$line")";   dir="$(cut -f2 <<< "$line")"
    br="$(cut -f3 <<< "$line")";    since="$(cut -f4 <<< "$line")"
    updated="$(cut -f5 <<< "$line")"
    wb_session_alive "$sid" "$lp" || continue      # dead -> phantom, skip
    # Probe says DOWN: a hold old enough that the resource SHOULD be up by now is
    # a phantom, but a hold still inside the startup grace is a boot in progress.
    if [ "$pstate" -eq 1 ] && [ $(( now - since )) -ge "$WB_PROBE_GRACE" ]; then
      continue
    fi
    if [ "$pstate" -eq 0 ]; then
      # A probe saying UP outranks idleness: an hour of session silence is
      # normal while the user hand-tests on a device.
      printf '%s\n%s\n%s\n%s\nhard\n' "$sid" "$dir" "$br" "$since"
    elif [ $(( now - updated )) -ge "$WB_HOLD_IDLE" ]; then
      printf '%s\n%s\n%s\n%s\nsoft\n' "$sid" "$dir" "$br" "$since"
    else
      printf '%s\n%s\n%s\n%s\nhard\n' "$sid" "$dir" "$br" "$since"
    fi
    return 0
  done <<< "$(jq -r --arg r "$r" --arg self "$self" '
      def clean: (. // "") | tostring | gsub("[\n\t\r]"; " ");
      .sessions | to_entries
      | map(select(.key != $self and ((.value.holds // {})[$r] // 0) > 0))
      | sort_by(.value.holds[$r])
      | .[] | [ (.key|clean), (.value.dir|clean), (.value.branch|clean),
                (.value.holds[$r]|tostring), (.value.updated|tostring) ]
      | @tsv' <<< "$fresh" 2>/dev/null)"
  return 0
}

# A live OTHER session whose priority window is still open, or nothing.
# Prints 3 lines: sid, seconds waited, until.
#
# The window holds off sessions that never waited. A session that IS on the
# waiting list is exempt outright — any waiter may take the resource, not only
# the one whose window is longest. Keeping that rule here rather than in the
# caller means a second caller cannot forget it.
wb_reserved_by() {
  local r="$1" self="$2" fresh lp now line sid since untl
  [ "$WB_RESERVE" -gt 0 ] 2>/dev/null || return 0
  fresh="$(wb_read_fresh)"; lp="$(wb_live_pids)"; now="$(wb_now)"
  if [ "$(jq -r --arg s "$self" --arg r "$r" \
        '((.sessions[$s].waits // {}) | has($r))' <<< "$fresh" 2>/dev/null)" = "true" ]; then
    return 0
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    sid="$(cut -f1 <<< "$line")"; since="$(cut -f2 <<< "$line")"
    untl="$(cut -f3 <<< "$line")"
    [ $(( now - since )) -lt "$WB_WAIT_TTL" ] || continue   # stale wait
    wb_session_alive "$sid" "$lp" || continue
    printf '%s\n%s\n%s\n' "$sid" "$(( now - since ))" "$untl"
    return 0
  done <<< "$(jq -r --arg r "$r" --arg self "$self" --arg n "$(wb_now)" '
      .sessions | to_entries
      | map(select(.key != $self
              and ((.value.waits // {})[$r].until // 0) > ($n|tonumber)))
      | sort_by(.value.waits[$r].since)
      | .[] | [ .key, (.value.waits[$r].since|tostring),
                (.value.waits[$r].until|tostring) ] | @tsv' <<< "$fresh" 2>/dev/null)"
  return 0
}

# Delete <resource> holds belonging to positively-dead sessions and print their
# short ids, one per line. A dead session's hold is invisible to wb_holder_of
# but still sits in the registry, where it would render on the board forever.
#
# The `wb_liveness_known` line below is an EARLY-OUT, not the safety guard.
# Mutation-checked: removing it leaves every test green, because wb_session_alive
# already returns "alive" when the session registry is unreadable. That guard —
# `[ "$lp" != "{}" ]` in wb_session_alive — is the load-bearing one, and removing
# IT turns "blind liveness still blocks" red. Keep this line to skip the jq and
# the loop entirely when there is nothing to learn; do not mistake it for the
# thing standing between "reclaim crashed sessions" and "silently disable the
# lock on any machine with no session registry".
wb_sweep_dead_holds() {
  local r="$1" fresh lp sid swept=""
  wb_liveness_known || return 0
  fresh="$(wb_read_fresh)"; lp="$(wb_live_pids)"
  while IFS= read -r sid; do
    [ -n "$sid" ] || continue
    wb_session_alive "$sid" "$lp" && continue
    wb_unhold "$sid" "$r"
    swept="${swept}${sid:0:8}
"
  done <<< "$(jq -r --arg r "$r" '
      .sessions | to_entries
      | map(select(((.value.holds // {})[$r] // 0) > 0))
      | .[].key' <<< "$fresh" 2>/dev/null)"
  [ -n "$swept" ] && printf '%s' "$swept"
  return 0
}

# Take <resource> for <sid> ONLY if no OTHER session already holds it, then
# report who actually got it. Returns 0 when this session holds it afterwards.
#
# The check and the write happen inside ONE jq expression under ONE lock. Doing
# them as separate steps — wb_holder_of, then wb_hold — leaves a gap in which
# two sessions both read "free" and both write: measured 5 of 12 concurrent
# claimers winning the same resource, which is precisely the double-stack
# corruption this feature exists to prevent.
#
# The re-read is not paranoia: `wb_update` reports nothing about whether its
# condition fired, so the write's success is not the resulting state.
wb_hold_exclusive() {
  local sid="$1" res="$2"
  wb_update '
    if (.sessions | to_entries
        | map(select(.key != $s and ((.value.holds // {}) | has($r))))
        | length) == 0
    then .sessions[$s] = ((.sessions[$s] // {})
         + {holds: ((.sessions[$s].holds // {})
                    | if has($r) then . else . + {($r): ($n|tonumber)} end)})
    else . end' \
    --arg s "$sid" --arg r "$res" --arg n "$(wb_now)" 2>/dev/null || true
  [ "$(wb_read_fresh | jq -r --arg s "$sid" --arg r "$res" \
        '((.sessions[$s].holds // {}) | has($r))' 2>/dev/null)" = "true" ]
}
