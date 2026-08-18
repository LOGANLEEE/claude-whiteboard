#!/usr/bin/env bash
# Logic tests for scripts/on-prompt.sh — ticket evidence priority (v0.2.2).
# Pure bash + jq: feeds hook JSON on stdin against a throwaway registry.
# Run: bash tests/on-prompt.test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/scripts/on-prompt.sh"

# Don't let a developer's shell config decide the result.
unset CC_WHITEBOARD_TICKET_RE CC_WHITEBOARD_TTL CC_WHITEBOARD_SESSIONS_DIR

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CC_WHITEBOARD_REGISTRY="$WORK/registry.json"
ERRLOG="$WORK/stderr"

# Fake stand-in for Claude Code's own session registry (~/.claude/sessions),
# which is where the SendMessage address of each peer comes from. Pointing at a
# throwaway copy keeps the suite off the developer's real, live sessions.
SESSDIR="$WORK/sessions"
mkdir -p "$SESSDIR"
peerfile() {  # peerfile <session-id> <name|""> <status>
  jq -n --arg s "$1" --arg n "$2" --arg st "$3" \
    '{sessionId:$s, kind:"interactive", status:$st, updatedAt:1}
     + (if $n != "" then {name:$n} else {} end)' > "$SESSDIR/$1.json"
}
peerfile OWNER   owner-peer   busy
peerfile MENTION mention-peer idle
peerfile L1      label-peer   idle
peerfile NONAME  ""           idle   # a session Claude Code has not named
export CC_WHITEBOARD_SESSIONS_DIR="$SESSDIR"

WT="$WORK/ethenapayf-1013-kyc-camera"    # worktree-looking dir, not a git repo
WT2="$WORK/ethenapayf-1013-dup"
PLAIN="$WORK/some-random-dir"
PIPEWT="$WORK/wt|pipe-jira-77-fix"       # "|" is legal in dir and branch names
GITWT="$WORK/plain-checkout"             # real repo; ticket lives in the branch
mkdir -p "$WT" "$WT2" "$PLAIN" "$PIPEWT" "$GITWT"
git init -q -b feat/ETHEN-447 "$GITWT" 2>/dev/null
git -C "$GITWT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$1" "$2" "$3"; }
eq()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
has()  { case "$3" in *"$2"*) ok "$1";; *) bad "$1" "contains: $2" "$3";; esac; }
hasnt(){ case "$3" in *"$2"*) bad "$1" "NOT contains: $2" "$3";; *) ok "$1";; esac; }

reset() { printf '{"sessions":{}}' > "$CC_WHITEBOARD_REGISTRY"; }

# run <sid> <cwd> <prompt> -> hook stdout. Callers use $(run ...), i.e. a
# subshell, so the exit code goes through a file (rc) rather than a variable.
RCF="$WORK/rc"
run() {
  jq -nc --arg s "$1" --arg c "$2" --arg p "$3" \
    '{session_id:$s, cwd:$c, prompt:$p}' \
    | bash "$HOOK" > "$WORK/out" 2>"$ERRLOG"
  printf '%s' "${PIPESTATUS[1]}" > "$RCF"
  cat "$WORK/out"
}
rc() { cat "$RCF"; }
q() { jq -r "$1" "$CC_WHITEBOARD_REGISTRY"; }

echo "registry: $CC_WHITEBOARD_REGISTRY"

# --- 1. worktree evidence beats a mention of a different ticket -------------
reset
out="$(run A "$WT" "please cross-check ETHENAPAYF-9999 before merging")"
eq "worktree ticket wins over prompt mention" \
   "ETHENAPAYF-1013" "$(q '.sessions.A.ticket')"
eq "ticket_src is worktree" "worktree" "$(q '.sessions.A.ticket_src')"
eq "hook exits 0" "0" "$(rc)"
eq "hook writes nothing to stderr" "" "$(cat "$ERRLOG")"

# --- 2. prompt sniff only when there is no worktree evidence ---------------
reset
run B "$PLAIN" "start work on ETHENAPAYF-1013" >/dev/null
eq "prompt sniff fills empty slot" "ETHENAPAYF-1013" "$(q '.sessions.B.ticket')"
eq "ticket_src is prompt" "prompt" "$(q '.sessions.B.ticket_src')"

# --- 3. a later mention never overwrites an existing ticket ----------------
run B "$PLAIN" "also see ETHENAPAYF-9999 for context" >/dev/null
eq "second mention does not overwrite" "ETHENAPAYF-1013" "$(q '.sessions.B.ticket')"

