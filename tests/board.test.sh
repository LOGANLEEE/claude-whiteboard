#!/usr/bin/env bash
# Logic tests for scripts/board.sh — the slash commands' direct entry point.
#
# Why this script exists at all: a slash command body is expanded into a user
# message that the UserPromptSubmit hook never receives, so the `@wb-*` marker
# the command used to ask the model to emit was structurally invisible. The
# session id IS in the environment of a Bash tool call, so the command body
# calls this instead. These tests pin that contract.
#
# Run: bash tests/board.test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOARD="$ROOT/scripts/board.sh"

unset CC_WHITEBOARD_TICKET_RE CC_WHITEBOARD_TTL CC_WHITEBOARD_SESSIONS_DIR
unset CC_WHITEBOARD_RESOURCES CC_WHITEBOARD_HOLD_IDLE CC_WHITEBOARD_RESERVE

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CC_WHITEBOARD_REGISTRY="$WORK/registry.json"

# Liveness fixtures. Without CC_WHITEBOARD_SESSIONS_DIR the library reads the
# REAL ~/.claude/sessions, where S1/S2 do not exist, so every holder here would
# read "crashed" and the refusal path could never be exercised.
SESSDIR="$WORK/sessions"; mkdir -p "$SESSDIR"
export CC_WHITEBOARD_SESSIONS_DIR="$SESSDIR"
MYSTART="$(TZ=UTC ps -o lstart= -p $$ 2>/dev/null | sed 's/^ *//; s/ *$//')"
sessfile() {  # sessfile <sid> <pid> <procStart> [name]
  jq -n --arg s "$1" --argjson p "$2" --arg ps "$3" --arg n "${4:-}" \
    '{sessionId:$s, pid:$p, procStart:$ps, kind:"interactive",
      status:"idle", updatedAt:1}
     + (if $n != "" then {name:$n} else {} end)' > "$SESSDIR/$1.json"
}
sessfile S1 $$     "$MYSTART"                 alpha
sessfile S2 $$     "$MYSTART"                 bravo
sessfile S3 999999 "Mon Jan  1 00:00:00 2020" charlie   # crashed

REPO="$WORK/mainrepo"
mkdir -p "$REPO"
git init -q -b main "$REPO"
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$1" "$2" "$3"; }
eq()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
has()  { case "$3" in *"$2"*) ok "$1";; *) bad "$1" "contains: $2" "$3";; esac; }

reset() { printf '{"sessions":{}}' > "$CC_WHITEBOARD_REGISTRY"; }
q()     { jq -r "$1" "$CC_WHITEBOARD_REGISTRY" 2>/dev/null; }

# run <session-id> <cwd> <args...> -> stdout; exit code lands in $RC.
# Callers use $(run ...), i.e. a subshell, so RC goes through a file.
RCF="$WORK/rc"
run() {
  local sid="$1" cwd="$2"; shift 2
  ( cd "$cwd" && CLAUDE_CODE_SESSION_ID="$sid" bash "$BOARD" "$@" ) 2>"$WORK/err"
  printf '%s' "$?" > "$RCF"
}
rc() { cat "$RCF"; }

# --- use / free ------------------------------------------------------------
reset
out="$(run S1 "$REPO" use xcode)"
eq "use records a repo-scoped hold" "true" \
   "$(q '.sessions.S1.holds | has("xcode@mainrepo")')"
has "use says what it claimed" "xcode@mainrepo" "$out"

out="$(run S1 "$REPO" free xcode)"
eq "free drops the hold" "0" "$(q '.sessions.S1.holds | length')"
eq "free by the real holder succeeds"  "0"          "$(rc)"
has "free by the real holder says so"  "released"   "$out"

# --- free opens the priority window for waiters ----------------------------
reset
run S1 "$REPO" use xcode >/dev/null
NOW="$(date +%s)"
jq --arg n "$NOW" '.sessions.S2 = {updated:($n|tonumber), started:($n|tonumber),
     waits:{"xcode@mainrepo":{since:($n|tonumber), until:0}}}' \
  "$CC_WHITEBOARD_REGISTRY" > "$WORK/tmp" && mv "$WORK/tmp" "$CC_WHITEBOARD_REGISTRY"
