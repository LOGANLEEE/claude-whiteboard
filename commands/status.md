---
description: Show the claude-whiteboard registry — all active Claude Code sessions and the ticket each is currently working on.
disable-model-invocation: true
---

Run the whiteboard status script and show the user the current board of active sessions.

```bash
"${CLAUDE_PLUGIN_ROOT}"/scripts/status.sh
```

Present the output as a short table (session, ticket, label, branch, peer, age). If the board is empty, say no other sessions are active.

The `PEER` column is that session's `SendMessage` address: a row showing `1276` can be
reached with `SendMessage({to: "1276", message: "..."})`. Mention this only if the user
asks how to contact one, or if a row overlaps the work this session is doing. A `-`
means Claude Code has not named that session, so it cannot be messaged by name.