# --- 4. worktree signal upgrades a prompt-sniffed value --------------------
run B "$WORK/ethenapayf-2001-foo" "keep going" >/dev/null
eq "worktree upgrades prompt value" "ETHENAPAYF-2001" "$(q '.sessions.B.ticket')"
eq "ticket_src upgraded to worktree" "worktree" "$(q '.sessions.B.ticket_src')"
eq "heartbeat refreshes dir on a session that moved" \
   "ethenapayf-2001-foo" "$(q '.sessions.B.dir')"

# --- 5. a mention-only holder gets a soft note, never ⚠ CONFLICT -----------
reset
run MENTION "$PLAIN" "coordination: session X is on ETHENAPAYF-1013" >/dev/null
out="$(run WORKER "$WT" "continue the camera work")"
hasnt "mention-only holder raises no CONFLICT" "CONFLICT" "$out"
has  "mention-only holder produces a note" "also mentioned ETHENAPAYF-1013." "$out"
eq   "note is one line" "1" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
hasnt "a mention-only holder gets no address line" "SendMessage" "$out"
eq   "mention holder recorded as weak" "prompt" "$(q '.sessions.MENTION.ticket_src')"

# --- 6. two worktree sessions on one ticket DO conflict, with dir ----------
reset
run OWNER "$WT" "working kyc camera" >/dev/null
out="$(run SECOND "$WT2" "same ticket here")"
has "worktree-vs-worktree raises conflict" "CONFLICT" "$out"
has "conflict names the ticket" "ETHENAPAYF-1013" "$out"
has "conflict shows holder dir" "dir: ethenapayf-1013-kyc-camera" "$out"
has "conflict carries the holder's SendMessage address" \
    'SendMessage({to: "owner-peer"' "$out"

# --- 7. the same conflict is announced once, not on every prompt -----------
out="$(run SECOND "$WT2" "still the same ticket")"
eq "repeat conflict is suppressed" "" "$out"
# ...but a DIFFERENT holder re-warns.
jq '.sessions.OTHEROWNER = .sessions.OWNER | del(.sessions.OWNER)' \
   "$CC_WHITEBOARD_REGISTRY" > "$WORK/r2" && mv "$WORK/r2" "$CC_WHITEBOARD_REGISTRY"
out="$(run SECOND "$WT2" "and again")"
has "a different holder re-warns" "CONFLICT" "$out"

# --- 8. generic ticket prefixes work, not just one project ----------------
reset
mkdir -p "$WORK/jira-12-login-fix" "$WORK/jira-12-second-take"
run J1 "$WORK/jira-12-login-fix" "working the login fix" >/dev/null
eq "worktree detection is tracker-agnostic" "JIRA-12" "$(q '.sessions.J1.ticket')"
eq "generic worktree ticket is strong" "worktree" "$(q '.sessions.J1.ticket_src')"
out="$(run J2 "$WORK/jira-12-second-take" "also on login")"
has "generic prefix still raises conflict" "CONFLICT" "$out"

# --- 9. branch-derived ticket (dir name carries no id) --------------------
reset
run G "$GITWT" "carry on" >/dev/null
eq "ticket derived from branch name" "ETHEN-447" "$(q '.sessions.G.ticket')"
eq "branch recorded" "feat/ETHEN-447" "$(q '.sessions.G.branch')"
run G2 "$GITWT" "same branch elsewhere" >/dev/null
out="$(run G3 "$GITWT" "third")"
has "conflict shows holder branch" "branch: feat/ETHEN-447" "$out"

# --- 10. "|" in a dir name does not corrupt the conflict message ----------
reset
run P1 "$PIPEWT" "pipe dir owner" >/dev/null
eq "ticket parsed out of a dir containing |" "JIRA-77" "$(q '.sessions.P1.ticket')"
mkdir -p "$WORK/jira-77-other"
out="$(run P2 "$WORK/jira-77-other" "second on 77")"
has "holder dir with | survives intact" "dir: wt|pipe-jira-77-fix" "$out"

# --- 11. legacy (pre-0.2.2) entries have no ticket_src -> soft, not hard ---
reset
jq -n --arg d "ethenapayf-1013-kyc-camera" --arg now "$(date +%s)" \
  '{sessions:{LEGACY:{ticket:"ETHENAPAYF-1013", dir:$d,
    started:($now|tonumber), updated:($now|tonumber)}}}' \
  > "$CC_WHITEBOARD_REGISTRY"
out="$(run NEW "$WT2" "picking up 1013")"
hasnt "legacy holder does not raise a hard conflict" "CONFLICT" "$out"
has   "legacy holder still produces a note" "also mentioned ETHENAPAYF-1013." "$out"

# --- 12. a rejected weak sniff is not conflict-checked (claim 6) -----------
reset
run OWNER "$WT" "kyc camera work" >/dev/null
run WEAK "$PLAIN" "start ETHENAPAYF-2222" >/dev/null
out="$(run WEAK "$PLAIN" "unrelated: what about ETHENAPAYF-1013?")"
eq    "rejected sniff keeps the original ticket" "ETHENAPAYF-2222" "$(q '.sessions.WEAK.ticket')"
hasnt "rejected sniff is not conflict-checked" "ETHENAPAYF-1013" "$out"

