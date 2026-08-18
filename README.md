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
| `SessionEnd` | Removes this session (ticket and label) and prunes stale (crashed) entries past the TTL. |

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

## Commands

- `/claude-whiteboard:status` — print the current board (active sessions, tickets, labels, branches, peer names, last-seen age).
- `/claude-whiteboard:claim <label>` — claim a free-text label for ticketless work so other sessions are warned off it.
- `/claude-whiteboard:release` — drop this session's claimed label.

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
