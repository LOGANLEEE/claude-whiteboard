# claude-whiteboard

A shared **whiteboard** for parallel [Claude Code](https://code.claude.com) sessions.

Run 2–6 sessions on the same repo (typically one per git worktree) and they can't
see each other's context — so two of them may unknowingly pick overlapping tickets
and do the **same work twice**. Git worktrees isolate *files*; they do nothing about
*double-work*. This plugin fixes that with a tiny shared registry.

Each session posts what ticket it's working on to a shared JSON file. Every other
session reads that file at startup and on every prompt, and is **warned before
starting work another session already owns** — and told **how to reach the session
that owns it**, so the two can settle it between themselves.

> Not orchestration — no lead, no workers. Just a whiteboard equal peers read and write.

## How it works

| Hook | What it does |
|------|--------------|
| `SessionStart` | Registers this session and injects the list of *other* active sessions into context, each with the address you can message it on. |
| `UserPromptSubmit` | Works out this session's current ticket (see [Ticket evidence](#ticket-evidence-mention--work)) plus any claimed **label**, records it, and — **only if another live session demonstrably owns that same ticket or label** — injects a conflict warning telling the agent to stop and check with you. Silent otherwise. |
| `PreToolUse` (Bash) | Matches the command against the [resource map](#shared-resources-the-local-stack-an-xcode-build-a-tunnel). Claims a free resource silently; **blocks** the command when another live session holds it, and records this session as a waiter. Does nothing at all for a command that touches no resource. |
| `SessionEnd` | Removes this session (ticket, label and holds) and prunes stale (crashed) entries past the TTL. Opens the priority window on anyone waiting for a resource it held. |

```
session A  ──"work on ETHEN-447"──▶  whiteboard: A = ETHEN-447
session B  ──"work on ETHEN-447"──▶  ⚠ warns B: ETHEN-447 already owned by A → stop & confirm
session A  ──"now ETHEN-880"─────▶  whiteboard: A = ETHEN-880   (updated in real time)
```

### Ticket evidence: mention ≠ work

Where a ticket id comes from decides how much it is trusted:

| Evidence | `ticket_src` | Strength | Behaviour |
|----------|--------------|----------|-----------|
| Worktree dir or branch name (`ethenapayf-1013-kyc-camera`, `jira-12-login-fix`, `feature/ETHEN-447`) | `worktree` | **strong** | Always wins. Overwrites a value previously sniffed from a prompt. |
| Ticket id inside your prompt (`ETHEN-447`) | `prompt` | weak | Used only when the session has no worktree evidence **and** no ticket recorded yet. Never overwrites an existing ticket. |

Dir/branch detection uses the same `CC_WHITEBOARD_TICKET_RE` as prompt sniffing,
so it works for any tracker — not one hard-coded project prefix.

How loud a warning gets depends on the **holder's** evidence:

| Holder's `ticket_src` | You get |
|-----------------------|---------|
| `worktree` — they are sitting in that worktree | `⚠ CONFLICT` + an instruction to stop and check with you |
| `prompt` (or a pre-0.2.2 entry with none) — they only mentioned it | a one-line note, no stop directive |

```
[claude-whiteboard] ⚠ CONFLICT: ticket "ETHENAPAYF-1013" is already being worked
on by session 4a9f21c8 (dir: ethenapayf-1013-kyc-camera, branch: feat/kyc-camera)
This is likely DOUBLE WORK. STOP before editing code: …

[claude-whiteboard] note: session 3689a1c2 (dir: worktrees) also mentioned ETHENAPAYF-1013.
```

The message names the holder's **directory** and branch so you can verify
ownership at a glance. Each distinct overlap is announced **once** — the same
ticket held by the same session will not warn again, so a real conflict can't
turn into an every-prompt drumbeat. A different holder warns again.

#### `@wb-ignore`

Put `@wb-ignore` in a prompt (as a whitespace-delimited token, anywhere) and the
hook is a complete no-op for it — no ticket sniffing, no claim markers, no
registry write, no conflict check:

```
@wb-ignore
Board dump from the other terminal — ETHENAPAYF-1013 is owned by session 3689…
```

Use it for pasted coordination dumps, cross-checks, and status reports that talk
*about* tickets you are not working on.

### Ticketless work: claim a label

No ticket id? Claim a free-text **label** so other sessions still get warned:

```
/claude-whiteboard:claim auth refactor   → whiteboard: this session = "auth refactor"
                                            another session that claims "auth refactor" is warned
/claude-whiteboard:release                → drop the label (also cleared at session end)
```

Labels match **exact, case-insensitive** — same reliability contract as ticket
ids, so a warning always means a real overlap. There is no fuzzy free-text
matching (that would fire false conflicts and erode trust in the warning). Ticket
detection is unchanged; a prompt can carry both a ticket and a claimed label.

### Talking to the session that owns it

A warning that names a stranger is only half an answer. Every board row also
carries that session's **peer name** — the address Claude Code's own
`SendMessage` tool delivers to — so the agent can ask the other session what it
has already done instead of routing the question back through you:

```
- 07a7860e  ticket: ETHENAPAYF-1013  dir: ethenapayf-1013-kyc-camera  peer: 1013 (busy)
```

```
[claude-whiteboard] ⚠ CONFLICT: ticket "ETHENAPAYF-1013" is already being worked on …
That session is reachable: SendMessage({to: "1013", message: "..."}) — ask what it
has already done before you touch anything.
```

The name comes from Claude Code's own session registry (`~/.claude/sessions/*.json`),
joined against the board **at render time** on the session id both sides already
record. Nothing is copied into the whiteboard's registry, so a session you rename
stays reachable and the board never serves a stale address.

Consequences worth knowing:

- **No new transport.** The whiteboard does not move messages; `SendMessage` does.
  The board only tells you the address.
- **Older Claude Code, or no session registry** — rows simply render without
  `peer:`, exactly as they did before. Nothing errors.
- **A session Claude Code has not named** gets no address line.
- **Duplicate names are possible** (two sessions can both be called `avax`). The
  board prints the name and the directory; `SendMessage` itself asks you to
  disambiguate when the name is ambiguous. The 6-hex `[ref]` that `ListAgents`
  prints is *not* stored in the session registry, so the board cannot offer it.
- **A mention-only note gets no address**, deliberately — it stays one line.

### Shared resources: the local stack, an Xcode build, a tunnel

A ticket conflict means two sessions may do the same work twice — wasteful, but
recoverable. A **resource** conflict is different in kind: the second session
does not duplicate the first, it *corrupts* it. Bringing up a second local stack
rewrites the database and the shared config rows the first session is running
against, and the victim then debugs a failure that looks like a bug in its own
feature.

So resources are not warned about at prompt time. They are **blocked at the
moment the command runs**, by a `PreToolUse` hook on `Bash`:

```
$ docker compose up -d

BLOCKED: "local-stack@wallet-monorepo" is held by session fe649d0f
  dir: backend   branch: fix/pay-106   since: 12m ago

You are now recorded as WAITING for it.
Ask the holder directly:
  SendMessage({to: "931-deposit", message: "I need local-stack. When can I take it?"})
```

**Names are scoped per repo** — `local-stack@wallet-monorepo`. The registry is one
file shared by every repo on the machine, so an unscoped name would let one
project block an unrelated one. The repo key comes from
`git rev-parse --git-common-dir`, **not** `--show-toplevel`: a linked worktree's
toplevel is its own directory, and worktrees of one repo are exactly the
collision domain, since they share the database and the ports.

#### Which commands claim what

`CC_WHITEBOARD_RESOURCES` is a JSON map of resource → `{claim, release, probe}`.
The shipped default is deliberately generic, because this plugin is public:

```json
{
  "local-stack": { "claim": "(^|[;&|(])[[:space:]]*(docker[- ]compose\\b.*\\bup\\b|ngrok\\b)",
                   "release": "(^|[;&|(])[[:space:]]*docker[- ]compose\\b.*\\bdown\\b", "probe": "" },
  "xcode":       { "claim": "(^|[;&|(])[[:space:]]*(xcodebuild\\b|xcrun +simctl +(boot|install|launch))",
                   "release": "(^|[;&|(])[[:space:]]*xcrun +simctl +shutdown", "probe": "" }
}
```

Every claim pattern is anchored to **command position** — start of line, or just
after `;`, `&`, `|` or `(`. A bare `\bngrok\b` claimed on the mere appearance of
the word: a `sed` writing the literal string `your-tunnel.ngrok-free.dev` into a
config file took the local-stack hold with no stack running. Anchor your own
patterns the same way. A claim blocks every other session, so a false positive is
far more expensive than a missed one.

`CC_WHITEBOARD_RESOURCES` **replaces** this map; it does not merge into it. So a
fix to a shipped pattern never reaches a machine that sets the variable — anchor
your own patterns yourself, including the branches that look guarded. In a real
override, `\bjust\b[^|;&]*\bstack::up\b` was assumed safe because `[^|;&]*`
keeps both halves inside one pipeline segment. It does not anchor anything:
`grep -rn "just stack::up" docs/` still claimed the resource.

Override the whole map to add your project's own recipes (`just stack::up`,
`just db::migrate`) and a real `probe`. A command matching several resources is
**all-or-nothing**: if one is held, nothing is claimed, so a block never leaves a
phantom on a resource that was not the reason for it.

#### Waiting, and getting it back

A blocked session is recorded as a waiter and handed the holder's `SendMessage`
address. The holder asks *you*, because only you know whether its run is still
needed — no session ever releases another session's resource.

When the holder releases (`/claude-whiteboard:free`, a matching release command,
or simply ending its session), every waiter gets a short **priority window**:
during it, a session that never waited is held off, while **any** waiter may
claim — not only the one who waited longest. That is deliberately a timestamp
rather than an auto-grant. Handing ownership to an idle waiter would create the
very phantom this feature exists to prevent.

#### A hold nobody is using

Three layers, all evaluated when a hook reads the registry. No daemon, no timers.

| Layer | What it catches |
|-------|-----------------|
| **PID liveness** | The holder crashed. Its `pid` / `procStart` come from Claude Code's own `~/.claude/sessions/<pid>.json`, so a dead holder is reclaimed on the next check instead of waiting out the TTL. |
| **Probe** (optional, per resource) | The holder is alive but tore the stack down. A probe exiting 0 means really up; it also outranks idleness, because an hour of silence is normal while you hand-test on a device. |
| **Idle soft-expiry** | No probe and the holder has not prompted for `CC_WHITEBOARD_HOLD_IDLE`. Anyone may then take it with a one-line notice, no `/force` needed. |

**Liveness is three-valued.** If the session registry is missing or unreadable,
liveness is *unknown*, never *dead* — otherwise every holder would read as dead
on such a machine, every hold would be reclaimed, and the lock would silently
stop working while still reporting success.

A probe that says a resource is up while **nobody** claims it produces a warning,
not a block: that is a non-Claude process or a session older than this plugin,
and there is nobody to ask.

### Token cost

Effectively **zero in steady state**. Hooks are shell scripts (no model tokens to
run). The only context cost is text a hook injects: a small list once at
`SessionStart` (peer names add roughly 8 tokens per listed session), and a
one-line warning **only when a real conflict is detected**. No conflict → nothing
injected. The address lookup runs only when a conflict is actually found, so an
ordinary prompt never pays for it.

## Install

```
/plugin marketplace add LOGANLEEE/claude-whiteboard
/plugin install claude-whiteboard@claude-whiteboard
```

Requires [`jq`](https://jqlang.github.io/jq/) (`brew install jq`). Without it the
plugin no-ops safely.

### Try it before installing

```bash
claude --plugin-dir ./claude-whiteboard
```

## Configuration (env vars)

| Var | Default | Purpose |
|-----|---------|---------|
| `CC_WHITEBOARD_REGISTRY` | `$CLAUDE_PLUGIN_DATA/whiteboard/registry.json` (falls back to `~/.claude/...`) | Where the shared registry lives. Point several sessions at the same path (default already does). Set to a repo-local path if you want per-repo boards. |
| `CC_WHITEBOARD_TICKET_RE` | `[A-Z][A-Z0-9]+-[0-9]+` | Regex used to detect a ticket id, both in a prompt and (case-insensitively) in the worktree dir / branch name. Matches `ETHEN-447`, `JIRA-12`, etc. Tighten it if your naming produces false hits — e.g. a directory called `portfolio-2024` reads as ticket `PORTFOLIO-2024`. |
| `CC_WHITEBOARD_SESSIONS_DIR` | `~/.claude/sessions` | Where Claude Code keeps its own per-session JSON files. Read-only — the plugin joins against it to learn each peer's `SendMessage` name. Point it elsewhere (or at an empty directory) to turn the address lookup off. |
| `CC_WHITEBOARD_TTL` | `14400` (4h) | Entries older than this are treated as stale and pruned (crash safety). |
| `CC_WHITEBOARD_RESOURCES` | generic map (see [Shared resources](#shared-resources-the-local-stack-an-xcode-build-a-tunnel)) | resource -> `{claim, release, probe}`. Override the whole map to add project-specific commands. |
| `CC_WHITEBOARD_HOLD_IDLE` | `3600` (1h) | Holder idle seconds before a hold with no probe goes soft and anyone may take it. |
| `CC_WHITEBOARD_RESERVE` | `300` (5m) | Priority window given to waiters when a resource is released. `0` disables it. |
| `CC_WHITEBOARD_WAIT_TTL` | `7200` (2h) | A wait older than this is ignored and grants no reservation. |
| `CC_WHITEBOARD_PROBE_TIMEOUT` | `2` | Seconds before a probe is treated as `unknown` rather than `down`. |

## Commands

- `/claude-whiteboard:status` — print the current board (active sessions, tickets, labels, branches, peer names, last-seen age).
- `/claude-whiteboard:claim <label>` — claim a free-text label for ticketless work so other sessions are warned off it.
- `/claude-whiteboard:release` — drop this session's claimed label.
- `/claude-whiteboard:use <resource>` — manually claim a shared resource. Needed only for something no command can be matched against, notably a GUI Xcode build. Refuses, and names the holder, when another session holds it.
- `/claude-whiteboard:free <resource>` — release a resource **this session holds** and give waiters a head start. Refuses, and names the holder, when someone else holds it.
- `/claude-whiteboard:force <resource>` — take it from a holder you have verified is not using it.

## Notes & limits

- **Pull, not push.** A session learns another moved on at *its own* next prompt or
  restart — at most one turn of lag. Fine for avoiding double-work.
- **Ticket or label.** Automatic detection prefers the worktree/branch name and
  falls back to a ticket id in your prompt (weak — see above). Ticketless work is
  tracked only when you `/claude-whiteboard:claim` a label — there is deliberately
  no fuzzy free-text sniffing.
- **A weak ticket sticks.** Once a session with no worktree evidence has a
  prompt-sniffed ticket, later prompts never change it; only moving into a
  matching worktree does. Prose can trip the default regex (`UTF-8`, `ISO-8601`,
  `RFC-7231` all match), and that value then sits on the board for the rest of the
  session. Use `@wb-ignore` on prompts that merely discuss tickets, and tighten
  `CC_WHITEBOARD_TICKET_RE` if your prompts are full of such tokens.
- **`@wb-ignore` skips the heartbeat too.** It writes nothing at all, so a session
  whose *every* prompt carries the marker can age past the TTL and drop off the
  board. Any normal prompt puts it back.
- **The address is a pointer, not a channel.** The board tells a session where to
  reach another one; delivery is entirely `SendMessage`'s job. If that tool is
  unavailable the row is just informational.
- **Concurrency-safe.** Writes are serialized with a portable `mkdir` lock (no
  `flock` dependency — works on macOS and Linux), so 2–6 sessions won't corrupt the file.

## Changelog

### Unreleased

- **Fix: `/use` handed one resource to two sessions and told both they had it.**
  `board.sh use` called `wb_hold`, which records a hold whoever else already has
  one, and printed `you now hold "<res>"` unconditionally — so the front door
  granted exactly the collision the `PreToolUse` hook refuses to allow. It now
  claims through `wb_hold_exclusive` (check and write in one `jq` under one lock,
  then a re-read) and refuses when another session holds the resource, naming the
  holder, the peer to message and `/force`. Crashed holders are swept first, so a
  phantom row cannot block a claim forever. Re-claiming a resource this session
  already holds stays idempotent and does not refresh `since`.
- The refusal message is now one helper shared by `use` and `free`, so the two
  commands cannot drift into telling a blocked session different things.

### 0.4.3

- **Fix: `/free` reported success without releasing anything.** `wb_unhold`
  deletes from the *caller's* holds, so a session freeing a resource it did not
  hold deleted nothing — while `board.sh free` printed `released "<res>"`
  unconditionally, because nothing checked whether the registry had changed. A
  session ran `/claude-whiteboard:free xcode` twice, was told it worked twice,
  and stayed blocked behind the same hold for 165 minutes. `free` now settles
  its own hold first, then refuses when another session holds the resource,
  naming the holder, the peer to message and `/force`; re-reads the registry
  before claiming a release; and opens the waiters' priority window only after
  a release that actually happened.

### 0.4.2

- **Fix: every marker-based slash command was a silent no-op.** `/use`, `/free`,
  `/force`, `/claim` and `/release` asked the model to emit an `@wb-*` marker and
  left the `UserPromptSubmit` hook to pick it up. The hook receives the text the
  user typed — `/claude-whiteboard:free xcode` — not the expanded command body, so
  the marker was never there to find. Each command reported success and changed
  nothing; a session waited 30 minutes behind a hold its owner believed it had
  released. The commands now call the new `scripts/board.sh` directly, using
  `CLAUDE_CODE_SESSION_ID`, which a Bash tool call does carry and which is the same
  id the hooks get on stdin. Hand-typed `@wb-*` markers keep working unchanged.
- **Fix: scripts run outside a hook read a different, empty registry.**
  `CLAUDE_PLUGIN_DATA` is set for hooks only, so `scripts/status.sh` fell back to
  `~/.claude` and printed `No active sessions` against a live board of eight.
  That made `/free`'s own verification step blind by construction. `lib.sh` now
  finds the plugin data directory by name when the variable is absent, and
  `status.sh` exits non-zero saying so rather than reporting a missing file as an
  empty board.
- **Fix: claim patterns are anchored to command position.** `\bngrok\b` matched a
  `sed` that merely wrote `your-tunnel.ngrok-free.dev` into a config file, taking
  the local-stack hold with nothing running and queueing a second session behind
  it. `\bxcodebuild\b` had the same shape. Both now require the tool to be in
  command position. No shippable generic probe exists for a public plugin — set
  one in `CC_WHITEBOARD_RESOURCES` (e.g. `lsof -nP -iTCP:7925 -sTCP:LISTEN`); the
  `CC_WHITEBOARD_PROBE_GRACE` window added in 0.4.1 already keeps it from evicting
  a stack that is still booting.
- Tests: 223 assertions (lib 65, on-prompt 68, on-pretool 70, board 20).

### 0.4.1

- **Fix: a probe no longer evicts a hold that is still booting.** A claim is recorded at
  `PreToolUse`, *before* the command runs, so a stack that takes minutes to start
  legitimately probes DOWN for that whole window. The probe-DOWN path treated such a hold
  as a phantom and cleared it, letting a second session claim mid-boot — the exact
  collision resource claims exist to prevent. Probe-driven eviction now applies only past
  `CC_WHITEBOARD_PROBE_GRACE` (default 300s).
- The defect was dormant in 0.4.0: every test ran with `probe: ""`, which yields
  *unknown* and never evicts, so the branch only armed itself once a real probe was
  configured. New env var `CC_WHITEBOARD_PROBE_GRACE`.
- Tests: 195 assertions (lib 57, on-prompt 68, on-pretool 70).

### 0.4.0

- **Exclusive resource claims.** Sessions now coordinate shared singletons — the
  local stack, an Xcode/device build, a tunnel — not just tickets and labels. A
  command that would take a resource another live session holds is **blocked by a
  new `PreToolUse` hook** rather than warned about a prompt too late.
- Resource names are **repo-scoped** (`local-stack@<repo>`), keyed on
  `git rev-parse --git-common-dir` so every worktree of a repo shares one key.
- A blocked session is recorded as a **waiter** and handed the holder's
  `SendMessage` address. On release, waiters get a short **priority window**; any
  waiter may claim during it, not only the first. Ownership is never auto-granted.
- **Phantom holds** are resolved at read time by three layers: PID liveness from
  Claude Code's own session registry, an optional per-resource probe, and idle
  soft-expiry. Liveness is three-valued — an unreadable session registry means
  *unknown*, never *dead*, so the lock cannot silently invert.
- New commands `/claude-whiteboard:use`, `:free`, `:force`; board rows gain
  `uses:` and `/claude-whiteboard:status` gains a `RESOURCE` table.
- Five new env vars (see Configuration).
- Tests: **181 assertions** across three suites (lib 54, on-prompt 68,
  on-pretool 59), up from 56 in one.

### 0.3.0

- **Every board row now carries the peer's `SendMessage` address**, so a session
  that finds an overlap can talk to the session that owns it instead of handing
  the problem back to you. `SessionStart` rows gain `peer: <name> (busy|idle)`,
  `⚠ CONFLICT` gains the exact `SendMessage({to: ...})` call for the holder, and
  `/claude-whiteboard:status` gains a `PEER` column.
- The name is joined from Claude Code's own `~/.claude/sessions/*.json` **at
  render time**, keyed on the session id both sides already record. Nothing new
  is stored, so a renamed session cannot go stale on the board.
- Degrades silently everywhere it can't resolve: no session registry, an unnamed
  session, or a half-written session file all render exactly the pre-0.3.0
  output with a clean stderr.
- A mention-only note deliberately stays one line — no address.
- New `CC_WHITEBOARD_SESSIONS_DIR` env var (also what makes the join testable).
- Tests: 56 assertions, up from 46.

### 0.2.2

- **Fix: prompt mentions no longer claim tickets.** Ticket evidence is now ranked
  — worktree/branch name (strong) beats a ticket id sniffed from prompt text
  (weak), and a weak value never overwrites an existing ticket. Previously the
  first ticket-looking token in *any* prompt became the session's ticket, so
  pasting coordination text that mentioned `ETHENAPAYF-1013` tagged that session
  as owning 1013 and buried the session actually in the `ethenapayf-1013-*`
  worktree under `⚠ CONFLICT` warnings on every prompt.
- `⚠ CONFLICT` now fires only when the *other* session's ticket came from a
  worktree. A mention-only holder produces a one-line note instead.
- **Each overlap is announced once**, not on every prompt, for as long as the
  ticket and the holder stay the same.
- Conflict messages now include the holder's directory alongside the branch.
- New `@wb-ignore` marker — a prompt containing it is skipped entirely.
- Sessions record `ticket_src` (`worktree` / `prompt`) in the registry.
- **Worktree ticket detection is no longer hard-coded to one project prefix**; it
  uses `CC_WHITEBOARD_TICKET_RE`, so `jira-12-login-fix` and `feature/ETHEN-447`
  are detected too.
- Fixed: `@wb-ignore` and `@wb-release` were silently ignored on prompts larger
  than the pipe buffer (~64 KiB). `grep -q` exits at the first match, killing the
  upstream `printf` with `SIGPIPE`, and under `pipefail` that turned a match into
  a non-zero status — exactly on the giant pasted dumps the marker exists for.
- Added `tests/on-prompt.test.sh` (bash + jq, 46 assertions, no Claude Code
  restart needed).

### 0.2.1

- Auto-detect the ticket from the worktree dir / branch name when the prompt
  never mentions it.

### 0.2.0

- Keyword label claim for ticketless work (`/claude-whiteboard:claim`).

## Development

```bash
bash tests/on-prompt.test.sh
```

## License

MIT
