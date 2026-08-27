---
description: Release this session's claimed label on the claude-whiteboard so other sessions are no longer warned off it.
disable-model-invocation: true
---

The user is releasing this session's claimed label on the shared whiteboard.

```bash
"${CLAUDE_PLUGIN_ROOT}"/scripts/board.sh release
```

Then tell the user in one line that the label has been released and other
sessions are no longer warned off it. (Ticket ownership, if any, is unaffected.)
