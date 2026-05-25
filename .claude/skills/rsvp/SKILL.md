---
name: rsvp
description: Open the terminal speed reader (RSVP) on the most recent plan, or on text/a file the user names. Use when the user wants to "speed read the plan", "RSVP this", or read some text with the speed reader in a new window. This helps the user understand important information in long write-ups.
argument-hint: "[file path | wpm flag, e.g. -w 500]"
allowed-tools: Bash(npx:*)
model: haiku
effort: low
---

# Speed-read in a new window

The launcher below runs immediately via the `!` inline-bash syntax, so when a
file is given it opens the reader without any extra round-trips:

!`if [ -n "$ARGUMENTS" ]; then npx -y agent-rsvp-launch $ARGUMENTS; else echo "NO_ARGS — no file given, use the recent plan"; fi`

## What to do next

- **If the launcher opened a window above** (a file/args were given): just tell
  the user it opened in a new window and remind them of the keys —
  `←/→` speed, `space` pause, `m` mode, `q` quit. You're done.

- **If it printed `NO_ARGS`**: no file was given, so speed-read the plan. Take
  the **most recent plan you presented** in this conversation (the markdown
  body from your last ExitPlanMode), write it verbatim to
  `/tmp/rsvp-plan-$(date +%s).md` with the Write tool, then launch it:

  ```bash
  npx -y agent-rsvp-launch <that-file>
  ```

  Then share the controls as above.

## Notes

- The reader is a full-screen TUI, so the launcher opens it in its own Terminal
  window — never try to run it inline in Claude Code's terminal.
- Default speed is 600 wpm; pass `-w <wpm>` in the arguments to change it.
- If the launcher prints a fallback command (non-macOS), relay it to the user.
