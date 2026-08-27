#!/usr/bin/env bash
# Unit tests for scripts/lib.sh helpers (resource claims).
# Pure bash + jq. Run: bash tests/lib.test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset CC_WHITEBOARD_TICKET_RE CC_WHITEBOARD_TTL CC_WHITEBOARD_SESSIONS_DIR
unset CC_WHITEBOARD_RESOURCES CC_WHITEBOARD_HOLD_IDLE CC_WHITEBOARD_RESERVE

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CC_WHITEBOARD_REGISTRY="$WORK/registry.json"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$1" "$2" "$3"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
yes() { if "${@:2}"; then ok "$1"; else bad "$1" "exit 0" "exit $?"; fi; }
no()  { if "${@:2}"; then bad "$1" "non-zero" "exit 0"; else ok "$1"; fi; }

# shellcheck source=../scripts/lib.sh
source "$ROOT/scripts/lib.sh"

# --- repo key groups worktrees ---------------------------------------------
MAIN="$WORK/mainrepo"
mkdir -p "$MAIN"
git init -q -b main "$MAIN"
git -C "$MAIN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$MAIN" worktree add -q "$WORK/wt-a" -b wt-a 2>/dev/null

eq "repo key from main checkout"  "mainrepo" "$(wb_repo_key "$MAIN")"
eq "repo key from linked worktree" "mainrepo" "$(wb_repo_key "$WORK/wt-a")"
eq "non-git dir has no repo key"  ""         "$(wb_repo_key "$WORK" 2>/dev/null)"

eq "resource name is repo-scoped" "local-stack@mainrepo" \
   "$(wb_resource_name local-stack "$MAIN")"
eq "resource name bare outside a repo" "local-stack" \
   "$(wb_resource_name local-stack "$WORK")"

# --- PID liveness ----------------------------------------------------------
SESSDIR="$WORK/sessions"; mkdir -p "$SESSDIR"
export CC_WHITEBOARD_SESSIONS_DIR="$SESSDIR"
WB_SESSIONS_DIR="$SESSDIR"
MYSTART="$(TZ=UTC ps -o lstart= -p $$ 2>/dev/null | sed 's/^ *//; s/ *$//')"

sessfile() {  # sessfile <sid> <pid> <procStart> [name]
  jq -n --arg s "$1" --argjson p "$2" --arg ps "$3" --arg n "${4:-}" \
    '{sessionId:$s, pid:$p, procStart:$ps, kind:"interactive",
      status:"idle", updatedAt:1}
     + (if $n != "" then {name:$n} else {} end)' > "$SESSDIR/$2.json"
}
sessfile LIVE    $$     "$MYSTART"                  live-peer
sessfile GONE    999999 "Mon Jan  1 00:00:00 2020"  gone-peer
sessfile REUSED  999998 "Mon Jan  1 00:00:00 2020"  reused-peer
sessfile UNNAMED 999997 "Mon Jan  1 00:00:00 2020"  ""

LP="$(wb_live_pids)"
eq "live_pids keyed by sessionId" "$$" "$(jq -r '.LIVE.pid' <<< "$LP")"
eq "live_pids keeps unnamed sessions" "999997" "$(jq -r '.UNNAMED.pid' <<< "$LP")"

yes "liveness is known when files exist" wb_liveness_known
yes "our own pid is alive"    wb_pid_alive "$$" "$MYSTART"
no  "a nonexistent pid is dead" wb_pid_alive 999999 "Mon Jan  1 00:00:00 2020"
no  "procStart mismatch is dead (pid reuse)" wb_pid_alive "$$" "Mon Jan  1 00:00:00 2020"
yes "empty procStart falls back to kill -0" wb_pid_alive "$$" ""
no  "non-numeric pid is dead" wb_pid_alive "abc" ""

yes "session_alive: live session"   wb_session_alive LIVE   "$LP"
no  "session_alive: gone session"   wb_session_alive GONE   "$LP"
no  "session_alive: absent from registry" wb_session_alive NOSUCH "$LP"

# --- the instrument guard: empty registry means UNKNOWN, never dead --------
EMPTY="$WORK/empty-sessions"; mkdir -p "$EMPTY"
CC_WHITEBOARD_SESSIONS_DIR="$EMPTY" \
  bash -c 'source "'"$ROOT"'/scripts/lib.sh"
           wb_liveness_known && echo KNOWN || echo UNKNOWN' > "$WORK/o"
eq "empty session dir reports liveness UNKNOWN" "UNKNOWN" "$(cat "$WORK/o")"

CC_WHITEBOARD_SESSIONS_DIR="$EMPTY" \
  bash -c 'source "'"$ROOT"'/scripts/lib.sh"
           wb_session_alive ANY "$(wb_live_pids)" && echo ALIVE || echo DEAD' > "$WORK/o"
eq "unknown liveness treats any session as ALIVE" "ALIVE" "$(cat "$WORK/o")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
