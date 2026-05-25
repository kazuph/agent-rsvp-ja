#!/usr/bin/env node
// Terminal RSVP (Rapid Serial Visual Presentation) speed reader.
// One word flashes at a time, aligned on its focal letter (the
// "optimal recognition point"), with a live WPM slider.

import { openSync, existsSync, readFileSync } from "node:fs";
import { ReadStream } from "node:tty";

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

// Read all of stdin to a string (used when text is piped in).
async function readStdin(): Promise<string> {
  let data = "";
  process.stdin.setEncoding("utf8");
  for await (const chunk of process.stdin) data += chunk;
  return data;
}

// ---------------------------------------------------------------------------
// ANSI helpers
// ---------------------------------------------------------------------------
const ESC = "\x1b[";
const ansi = {
  clear: `${ESC}2J`,
  home: `${ESC}H`,
  hideCursor: `${ESC}?25l`,
  showCursor: `${ESC}?25h`,
  altScreen: `${ESC}?1049h`,
  mainScreen: `${ESC}?1049l`,
  reset: `${ESC}0m`,
  dim: `${ESC}2m`,
  bold: `${ESC}1m`,
  red: `${ESC}38;5;203m`,
  gray: `${ESC}38;5;240m`,
  green: `${ESC}38;5;78m`,
  moveTo: (row: number, col: number) => `${ESC}${row};${col}H`,
};

const write = (s: string) => process.stdout.write(s);

// ---------------------------------------------------------------------------
// Text input: file argument, piped stdin, or a built-in sample.
// ---------------------------------------------------------------------------
const SAMPLE = `Speed reading is the practice of increasing one's reading speed
without an unacceptable reduction in comprehension. Rapid Serial Visual
Presentation, or RSVP, shows words one at a time in a fixed location so your
eyes never have to move. Because the focal point stays put, your brain spends
its energy recognizing words instead of physically scanning lines of text.
With a little practice, most people can comfortably read well above four
hundred words per minute. Use the left and right arrow keys to change the
speed, the space bar to pause, and watch how your comprehension holds up as
the words begin to blur together.`;

// ---------------------------------------------------------------------------
// CLI args: an optional file positional plus flags (-w/--wpm to set speed).
// ---------------------------------------------------------------------------
function parseArgs(argv: string[]) {
  let file: string | undefined;
  let wpm: number | undefined;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]!;
    if (a === "-w" || a === "--wpm") {
      wpm = Number(argv[++i]);
    } else if (a.startsWith("--wpm=")) {
      wpm = Number(a.slice("--wpm=".length));
    } else if (a.startsWith("-w")) {
      wpm = Number(a.slice(2)); // -w250
    } else if (!a.startsWith("-")) {
      file = a;
    }
  }
  return { file, wpm: Number.isFinite(wpm!) ? wpm : undefined };
}

const args = parseArgs(process.argv.slice(2));

async function loadText(): Promise<string> {
  if (args.file) {
    if (existsSync(args.file)) return readFileSync(args.file, "utf8");
    console.error(`File not found: ${args.file}`);
    process.exit(1);
  }
  if (!process.stdin.isTTY) {
    const piped = await readStdin();
    if (piped.trim()) return piped;
  }
  return SAMPLE;
}

