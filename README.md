# claude-whiteboard

A shared **whiteboard** for parallel [Claude Code](https://code.claude.com) sessions.

Run 2–6 sessions on the same repo (typically one per git worktree) and they can't
see each other's context — so two of them may unknowingly pick overlapping tickets
and do the **same work twice**. Git worktrees isolate *files*; they do nothing about
*double-work*. This plugin fixes that with a tiny shared registry.

Each session posts what ticket it's working on to a shared JSON file. Every other
session reads that file at startup and on every prompt, and is **warned before
starting work another session already owns**.

> Not orchestration — no lead, no workers. Just a whiteboard equal peers read and write.

## How it works

| Hook | What it does |
|------|--------------|
| `SessionStart` | Registers this session and injects the list of *other* active sessions into context. |
| `UserPromptSubmit` | Sniffs a ticket id (e.g. `ETHEN-447`) from your prompt, records it as this session's current ticket, and — **only if another live session already holds that ticket** — injects a conflict warning telling the agent to stop and check with you. Silent otherwise. |
| `SessionEnd` | Removes this session and prunes stale (crashed) entries past the TTL. |

```
session A  ──"work on ETHEN-447"──▶  whiteboard: A = ETHEN-447
session B  ──"work on ETHEN-447"──▶  ⚠ warns B: ETHEN-447 already owned by A → stop & confirm
session A  ──"now ETHEN-880"─────▶  whiteboard: A = ETHEN-880   (updated in real time)
```

### Token cost

Effectively **zero in steady state**. Hooks are shell scripts (no model tokens to
run). The only context cost is text a hook injects: a small list once at
`SessionStart`, and a one-line warning **only when a real conflict is detected**.
No conflict → nothing injected.

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
| `CC_WHITEBOARD_TICKET_RE` | `[A-Z][A-Z0-9]+-[0-9]+` | Regex used to detect a ticket id in a prompt. Matches `ETHEN-447`, `JIRA-12`, etc. |
| `CC_WHITEBOARD_TTL` | `14400` (4h) | Entries older than this are treated as stale and pruned (crash safety). |

## Commands

- `/claude-whiteboard:status` — print the current board (active sessions, tickets, branches, last-seen age).

## Notes & limits

- **Pull, not push.** A session learns another moved on at *its own* next prompt or
  restart — at most one turn of lag. Fine for avoiding double-work.
- **Ticket-based.** Detection keys on a ticket id in your prompt. Free-text work
  with no ticket id isn't tracked (mention the ticket once and it's captured).
- **Concurrency-safe.** Writes are serialized with a portable `mkdir` lock (no
  `flock` dependency — works on macOS and Linux), so 2–6 sessions won't corrupt the file.

## License

MIT
