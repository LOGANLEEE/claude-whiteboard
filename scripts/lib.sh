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

# Short session id for display.
wb_short() { printf '%s' "${1:0:8}"; }
