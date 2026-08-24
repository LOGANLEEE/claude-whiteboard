# claude-whiteboard: exclusive resource claims

## Goal

Stop two parallel sessions from destroying each other's shared singletons — the
local backend stack, an Xcode/device build, an ngrok tunnel, a shared database.

Today the plugin coordinates *work* (ticket, label). It does not coordinate
*resources*. Nothing detects that another session already has the stack up, and
nothing blocks the command that breaks it.

## The problem this solves

A ticket conflict means "we may be doing the same work twice" — wasteful but
recoverable. A resource conflict is different in kind: the second session does
not duplicate the first, it *corrupts* it.

Concretely, for a repo whose local stack is brought up per-worktree while the
database is shared:

- The database is shared across all worktrees of a repo. A migration run from
  worktree B rewrites the database worktree A is running against.
- Bringing a stack up rewrites shared config rows (e.g. passkey RP / tunnel
  origin) to B's tunnel domain. A's already-running device build then starts
  failing authentication, with an error that looks like a bug in A's own work.
- Teardown is global. Whoever runs it stops the stack for everyone.
- Ports are machine-wide. The second bind fails, or worse, silently attaches.

None of these announce their cause. The victim session sees a plausible-looking
bug in its own feature and debugs the wrong thing.

## Non-goals

- **No auto-grant of ownership.** A released resource is never assigned to a
  session that did not ask for it in that moment. See "Priority window".
- **No cross-machine coordination.** The registry is one file on one machine.
- **No new transport.** Sessions negotiate over `SendMessage`, which already
  exists. The whiteboard supplies the address and the reason, not the channel.
- **No fuzzy resource matching.** Exact name match, same reliability contract as
  labels. A block must always mean a real overlap.
- **No repo-specific patterns in the shipped defaults.** The plugin is public.
  Project-specific commands go in the user's `CC_WHITEBOARD_RESOURCES` override.

## Concepts

| Term | Meaning |
|------|---------|
| **resource** | A named singleton, scoped to a repo: `local-stack@wallet-monorepo` |
| **hold** | A session is using it. Others are blocked. |
| **wait** | A session was blocked and is queued. Carries no ownership. |
| **priority window** | After a release, waiters may claim; non-waiters may not, for a short period. |

There is deliberately no "granted" state. See "Priority window" for why.

## Resource naming: `<name>@<repo>`

The registry is a single file shared by every repo on the machine
(`~/.claude/whiteboard/registry.json`). Without a repo suffix, one project's
`local-stack` would block an unrelated project's `local-stack`.

The repo key is the basename of:

```sh
git rev-parse --path-format=absolute --git-common-dir
```

This groups all worktrees of a repo under one key, which is the correct
collision domain — worktrees share the database and the ports.

Verified by control test (2026-08-24, this repo, throwaway worktree):

```
main repo   --git-common-dir : /Users/…/claude-whiteboard/.git
linked wt   --git-common-dir : /Users/…/claude-whiteboard/.git   ← same
linked wt   --show-toplevel  : /…/scratchpad/wt-probe            ← different
```

`--show-toplevel` does **not** group worktrees and must not be used here.

A non-git directory yields the bare name with no suffix.

## Registry shape

Session-centric, extending the existing entry. No new top-level key.

```json
{
  "sessions": {
    "fe649d0f-…": {
      "ticket": "PAY-106",
      "ticket_src": "worktree",
      "dir": "backend",
      "branch": "fix/pay-106-send-supported",
      "updated": 1787588908,
      "holds": { "local-stack@wallet-monorepo": 1787588000 },
      "waits": {}
    },
    "8d705b09-…": {
      "ticket": "PAY-161",
      "holds": {},
      "waits": { "local-stack@wallet-monorepo": { "since": 1787588300, "until": 0 } }
    }
  }
}
```

`holds` maps resource → claim timestamp, so "held 12m" renders for free.