// Flatten Markdown to readable prose: drop code fences, list/quote markers,
// heading hashes, emphasis characters, tables, and HTML; collapse links and
// images to their text. The goal is a clean stream of words for RSVP, so
// markup that would otherwise flash as stray symbols is removed here.
function stripMarkdown(src: string): string {
  return src
    .replace(/```[\s\S]*?```/g, " ")           // fenced code blocks
    .replace(/~~~[\s\S]*?~~~/g, " ")           // fenced code blocks (tildes)
    .replace(/`([^`]*)`/g, "$1")               // inline code
    .replace(/!\[[^\]]*\]\([^)]*\)/g, " ")     // images
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")   // links -> text
    .replace(/<[^>\n]+>/g, " ")                 // HTML tags
    .replace(/^\s{0,3}#{1,6}\s+/gm, "")        // heading hashes
    .replace(/^\s{0,3}>\s?/gm, "")             // blockquote markers
    .replace(/^\s*[-*+]\s+/gm, "")             // bullet markers
    .replace(/^\s*\d+\.\s+/gm, "")             // ordered list markers
    .replace(/^\s*\|?[\s:|-]*-[\s:|-]*\|?\s*$/gm, " ") // table separator rows
    .replace(/\|/g, " ")                        // remaining table cell pipes
    .replace(/~~([^~]+)~~/g, "$1")             // strikethrough
    .replace(/[*_]{1,3}([^*_]+)[*_]{1,3}/g, "$1") // bold/italic
    .replace(/^\s*([-*_])\1{2,}\s*$/gm, " ")   // horizontal rules
    .trim();
}

// Turn flattened text into RSVP tokens. Tokens with no letter or digit (lone
// punctuation like "->", "—", "•") are dropped — they only flash as noise.
function tokenize(text: string): string[] {
  return text
    .split(/\s+/)
    .filter((w) => /[\p{L}\p{N}]/u.test(w));
}

// ---------------------------------------------------------------------------
// Focal letter ("optimal recognition point") — roughly 30% into the word.
// ---------------------------------------------------------------------------
function orpIndex(word: string): number {
  const n = word.length;
  let i: number;
  if (n <= 1) i = 0;
  else if (n <= 5) i = 1;
  else if (n <= 9) i = 2;
  else if (n <= 13) i = 3;
  else i = 4;
  // Don't pin the focal point on a symbol: nudge to the nearest letter/digit.
  if (!/[\p{L}\p{N}]/u.test(word[i] ?? "")) {
    for (let d = 1; d < n; d++) {
      if (/[\p{L}\p{N}]/u.test(word[i + d] ?? "")) return i + d;
      if (i - d >= 0 && /[\p{L}\p{N}]/u.test(word[i - d]!)) return i - d;
    }
  }
  return i;
}

// Words longer than this pause a touch extra; punctuation also adds delay.
function delayMultiplier(word: string): number {
  let m = 1;
  if (/[.!?]$/.test(word)) m += 1.2;
  else if (/[,;:]$/.test(word)) m += 0.6;
  if (word.length > 8) m += 0.3;
  return m;
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
const text = stripMarkdown(await loadText());
const words = tokenize(text);

const MIN_WPM = 100;
const MAX_WPM = 1000;
const WPM_STEP = 25;
let wpm = Math.max(MIN_WPM, Math.min(MAX_WPM, args.wpm ?? 600));

let index = 0;
let paused = false;
let quit = false;
type Mode = "minimal" | "context";
let mode: Mode = "minimal";
let showHud = true;

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------
function termSize() {
  return {
    cols: process.stdout.columns || 80,
    rows: process.stdout.rows || 24,
  };
}

function renderSlider(width: number): string {
  const frac = (wpm - MIN_WPM) / (MAX_WPM - MIN_WPM);
  const pos = Math.round(frac * (width - 1));
  let bar = "";
  for (let i = 0; i < width; i++) {
    bar += i === pos ? `${ansi.green}●${ansi.reset}` : `${ansi.gray}─${ansi.reset}`;
  }
  return bar;
}

// Greedily wrap a list of words into lines no wider than `width`.
function wrapWords(slice: string[], width: number): string[] {
  const lines: string[] = [];
  let line = "";
  for (const w of slice) {
    if (!line.length) line = w;
    else if (line.length + 1 + w.length <= width) line += " " + w;
    else {
      lines.push(line);
      line = w;
    }
  }
  if (line.length) lines.push(line);
  return lines;
}

// Grayscale ramp toward black for the fade effect. `dist` is the line's
// distance from the focal band (1 = nearest); larger fades darker.
function fade(dist: number, text: string): string {
  const level = Math.max(234, 252 - dist * 4); // 256-color grays 234..252
  return `${ESC}38;5;${level}m${text}${ansi.reset}`;
}

// The shared focal band: two guide lines with the current word between them,
// pinned on its focal letter, notches pointing inward at the word.
function renderBand(focalCol: number, midRow: number): string {
  const { cols } = termSize();
  const word = words[index] ?? "";
  const orp = orpIndex(word);
  const before = word.slice(0, orp);
  const focal = word[orp] ?? "";
  const after = word.slice(orp + 1);
  const startCol = focalCol - before.length;

  const lineWidth = Math.min(40, cols - 4);
  const lineStart = focalCol - Math.floor(lineWidth / 2);
  const notchOffset = focalCol - lineStart;
  const pad = " ".repeat(Math.max(0, lineStart - 1));
  const lineWith = (tick: string) =>
    pad +
    `${ansi.gray}${"─".repeat(notchOffset)}${tick}${"─".repeat(Math.max(0, lineWidth - notchOffset - 1))}${ansi.reset}`;

  return (
    ansi.moveTo(midRow - 1, 1) +
    lineWith("┬") +
    ansi.moveTo(midRow, Math.max(1, startCol)) +
    `${ansi.bold}${before}${ansi.red}${focal}${ansi.reset}${ansi.bold}${after}${ansi.reset}` +
    ansi.moveTo(midRow + 1, 1) +
    lineWith("┴")
  );
}

function renderHud(rows: number, cols: number): string {
  const pct = words.length ? Math.round(((index + 1) / words.length) * 100) : 0;
  const status = paused ? `${ansi.red}❚❚ paused${ansi.reset}` : `${ansi.green}▶ playing${ansi.reset}`;
  const sliderWidth = Math.min(30, cols - 20);
  return (
    ansi.moveTo(rows - 2, 3) +
    `${ansi.bold}${wpm}${ansi.reset}${ansi.dim} wpm  ${ansi.reset}` +
    renderSlider(sliderWidth) +
    `  ${status}${ansi.dim}  ·  ${index + 1}/${words.length} (${pct}%)${ansi.reset}` +
    ansi.moveTo(rows - 1, 3) +
    `${ansi.dim}←/→ speed   space pause   ↑↓/hl scrub   m mode   ? hide   r restart   q quit${ansi.reset}`
  );
}

function render() {
  const { cols, rows } = termSize();
  const midRow = Math.floor(rows / 2);
  const focalCol = Math.floor(cols / 2);

  let out = ansi.home + ansi.clear;

  if (mode === "context") {
    const margin = 2;
    const wrapWidth = Math.min(cols - margin * 2, 100);

    // Lines above the band: the text already read, fading upward.
    const topRows = midRow - 2; // rows 1 .. midRow-2
    if (topRows > 0) {
      const prior = wrapWords(words.slice(0, index), wrapWidth).slice(-topRows);
      for (let i = 0; i < prior.length; i++) {
        const row = midRow - 2 - (prior.length - 1 - i); // bottom-aligned above band
        const dist = midRow - 1 - row; // 1 nearest the band
        out += ansi.moveTo(row, margin + 1) + fade(dist, prior[i]!);
      }
    }

    // Lines below the band: upcoming text, fading downward.
    const bottomStart = midRow + 2;
    const bottomRows = rows - 3 - bottomStart + 1; // leave last 2 rows for HUD
    if (bottomRows > 0) {
      const upcoming = wrapWords(words.slice(index + 1), wrapWidth).slice(0, bottomRows);
      for (let i = 0; i < upcoming.length; i++) {
        const row = bottomStart + i;
        const dist = i + 1; // 1 nearest the band
        out += ansi.moveTo(row, margin + 1) + fade(dist, upcoming[i]!);
      }
    }
  }

  out += renderBand(focalCol, midRow);
  if (showHud) out += renderHud(rows, cols);
  write(out);
}

// ---------------------------------------------------------------------------
// Playback loop — recomputes delay each tick so WPM changes apply live.
// ---------------------------------------------------------------------------
async function loop() {
  while (!quit) {
    render();
    if (paused || index >= words.length) {
      await sleep(60);
      if (index >= words.length) paused = true;
      continue;
    }
    const base = 60000 / wpm;
    const delay = base * delayMultiplier(words[index]!);
    await sleep(delay);
    if (!paused && index < words.length) index++;
  }
}

// ---------------------------------------------------------------------------
// Input handling (raw mode)
// ---------------------------------------------------------------------------
function clampWpm(v: number) {
  wpm = Math.max(MIN_WPM, Math.min(MAX_WPM, v));
}

// Keyboard source. When stdin is a TTY we read it directly; when text was
// piped in (`cat file | cmd`), stdin is the pipe, so we reopen the controlling
// terminal at /dev/tty to keep the keyboard controls working.
let keyInput: NodeJS.ReadStream | ReadStream = process.stdin;
let ttyFd: number | undefined;

function setup() {
  write(ansi.altScreen + ansi.hideCursor + ansi.clear);
  if (!process.stdin.isTTY) {
    try {
      ttyFd = openSync("/dev/tty", "r");
      keyInput = new ReadStream(ttyFd);
    } catch {
      keyInput = process.stdin; // no controlling terminal; controls disabled
    }
  }
  if (keyInput.isTTY) keyInput.setRawMode(true);
  keyInput.resume();
  keyInput.on("data", onKey);
}

function teardown() {
  quit = true;
  if (keyInput.isTTY) keyInput.setRawMode(false);
  write(ansi.showCursor + ansi.mainScreen);
  keyInput.pause();
  process.exit(0);
}

function onKey(buf: Buffer) {
  const k = buf.toString();
  switch (k) {
    case "q":
    case "\x03": // Ctrl-C
      teardown();
      break;
    case " ":
      paused = !paused;
      if (index >= words.length) {
        index = 0;
        paused = false;
      }
      break;
    case "r":
      index = 0;
      paused = false;
      break;
    case "m":
    case "\t":
      mode = mode === "context" ? "minimal" : "context";
      break;
    case "?":
      showHud = !showHud;
      break;
    case "\x1b[C": // right arrow
      clampWpm(wpm + WPM_STEP);
      break;
    case "\x1b[D": // left arrow
      clampWpm(wpm - WPM_STEP);
      break;
    case "\x1b[A": // up arrow — scrub forward
    case "l":
      index = Math.min(words.length - 1, index + 1);
      break;
    case "\x1b[B": // down arrow — scrub back
    case "h":
      index = Math.max(0, index - 1);
      break;
  }
}

process.on("SIGINT", teardown);
process.on("exit", () => write(ansi.showCursor + ansi.mainScreen));
process.stdout.on("resize", render);

setup();
await loop();
