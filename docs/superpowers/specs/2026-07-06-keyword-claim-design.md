# claude-whiteboard: keyword claim

## Goal

Coordinate ticketless work between parallel Claude Code sessions. Today the
plugin only detects a ticket id (`ETHEN-447`) sniffed from the prompt. Add an
explicit way to claim a free-text label so sessions doing ticketless work still
warn each other before double-work. Ticket detection stays unchanged.

## Non-goals

- Automatic free-text keyword sniffing. Rejected: noisy, produces false
  conflicts that erode trust in the warning. A warning must always mean a real
  overlap.
- Fuzzy label matching. Labels match exact (case-insensitive, trimmed), same
  reliability contract as ticket ids.

## Mechanism

A session claims a label by emitting a marker line into its prompt. The existing
`on-prompt.sh` hook — which already runs every prompt and already has
`session_id` and registry write access — sniffs the marker alongside the ticket.

Markers:
- `@wb-claim: <label>` — set this session's label to `<label>`
- `@wb-release` — clear this session's label

Why marker-in-prompt and not a standalone script invoked by the slash command:
only the hook receives `session_id` on stdin. A script run from a command body
cannot identify which session invoked it, so it could not write the correct
registry entry.

The slash commands are thin wrappers that emit the marker line so the hook
captures it.

## Registry shape

Add a `label` field alongside `ticket`:

```json
{
  "sessions": {
    "<sid>": {
      "ticket": "ETHEN-447",
      "label": "auth refactor",
      "branch": "feature/x",
      "cwd": "/path",
      "started": 1000,
      "updated": 1234
    }
  }
}
```

`label` is `null` when unset. SessionEnd already deletes the whole session entry,
so the label is cleared on exit with no extra code.

## Conflict check

Two independent keys, each checked in `on-prompt.sh`:

1. ticket match (existing) → warn
2. label match — case-insensitive, trimmed, exact — against any OTHER fresh
   session's label → warn

Either match emits the conflict message. Both silent when no overlap. Zero
steady-state token cost preserved: no marker and no match → nothing injected.

## Marker parsing rules

- `@wb-claim:` — everything after the colon on that line, trimmed. Empty label
  after trim → ignored (no-op).
- `@wb-release` — clears label; takes precedence if both markers appear.
- A prompt may carry a ticket AND a claim; both are recorded.
- Markers are read from the prompt; the hook does not modify the prompt text.

## Files touched

1. `scripts/on-prompt.sh` — sniff `@wb-claim:` / `@wb-release`; record label;
   add label conflict check next to the ticket check.
2. `scripts/on-session-start.sh` — include label in the "other sessions" list.
3. `scripts/status.sh` — add a LABEL column.
4. `commands/claim.md` — new. Emits `@wb-claim: <args>`.
5. `commands/release.md` — new. Emits `@wb-release`.
6. `commands/status.md` — mention label in the presented table.
7. `README.md` — document claim/release and the label field.

## Testing

- Claim then a second session claims same label (diff case/spacing) → warning.
- Claim label A, other session on label B → silent.
- `@wb-release` → label gone from registry, no more conflict.
- No marker, no ticket → hook silent, registry only heartbeat-updated.
- `jq` absent → whole plugin no-ops (existing guard).
- `claude plugin validate .` clean after new command files.
