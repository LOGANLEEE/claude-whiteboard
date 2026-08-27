# Exclusive Resource Claims Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let parallel Claude Code sessions claim shared singletons (local stack, Xcode/device build, ngrok tunnel, shared database) so the second session is blocked at the moment of damage instead of silently corrupting the first.

**Architecture:** A new `PreToolUse` hook on Bash matches the command against a configurable resource pattern map, records a hold in the existing whiteboard registry, and blocks with `exit 2` when another live session holds it. Phantom holds are resolved at read time by three layers — PID liveness from `~/.claude/sessions/<pid>.json`, an optional per-resource probe, and idle soft-expiry. No daemon, no timers, no new top-level registry key.

**Tech Stack:** bash 3.2 (macOS system bash), `jq`, `git`, BSD/GNU `grep -E`. No other dependencies.

**Spec:** `docs/superpowers/specs/2026-08-24-resource-claims-design.md`

## Global Constraints

- **bash 3.2 compatible.** macOS ships bash 3.2. No associative arrays (`declare -A`), no `${var^^}`, no `mapfile`/`readarray`. Use `tr` for case, `while IFS= read -r` for lists.
- **`jq` is the only hard dependency.** Every script starts with `wb_have_jq || exit 0`.
- **Never break a session without `jq`.** Absent `jq` must be a silent no-op, never a block.
- **`set -euo pipefail` in every script**, matching the existing files.
- **`grep -qE ... <<< "$var"`, never `printf | grep -q`.** `grep -q` exits at first match and kills the upstream `printf` with `SIGPIPE`; under `pipefail` that turns a match into a non-zero status on inputs larger than the pipe buffer (~64 KiB). This bug was already fixed once in 0.2.2; do not reintroduce it.
- **Every registry write goes through `wb_update`**, which holds the `mkdir` lock. Never write `$WB_REGISTRY` directly.
- **Liveness is three-valued: alive / dead / unknown.** Unknown must never reclaim a hold. An absent or empty session registry is `unknown`, not `dead`.
- **Word-boundary `\b` in `grep -E` is verified working** on BSD grep 2.6.0-FreeBSD (macOS) with a positive and negative control. GNU grep supports it too.
- **Registry field types, fixed for all tasks:**
  - `holds`: object, `{"<resource>": <claim-epoch-seconds>}`
  - `waits`: object, `{"<resource>": {"since": <epoch>, "until": <epoch>}}` — `until` is `0` when no priority window is open.
- **Resource name format:** `<bare>@<repo>`, or bare `<bare>` when the directory is not a git repo.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `scripts/lib.sh` | Config vars, repo key, PID liveness, resource config + matching, probe, hold/wait state helpers. Sourced by every hook. No output. |
| `scripts/on-pretool.sh` | New. The only place that decides claim / block / reclaim / release for a Bash command. |
| `scripts/on-prompt.sh` | Adds three notices: waiters pending on holds you own, a resource you waited for is free, a hold you lost to soft-expiry. Plus `@wb-use:` / `@wb-free:` / `@wb-force:` markers. |
| `scripts/on-session-end.sh` | Opens the priority window on waiters before deleting the entry. |
| `scripts/on-session-start.sh` | Renders `uses:` on rows. |
| `scripts/status.sh` | Renders the resource table. |
| `hooks/hooks.json` | Registers `PreToolUse` for `Bash`. |
| `commands/use.md`, `free.md`, `force.md` | New thin marker-emitting commands. |
| `tests/lib.test.sh` | New. Unit tests for the `lib.sh` helpers. |
| `tests/on-pretool.test.sh` | New. Behavior tests for the hook. |

---

### Task 1: Repo key and PID liveness in `lib.sh`

**Files:**
- Modify: `scripts/lib.sh` (append after `wb_short`)
- Test: `tests/lib.test.sh` (create)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `wb_repo_key <dir>` → repo basename on stdout, empty + non-zero if not a git repo.
  - `wb_resource_name <bare> <dir>` → `bare@repo` or `bare`.
  - `wb_live_pids` → JSON `{"<sessionId>": {"pid": N, "procStart": "…", "updatedAt": N}}`, `{}` when unreadable.
  - `wb_liveness_known` → exit 0 when the session registry produced at least one entry.
  - `wb_pid_alive <pid> <procStart>` → exit 0 alive, 1 dead.
  - `wb_session_alive <sid> <live_pids_json>` → exit 0 alive **or unknown**, 1 dead.

- [ ] **Step 1: Write the failing test**

Create `tests/lib.test.sh`:

```bash
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
MYSTART="$(TZ=UTC ps -o lstart= -p $$ 2>/dev/null | sed 's/^ *//; s/ *$//')"

sessfile() {  # sessfile <sid> <pid> <procStart> [name]
  jq -n --arg s "$1" --argjson p "$2" --arg ps "$3" --arg n "${4:-}" \
    '{sessionId:$s, pid:$p, procStart:$ps, kind:"interactive",
      status:"idle", updatedAt:1}
     + (if $n != "" then {name:$n} else {} end)' > "$SESSDIR/$2.json"
}
sessfile LIVE   $$     "$MYSTART"                  live-peer
sessfile GONE   999999 "Mon Jan  1 00:00:00 2020"  gone-peer
sessfile REUSED $$     "Mon Jan  1 00:00:00 2020"  reused-peer
sessfile UNNAMED $((999998)) "Mon Jan  1 00:00:00 2020" ""

LP="$(wb_live_pids)"
eq "live_pids keyed by sessionId" "$$" "$(jq -r '.LIVE.pid' <<< "$LP")"
eq "live_pids keeps unnamed sessions" "999998" "$(jq -r '.UNNAMED.pid' <<< "$LP")"

yes "liveness is known when files exist" wb_liveness_known
yes "our own pid is alive"    wb_pid_alive "$$" "$MYSTART"
no  "a nonexistent pid is dead" wb_pid_alive 999999 "Mon Jan  1 00:00:00 2020"
no  "procStart mismatch is dead (pid reuse)" wb_pid_alive "$$" "Mon Jan  1 00:00:00 2020"
yes "empty procStart falls back to kill -0" wb_pid_alive "$$" ""
no  "non-numeric pid is dead" wb_pid_alive "abc" ""

yes "session_alive: live session"   wb_session_alive LIVE   "$LP"
no  "session_alive: gone session"   wb_session_alive GONE   "$LP"
no  "session_alive: reused pid"     wb_session_alive REUSED "$LP"
no  "session_alive: absent from registry" wb_session_alive NOSUCH "$LP"

# --- the instrument guard: empty registry means UNKNOWN, never dead --------
EMPTY="$WORK/empty-sessions"; mkdir -p "$EMPTY"
CC_WHITEBOARD_SESSIONS_DIR="$EMPTY" WB_SESSIONS_DIR="$EMPTY" \
  bash -c 'source "'"$ROOT"'/scripts/lib.sh"
           wb_liveness_known && echo KNOWN || echo UNKNOWN' > "$WORK/o"
eq "empty session dir reports liveness UNKNOWN" "UNKNOWN" "$(cat "$WORK/o")"

CC_WHITEBOARD_SESSIONS_DIR="$EMPTY" WB_SESSIONS_DIR="$EMPTY" \
  bash -c 'source "'"$ROOT"'/scripts/lib.sh"
           wb_session_alive ANY "$(wb_live_pids)" && echo ALIVE || echo DEAD' > "$WORK/o"
eq "unknown liveness treats any session as ALIVE" "ALIVE" "$(cat "$WORK/o")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/lib.test.sh`
Expected: FAIL — `wb_repo_key: command not found` on the first assertion.

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/lib.sh`, after `wb_short`:

```bash
# --- Resource claims -------------------------------------------------------

