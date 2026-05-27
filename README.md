# agent-rsvp-ja

A Japanese-focused fork of `agent-rsvp`, a native RSVP (Rapid Serial Visual
Presentation) speed reader. Display chunks flash between two guide lines, pinned
on their center-right focal character, with a live words-per-minute slider.

This JA edition keeps the CLI shape of the original project while adding a tiny
Zig/AppKit native window, Japanese chunk tuning, Aozora Bunko title lookup, and
fixed-position focus-character rendering.

## Install

Runs on **Node ≥ 20.11**. The published CLI launches a Zig-built native macOS
window instead of opening Terminal.

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
agent-rsvp 坊っちゃん           # fetch and read the title from Aozora Bunko
agent-rsvp sample.md -w 450     # start at 450 wpm
agent-rsvp -t sample.md         # print display chunks, one per line
agent-rsvp --test-layout sample.md # print chunks with focus markers
cat tea.txt | agent-rsvp -w 250 # read piped stdin at 250 wpm
agent-rsvp -o                   # open a native window and choose a file
```

`-w` / `--wpm` sets the starting speed. Piped input works with `--open` by
stashing the text in a temporary file and launching the native window detached.

`-o` / `--open` opens the reader in its own native window without launching
Terminal:

```bash
agent-rsvp -o sample.md -w 350   # from a file
pbpaste | agent-rsvp -o -w 350   # from the clipboard / stdin
```

## Aozora Bunko

If the positional argument is not a local file, `agent-rsvp` looks it up as an
Aozora Bunko title using the official UTF-8 work index. The index is cached for
seven days and fetched works are cached as cleaned UTF-8 text.

```bash
agent-rsvp 坊っちゃん
agent-rsvp 吾輩は猫である
agent-rsvp セロ弾きのゴーシュ
agent-rsvp -t 坊っちゃん             # inspect the generated chunks
agent-rsvp --aozora-refresh 坊っちゃん # refresh the cached index/text
```

Ruby annotations, Aozora input notes, and standalone chapter-number lines are
removed before chunking.

## Modes

- **minimal** (default): only the active chunk lines are shown between the guide
  lines.
- **context**: already-read text appears above the guide lines, and upcoming
  text appears below them.

Press `m` or `Tab` to switch.

## Use inside Claude Code

This package also ships a Claude Code plugin with a `/rsvp` slash command. Once
installed, run `/rsvp` to speed-read the plan Claude most recently presented (or
a file/text you name) in a native window.

Under the hood `/rsvp` calls the CLI with `--open`:

```bash
npx -y agent-rsvp -o plan.md -w 350      # from a file
pbpaste | npx -y agent-rsvp -o -w 350    # from the clipboard / stdin
```

## Controls

| Key            | Action               |
| -------------- | -------------------- |
| `h` / `l` or `←` / `→` | decrease / increase speed (25 wpm) |
| `j` / `k`      | decrease / increase visible lines (starts at 1) |
| `m` / `Tab`    | toggle minimal / context mode |
| `Cmd-` / `Cmd+` | decrease / increase font size |
| `Cmd0`         | reset font size |
| `o` / `Cmd-O`  | open a file |
| `f`            | toggle fullscreen |
| `space`        | pause / resume       |
| `?`            | hide / show the HUD (distraction-free) |
| `r`            | restart from the beginning |
| `q` / `Esc`    | quit                 |

## Development

```bash
bun install
bun run dev -- sample.md    # run Zig/AppKit source
bun run build               # compile native app and Node launcher to dist/
```

Built with Zig, AppKit, macOS NaturalLanguage, and a small Node launcher for npm
compatibility.
