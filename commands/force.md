---
description: Take a shared resource from another session on the claude-whiteboard. Only for a holder you have already verified is gone.
disable-model-invocation: true
argument-hint: <resource>
---

The user is forcing the claim of **$ARGUMENTS**, taking it from whichever session
currently holds it.

This is an override, not a normal path. The whiteboard already reclaims a
resource by itself when the holder's process is gone, and already lets anyone take
a hold whose session has been idle past the threshold with no probe to prove the
resource is still up. Forcing is for the remaining case: the holder's process is
alive but the resource is not actually in use.

First run the status script below and tell the user, in one line, who currently
holds it. **If a live session holds it, say so and ask them to confirm** — taking
a resource out from under a running stack breaks that session's work, and the
board will not warn that session until its next prompt.

```bash
"${CLAUDE_PLUGIN_ROOT}"/scripts/status.sh
```

On confirmation, emit exactly this marker line and nothing else:

@wb-force: $ARGUMENTS