# Repo key for scoping a resource name. Uses --git-common-dir, NOT
# --show-toplevel: a linked worktree's toplevel is its own directory, so
# --show-toplevel would give every worktree a different key and defeat the
# whole point. --git-common-dir returns the MAIN repo's .git for a worktree,
# which is the real collision domain (shared DB, shared ports).
wb_repo_key() {
  local d="${1:-$PWD}" g
  [ -d "$d" ] || return 1
  g="$(git -C "$d" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [ -n "$g" ] || return 1
  basename "$(dirname "$g")"
}

# "<bare>@<repo>", or bare when the directory is not a git repo. The registry
# is shared by every repo on the machine, so an unscoped name would let one
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
  out="$(jq -s 'map(select((.sessionId // "") != "" and ((.pid // 0) | tonumber?) > 0))
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

# Is <pid> the same process that <procStart> was recorded for?
# Errs SAFE: anything we cannot determine returns "alive", so an unclear signal
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/lib.test.sh`
Expected: PASS, `19 passed, 0 failed`.

Also run the existing suite to confirm nothing regressed:
Run: `bash tests/on-prompt.test.sh`
Expected: PASS, unchanged assertion count.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib.sh tests/lib.test.sh
git commit -m "feat: repo-scoped resource names and PID liveness helpers"
```

---

### Task 2: Resource config, command matching, and probe

**Files:**
- Modify: `scripts/lib.sh` (append)
- Test: `tests/lib.test.sh` (append before the final summary)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  - `wb_resources` → the resource map as JSON.
  - `wb_match_resources <command> <claim|release>` → matching bare names, one per line.
  - `wb_probe <bare>` → exit 0 up, 1 down, 2 unknown (no probe configured, or it could not run).

- [ ] **Step 1: Write the failing test**

Append to `tests/lib.test.sh`, before the `printf '\n%d passed…` line:

```bash
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
case "$out" in *local-stack*) case "$out" in *xcode*) ok "compound command matches both";;
  *) bad "compound command matches both" "both" "$out";; esac;;
  *) bad "compound command matches both" "both" "$out";; esac

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
eq "probe exit 0 means UP"        "0" "$(probe_rc 'true')"
eq "probe non-zero means DOWN"    "1" "$(probe_rc 'false')"
eq "no probe configured is UNKNOWN" "2" "$(probe_rc '')"
eq "unrunnable probe is UNKNOWN"  "2" "$(probe_rc '/nonexistent/binary/xyz')"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/lib.test.sh`
Expected: FAIL — `wb_resources: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/lib.sh`:

```bash
# Resource pattern map. Shipped defaults stay GENERIC: this plugin is public,
# so project-specific recipes (just stack::up, just db::migrate) belong in a
# user's CC_WHITEBOARD_RESOURCES override, not here.
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
  local cmd
  cmd="$(wb_resources | jq -r --arg n "$1" '.[$n].probe // ""' 2>/dev/null)"
  [ -n "$cmd" ] || return 2
  if command -v timeout >/dev/null 2>&1; then
    timeout "$WB_PROBE_TIMEOUT" sh -c "$cmd" >/dev/null 2>&1
  else
    sh -c "$cmd" >/dev/null 2>&1
  fi
  case "$?" in
    0)   return 0 ;;
    127) return 2 ;;   # command not found -> we learned nothing
    124) return 2 ;;   # timeout(1) killed it -> we learned nothing
    *)   return 1 ;;
  esac
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/lib.test.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib.sh tests/lib.test.sh
git commit -m "feat: resource pattern map, command matching, three-valued probe"
```

---

### Task 3: Hold and wait state helpers

**Files:**
- Modify: `scripts/lib.sh` (append)
- Test: `tests/lib.test.sh` (append)

**Interfaces:**
- Consumes: `wb_session_alive`, `wb_probe`, `wb_update`, `wb_read_fresh` from Tasks 1–2.
- Produces:
  - `wb_hold <sid> <resource>` — idempotent; does not refresh an existing `since`.
  - `wb_unhold <sid> <resource>`
  - `wb_add_wait <sid> <resource>`
  - `wb_drop_wait <sid> <resource>`
  - `wb_open_window <resource> <seconds>` — sets `until` on every waiter.
  - `wb_holder_of <resource> <self_sid> <bare>` → 5 lines: `sid`, `dir`, `branch`, `since`, `state` where state is `hard` or `soft`. Prints nothing when the resource is free.
  - `wb_reserved_by <resource> <self_sid>` → 3 lines: `sid`, `waited_seconds`, `until`. Prints nothing when no window is open for another session.

- [ ] **Step 1: Write the failing test**

Append to `tests/lib.test.sh`:

```bash
# --- hold / wait state -----------------------------------------------------
NOW="$(date +%s)"
reset_reg() { printf '{"sessions":{}}' > "$CC_WHITEBOARD_REGISTRY"; }
touch_sess() {  # touch_sess <sid> <updated>
  wb_update '.sessions[$s] = ((.sessions[$s] // {}) + {updated:($u|tonumber), started:($u|tonumber)})' \
    --arg s "$1" --arg u "$2"
}
h5() { # h5 <resource> <self> -> "sid|dir|branch|since|state"
  wb_holder_of "$1" "$2" "${3:-local-stack}" | tr '\n' '|'
}

reset_reg
touch_sess LIVE "$NOW"
wb_hold LIVE "local-stack@r"
eq "hold recorded" "true" "$(jq '.sessions.LIVE.holds | has("local-stack@r")' "$CC_WHITEBOARD_REGISTRY")"
SINCE1="$(jq -r '.sessions.LIVE.holds["local-stack@r"]' "$CC_WHITEBOARD_REGISTRY")"
sleep 1
wb_hold LIVE "local-stack@r"
eq "re-hold does not refresh since" "$SINCE1" \
   "$(jq -r '.sessions.LIVE.holds["local-stack@r"]' "$CC_WHITEBOARD_REGISTRY")"

eq "holder found by another session" "LIVE" "$(h5 'local-stack@r' OTHER | cut -d'|' -f1)"
eq "holder state is hard while recent" "hard" "$(h5 'local-stack@r' OTHER | cut -d'|' -f5)"
eq "holder hidden from itself" "" "$(h5 'local-stack@r' LIVE)"

# dead holder -> not a holder at all
reset_reg
touch_sess GONE "$NOW"
wb_hold GONE "local-stack@r"
eq "dead session is not a holder" "" "$(h5 'local-stack@r' OTHER)"

# alive but idle past HOLD_IDLE, no probe -> soft
reset_reg
touch_sess LIVE "$((NOW - 7200))"
wb_hold LIVE "local-stack@r"
eq "idle holder goes soft" "soft" "$(h5 'local-stack@r' OTHER | cut -d'|' -f5)"

# a probe that says UP suppresses idle soft-expiry
CC_WHITEBOARD_RESOURCES='{"local-stack":{"claim":"x","release":"","probe":"true"}}' \
  bash -c 'source "'"$ROOT"'/scripts/lib.sh"
           wb_holder_of "local-stack@r" OTHER local-stack | tail -1' > "$WORK/o"
eq "probe UP keeps an idle hold hard" "hard" "$(cat "$WORK/o")"

# a probe that says DOWN makes it a phantom regardless of idleness
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
eq "a waiter is not blocked by its own window" "" "$(wb_reserved_by 'local-stack@r' W1 | head -1)"

wb_drop_wait W1 "local-stack@r"
wb_drop_wait W2 "local-stack@r"
eq "waits cleared" "0" \
   "$(jq '[.sessions[].waits // {} | length] | add' "$CC_WHITEBOARD_REGISTRY")"

# an expired wait grants nobody a reservation
reset_reg
touch_sess W1 "$NOW"
wb_update '.sessions.W1.waits = {"local-stack@r":{"since":($t|tonumber),"until":($u|tonumber)}}' \
  --arg t "$((NOW - 99999))" --arg u "$((NOW + 300))"
eq "wait older than WAIT_TTL is ignored" "" "$(wb_reserved_by 'local-stack@r' STRANGER | head -1)"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/lib.test.sh`
Expected: FAIL — `wb_hold: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/lib.sh`:

