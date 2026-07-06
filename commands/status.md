---
description: Show the claude-whiteboard registry — all active Claude Code sessions and the ticket each is currently working on.
disable-model-invocation: true
---

Run the whiteboard status script and show the user the current board of active sessions.

```bash
"${CLAUDE_PLUGIN_ROOT}"/scripts/status.sh
```

Present the output as a short table (session, ticket, label, branch, age). If the board is empty, say no other sessions are active.
