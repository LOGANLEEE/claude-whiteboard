---
description: Release a shared resource this session holds on the claude-whiteboard, and give waiting sessions a head start on it.
disable-model-invocation: true
argument-hint: <resource>
---

The user is releasing the shared resource **$ARGUMENTS**.

Run this. It releases the hold and then prints the board:

```bash
"${CLAUDE_PLUGIN_ROOT}"/scripts/board.sh free "$ARGUMENTS"
"${CLAUDE_PLUGIN_ROOT}"/scripts/status.sh
```

Then tell the user, in one line, whether any session was waiting on it. If one
was, say that those sessions now have a short head start over anyone who never
waited, and that they can be told directly with `SendMessage` using the peer
name in the board's `WAITING` column.