```bash
# Claim. Idempotent: re-running the same command must NOT refresh `since`, or
# an idle holder could hold a resource forever by repeating its own command.
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

# Give every current waiter a head start over sessions that never waited.
# This is the whole of "auto-grant": a timestamp, not a state machine. Nobody
# is assigned ownership, so nobody ends up holding what they no longer want.
wb_open_window() {
  local secs="${2:-$WB_RESERVE}"
  [ "$secs" -gt 0 ] 2>/dev/null || return 0
  wb_update '.sessions |= with_entries(
      if (.value.waits // {}) | has($r)
      then .value.waits[$r].until = (($n|tonumber) + ($s|tonumber))
      else . end)' \
    --arg r "$1" --arg n "$(wb_now)" --arg s "$secs" 2>/dev/null || true
}

# Holder of <resource>, excluding <self>, or nothing when free.
# Prints 5 lines: sid, dir, branch, since, state(hard|soft).
# Newlines and tabs inside dir/branch are flattened so the lines stay aligned —
# "|" is legal in a branch name, so a single delimited line does not work.
wb_holder_of() {
  local r="$1" self="$2" bare="${3:-}" fresh lp now line
  local sid dir br since updated pstate
  fresh="$(wb_read_fresh)"; lp="$(wb_live_pids)"; now="$(wb_now)"

  pstate=2
  if [ -n "$bare" ]; then wb_probe "$bare"; pstate=$?; fi
  [ "$pstate" -eq 1 ] && return 0     # probe says DOWN -> nobody holds it

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    sid="$(cut -f1 <<< "$line")";   dir="$(cut -f2 <<< "$line")"
    br="$(cut -f3 <<< "$line")";    since="$(cut -f4 <<< "$line")"
    updated="$(cut -f5 <<< "$line")"
    wb_session_alive "$sid" "$lp" || continue      # dead -> phantom, skip
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
wb_reserved_by() {
  local r="$1" self="$2" fresh lp now line sid since until
  [ "$WB_RESERVE" -gt 0 ] 2>/dev/null || return 0
  fresh="$(wb_read_fresh)"; lp="$(wb_live_pids)"; now="$(wb_now)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    sid="$(cut -f1 <<< "$line")"; since="$(cut -f2 <<< "$line")"
    until="$(cut -f3 <<< "$line")"
    [ $(( now - since )) -lt "$WB_WAIT_TTL" ] || continue   # stale wait
    wb_session_alive "$sid" "$lp" || continue
    printf '%s\n%s\n%s\n' "$sid" "$(( now - since ))" "$until"
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/lib.test.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib.sh tests/lib.test.sh
git commit -m "feat: hold, wait and priority-window state helpers"
```

---

### Task 4: `on-pretool.sh` — claim, block, waiter recording

**Files:**
- Create: `scripts/on-pretool.sh`
- Test: `tests/on-pretool.test.sh` (create)

**Interfaces:**
- Consumes: everything from Tasks 1–3.
- Produces: the hook itself. Contract: reads PreToolUse JSON on stdin (`session_id`, `cwd`, `tool_name`, `tool_input.command`). Exit 0 = allow, exit 2 = block with the reason on stderr.

- [ ] **Step 1: Write the failing test**

Create `tests/on-pretool.test.sh`:

```bash
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
sessfile() {  # sessfile <sid> <pid> <procStart> [name]
  jq -n --arg s "$1" --argjson p "$2" --arg ps "$3" --arg n "${4:-}" \
    '{sessionId:$s, pid:$p, procStart:$ps, kind:"interactive",
      status:"idle", updatedAt:1}
     + (if $n != "" then {name:$n} else {} end)' > "$SESSDIR/$2.json"
}
sessfile A  $$     "$MYSTART"                 alpha
sessfile B  $$     "$MYSTART"                 bravo
sessfile C  $$     "$MYSTART"                 charlie
sessfile D  999999 "Mon Jan  1 00:00:00 2020" delta   # crashed

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
hasnt(){ case "$3" in *"$2"*) bad "$1" "NOT contains: $2" "$3";; *) ok "$1";; esac; }

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
eq "unmatched command exits 0"      "0"  "$(rc)"
eq "unmatched command is silent"    ""   "$(err)"
eq "unmatched command writes nothing" "0" "$(q '[.sessions[]|(.holds//{})|length]|add // 0')"

# --- 2. claiming a free resource ------------------------------------------
reset
runp A "$R1" "docker compose up -d" >/dev/null
eq "claim exits 0"     "0"    "$(rc)"
eq "claim is silent"   ""     "$(err)"
eq "hold recorded, repo-scoped" "true" \
   "$(q '.sessions.A.holds | has("local-stack@repo-one")')"

# --- 3. a second session is blocked and recorded as a waiter --------------
runp B "$R1" "docker compose up -d" >/dev/null
eq "blocked with exit 2" "2" "$(rc)"
has "block names the resource" 'local-stack@repo-one' "$(err)"
has "block names the holder"   'alpha'                "$(err)"
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

# --- 7. a crashed holder does not block ------------------------------------
reset
runp D "$R1" "docker compose up -d" >/dev/null   # D's pid 999999 is dead
runp A "$R1" "docker compose up -d" >/dev/null
eq "dead holder is reclaimed" "0" "$(rc)"
has "reclaim is announced" "reclaimed" "$(err)"
eq "reclaimer now holds it" "true" "$(q '.sessions.A.holds | has("local-stack@repo-one")')"
eq "dead session lost the hold" "false" \
   "$(q '.sessions.D | (.holds // {}) | has("local-stack@repo-one")')"

# --- 8. no jq / wrong tool -> no-op ---------------------------------------
reset
jq -nc '{session_id:"A", cwd:"'"$R1"'", tool_name:"Read", tool_input:{file_path:"/x"}}' \
  | bash "$HOOK" >/dev/null 2>"$ERRLOG"; eq "non-Bash tool exits 0" "0" "$?"
eq "non-Bash tool is silent" "" "$(err)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/on-pretool.test.sh`
Expected: FAIL — the hook file does not exist, every `runp` returns non-zero from `bash: … No such file`.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/on-pretool.sh`:

```bash
#!/usr/bin/env bash
# PreToolUse hook (Bash).
#
# A ticket conflict wastes work. A RESOURCE conflict corrupts it: the second
# session to bring up a shared stack rewrites the database and the shared config
# rows the first session is running against, and the victim then debugs a bug
# that is not theirs. Prompt-time warnings are too late for that — by the time a
# prompt is submitted the damage is done. So this runs at the moment the command
# is about to execute.
#
# Decision table for a command that matches a resource's `claim` pattern:
#   free                      -> record the hold, exit 0, silent
#   already held by SELF      -> exit 0, silent (and do NOT refresh `since`)
#   held by a live session    -> exit 2, block, record this session as a waiter
#   held by a dead session    -> reclaim it, exit 0, say so
#   free but reserved         -> exit 2, block, name who is in line
# A command matching a `release` pattern drops the hold and opens the priority
# window on every waiter.
#
# Input: JSON on stdin. Exit 0 = allow. Exit 2 = block, stderr shown to Claude.

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