Why session-centric rather than a top-level `.resources` map: `wb_read_fresh`
already drops a stale session's whole entry on the TTL, so its holds and waits
disappear with it. A separate resource map would need its own pruning, its own
staleness rules, and would then disagree with the session list.

## Detection: a `PreToolUse` hook on Bash

New `scripts/on-pretool.sh`, registered for `PreToolUse` matching `Bash`.

It reads `tool_input.command`, matches it against a resource pattern map, and:

- **no match** → exit 0, silent. This is the overwhelmingly common path.
- **matches a `release` pattern** → drop this session's hold, open the priority
  window on every waiter.
- **matches a `claim` pattern, resource free** → record the hold, exit 0 silent.
- **matches a `claim` pattern, already held by *this* session** → exit 0 silent.
  Re-claiming is idempotent and must not refresh the `since` timestamp.
- **matches a `claim` pattern, resource held by a live other session** →
  **exit 2** with the block message on stderr, and record this session as a
  waiter.

One command may match several resources (`docker compose up && xcodebuild …`).
Every matching resource is evaluated; a block on any one blocks the command, and
no hold is recorded for the others. Partial claims would leave a phantom on the
resource that was not the reason for the block.

Blocking is `exit 2` + stderr, the mechanism already used by
`~/.claude/hooks/block-yubikey-git-remote.sh` (read 2026-08-24). Claude sees the
stderr text and stops.

### Pattern map

`CC_WHITEBOARD_RESOURCES` holds JSON. Shipped default, intentionally generic:

```json
{
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
}
```

A user with project-specific recipes overrides the whole map, e.g. adding
`just +stack::(up|tunnel|client-up)` and `just +db::(migrate|reset)` to
`local-stack.claim`, and a real `probe`.

## Phantom holds: three layers, all evaluated at read time

A hold nobody is actually using blocks everyone. There is no daemon, so every
expiry rule is computed when a hook reads the registry — the same lazy pattern
`wb_read_fresh` already uses for the session TTL.

### Layer 1 — PID liveness (strongest)

Claude Code writes `~/.claude/sessions/<pid>.json` per live session. Verified
keys (2026-08-24):

```
bridgeSessionId, cwd, entrypoint, kind, messagingSocketPath, name, nameSince,
peerFeatures, peerProtocol, pid, procStart, sessionId, startedAt, status,
statusUpdatedAt, updatedAt, version
```

A hold is dead when the session registry is **readable** and any of these is true:

1. No session file carries that `sessionId`.
2. `kill -0 <pid>` fails.
3. `TZ=UTC ps -o lstart= -p <pid>` (trimmed) ≠ the stored `procStart` — PID reuse.

**The instrument must be proven able to see before its silence counts.** If the
session directory is missing or contains no readable session file, liveness is
`unknown`, not `dead`. Layer 1 is then skipped entirely and holds expire only on
the existing session TTL.

Without this guard the feature inverts on any machine with no session registry:
every holder reads as dead, every hold is reclaimed, and the locking silently
stops working while still reporting success. An empty result proves nothing until
the instrument is shown to work.

Rule 3 also degrades to `unknown` rather than `dead` when `ps` yields nothing for
a PID that `kill -0` accepted, and rule 3 is skipped when `procStart` was never
recorded.

Verified this session:

```
kill -0 10710 → ALIVE    kill -0 93745 → ALIVE    kill -0 999999 → DEAD
```

**Timezone trap.** `procStart` is stored in UTC; plain `ps -o lstart=` prints
local time. On a `+04` machine they differ by four hours and a naive string
compare always fails:

```
file procStart        : Mon Aug 24 15:23:48 2026
ps -o lstart=         : Mon Aug 24 19:23:48 2026   ← mismatch
TZ=UTC ps -o lstart=  : Mon Aug 24 15:23:48 2026   ← match, after trimming
```

