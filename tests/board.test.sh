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

run S1 "$REPO" free xcode >/dev/null
eq "free drops the hold" "0" "$(q '.sessions.S1.holds | length')"

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