input="$(cat)"
wb_have_jq || exit 0

tool="$(printf '%s' "$input" | jq -r '.tool_name // ""')"
[ "$tool" = "Bash" ] || exit 0

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"
[ -n "$cmd" ] || exit 0

sid="$(printf '%s' "$input" | jq -r '.session_id // "unknown"')"
cwd="$(printf '%s' "$input" | jq -r '.cwd // ""')"
[ -n "$cwd" ] || cwd="$PWD"

# --- release first: "compose down && compose up" is a restart, not a claim --
released=0
while IFS= read -r bare; do
  [ -n "$bare" ] || continue
  res="$(wb_resource_name "$bare" "$cwd")"
  wb_unhold "$sid" "$res"
  wb_open_window "$res" "$WB_RESERVE"
  released=1
done <<< "$(wb_match_resources "$cmd" release)"

# --- collect claims --------------------------------------------------------
claims="$(wb_match_resources "$cmd" claim)"
if [ -z "$claims" ]; then
  exit 0
fi

# Address of a session, for the "go ask them" line. Looked up lazily: an
# ordinary command never reaches here, so the join costs nothing in steady state.
peer_name() {
  wb_peer_names | jq -r --arg s "$1" '.[$s].name // ""' 2>/dev/null || true
}

ago() {  # ago <epoch> -> "12m"
  local d=$(( $(wb_now) - $1 ))
  if [ "$d" -lt 60 ]; then printf '%ds' "$d"; else printf '%dm' $(( d / 60 )); fi
}

# Pass 1: decide. A compound command must be all-or-nothing — a partial claim
# would leave a phantom on a resource that was not even the reason for the block.
blocked=""
notes=""
while IFS= read -r bare; do
  [ -n "$bare" ] || continue
  res="$(wb_resource_name "$bare" "$cwd")"

  holder="$(wb_holder_of "$res" "$sid" "$bare")"
  if [ -n "$holder" ]; then
    { IFS= read -r h_sid; IFS= read -r h_dir; IFS= read -r h_br
      IFS= read -r h_since; IFS= read -r h_state; } <<< "$holder" || true
    if [ "$h_state" = "hard" ]; then
      name="$(peer_name "$h_sid")"
      blocked="${blocked}$(cat <<EOF
BLOCKED: "$res" is held by session ${h_sid:0:8}
  dir: ${h_dir:-?}   branch: ${h_br:-?}   since: $(ago "$h_since") ago

Do NOT start your own — a second instance rewrites the shared state the holder
is running against, and the failure will surface as a bug in THEIR work.

You are now recorded as WAITING for it.
$( [ -n "$name" ] && printf 'Ask the holder directly:\n  SendMessage({to: "%s", message: "I need %s. When can I take it?"})\n' "$name" "$bare" || printf 'Claude Code has not named that session, so it cannot be messaged by name.\n' )
If you have verified that session is dead: /claude-whiteboard:force $bare

EOF
)"
      wb_add_wait "$sid" "$res"
      continue
    fi
    # soft: the holder is alive but idle and unprobed. Take it, say so.
    wb_unhold "$h_sid" "$res"
    notes="${notes}[claude-whiteboard] took \"$res\" from session ${h_sid:0:8} — idle $(ago "$h_since"), no probe to prove it is still up.
"
  fi

  # Free, but is someone else first in line?
  reserved="$(wb_reserved_by "$res" "$sid")"
  if [ -n "$reserved" ]; then
    { IFS= read -r w_sid; IFS= read -r w_for; IFS= read -r w_until; } <<< "$reserved" || true
    name="$(peer_name "$w_sid")"
    blocked="${blocked}$(cat <<EOF
BLOCKED: "$res" is free but reserved for $(( (w_until - $(wb_now)) / 60 + 1 ))m more.
Session ${w_sid:0:8}${name:+ ($name)} has been waiting $(( w_for / 60 ))m. Ask before you take it:
$( [ -n "$name" ] && printf '  SendMessage({to: "%s", message: "taking %s — ok?"})\n' "$name" "$bare" || printf '  (that session has no SendMessage name)\n' )

EOF
)"
    continue
  fi
done <<< "$claims"

if [ -n "$blocked" ]; then
  printf '%s\n' "$blocked" >&2
  exit 2
fi

# Pass 2: nothing blocked, so take every claim.
while IFS= read -r bare; do
  [ -n "$bare" ] || continue
  res="$(wb_resource_name "$bare" "$cwd")"
  wb_hold "$sid" "$res"
  wb_drop_wait "$sid" "$res"
done <<< "$claims"

[ -n "$notes" ] && printf '%s' "$notes" >&2
exit 0
```

Then make it executable and register a reclaim note. The reclaim path in Task 5 adds the `reclaimed` wording; for now the dead-holder case already works because `wb_holder_of` skips dead sessions — but the old hold must still be deleted. Add this right after the `holder` block, inside the loop:

```bash
  # A dead session's hold is invisible to wb_holder_of but still sits in the
  # registry, where it would show on the board forever. Sweep it here.
  wb_sweep_dead_holds "$res"
```

- [ ] **Step 4: Run test to verify it passes**

`wb_sweep_dead_holds` does not exist yet — that is Task 5. For this task, comment that line out and expect assertions 1–6 and 8 to pass, with the "crashed holder" group (7) failing on the `reclaimed` wording.

Run: `chmod +x scripts/on-pretool.sh && bash tests/on-pretool.test.sh`
Expected: all pass except the two assertions in group 7 (`reclaim is announced`, `dead session lost the hold`).

- [ ] **Step 5: Commit**

```bash
git add scripts/on-pretool.sh tests/on-pretool.test.sh
git commit -m "feat: PreToolUse hook claims resources and blocks on conflict"
```

---

### Task 5: Phantom reclaim sweep

**Files:**
- Modify: `scripts/lib.sh` (append), `scripts/on-pretool.sh` (enable the sweep call)
- Test: `tests/on-pretool.test.sh` — group 7 already written in Task 4; add two more.

**Interfaces:**
- Consumes: `wb_session_alive`, `wb_read_fresh`, `wb_update`.
- Produces: `wb_sweep_dead_holds <resource>` → deletes that resource's hold from every positively-dead session; prints the short ids it swept, one per line.

- [ ] **Step 1: Write the failing test**

Append to `tests/on-pretool.test.sh`, before the summary:

```bash
# --- 9. the instrument guard: no session registry -> never reclaim ---------
reset
runp A "$R1" "docker compose up -d" >/dev/null
EMPTY="$WORK/no-sessions"; mkdir -p "$EMPTY"
jq -nc --arg c "$R1" '{session_id:"B", cwd:$c, tool_name:"Bash",
                       tool_input:{command:"docker compose up -d"}}' \
  | CC_WHITEBOARD_SESSIONS_DIR="$EMPTY" bash "$HOOK" >/dev/null 2>"$ERRLOG"
eq "blind liveness still blocks (does not reclaim)" "2" "$?"
eq "hold survived a blind reclaim" "true" \
   "$(q '.sessions.A.holds | has("local-stack@repo-one")')"

