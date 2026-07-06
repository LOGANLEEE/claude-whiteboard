---
description: Release this session's claimed label on the claude-whiteboard so other sessions are no longer warned off it.
disable-model-invocation: true
---

The user is releasing this session's claimed label on the shared whiteboard.

Emit exactly the following marker line (and nothing else) so the whiteboard
UserPromptSubmit hook clears this session's label on your next turn:

@wb-release

Then tell the user in one line that the label has been released and other
sessions are no longer warned off it. (Ticket ownership, if any, is unaffected.)