New helper `wb_live_pids()` returns `{sessionId: {pid, procStart}}`. It must
**not** reuse `wb_peer_names()`, which filters `select((.name // "") != "")`.
Liveness does not need a name, and filtering on one would misreport an unnamed
session as dead.

This errs safe. A false "alive" leaves a phantom, which `/force` clears. The
dangerous direction — judging a live holder dead — requires the process to
genuinely not exist.

### Layer 2 — resource probe (physical truth, optional per resource)

An optional `probe` command per resource. Exit 0 means the resource is actually
up. It runs only when a claim is being evaluated for that resource, never on an
unrelated command, so an ordinary Bash call pays nothing.

A probe that times out or cannot run is **unknown**, not "down". Unknown falls
through to layers 1 and 3 — it never itself releases a hold.

| probe | registry | outcome |
|-------|----------|---------|
| down | held | Phantom. Auto-release, then let the claimer take it. |
| up | held | Real. Block. |
| up | free | Warn on stderr, **allow** (exit 0). Something is up that the board cannot attribute — a non-Claude process, or a session that started before the plugin. The claimer decides. |
| unknown | any | Ignore the probe; fall through to layers 1 and 3. |

The third row is visible only to a probe, and it is the case where the user
brought the stack up by hand. It warns rather than blocks, because a resource
with no recorded holder gives nobody to ask, and blocking on an unattributable
signal is exactly the noise that erodes trust in the warning.

Xcode ships with no probe: a GUI Xcode build is not an `xcodebuild` process, so
there is no cheap honest check. It falls back to layers 1 and 3.

### Layer 3 — idle soft-expiry (for resources with no probe)

`CC_WHITEBOARD_HOLD_IDLE`, default 3600s. If the holder's PID is alive, the
resource has no probe, and the holder has not submitted a prompt within that
window, the hold becomes **soft**.

A soft hold may be taken by **anyone**, not only a waiter, with a one-line notice
and no `/force`. Restricting it to waiters would mean a session that never got
blocked has to first get blocked in order to qualify, which is a round trip that
buys nothing. The former holder is told it lost the resource on its next prompt.

This catches the holder who tore the stack down and forgot. The common case is
already caught by the `release` pattern; this catches the rest.

### Precedence

**probe (when present) > pid > idle.**

A probe that says "up" suppresses idle expiry. An hour of session idleness is
normal while the user hand-tests on a device, and taking the hold then would be
exactly wrong. Only the probe can tell that case apart from an abandoned hold.

## Priority window (instead of auto-grant)

Real auto-grant — assigning a released resource to the first waiter — creates
the phantom it is meant to avoid. An idle waiter would hold something it no
longer wants while a third session is blocked, and it needs a state machine
(`granted` → `held` / `lapsed`) plus head-of-line blocking.

What auto-grant actually buys is narrower: a session that waited 40 minutes
should not lose the resource, the instant it frees, to a fresh session that
never waited.

That is obtainable with a timestamp and no state machine. On release, every
waiter's `waits[r].until` is set to `now + CC_WHITEBOARD_RESERVE` (default 300s).

- A waiter claims → allowed.
- A non-waiter claims while any **live** waiter has `until > now` → blocked,
  and told who is in line and for how much longer.
- After the window → free for all.

Properties:

- No session ever holds a resource it did not ask for in that moment.
- No head-of-line blocking: any waiter may take it, not only the first.
- No new top-level key — the field lives on the waiter's own entry and is pruned
  with that waiter's session.

Waits expire on their own: `CC_WHITEBOARD_WAIT_TTL`, default 7200s. A wait is
also dropped when the waiter successfully claims, or when its session ends.

## The handoff flow

1. B runs a claiming command. A holds the resource and is live.
2. B is blocked and recorded as a waiter. The block message carries the holder's
   dir, branch, hold age, and the exact `SendMessage` call.
3. B messages A. A asks the user, because only the user knows whether A's run is
   still needed. **This is the decision point, and it is always the user's.**
