---
description: Claim a shared resource (local stack, Xcode build, tunnel) on the claude-whiteboard so other parallel sessions are blocked from taking it.
disable-model-invocation: true
argument-hint: <resource>
---

The user is claiming the shared resource **$ARGUMENTS** on the whiteboard.

Use this for a resource no Bash command can be matched against — most importantly
a GUI Xcode build, which executes no command this plugin can see. Resources that
*are* driven by a command (`docker compose up`, `ngrok`, `xcodebuild`) are claimed
automatically and need no `/use`.

Emit exactly the following marker line (and nothing else) so the whiteboard
UserPromptSubmit hook records the claim:

@wb-use: $ARGUMENTS

Then tell the user in one line that "$ARGUMENTS" is claimed **for this repo**
(claims are scoped per repo, so another project's resource of the same name is
untouched), that another session running a matching command will now be blocked
and queued behind them, and that `/claude-whiteboard:free $ARGUMENTS` releases it
— session end releases it too.