# --- 10. a soft (idle, unprobed) hold can be taken by anyone ---------------
reset
NOW="$(date +%s)"
jq -n --arg n "$((NOW - 99999))" --arg t "$((NOW - 99999))" \
  '{sessions:{A:{updated:($n|tonumber), started:($n|tonumber),
                 holds:{"local-stack@repo-one":($t|tonumber)}}}}' \
  > "$CC_WHITEBOARD_REGISTRY"
# A's session entry is older than the 4h TTL, so use a fresher one to isolate
# soft-expiry from TTL pruning: bump `updated` to just past HOLD_IDLE.
jq --arg n "$((NOW - 4000))" '.sessions.A.updated = ($n|tonumber)' \
  "$CC_WHITEBOARD_REGISTRY" > "$WORK/t" && mv "$WORK/t" "$CC_WHITEBOARD_REGISTRY"
runp C "$R1" "docker compose up -d" >/dev/null
eq "soft hold is taken, not blocked" "0" "$(rc)"
has "taking a soft hold is announced" "idle" "$(err)"
eq "taker holds it now" "true" "$(q '.sessions.C.holds | has("local-stack@repo-one")')"
eq "former holder lost it" "false" \
   "$(q '.sessions.A | (.holds // {}) | has("local-stack@repo-one")')"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/on-pretool.test.sh`
Expected: FAIL on `reclaim is announced` and `dead session lost the hold` (group 7), because `wb_sweep_dead_holds` is still commented out.

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/lib.sh`:

```bash
# Delete <resource> holds belonging to positively-dead sessions and print their
# short ids. A dead session's hold is invisible to wb_holder_of but still sits
# in the registry, where it would render on the board indefinitely.
#
# Does nothing when liveness is unknown. That guard is the whole difference
# between "reclaim crashed sessions" and "silently disable the lock on any
# machine with no session registry".
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
```

In `scripts/on-pretool.sh`, uncomment the sweep call and emit its result. Replace the placeholder line with:

```bash
  # Sweep first: a crashed holder must not block, and its stale row must not
  # linger on the board.
  dead="$(wb_sweep_dead_holds "$res")"
  if [ -n "$dead" ]; then
    notes="${notes}[claude-whiteboard] reclaimed \"$res\" from session $(printf '%s' "$dead" | tr '\n' ' ' | sed 's/ *$//') — its process is gone.
"
  fi
```

Move it to run **before** `holder="$(wb_holder_of ...)"` so the sweep happens first.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/on-pretool.test.sh`
Expected: PASS, all groups.

Then prove the guard is real by mutating it: temporarily change `wb_liveness_known || return 0` to `true`, re-run, and confirm assertion 9 (`hold survived a blind reclaim`) FAILS. Restore the line.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib.sh scripts/on-pretool.sh tests/on-pretool.test.sh
git commit -m "feat: reclaim holds from crashed sessions, guarded on liveness being observable"
```

---

### Task 6: Probe integration and the unattributed-resource warning

**Files:**
- Modify: `scripts/on-pretool.sh`
- Test: `tests/on-pretool.test.sh` (append)

**Interfaces:**
- Consumes: `wb_probe` (Task 2), `wb_holder_of` (Task 3, already probe-aware).
- Produces: no new function. Adds the "up but unclaimed" stderr warning on the allow path.

- [ ] **Step 1: Write the failing test**

Append to `tests/on-pretool.test.sh`:

```bash
# --- 11. probe UP with no recorded holder -> warn, but ALLOW ---------------
reset
out="$(CC_WHITEBOARD_RESOURCES='{"local-stack":{"claim":"docker[- ]compose\\b.*\\bup\\b","release":"","probe":"true"}}' \
  runp A "$R1" "docker compose up -d")"
eq "unattributed resource does not block" "0" "$(rc)"
has "unattributed resource warns" "unclaimed" "$(err)"
eq "claim still recorded" "true" "$(q '.sessions.A.holds | has("local-stack@repo-one")')"

# --- 12. probe DOWN clears a hold that the registry still shows ------------
reset
runp A "$R1" "docker compose up -d" >/dev/null
jq -nc --arg c "$R1" '{session_id:"B", cwd:$c, tool_name:"Bash",
                       tool_input:{command:"docker compose up -d"}}' \
  | CC_WHITEBOARD_RESOURCES='{"local-stack":{"claim":"docker[- ]compose\\b.*\\bup\\b","release":"","probe":"false"}}' \
    bash "$HOOK" >/dev/null 2>"$ERRLOG"
eq "probe DOWN means the hold is a phantom" "0" "$?"

# --- 13. probe UP keeps an idle hold hard ---------------------------------
reset
NOW="$(date +%s)"
jq -n --arg u "$((NOW - 4000))" --arg t "$((NOW - 4000))" \
  '{sessions:{A:{updated:($u|tonumber), started:($u|tonumber),
                 holds:{"local-stack@repo-one":($t|tonumber)}}}}' \
  > "$CC_WHITEBOARD_REGISTRY"
jq -nc --arg c "$R1" '{session_id:"B", cwd:$c, tool_name:"Bash",
                       tool_input:{command:"docker compose up -d"}}' \
  | CC_WHITEBOARD_RESOURCES='{"local-stack":{"claim":"docker[- ]compose\\b.*\\bup\\b","release":"","probe":"true"}}' \
    bash "$HOOK" >/dev/null 2>"$ERRLOG"
eq "probe UP blocks even an idle holder" "2" "$?"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/on-pretool.test.sh`
Expected: FAIL on `unattributed resource warns` — no such wording is emitted yet.

- [ ] **Step 3: Write minimal implementation**

In `scripts/on-pretool.sh`, inside the pass-1 loop, after the `reserved` check and before `done`, add:

```bash
  # The resource is up, but nobody on the board claims it. Only a probe can see
  # this: it means a non-Claude process, or a session that started before the
  # plugin was installed. WARN, do not block — an unattributed signal gives
  # nobody to ask, and blocking on it is exactly the noise that makes people
  # stop trusting the warning.
  if wb_probe "$bare"; then
    if [ -z "$holder" ]; then
      notes="${notes}[claude-whiteboard] \"$res\" appears to be UP but is unclaimed on the board — another process, or a session older than this plugin. Check before you rely on it.
"
    fi
  fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/on-pretool.test.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/on-pretool.sh tests/on-pretool.test.sh
git commit -m "feat: warn when a probed resource is up but unclaimed"
```

---

### Task 7: Release path, priority window, and session end

**Files:**
- Modify: `scripts/on-session-end.sh`
- Test: `tests/on-pretool.test.sh` (append)

**Interfaces:**
- Consumes: `wb_open_window`, `wb_reserved_by`.
- Produces: no new function. `on-session-end.sh` opens the window on waiters before the entry is deleted.

- [ ] **Step 1: Write the failing test**

Append to `tests/on-pretool.test.sh`:

