#!/usr/bin/env bash
# Behavior tests for scripts/on-pretool.sh — resource claims.
# Pure bash + jq: feeds PreToolUse JSON on stdin against a throwaway registry.
# Run: bash tests/on-pretool.test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/scripts/on-pretool.sh"
unset CC_WHITEBOARD_TICKET_RE CC_WHITEBOARD_TTL
unset CC_WHITEBOARD_RESOURCES CC_WHITEBOARD_HOLD_IDLE CC_WHITEBOARD_RESERVE
unset CC_WHITEBOARD_WAIT_TTL CC_WHITEBOARD_PROBE_TIMEOUT

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CC_WHITEBOARD_REGISTRY="$WORK/registry.json"
ERRLOG="$WORK/stderr"; RCF="$WORK/rc"

SESSDIR="$WORK/sessions"; mkdir -p "$SESSDIR"
export CC_WHITEBOARD_SESSIONS_DIR="$SESSDIR"
MYSTART="$(TZ=UTC ps -o lstart= -p $$ 2>/dev/null | sed 's/^ *//; s/ *$//')"
# Named by sid: wb_live_pids globs *.json and keys on the sessionId inside, so
# the filename does not matter and several fixtures can share one live pid.
sessfile() {  # sessfile <sid> <pid> <procStart> [name]
  jq -n --arg s "$1" --argjson p "$2" --arg ps "$3" --arg n "${4:-}" \
    '{sessionId:$s, pid:$p, procStart:$ps, kind:"interactive",
      status:"idle", updatedAt:1}
     + (if $n != "" then {name:$n} else {} end)' > "$SESSDIR/$1.json"
}
sessfile A $$     "$MYSTART"                 alpha
sessfile B $$     "$MYSTART"                 bravo
sessfile C $$     "$MYSTART"                 charlie
sessfile D 999999 "Mon Jan  1 00:00:00 2020" delta   # crashed

# Two separate repos, so the @repo suffix can be shown to isolate them.
R1="$WORK/repo-one"; R2="$WORK/repo-two"
for r in "$R1" "$R2"; do
  mkdir -p "$r"; git init -q -b main "$r"
  git -C "$r" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
done

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$1" "$2" "$3"; }
eq()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
has()  { case "$3" in *"$2"*) ok "$1";; *) bad "$1" "contains: $2" "$3";; esac; }

reset() { printf '{"sessions":{}}' > "$CC_WHITEBOARD_REGISTRY"; }
runp() {  # runp <sid> <cwd> <command>
  jq -nc --arg s "$1" --arg c "$2" --arg cmd "$3" \
    '{session_id:$s, cwd:$c, tool_name:"Bash", tool_input:{command:$cmd}}' \
    | bash "$HOOK" > "$WORK/out" 2>"$ERRLOG"
  printf '%s' "${PIPESTATUS[1]}" > "$RCF"
  cat "$WORK/out"
}
rc()  { cat "$RCF"; }
err() { cat "$ERRLOG"; }
q()   { jq -r "$1" "$CC_WHITEBOARD_REGISTRY"; }

echo "registry: $CC_WHITEBOARD_REGISTRY"

# --- 1. an unmatched command is a silent no-op -----------------------------
reset
runp A "$R1" "ls -la" >/dev/null
eq "unmatched command exits 0"        "0" "$(rc)"
eq "unmatched command is silent"      ""  "$(err)"
eq "unmatched command writes no hold" "0" "$(q '[.sessions[]|(.holds//{})|length]|add // 0')"

# --- 2. claiming a free resource ------------------------------------------
reset
runp A "$R1" "docker compose up -d" >/dev/null
eq "claim exits 0"   "0" "$(rc)"
eq "claim is silent" ""  "$(err)"
eq "hold recorded, repo-scoped" "true" \
   "$(q '.sessions.A.holds | has("local-stack@repo-one")')"
# A hold written without a heartbeat is invisible: wb_read_fresh drops any entry
# whose `updated` is missing, so the claim would silently block nobody. Asserted
# directly so a regression fails on the cause, not on a downstream symptom.
eq "claim also heartbeats the session" "true" \
   "$(q '(.sessions.A.updated // 0) > 0')"
eq "claim records dir for the block message" "repo-one" "$(q '.sessions.A.dir')"

# --- 3. a second session is blocked and recorded as a waiter --------------
runp B "$R1" "docker compose up -d" >/dev/null
eq  "blocked with exit 2" "2" "$(rc)"
has "block names the resource" 'local-stack@repo-one'     "$(err)"
has "block names the holder"   'alpha'                    "$(err)"
has "block offers SendMessage" 'SendMessage({to: "alpha"' "$(err)"
eq  "waiter recorded" "true" "$(q '.sessions.B.waits | has("local-stack@repo-one")')"
eq  "blocked session takes no hold" "false" \
    "$(q '.sessions.B | (.holds // {}) | has("local-stack@repo-one")')"

# --- 4. the same bare name in another repo does not collide ---------------
runp C "$R2" "docker compose up -d" >/dev/null
eq "other repo claims freely" "0" "$(rc)"
eq "other repo hold is separate" "true" \
   "$(q '.sessions.C.holds | has("local-stack@repo-two")')"

# --- 5. re-claiming your own hold is idempotent ---------------------------
SINCE="$(q '.sessions.A.holds["local-stack@repo-one"]')"
sleep 1
runp A "$R1" "docker compose up -d" >/dev/null
eq "holder re-claim exits 0" "0" "$(rc)"
eq "holder re-claim keeps since" "$SINCE" "$(q '.sessions.A.holds["local-stack@repo-one"]')"

# --- 6. a compound command is all-or-nothing ------------------------------
reset
runp A "$R1" "docker compose up -d" >/dev/null
runp B "$R1" "docker compose up -d && xcodebuild -scheme App" >/dev/null
eq "compound blocked by one held resource" "2" "$(rc)"
eq "no partial hold on the free resource" "false" \
   "$(q '.sessions.B | (.holds // {}) | has("xcode@repo-one")')"

# --- 7. a non-Bash tool is a no-op ----------------------------------------
reset
jq -nc --arg c "$R1" '{session_id:"A", cwd:$c, tool_name:"Read",
                       tool_input:{file_path:"/x"}}' \
  | bash "$HOOK" >/dev/null 2>"$ERRLOG"
eq "non-Bash tool exits 0"   "0" "$?"
eq "non-Bash tool is silent" ""  "$(err)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
