---
description: Claim a free-text label on the claude-whiteboard so other parallel sessions are warned before doing the same ticketless work.
disable-model-invocation: true
argument-hint: <label>
---

The user is claiming the label **$ARGUMENTS** on the shared whiteboard so other
parallel Claude Code sessions know this session owns that work.

```bash
"${CLAUDE_PLUGIN_ROOT}"/scripts/board.sh claim "$ARGUMENTS"
```

Then tell the user in one line that the label "$ARGUMENTS" is now claimed on the
whiteboard, and that another session claiming the same label will be warned.
Release it later with `/claude-whiteboard:release` (it also clears at session end).