```bash
# --- 14. release drops the hold and opens the window ----------------------
reset
runp A "$R1" "docker compose up -d" >/dev/null
runp B "$R1" "docker compose up -d" >/dev/null       # B becomes a waiter
runp A "$R1" "docker compose down"  >/dev/null
eq "release exits 0" "0" "$(rc)"
eq "hold dropped" "false" "$(q '.sessions.A | (.holds // {}) | has("local-stack@repo-one")')"
eq "waiter window opened" "true" \
   "$(q --argjson n "$(date +%s)" '.sessions.B.waits["local-stack@repo-one"].until > $n' 2>/dev/null || \
      jq --argjson n "$(date +%s)" '.sessions.B.waits["local-stack@repo-one"].until > $n' "$CC_WHITEBOARD_REGISTRY")"

# --- 15. a stranger is held off during the window, the waiter is not ------
runp C "$R1" "docker compose up -d" >/dev/null
eq "stranger blocked inside the window" "2" "$(rc)"
has "block names who is in line" "waiting" "$(err)"
runp B "$R1" "docker compose up -d" >/dev/null
eq "the waiter itself may claim" "0" "$(rc)"
eq "waiter now holds it" "true" "$(q '.sessions.B.holds | has("local-stack@repo-one")')"
eq "wait entry cleared on claim" "false" \
   "$(q '.sessions.B | (.waits // {}) | has("local-stack@repo-one")')"

# --- 16. once the window elapses a stranger may claim --------------------
reset
NOW="$(date +%s)"
jq -n --arg u "$NOW" --arg s "$((NOW - 600))" --arg t "$((NOW - 60))" \
  '{sessions:{B:{updated:($u|tonumber), started:($u|tonumber), holds:{},
                 waits:{"local-stack@repo-one":{since:($s|tonumber), until:($t|tonumber)}}}}}' \
  > "$CC_WHITEBOARD_REGISTRY"
runp C "$R1" "docker compose up -d" >/dev/null
eq "expired window does not block" "0" "$(rc)"

# --- 17. a wait older than WAIT_TTL grants no reservation ----------------
reset
jq -n --arg u "$NOW" --arg s "$((NOW - 99999))" --arg t "$((NOW + 300))" \
  '{sessions:{B:{updated:($u|tonumber), started:($u|tonumber), holds:{},
                 waits:{"local-stack@repo-one":{since:($s|tonumber), until:($t|tonumber)}}}}}' \
  > "$CC_WHITEBOARD_REGISTRY"
runp C "$R1" "docker compose up -d" >/dev/null
eq "stale wait grants no reservation" "0" "$(rc)"

# --- 18. session end opens the window on waiters -------------------------
reset
runp A "$R1" "docker compose up -d" >/dev/null
runp B "$R1" "docker compose up -d" >/dev/null
jq -nc '{session_id:"A", reason:"exit"}' | bash "$ROOT/scripts/on-session-end.sh" >/dev/null 2>&1
eq "ending session is gone" "false" "$(q '.sessions | has("A")')"
eq "session end opened the waiter window" "true" \
   "$(jq --argjson n "$(date +%s)" '.sessions.B.waits["local-stack@repo-one"].until > $n' "$CC_WHITEBOARD_REGISTRY")"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/on-pretool.test.sh`
