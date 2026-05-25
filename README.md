# agent-rsvp

A terminal RSVP (Rapid Serial Visual Presentation) speed reader. Words flash
one at a time, pinned on their focal letter between two guide lines, with a
live words-per-minute slider.

## Install

Runs on **Node ≥ 20.11** (Bun is only needed for development).

```bash
# one-off, no install
npx agent-rsvp sample.md
npx agent-rsvp -w 450 sample.md

# or install globally
npm i -g agent-rsvp
agent-rsvp sample.md
```

```bash
agent-rsvp                      # built-in sample text
agent-rsvp sample.md            # read a file (Markdown/docs flattened to prose)
agent-rsvp sample.md -w 450     # start at 450 wpm
cat tea.txt | agent-rsvp -w 250 # read piped stdin at 250 wpm
```

`-w` / `--wpm` sets the starting speed. Piped input stays fully interactive —
the keyboard controls read from the controlling terminal (`/dev/tty`).

`-o` / `--open` opens the reader in its own new Terminal window instead of
running inline (handy when launching from a context that doesn't own a tty):

```bash
agent-rsvp -o sample.md -w 350   # from a file
pbpaste | agent-rsvp -o -w 350   # from the clipboard / stdin
```

## Modes

- **minimal** (default): just the single focal word between the guide lines.
- **context**: the full passage flows around the focal band, with the
  already-read text above and upcoming text below fading to black at the edges.

Press `m` (or `tab`) to switch.

## Use inside Claude Code

This package also ships a Claude Code plugin with a `/rsvp` slash command. Once
installed, run `/rsvp` to speed-read the plan Claude most recently presented (or
a file/text you name) in a **new Terminal window** (the reader is a full-screen
TUI, so it needs its own tty).

Under the hood `/rsvp` calls the CLI with `--open`:

```bash
npx -y agent-rsvp -o plan.md -w 350      # from a file
pbpaste | npx -y agent-rsvp -o -w 350    # from the clipboard / stdin
```

## Controls

| Key            | Action               |
| -------------- | -------------------- |
| `←` / `→`      | decrease / increase speed (25 wpm) |
| `space`        | pause / resume       |
| `↑`/`↓` or `l`/`h` | scrub forward / back one word |
| `m` / `tab`    | toggle context / minimal mode |
| `?`            | hide / show the HUD (distraction-free) |
| `r`            | restart from the beginning |
| `q` / `Ctrl-C` | quit                 |

## Development

```bash
bun install
bun run dev sample.md       # run from source
bun run build               # compile to dist/ (node-ready, with shebangs)
```

Built with [Bun](https://bun.com).
