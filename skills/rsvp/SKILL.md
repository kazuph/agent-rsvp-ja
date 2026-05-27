---
name: rsvp
description: Open the native speed reader (RSVP) on the most recent plan, or on text/a file the user names. Use when the user wants to "speed read the plan", "RSVP this", or read some text with the speed reader in a new window.
---

# Speed-read a plan

Launch the RSVP speed reader in a native window on some text — by
default the plan you most recently presented.

## Steps

1. Decide what text to read:
   - If `$ARGUMENTS` names a file path, use that file directly (skip to step 3).
   - If `$ARGUMENTS` is other text, treat that as the content to read.
   - If there is no text/file, launch `agent-rsvp -o` so the user can choose a file.
   - Otherwise, use the **most recent plan you presented** in this conversation
     (the markdown body from your last ExitPlanMode / plan). Use it verbatim.

2. Write the chosen text to a temp markdown file, e.g.
   `/tmp/speed-read-plan-$(date +%s).md`, using the Write tool.

3. Launch the reader on it:

   ```bash
   agent-rsvp -o <file> -w 350
   ```

   `agent-rsvp -o` opens the reader in its own native window without Terminal.
   Pass `-w <wpm>` to set the starting speed; default to 350 if
   the user hasn't asked for a speed. This command expects the local
   `agent-rsvp-ja` fork to be installed or linked first.

   Use `agent-rsvp -t <file>` only when inspecting chunk boundaries; it prints
   the display chunks one per line and does not open a window.
   Use `agent-rsvp --test-layout <file>` when inspecting where the red focus
   character will appear.

4. Tell the user it opened in a new window and remind them of the keys:
   `o` open file, `f` fullscreen, `h/l` speed, `j/k` visible lines (starts at 1), `m`/`Tab` mode, `Cmd-/Cmd+` font, `space` pause, `q` quit.

## Notes

- Don't use macOS Terminal or osascript for `/rsvp`; `agent-rsvp -o` detaches a
  native window process directly.