Expected: PASS for groups 14–17 (already implemented in Task 4's release block), FAIL for group 18 — `session end opened the waiter window` is `false`.

- [ ] **Step 3: Write minimal implementation**

In `scripts/on-session-end.sh`, before the existing `wb_update 'del(.sessions[$sid]) …'` call, insert:

```bash
# Hand every resource this session holds back to whoever is waiting, BEFORE the
# entry is deleted. SessionEnd output is not injected into any session's
# context, so this cannot notify anyone directly — it opens the priority window
# and the waiter learns at its own next prompt. That still completes the handoff
# when a holder simply exits.
for res in $(jq -r --arg s "$sid" '.sessions[$s].holds // {} | keys[]' \
               "$WB_REGISTRY" 2>/dev/null); do
  wb_open_window "$res" "$WB_RESERVE"
done
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/on-pretool.test.sh`
Expected: PASS, all groups.

- [ ] **Step 5: Commit**

```bash
git add scripts/on-session-end.sh tests/on-pretool.test.sh
git commit -m "feat: open the waiter priority window on release and on session end"
```

---

### Task 8: Prompt-time notices in `on-prompt.sh`

**Files:**
- Modify: `scripts/on-prompt.sh` (append, before the final `exit 0`)
- Test: `tests/on-prompt.test.sh` (append)

**Interfaces:**
- Consumes: `wb_read_fresh`, `wb_live_pids`, `wb_session_alive`, `wb_peer_names`.
- Produces: no new function. Three stdout notices.

- [ ] **Step 1: Write the failing test**

Append to `tests/on-prompt.test.sh`, before its summary:

```bash
# --- resource notices ------------------------------------------------------
NOW="$(date +%s)"
reset
jq -n --arg u "$NOW" --arg s "$((NOW - 2400))" \
  '{sessions:{
     OWNER:{updated:($u|tonumber), started:($u|tonumber), dir:"backend",
            holds:{"local-stack@repo":($u|tonumber)}},
     L1:{updated:($u|tonumber), started:($u|tonumber),
         waits:{"local-stack@repo":{since:($s|tonumber), until:0}}}}}' \
  > "$CC_WHITEBOARD_REGISTRY"

out="$(run OWNER "$PLAIN" "carry on")"
has "holder is told someone is waiting" 'waiting on "local-stack@repo"' "$out"
has "holder is given the waiter address" 'label-peer' "$out"

out="$(run OWNER "$PLAIN" "carry on again")"
hasnt "the waiting notice does not repeat" 'waiting on' "$out"

# a waiter whose resource became free
reset
jq -n --arg u "$NOW" --arg s "$((NOW - 600))" --arg t "$((NOW + 240))" \
  '{sessions:{L1:{updated:($u|tonumber), started:($u|tonumber),
     waits:{"local-stack@repo":{since:($s|tonumber), until:($t|tonumber)}}}}}' \
  > "$CC_WHITEBOARD_REGISTRY"
out="$(run L1 "$PLAIN" "any news")"
has "waiter is told the resource is free" 'is now FREE' "$out"
has "waiter is told about its head start" 'Reserved for you' "$out"
out="$(run L1 "$PLAIN" "any news again")"
hasnt "the free notice does not repeat" 'is now FREE' "$out"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/on-prompt.test.sh`
Expected: FAIL — none of the notice strings are emitted.

- [ ] **Step 3: Write minimal implementation**

In `scripts/on-prompt.sh`, immediately before the final `exit 0`, add:

```bash
# --- Resource notices ------------------------------------------------------
# Pull backup for the SendMessage handoff: a holder that never reads its inbox
# still learns at its own next prompt that someone is blocked on it, and a
# waiter learns its resource came free without asking again.
#
# Both reuse the existing `warned` dedup so a real situation is stated once and
# does not become an every-prompt drumbeat.

fresh="$(wb_read_fresh)"
lp="$(wb_live_pids)"
peers="$(wb_peer_names)"

# 1. Resources I hold that other live sessions are waiting on.
while IFS= read -r res; do
  [ -n "$res" ] || continue
  waiters="$(jq -r --arg r "$res" --arg self "$sid" '
      .sessions | to_entries
      | map(select(.key != $self and ((.value.waits // {}) | has($r))))
      | .[] | [.key, (.value.waits[$r].since|tostring)] | @tsv' \
    <<< "$fresh" 2>/dev/null)"
  live_waiters=""
  while IFS= read -r wline; do
    [ -n "$wline" ] || continue
    w_sid="$(cut -f1 <<< "$wline")"; w_since="$(cut -f2 <<< "$wline")"
    wb_session_alive "$w_sid" "$lp" || continue
    w_name="$(jq -r --arg s "$w_sid" '.[$s].name // ""' <<< "$peers" 2>/dev/null)"
    live_waiters="${live_waiters:+$live_waiters, }${w_name:-${w_sid:0:8}} ($(( ( $(wb_now) - w_since ) / 60 ))m)"
  done <<< "$waiters"
  [ -n "$live_waiters" ] || continue
  first_time "H:$res:$live_waiters" || continue
  echo "[claude-whiteboard] sessions are waiting on \"$res\", which you hold: $live_waiters."
  echo "Release it with /claude-whiteboard:free ${res%%@*} when your run is done."
done <<< "$(jq -r --arg s "$sid" '.sessions[$s].holds // {} | keys[]' <<< "$fresh" 2>/dev/null)"

# 2. Resources I am waiting for that nobody live holds any more.
while IFS= read -r res; do
  [ -n "$res" ] || continue
  holder="$(wb_holder_of "$res" "$sid" "${res%%@*}")"
  [ -z "$holder" ] || continue
  first_time "F:$res" || continue
  until_ts="$(jq -r --arg r "$res" --arg s "$sid" \
    '.sessions[$s].waits[$r].until // 0' <<< "$fresh" 2>/dev/null)"
  left=$(( until_ts - $(wb_now) ))
  if [ "$left" -gt 0 ]; then
    echo "[claude-whiteboard] \"$res\" is now FREE — you were waiting. Reserved for you for $(( left / 60 + 1 ))m more."
  else
    echo "[claude-whiteboard] \"$res\" is now FREE — you were waiting."
  fi
done <<< "$(jq -r --arg s "$sid" '.sessions[$s].waits // {} | keys[]' <<< "$fresh" 2>/dev/null)"

if [ "$warned_now" != "$warned_before" ]; then
  wb_update '.sessions[$sid].warned = $w' \
    --arg sid "$sid" --arg w "$warned_now" 2>/dev/null || true
fi
```

Note: the existing script already has a `warned_now != warned_before` write near the end. Move the new block **above** that write and delete the duplicate added here, so `warned` is persisted exactly once.

The early `exit 0` guard — `if [ -z "$wt_ticket" ] && [ -z "$prompt_ticket" ] && [ -z "$label" ]; then exit 0; fi` — must be removed, because a session with no ticket and no label still needs these notices. Replace it with a flag so the ticket/label conflict blocks are skipped instead:

```bash
check_conflicts=1
if [ -z "$wt_ticket" ] && [ -z "$prompt_ticket" ] && [ -z "$label" ]; then
  check_conflicts=0
fi
```

and wrap the two existing conflict blocks in `if [ "$check_conflicts" = 1 ]; then … fi`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/on-prompt.test.sh`
Expected: PASS, previous assertions unchanged plus the six new ones.

Run: `bash tests/on-pretool.test.sh` and `bash tests/lib.test.sh`
Expected: both PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/on-prompt.sh tests/on-prompt.test.sh
git commit -m "feat: prompt-time notices for pending waiters and freed resources"
```

---

### Task 9: `use` / `free` / `force` commands

**Files:**
- Create: `commands/use.md`, `commands/free.md`, `commands/force.md`
- Modify: `scripts/on-prompt.sh` (marker handling)
- Test: `tests/on-prompt.test.sh` (append)

**Interfaces:**
- Consumes: `wb_hold`, `wb_unhold`, `wb_open_window`, `wb_sweep_dead_holds`, `wb_resource_name`.
- Produces: three markers handled in `on-prompt.sh`: `@wb-use: <bare>`, `@wb-free: <bare>`, `@wb-force: <bare>`.

- [ ] **Step 1: Write the failing test**

Append to `tests/on-prompt.test.sh`:

```bash
# --- resource markers ------------------------------------------------------
reset
run M1 "$GITWT" "@wb-use: xcode" >/dev/null
eq "@wb-use records a hold" "true" \
   "$(q '.sessions.M1.holds | keys | map(startswith("xcode@")) | any')"

run M1 "$GITWT" "@wb-free: xcode" >/dev/null
eq "@wb-free drops the hold" "0" \
   "$(q '.sessions.M1.holds | length')"

reset
run M1 "$GITWT" "@wb-use: xcode" >/dev/null
out="$(run M2 "$GITWT" "@wb-force: xcode")"
eq "@wb-force takes it" "true" \
   "$(q '.sessions.M2.holds | keys | map(startswith("xcode@")) | any')"
eq "@wb-force strips the previous holder" "0" "$(q '.sessions.M1.holds | length')"
has "@wb-force names whom it took from" "M1" "$out"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/on-prompt.test.sh`
Expected: FAIL — `@wb-use` records nothing.

- [ ] **Step 3: Write minimal implementation**

In `scripts/on-prompt.sh`, next to the existing `@wb-claim:` / `@wb-release` parsing, add:

```bash
# Resource markers. Same marker-in-prompt pattern as @wb-claim, for the same
# reason: a script invoked from a command body never receives session_id, so
# only a hook can write the right registry entry.
marker_arg() {  # marker_arg <marker-name>
  grep -oE "@wb-$1:.*" <<< "$prompt" | head -n1 \
    | sed -E "s/^@wb-$1:[[:space:]]*//; s/[[:space:]]+\$//" || true
}
r_use="$(marker_arg use)"
r_free="$(marker_arg free)"
r_force="$(marker_arg force)"
```

and after the label handling, add:

```bash
if [ -n "$r_use" ]; then
  wb_hold "$sid" "$(wb_resource_name "$r_use" "$cwd")"
fi
if [ -n "$r_free" ]; then
  res="$(wb_resource_name "$r_free" "$cwd")"
  wb_unhold "$sid" "$res"
  wb_open_window "$res" "$WB_RESERVE"
fi
if [ -n "$r_force" ]; then
  res="$(wb_resource_name "$r_force" "$cwd")"
  prev="$(jq -r --arg r "$res" --arg self "$sid" '
      .sessions | to_entries
      | map(select(.key != $self and ((.value.holds // {}) | has($r))))
      | .[].key' <<< "$(wb_read_fresh)" 2>/dev/null)"
  for p in $prev; do wb_unhold "$p" "$res"; done
  wb_hold "$sid" "$res"
  if [ -n "$prev" ]; then
    echo "[claude-whiteboard] forced \"$res\" — taken from session(s): $(printf '%s' "$prev" | tr '\n' ' ' | sed 's/ *$//')."
  else
    echo "[claude-whiteboard] \"$res\" was already free; you hold it now."
  fi
fi
```

Create `commands/use.md`:

```markdown
---
description: Claim a shared resource (local stack, Xcode build, tunnel) on the claude-whiteboard so other parallel sessions are blocked from taking it.
disable-model-invocation: true
argument-hint: <resource>
---

The user is claiming the shared resource **$ARGUMENTS** on the whiteboard. Use
this for a resource no Bash command can be matched against — most importantly a
GUI Xcode build, which executes no command this plugin can see.

Emit exactly the following marker line (and nothing else) so the whiteboard
UserPromptSubmit hook records the claim:

@wb-use: $ARGUMENTS

Then tell the user in one line that "$ARGUMENTS" is claimed for this repo, that
another session running a matching command will now be blocked and queued, and
that `/claude-whiteboard:free $ARGUMENTS` releases it (session end also does).
```

Create `commands/free.md`:

```markdown
---
description: Release a shared resource this session holds on the claude-whiteboard, and give waiting sessions a head start on it.
disable-model-invocation: true
argument-hint: <resource>
---

The user is releasing the shared resource **$ARGUMENTS**.

Emit exactly the following marker line (and nothing else) so the whiteboard
UserPromptSubmit hook drops the hold and opens the priority window:

@wb-free: $ARGUMENTS

Then run the status script and tell the user, in one line, whether any session
was waiting on it — and if so, that those sessions now have a short head start
and can be told directly with SendMessage.

```bash
"${CLAUDE_PLUGIN_ROOT}"/scripts/status.sh
```
```

Create `commands/force.md`:

```markdown
---
description: Take a shared resource from another session on the claude-whiteboard. Only for a holder you have already verified is gone.
disable-model-invocation: true
argument-hint: <resource>
---

The user is forcing the claim of **$ARGUMENTS**, taking it from whichever session
currently holds it.

This is an override, not a normal path. The whiteboard already reclaims a
resource automatically when the holder's process is gone. Forcing is for the case
where the holder's process is alive but the resource is not actually in use.

Before emitting the marker, tell the user in one line who currently holds it (run
the status script below). If a live session holds it, say so and ask them to
confirm — taking a resource out from under a running stack breaks that session's
work.

```bash
"${CLAUDE_PLUGIN_ROOT}"/scripts/status.sh
```

On confirmation, emit exactly this marker line and nothing else:

@wb-force: $ARGUMENTS
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/on-prompt.test.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add commands/use.md commands/free.md commands/force.md scripts/on-prompt.sh tests/on-prompt.test.sh
git commit -m "feat: /use, /free and /force commands for shared resources"
```

---

### Task 10: Board rendering, hook registration, docs

**Files:**
- Modify: `scripts/on-session-start.sh`, `scripts/status.sh`, `hooks/hooks.json`, `README.md`, `.claude-plugin/plugin.json`
- Test: manual smoke run plus the three suites.

**Interfaces:**
- Consumes: everything.
- Produces: nothing new for other tasks.

- [ ] **Step 1: Register the hook**

In `hooks/hooks.json`, add a `PreToolUse` entry alongside the existing three:

```json
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}\"/scripts/on-pretool.sh" }
        ]
      }
    ]
```

- [ ] **Step 2: Render `uses:` on SessionStart rows**

In `scripts/on-session-start.sh`, inside the `others` jq map, after the `label` segment and before the `dir` segment, add:

```jq
        + (((.value.holds // {}) | keys) as $h
           | if ($h | length) > 0 then "  uses: " + ($h | join(", ")) else "" end)
```

And extend the trailing hint block so a board showing a resource explains itself:

```bash
  case "$others" in
    *"  uses: "*)
      echo 'A row with "uses:" holds that shared resource. A command that would take it is blocked until they release it — ask them rather than working around the block.'
      ;;
  esac
```

- [ ] **Step 3: Add the resource table to `status.sh`**

Append to `scripts/status.sh`:

```bash
echo
fresh="$(wb_read_fresh)"
lp="$(wb_live_pids)"

resrows="$(jq -r --argjson peers "$peers" --arg now "$(wb_now)" '
  [ .sessions | to_entries[] as $s
    | ($s.value.holds // {}) | to_entries[]
    | { res: .key, holder: $s.key, since: .value } ] as $held
  | [ .sessions | to_entries[] as $s
      | ($s.value.waits // {}) | to_entries[]
      | { res: .key, waiter: $s.key, since: .value.since } ] as $waiting
  | ($held + ($waiting | map({res}))) | map(.res) | unique
  | map(. as $r
      | ($held | map(select(.res == $r)) | first) as $h
      | ($waiting | map(select(.res == $r)) | map(
          (($peers[.waiter] // {}).name // .waiter[0:8])
          + "(" + ((((($now|tonumber) - .since) / 60) | floor | tostring)) + "m)")
         | join(", ")) as $w
      | $r
        + "\t" + (if $h then $h.holder[0:8] else "-" end)
        + "\t" + (if $h then ((($peers[$h.holder] // {}).name // "-")) else "-" end)
        + "\t" + (if $h then (((($now|tonumber) - $h.since) / 60) | floor | tostring) + "m" else "-" end)
        + "\t" + (if $w == "" then "-" else $w end))
  | .[]' <<< "$fresh" 2>/dev/null)"

if [ -z "$resrows" ]; then
  echo "No shared resources claimed."
else
  printf 'RESOURCE\tHOLDER\tPEER\tSINCE\tWAITING\n'
  printf '%s\n' "$resrows"
fi
```

- [ ] **Step 4: Verify everything**

Run all three suites and record the actual counts:

```bash
bash tests/lib.test.sh
bash tests/on-prompt.test.sh
bash tests/on-pretool.test.sh
```

Expected: all three print `N passed, 0 failed`.

Syntax-check every script:

```bash
for f in scripts/*.sh; do bash -n "$f" || echo "SYNTAX FAIL: $f"; done
```

Expected: no output.

Smoke-test the real hook end to end in a throwaway registry:

```bash
TMP=$(mktemp -d)
CC_WHITEBOARD_REGISTRY=$TMP/r.json jq -nc \
  '{session_id:"smoke", cwd:"'"$PWD"'", tool_name:"Bash",
    tool_input:{command:"docker compose up -d"}}' \
  | CC_WHITEBOARD_REGISTRY=$TMP/r.json bash scripts/on-pretool.sh; echo "rc=$?"
jq . "$TMP/r.json"
rm -rf "$TMP"
```

Expected: `rc=0`, and the registry shows `holds: {"local-stack@claude-whiteboard": …}`.

- [ ] **Step 5: Update `README.md` and bump the version**

Add a `## Shared resources` section to `README.md` after "Talking to the session that owns it", covering: what a resource is, the `@repo` scoping and why `--git-common-dir` rather than `--show-toplevel`, the block message, the waiter/priority-window flow, the three phantom layers including the liveness-unknown guard, the three commands, and the five new env vars in the Configuration table.

Add a `### 0.4.0` changelog entry. Bump `version` in `.claude-plugin/plugin.json` to `0.4.0`.

State the measured assertion counts from Step 4 in the changelog, not estimates.

- [ ] **Step 6: Commit**

```bash
git add scripts/on-session-start.sh scripts/status.sh hooks/hooks.json README.md .claude-plugin/plugin.json
git commit -m "feat: render shared resources on the board; register PreToolUse; docs for 0.4.0"
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| Resource naming `<name>@<repo>` | 1 |
| Registry shape (`holds`, `waits`) | 3 |
| PreToolUse detection, block, all-or-nothing compound | 4 |
| Pattern map + env override | 2 |
| Layer 1 PID liveness + unknown guard | 1, 5 |
| Layer 2 probe, three-valued, warn-and-allow | 2, 6 |
| Layer 3 idle soft-expiry, taken by anyone | 3, 5 |
| Precedence probe > pid > idle | 3 |
| Priority window | 3, 7 |
| Handoff flow, pull backup | 8 |
| Messages | 4, 6, 8 |
| Commands use/free/force | 9 |
| Board rendering | 10 |
| Configuration vars | 2 |
| Tests 1–20 | 4, 5, 6, 7 (hook), 1–3 (helpers) |

No spec section is unassigned.

**Type consistency:** `holds` is `{resource: epoch}` in Tasks 3, 4, 5, 7, 9, 10. `waits` is `{resource: {since, until}}` in Tasks 3, 7, 8, 9. `wb_holder_of` prints 5 lines in Tasks 3, 4 and 8. `wb_reserved_by` prints 3 lines in Tasks 3 and 4. `wb_probe` returns 0/1/2 in Tasks 2, 3 and 6.

**Known plan-level risk:** Task 8 restructures the early `exit 0` in `on-prompt.sh`. That script's existing 46+ assertions must all still pass; if any regress, the restructure is wrong, not the tests.
