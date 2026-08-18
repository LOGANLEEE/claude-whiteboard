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
