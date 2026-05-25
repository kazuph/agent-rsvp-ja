#!/usr/bin/env node
// Launch the speed reader in its OWN Terminal window.
//
// The reader is a full-screen TUI, so it needs a dedicated terminal with its
// own tty — it can't share the calling process's. This takes text (from a file
// arg or piped stdin), stashes it in a temp file, and opens a new terminal
// window running the reader on it.
//
// Usage:
//   agent-rsvp-launch plan.md
//   agent-rsvp-launch plan.md -w 350
//   echo "some text" | agent-rsvp-launch -w 350

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = import.meta.dirname ?? dirname(fileURLToPath(import.meta.url));
// The reader sits next to this file. When compiled, both are .js (run with
// node); in dev, both are .ts (run with bun). Pick whichever exists.
const readerJs = join(here, "index.js");
const readerTs = join(here, "index.ts");
const reader = existsSync(readerJs) ? readerJs : readerTs;
const runtime = reader.endsWith(".ts") ? "bun" : "node";

// Read all of stdin to a string (used when text is piped in).
async function readStdin(): Promise<string> {
  let data = "";
  process.stdin.setEncoding("utf8");
  for await (const chunk of process.stdin) data += chunk;
  return data;
}

// Split args into an optional input file and pass-through reader flags (-w …).
const argv = process.argv.slice(2);
let inputFile: string | undefined;
const passthrough: string[] = [];
for (let i = 0; i < argv.length; i++) {
  const a = argv[i]!;
  if (a === "-w" || a === "--wpm") {
    passthrough.push(a, argv[++i] ?? "");
  } else if (a.startsWith("-")) {
    passthrough.push(a);
  } else if (!inputFile) {
    inputFile = a;
  }
}

// Resolve the text to read.
let text: string;
if (inputFile) {
  if (!existsSync(inputFile)) {
    console.error(`File not found: ${inputFile}`);
    process.exit(1);
  }
  text = readFileSync(inputFile, "utf8");
} else if (!process.stdin.isTTY) {
  text = await readStdin();
} else {
  console.error("Provide a file argument or pipe text in.");
  process.exit(1);
}

if (!text.trim()) {
  console.error("Nothing to read (empty input).");
  process.exit(1);
}

// Stash in a temp file so the spawned window can read it independently.
const dest = join(tmpdir(), `speed-read-${Date.now()}.md`);
writeFileSync(dest, text);

// Build the command the new window will run. Quote paths for the shell.
const q = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;
const cmd = [runtime, q(reader), q(dest), ...passthrough].join(" ");

if (process.platform === "darwin") {
  // AppleScript string: escape backslashes and double quotes.
  const osa = cmd.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
  spawnSync("osascript", [
    "-e",
    `tell application "Terminal" to do script "${osa}"`,
    "-e",
    `tell application "Terminal" to activate`,
  ]);
  console.log("Opened the speed reader in a new Terminal window.");
} else if (process.platform === "linux" && trySpawnLinuxTerminal(cmd)) {
  console.log("Opened the speed reader in a new terminal window.");
} else {
  // Fallback: print the command to run.
  console.log("Run this in a terminal to start the reader:\n  " + cmd);
}

// Try common Linux terminal emulators; return true if one launched.
function trySpawnLinuxTerminal(command: string): boolean {
  const candidates: Array<[string, string[]]> = [
    ["gnome-terminal", ["--", "bash", "-lc", command]],
    ["konsole", ["-e", "bash", "-lc", command]],
    ["xterm", ["-e", `bash -lc ${q(command)}`]],
  ];
  for (const [bin, bargs] of candidates) {
    const r = spawnSync(bin, bargs, { stdio: "ignore" });
    if (r.error == null) return true;
  }
  return false;
}