4. A releases — via `/claude-whiteboard:free`, a matching `release` command, or
   session end. All three open the priority window on every waiter. The first
   two also print the waiters and how to notify them; session end cannot, because
   `SessionEnd` output is not injected into any session's context. B still learns
   at its own next prompt, so the handoff completes even when A simply exits.
5. B's next prompt reports the resource is free and clears B's wait entry. B
   re-runs the command and claims it through the same hook.

Step 3 has a pull backup: A's own `UserPromptSubmit` reports how many sessions
are waiting on resources A holds, so an unread `SendMessage` does not strand B.

## Messages

Block, resource held:

```
BLOCKED: "local-stack@wallet-monorepo" is held by session fe649d0f
  dir: backend   branch: fix/pay-106-send-supported   since: 12m ago

Do NOT start your own — you would migrate the shared database and rewrite
shared config rows under their running device build.

You are now recorded as WAITING for it.
Ask the holder directly:
  SendMessage({to: "931-deposit",
    message: "I need local-stack for PAY-161. When can I take it?"})

If you have verified that session is dead: /claude-whiteboard:force local-stack
```

Block, priority window:

```
BLOCKED: "local-stack@wallet-monorepo" is free but reserved for 4m more.
Session 8d705b09 (1409) has been waiting 41m. Ask before you take it:
  SendMessage({to: "1409", message: "..."})
```

Holder's prompt, waiters pending:

```
[claude-whiteboard] 2 sessions are waiting on "local-stack@wallet-monorepo",
which you hold: 1409 (41m), 161-icon (6m). Release it with
/claude-whiteboard:free local-stack when your run is done.
```

Waiter's prompt, now free:

```
[claude-whiteboard] "local-stack@wallet-monorepo" is now FREE — you were
waiting. Reserved for you for 4m more.
```

Reclaimed phantom:

```
[claude-whiteboard] reclaimed "local-stack@wallet-monorepo" from session
fe649d0f — its process is gone. Taking it.
```

## Commands

- `/claude-whiteboard:use <resource>` — manual claim. Required for anything with
  no Bash command to match, notably a GUI Xcode build.
- `/claude-whiteboard:free <resource>` — release, and print waiters to notify.
- `/claude-whiteboard:force <resource>` — take a resource from a session you have
  verified is dead. Names whom it was taken from.

These follow the marker-in-prompt pattern the existing `/claim` command already
uses, for the reason recorded in the keyword-claim spec: a script invoked from a
command body does not receive `session_id`, so only a hook can write the correct
registry entry.

## Board rendering

`SessionStart` rows gain a `uses:` segment, omitted when empty:

```
- fe649d0f  ticket: PAY-106  dir: backend  peer: 931-deposit (idle)  uses: local-stack
```

`status.sh` gains a resource section below the session table:

```
RESOURCE                      HOLDER    PEER          SINCE   WAITING
local-stack@wallet-monorepo   fe649d0f  931-deposit   12m     1409(41m), 161-icon(6m)
xcode@wallet-monorepo         -         -             -       -
```

## Configuration

| Var | Default | Purpose |
|-----|---------|---------|
| `CC_WHITEBOARD_RESOURCES` | generic map (above) | resource → `{claim, release, probe}` regex/command map |
| `CC_WHITEBOARD_HOLD_IDLE` | `3600` | Holder idle seconds before a probe-less hold goes soft |
| `CC_WHITEBOARD_RESERVE` | `300` | Priority window after release; `0` disables |
| `CC_WHITEBOARD_WAIT_TTL` | `7200` | A wait older than this is dropped |
| `CC_WHITEBOARD_PROBE_TIMEOUT` | `2` | Seconds before a probe is treated as unknown |

Existing vars are unchanged.

## Known limits

- **A GUI Xcode build is invisible** unless someone runs
  `/claude-whiteboard:use xcode`. No Bash command is executed, and there is no
  honest cheap probe.
