---
name: rsvp
description: Open the terminal speed reader (RSVP) on the most recent plan, or on text/a file the user names. Use when the user wants to "speed read the plan", "RSVP this", or read some text with the speed reader in a new window.
---

# Speed-read a plan

Launch the RSVP speed reader in a **new Terminal window** on some text — by
default the plan you most recently presented.

## Steps

1. Decide what text to read:
   - If `$ARGUMENTS` names a file path, use that file directly (skip to step 3).
   - If `$ARGUMENTS` is other text, treat that as the content to read.
   - Otherwise, use the **most recent plan you presented** in this conversation
     (the markdown body from your last ExitPlanMode / plan). Use it verbatim.

2. Write the chosen text to a temp markdown file, e.g.
   `/tmp/speed-read-plan-$(date +%s).md`, using the Write tool.

3. Launch the reader on it:

   ```bash
   npx -y agent-rsvp -o <file> -w 350
   ```

   `agent-rsvp -o` opens the reader in its own Terminal window (a TUI needs
   its own tty). Pass `-w <wpm>` to set the starting speed; default to 350 if
   the user hasn't asked for a speed. `npx` fetches the package on demand, so no
   prior install is required (it also uses a global install if present).

4. Tell the user it opened in a new window and remind them of the keys:
   `←/→` speed, `space` pause, `m` mode, `q` quit.

## Notes

- Don't try to run the reader inline in the agent's terminal — it's a
  full-screen TUI and needs the separate window the launcher provides.
- If the launcher prints a fallback command (non-macOS/Linux), relay it to the
  user so they can run it themselves.