# --- 13. @wb-ignore writes nothing and says nothing ------------------------
reset
out="$(run GHOST "$WT" "@wb-ignore pasted board: ETHENAPAYF-1013 is owned by session 36892824")"
eq "@wb-ignore produces no output" "" "$out"
eq "@wb-ignore writes no session entry" "null" "$(q '.sessions.GHOST // "null"')"
eq "@wb-ignore exits 0" "0" "$(rc)"

# --- 14. @wb-ignore survives a huge pasted prompt (SIGPIPE/pipefail) -------
# grep -q exits on first match; with `printf ... | grep -q` under pipefail that
# turns a MATCH into status 141 once the prompt exceeds the pipe buffer.
BIG="$(python3 -c "print('@wb-ignore pasted board dump'); print('ETHENAPAYF-1013 owned by OWNERSESSION'); print('filler line ' * 8000)")"
reset
run OWNER "$WT" "kyc camera work" >/dev/null
out="$(run HUGE "$PLAIN" "$BIG")"
eq "@wb-ignore holds on a >64KB prompt" "" "$out"
eq "huge @wb-ignore prompt writes nothing" "null" "$(q '.sessions.HUGE // "null"')"

# --- 15. @wb-claim / @wb-release ------------------------------------------
reset
run L1 "$WT" "@wb-claim: auth refactor" >/dev/null
eq "label recorded" "auth refactor" "$(q '.sessions.L1.label')"
out="$(run L1 "$WT" "@wb-claim: auth refactor")"
eq "a lone claimer never warns about itself" "" "$out"
out="$(run L2 "$PLAIN" "@wb-claim: Auth Refactor")"
has "label conflict is case-insensitive" 'label "Auth Refactor"' "$out"
has "label conflict shows holder dir" "dir: ethenapayf-1013-kyc-camera" "$out"
has "label conflict carries the holder's address" 'SendMessage({to: "label-peer"' "$out"
run L1 "$WT" "@wb-release" >/dev/null
eq "@wb-release clears the label" "null" "$(q '.sessions.L1.label')"
BIGREL="$(python3 -c "print('@wb-release'); print('filler line ' * 8000)")"
run L2 "$PLAIN" "@wb-claim: solo work" >/dev/null
run L2 "$PLAIN" "$BIGREL" >/dev/null
eq "@wb-release holds on a >64KB prompt" "null" "$(q '.sessions.L2.label')"

# --- 16. no evidence at all -> silent, but heartbeat still recorded --------
reset
out="$(run Q "$PLAIN" "what does this function do?")"
eq "no evidence -> no output" "" "$out"
eq "no evidence -> no ticket" "null" "$(q '.sessions.Q.ticket // "null"')"
eq "no evidence -> heartbeat written" "$(basename "$PLAIN")" "$(q '.sessions.Q.dir')"

# --- 17. peer bridge degrades instead of breaking --------------------------
# A holder Claude Code never named: conflict still fires, no address offered.
reset
run NONAME "$WT" "kyc camera work" >/dev/null
out="$(run N2 "$WT2" "same ticket")"
has   "unnamed holder still raises a conflict" "CONFLICT" "$out"
hasnt "unnamed holder offers no address" "SendMessage" "$out"

# No native session registry at all (older Claude Code, another machine).
export CC_WHITEBOARD_SESSIONS_DIR="$WORK/absent-sessions-dir"
reset
run OWNER "$WT" "kyc camera work" >/dev/null
out="$(run N3 "$WT2" "same ticket")"
has   "conflict survives a missing session registry" "CONFLICT" "$out"
hasnt "missing session registry offers no address" "SendMessage" "$out"
eq    "missing session registry keeps stderr clean" "" "$(cat "$ERRLOG")"

# A half-written session file must not take the address lookup down with it.
export CC_WHITEBOARD_SESSIONS_DIR="$SESSDIR"
printf 'not json{' > "$SESSDIR/torn.json"
reset
run OWNER "$WT" "kyc camera work" >/dev/null
out="$(run N4 "$WT2" "same ticket")"
has "a torn session file still leaves the conflict intact" "CONFLICT" "$out"
eq  "a torn session file keeps stderr clean" "" "$(cat "$ERRLOG")"
rm -f "$SESSDIR/torn.json"

# --- 18. registry stays valid JSON ----------------------------------------
jq -e . "$CC_WHITEBOARD_REGISTRY" >/dev/null 2>&1 \
  && ok "registry is valid JSON" || bad "registry is valid JSON" "valid" "invalid"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
