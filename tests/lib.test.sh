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

# Named by SID, not pid. Claude Code names these <pid>.json, but wb_live_pids
# globs *.json and keys on the sessionId INSIDE, so the filename is functionally
# irrelevant — and sid-naming lets several test sessions share one live pid.
sessfile() {  # sessfile <sid> <pid> <procStart> [name]
  jq -n --arg s "$1" --argjson p "$2" --arg ps "$3" --arg n "${4:-}" \
    '{sessionId:$s, pid:$p, procStart:$ps, kind:"interactive",
      status:"idle", updatedAt:1}
     + (if $n != "" then {name:$n} else {} end)' > "$SESSDIR/$1.json"
}
sessfile LIVE    $$     "$MYSTART"                  live-peer
sessfile GONE    999999 "Mon Jan  1 00:00:00 2020"  gone-peer
sessfile REUSED  999998 "Mon Jan  1 00:00:00 2020"  reused-peer
sessfile UNNAMED 999997 "Mon Jan  1 00:00:00 2020"  ""
# Waiters used further down. They must be positively ALIVE: once the session
# registry is non-empty, liveness is KNOWN, and a waiter with no session file
# reads as dead and correctly forfeits its reservation.
sessfile W1      $$     "$MYSTART"                  waiter-one
sessfile W2      $$     "$MYSTART"                  waiter-two

LP="$(wb_live_pids)"
eq "live_pids keyed by sessionId" "$$" "$(jq -r '.LIVE.pid' <<< "$LP")"
eq "live_pids keeps unnamed sessions" "999997" "$(jq -r '.UNNAMED.pid' <<< "$LP")"

yes "liveness is known when files exist" wb_liveness_known
yes "our own pid is alive"    wb_pid_alive "$$" "$MYSTART"
no  "a nonexistent pid is dead" wb_pid_alive 999999 "Mon Jan  1 00:00:00 2020"
no  "procStart mismatch is dead (pid reuse)" wb_pid_alive "$$" "Mon Jan  1 00:00:00 2020"
yes "empty procStart falls back to kill -0" wb_pid_alive "$$" ""
no  "non-numeric pid is dead" wb_pid_alive "abc" ""

# `ps` yielding nothing for a pid `kill -0` accepted is UNKNOWN, not dead. A
# container or a locked-down sandbox can produce exactly that, and treating it
# as dead would hand the resource away from a live holder. Stubbed, because a
# pid that passes kill -0 while ps stays silent cannot be arranged on purpose.
ps() { :; }
yes "silent ps keeps the holder alive" wb_pid_alive "$$" "Mon Jan  1 00:00:00 2020"
unset -f ps
no  "and the real ps still detects reuse" wb_pid_alive "$$" "Mon Jan  1 00:00:00 2020"

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

# --- resource config + command matching ------------------------------------
eq "default map has local-stack" "true"  "$(wb_resources | jq 'has("local-stack")')"
eq "default map has xcode"       "true"  "$(wb_resources | jq 'has("xcode")')"

m() { wb_match_resources "$1" "${2:-claim}" | tr '\n' ',' ; }

eq "docker compose up claims local-stack" "local-stack," "$(m 'docker compose up -d')"
eq "docker-compose up claims too"         "local-stack," "$(m 'docker-compose up')"
eq "ngrok claims local-stack"             "local-stack," "$(m 'ngrok http 8080')"
eq "docker compose ps claims nothing"     ""             "$(m 'docker compose ps')"
eq "mongrokker is not ngrok"              ""             "$(m 'cat mongrokker.log')"
eq "xcodebuild claims xcode"              "xcode,"       "$(m 'xcodebuild -scheme App')"
eq "simctl boot claims xcode"             "xcode,"       "$(m 'xcrun simctl boot ABC')"
eq "docker compose down releases"    "local-stack," "$(m 'docker compose down' release)"
eq "docker compose down does not claim" ""          "$(m 'docker compose down')"
eq "ls claims nothing"                    ""             "$(m 'ls -la')"

out="$(m 'docker compose up -d && xcodebuild -scheme App')"
case "$out" in
  *local-stack*) case "$out" in
      *xcode*) ok "compound command matches both";;
      *) bad "compound command matches both" "both" "$out";; esac;;
  *) bad "compound command matches both" "both" "$out";;
esac

CC_WHITEBOARD_RESOURCES='{"db":{"claim":"just +db::migrate","release":"","probe":""}}' \
  bash -c 'source "'"$ROOT"'/scripts/lib.sh"
           wb_match_resources "just db::migrate" claim' > "$WORK/o"
eq "env override replaces the map" "db" "$(cat "$WORK/o")"

# --- probe: three-valued ---------------------------------------------------
probe_rc() {  # probe_rc <probe-command>
  CC_WHITEBOARD_RESOURCES="$(jq -nc --arg p "$1" \
      '{r:{claim:"never-matches-anything",release:"",probe:$p}}')" \
    bash -c 'source "'"$ROOT"'/scripts/lib.sh"; wb_probe r; echo $?' | tail -1
}
eq "probe exit 0 means UP"          "0" "$(probe_rc 'true')"
eq "probe non-zero means DOWN"      "1" "$(probe_rc 'false')"
eq "no probe configured is UNKNOWN" "2" "$(probe_rc '')"
eq "unrunnable probe is UNKNOWN"    "2" "$(probe_rc '/nonexistent/binary/xyz')"

