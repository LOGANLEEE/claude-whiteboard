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
was waiting on it. If one was, say that those sessions now have a short head
start over anyone who never waited, and that they can be told directly with
`SendMessage` using the peer name in the board's `WAITING` column.

```bash
"${CLAUDE_PLUGIN_ROOT}"/scripts/status.sh
```
