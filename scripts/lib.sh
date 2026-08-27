#!/usr/bin/env bash
# claude-whiteboard shared library — registry location, config, atomic read/write.
# Sourced by every hook script. No output here.

# --- Config (all overridable via env) -------------------------------------

# Registry file. Default: per-user, shared across ALL sessions & worktrees.
# CLAUDE_PLUGIN_DATA persists across plugin updates; fall back to ~/.claude.
WB_REGISTRY="${CC_WHITEBOARD_REGISTRY:-${CLAUDE_PLUGIN_DATA:-$HOME/.claude}/whiteboard/registry.json}"

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
WB_RESOURCES_DEFAULT='{
  "local-stack": {
    "claim":   "docker[- ]compose\\b.*\\bup\\b|\\bngrok\\b",
    "release": "docker[- ]compose\\b.*\\bdown\\b",
    "probe":   ""
  },
  "xcode": {
    "claim":   "\\bxcodebuild\\b|xcrun +simctl +(boot|install|launch)",
    "release": "xcrun +simctl +shutdown",
    "probe":   ""
  }
}'
WB_HOLD_IDLE="${CC_WHITEBOARD_HOLD_IDLE:-3600}"
WB_RESERVE="${CC_WHITEBOARD_RESERVE:-300}"
WB_WAIT_TTL="${CC_WHITEBOARD_WAIT_TTL:-7200}"
WB_PROBE_TIMEOUT="${CC_WHITEBOARD_PROBE_TIMEOUT:-2}"

wb_resources() { printf '%s' "${CC_WHITEBOARD_RESOURCES:-$WB_RESOURCES_DEFAULT}"; }

# Bare resource names whose <action> pattern matches <command>, one per line.
# One command can match several resources; the caller must treat that as an
# all-or-nothing set, never as independent claims.
wb_match_resources() {
  local cmd="$1" action="${2:-claim}" name re res
  res="$(wb_resources)"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    re="$(jq -r --arg n "$name" --arg a "$action" '.[$n][$a] // ""' <<< "$res" 2>/dev/null)"
    [ -n "$re" ] || continue
    # Here-string, not printf|grep: grep -q exits at the first match and SIGPIPEs
    # the writer, which under pipefail turns a MATCH into a failure on long input.
    if grep -qE "$re" <<< "$cmd" 2>/dev/null; then printf '%s\n' "$name"; fi
  done <<< "$(jq -r 'keys[]' <<< "$res" 2>/dev/null)"
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