- **A probe answers "is it up", never "whose".** Attribution always comes from
  the registry. A resource that is up with no claim is reported as unattributed,
  not guessed at.
- **Ports are machine-wide, resource names are repo-scoped.** Two different repos
  binding the same port will not block each other. Claim a shared name manually
  if that matters.
- **`exit 2` blocks the Bash tool call, not the user.** A user running the
  command in their own terminal is unaffected, by design.
- **Pull lag persists.** A holder learns about a waiter at its next prompt, or
  immediately if the waiter sends a `SendMessage`.

## Tests

`tests/on-pretool.test.sh`, in the style of the existing bash + jq harness (no
Claude Code restart required):

1. Unmatched command → exit 0, registry unchanged.
2. Claim pattern, resource free → hold recorded, exit 0.
3. Claim pattern, resource held by a live session → exit 2, stderr names the
   holder, waiter recorded.
4. Same resource name in two different repos → both hold, no block.
5. Holder's PID dead → hold reclaimed, exit 0, reclaim message emitted.
6. `procStart` mismatch (PID reuse simulated) → treated as dead.
7. Release pattern → hold dropped, waiters' `until` set.
8. Non-waiter claims inside the priority window → blocked, names the waiter.
9. Waiter claims inside the priority window → allowed, wait entry cleared.
10. Priority window elapsed → non-waiter allowed.
11. Probe exits 0 while holder is idle past `HOLD_IDLE` → hold kept.
12. No probe, holder idle past `HOLD_IDLE` → hold soft, waiter takes it.
13. Wait older than `WAIT_TTL` → dropped, no reservation granted.
14. Holder re-runs its own claim command → exit 0, `since` unchanged.
15. One command matching two resources, one of them held → exit 2, and **no**
    hold recorded for the free one.
16. Probe exits 0 while the registry shows the resource free → exit 0, warning
    on stderr, hold recorded.
17. Soft hold taken by a session that never waited → allowed.
18. Session end while holding a resource → hold gone, waiters' `until` set.
19. Empty `CC_WHITEBOARD_SESSIONS_DIR` → hold **kept**, not reclaimed. This is
    the guard against the feature inverting where no session registry exists.
20. `ps` returns nothing for a PID that `kill -0` accepted → hold kept.

Liveness tests inject a fake `CC_WHITEBOARD_SESSIONS_DIR` with hand-written
session files, so no real Claude session is needed.

## Files touched

| File | Change |
|------|--------|
| `scripts/lib.sh` | `wb_live_pids`, `wb_repo_key`, `wb_resource_holder`, hold/wait/probe helpers |
| `scripts/on-pretool.sh` | new — detection, block, reclaim, release |
| `scripts/on-prompt.sh` | waiter notices, holder waiter-count notice, freed notice |
| `scripts/on-session-start.sh` | `uses:` on rows |
| `scripts/status.sh` | resource section |
| `scripts/on-session-end.sh` | open the priority window on waiters before deleting this entry |
| `hooks/hooks.json` | register `PreToolUse` |
| `commands/use.md`, `free.md`, `force.md` | new |
| `tests/on-pretool.test.sh` | new |
| `README.md` | resource section, config vars, changelog |

## Evidence

Measured in this session (2026-08-24) on this machine:

- Worktree grouping via `--git-common-dir`: control test with a throwaway
  worktree, both paths identical, `--show-toplevel` different.
- `kill -0` liveness: two live PIDs from the session registry reported ALIVE,
  a nonexistent PID reported DEAD.
- `procStart` timezone offset and the `TZ=UTC` fix: compared file value against
  `ps -o lstart=` for two PIDs.
- Session file key list: read from three files in `~/.claude/sessions/`.
- `exit 2` blocking: read from `~/.claude/hooks/block-yubikey-git-remote.sh`.

Not verified: the shared-database and shared-config corruption modes in the
problem statement come from a project runbook, not from reading that project's
build recipes. They motivate the design; no code here depends on them.