run S1 "$REPO" free xcode >/dev/null
eq "free opens the waiter's priority window" "true" \
   "$(q '.sessions.S2.waits["xcode@mainrepo"].until > 0')"

# --- use refuses when someone else holds it --------------------------------
# The bug this pins: `use` called wb_hold, which records a hold whoever else has
# one, and printed "you now hold" unconditionally. Two sessions could hold the
# same resource through /use and both be told they had it — the exact collision
# the PreToolUse hook refuses to allow, reached through the front door.
reset
run S2 "$REPO" use xcode >/dev/null
SINCE_BEFORE="$(q '.sessions.S2.holds["xcode@mainrepo"]')"
out="$(run S1 "$REPO" use xcode)"; err="$(cat "$WORK/err")"
eq  "use against a live holder fails"          "2"     "$(rc)"
eq  "use against a live holder takes nothing"  "false" \
    "$(q '(.sessions.S1.holds // {}) | has("xcode@mainrepo")')"
eq  "use against a live holder leaves the holder alone" "$SINCE_BEFORE" \
    "$(q '.sessions.S2.holds["xcode@mainrepo"]')"
eq  "use against a live holder prints no success" "" "$out"
has "use refusal names the holder"        "S2"           "$err"
has "use refusal gives the peer name"     'to: "bravo"'  "$err"
has "use refusal gives the escape hatch"  "force xcode"  "$err"

# Re-using what this session already holds stays idempotent — `since` must not be
# refreshed, or an idle holder could keep a resource forever by repeating itself.
reset
run S1 "$REPO" use xcode >/dev/null
SINCE_BEFORE="$(q '.sessions.S1.holds["xcode@mainrepo"]')"
out="$(run S1 "$REPO" use xcode)"
eq  "re-using your own hold succeeds" "0" "$(rc)"
eq  "re-using your own hold does not refresh since" "$SINCE_BEFORE" \
    "$(q '.sessions.S1.holds["xcode@mainrepo"]')"
has "re-using your own hold says so" "you now hold" "$out"

# A crashed holder must not block a claim: wb_hold_exclusive refuses on ANY other
# session's row, phantom included, so the sweep has to run first.
reset
run S3 "$REPO" use xcode >/dev/null
out="$(run S1 "$REPO" use xcode)"
eq  "use clears a crashed holder"       "0"    "$(rc)"
eq  "use then takes the resource"       "true" "$(q '.sessions.S1.holds | has("xcode@mainrepo")')"
eq  "the crashed holder's row is gone"  "0"    "$(q '.sessions.S3.holds | length')"
has "the sweep is reported by use"      "crashed session" "$out"

# --- free refuses when someone else holds it -------------------------------
# The bug this pins: wb_unhold deletes from the CALLER's holds, so a non-holder
# deleted nothing while `free` printed "released" unconditionally. A session sat
# blocked for 165 minutes behind a hold it believed it had cleared, twice.
reset
run S2 "$REPO" use xcode >/dev/null
SINCE_BEFORE="$(q '.sessions.S2.holds["xcode@mainrepo"]')"
out="$(run S1 "$REPO" free xcode)"; err="$(cat "$WORK/err")"
eq  "free by a non-holder fails"            "2" "$(rc)"
eq  "free by a non-holder leaves the hold"  "$SINCE_BEFORE" \
    "$(q '.sessions.S2.holds["xcode@mainrepo"]')"
eq  "free by a non-holder prints no success" "" "$out"
has "refusal names the holder"    "S2"       "$err"
has "refusal says nothing changed" "Nothing was changed" "$err"
has "refusal gives the peer name" 'to: "bravo"' "$err"
has "refusal gives the escape hatch" "force xcode" "$err"

# A refusal must not spend the waiters' head start on a resource still held.
reset
run S2 "$REPO" use xcode >/dev/null
NOW="$(date +%s)"
jq --arg n "$NOW" '.sessions.S1 = {updated:($n|tonumber), started:($n|tonumber),
     waits:{"xcode@mainrepo":{since:($n|tonumber), until:0}}}' \
  "$CC_WHITEBOARD_REGISTRY" > "$WORK/tmp" && mv "$WORK/tmp" "$CC_WHITEBOARD_REGISTRY"