# --- hold / wait state -----------------------------------------------------
NOW="$(date +%s)"
reset_reg() { printf '{"sessions":{}}' > "$CC_WHITEBOARD_REGISTRY"; }
touch_sess() {  # touch_sess <sid> <updated>
  wb_update '.sessions[$s] = ((.sessions[$s] // {}) + {updated:($u|tonumber), started:($u|tonumber)})' \
    --arg s "$1" --arg u "$2"
}
h5() { wb_holder_of "$1" "$2" "${3:-local-stack}" | tr '\n' '|'; }

reset_reg
touch_sess LIVE "$NOW"
wb_hold LIVE "local-stack@r"
eq "hold recorded" "true" \
   "$(jq '.sessions.LIVE.holds | has("local-stack@r")' "$CC_WHITEBOARD_REGISTRY")"
SINCE1="$(jq -r '.sessions.LIVE.holds["local-stack@r"]' "$CC_WHITEBOARD_REGISTRY")"
sleep 1
wb_hold LIVE "local-stack@r"
eq "re-hold does not refresh since" "$SINCE1" \
   "$(jq -r '.sessions.LIVE.holds["local-stack@r"]' "$CC_WHITEBOARD_REGISTRY")"

eq "holder found by another session"    "LIVE" "$(h5 'local-stack@r' OTHER | cut -d'|' -f1)"
eq "holder state is hard while recent"  "hard" "$(h5 'local-stack@r' OTHER | cut -d'|' -f5)"
eq "holder hidden from itself"          ""     "$(h5 'local-stack@r' LIVE)"

reset_reg
touch_sess GONE "$NOW"
wb_hold GONE "local-stack@r"
eq "dead session is not a holder" "" "$(h5 'local-stack@r' OTHER)"

reset_reg
touch_sess LIVE "$((NOW - 7200))"
wb_hold LIVE "local-stack@r"
eq "idle holder goes soft" "soft" "$(h5 'local-stack@r' OTHER | cut -d'|' -f5)"

CC_WHITEBOARD_RESOURCES='{"local-stack":{"claim":"x","release":"","probe":"true"}}' \
  bash -c 'source "'"$ROOT"'/scripts/lib.sh"
           wb_holder_of "local-stack@r" OTHER local-stack | tail -1' > "$WORK/o"
eq "probe UP keeps an idle hold hard" "hard" "$(cat "$WORK/o")"

reset_reg
touch_sess LIVE "$NOW"
wb_hold LIVE "local-stack@r"
CC_WHITEBOARD_RESOURCES='{"local-stack":{"claim":"x","release":"","probe":"false"}}' \
  bash -c 'source "'"$ROOT"'/scripts/lib.sh"
           wb_holder_of "local-stack@r" OTHER local-stack' > "$WORK/o"
eq "probe DOWN means no holder" "" "$(cat "$WORK/o")"

# --- waits and the priority window ----------------------------------------
reset_reg
touch_sess W1 "$NOW"; touch_sess W2 "$NOW"
wb_add_wait W1 "local-stack@r"
wb_add_wait W2 "local-stack@r"
eq "wait recorded with until=0" "0" \
   "$(jq -r '.sessions.W1.waits["local-stack@r"].until' "$CC_WHITEBOARD_REGISTRY")"
eq "no window open yet" "" "$(wb_reserved_by 'local-stack@r' W2 | head -1)"

wb_open_window "local-stack@r" 300
eq "window opened for W1" "true" \
   "$(jq --argjson n "$NOW" '.sessions.W1.waits["local-stack@r"].until > $n' "$CC_WHITEBOARD_REGISTRY")"
eq "a stranger sees the reservation" "W1" "$(wb_reserved_by 'local-stack@r' STRANGER | head -1)"
# Any waiter may claim, not only the one who waited longest — so a waiter is
# exempt from the window even while ANOTHER waiter's window is open.
eq "a waiter is exempt from the window" "" "$(wb_reserved_by 'local-stack@r' W1 | head -1)"
eq "the other waiter is exempt too"     "" "$(wb_reserved_by 'local-stack@r' W2 | head -1)"

wb_drop_wait W1 "local-stack@r"; wb_drop_wait W2 "local-stack@r"
eq "waits cleared" "0" \
   "$(jq '[.sessions[].waits // {} | length] | add' "$CC_WHITEBOARD_REGISTRY")"

reset_reg
touch_sess W1 "$NOW"
wb_update '.sessions.W1.waits = {"local-stack@r":{"since":($t|tonumber),"until":($u|tonumber)}}' \
  --arg t "$((NOW - 99999))" --arg u "$((NOW + 300))"
eq "wait older than WAIT_TTL is ignored" "" "$(wb_reserved_by 'local-stack@r' STRANGER | head -1)"

# A waiter whose process is gone must not keep blocking strangers with a
# reservation nobody is waiting on any more.
reset_reg
touch_sess GONE "$NOW"
wb_update '.sessions.GONE.waits = {"local-stack@r":{"since":($t|tonumber),"until":($u|tonumber)}}' \
  --arg t "$NOW" --arg u "$((NOW + 300))"
eq "a dead waiter forfeits its reservation" "" \
   "$(wb_reserved_by 'local-stack@r' STRANGER | head -1)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