run S1 "$REPO" free xcode >/dev/null
eq "a refused free leaves the priority window shut" "0" \
   "$(q '.sessions.S1.waits["xcode@mainrepo"].until')"

# --- free when nobody holds it ---------------------------------------------
reset
out="$(run S1 "$REPO" free xcode)"
eq  "free on a free resource succeeds"  "0"                   "$(rc)"
has "free on a free resource says so"   "nothing to release"  "$out"

# A crashed holder's row is cleared, not reported as somebody else's hold.
reset
run S3 "$REPO" use xcode >/dev/null
out="$(run S1 "$REPO" free xcode)"
eq  "a crashed holder's row is cleared" "0" "$(q '.sessions.S3.holds | length')"
has "the sweep is reported"             "crashed session"    "$out"
has "and then there is nothing to free" "nothing to release" "$out"

# --- force -----------------------------------------------------------------
reset
run S1 "$REPO" use xcode >/dev/null
out="$(run S2 "$REPO" force xcode)"
eq "force takes the hold"              "true" "$(q '.sessions.S2.holds | has("xcode@mainrepo")')"
eq "force strips the previous holder"  "0"    "$(q '.sessions.S1.holds | length')"
has "force names whom it took from"    "S1"   "$out"

reset
out="$(run S2 "$REPO" force xcode)"
has "force on a free resource says so" "already free" "$out"

# --- label claim / release -------------------------------------------------
reset
out="$(run S1 "$REPO" claim 'flaky auth test')"
eq "claim sets the label" "flaky auth test" "$(q '.sessions.S1.label')"
has "claim echoes the label" "flaky auth test" "$out"

run S1 "$REPO" release >/dev/null
eq "release clears the label" "null" "$(q '.sessions.S1.label')"

# --- safety: never write a wrong entry -------------------------------------
# Without the session id there is no way to know whose hold this is. Writing
# anything at all would corrupt another session's row or invent a ghost.
reset
out="$( ( cd "$REPO" && env -u CLAUDE_CODE_SESSION_ID bash "$BOARD" use xcode ) 2>&1 )"
eq "no session id -> registry untouched" "0" "$(q '.sessions | length')"
has "no session id -> says why" "CLAUDE_CODE_SESSION_ID" "$out"

reset
run S1 "$REPO" use >/dev/null
eq "use with no resource is rejected" "0" "$(q '.sessions | length')"
[ "$(rc)" != "0" ] && ok "use with no resource exits non-zero" \
  || bad "use with no resource exits non-zero" "non-zero" "$(rc)"

reset
run S1 "$REPO" bogus thing >/dev/null
[ "$(rc)" != "0" ] && ok "an unknown action exits non-zero" \
  || bad "an unknown action exits non-zero" "non-zero" "$(rc)"

# --- resource name falls back to bare outside a repo -----------------------
reset
PLAIN="$WORK/not-a-repo"; mkdir -p "$PLAIN"
run S1 "$PLAIN" use xcode >/dev/null
eq "outside a repo the name is bare" "true" "$(q '.sessions.S1.holds | has("xcode")')"

# --- status.sh must not pass off the wrong file as an empty board ----------
# status.sh is what /free tells the model to run to verify the release worked.
# When it resolved a registry that does not exist it printed "No active
# sessions" — the command's own check was blind by construction.
STATUS="$ROOT/scripts/status.sh"
out="$(CC_WHITEBOARD_REGISTRY="$WORK/nowhere/registry.json" bash "$STATUS" 2>&1)"
srn=$?
has "a missing registry is called out, not read as empty" "no registry" "$out"
[ "$srn" -ne 0 ] && ok "a missing registry exits non-zero" \
  || bad "a missing registry exits non-zero" "non-zero" "$srn"

reset
out="$(bash "$STATUS" 2>&1)"
has "an existing but empty registry still reads as an empty board" \
    "No active sessions" "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
