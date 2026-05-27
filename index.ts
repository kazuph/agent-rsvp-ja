#!/usr/bin/env node
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { spawn, spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { homedir, tmpdir } from "node:os";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const packagedBinary = join(here, "agent-rsvp-native");
const devBinary = join(here, "zig-out", "bin", "agent-rsvp-native");
const binary = existsSync(packagedBinary) ? packagedBinary : devBinary;
const args = process.argv.slice(2);
const test = args.includes("-t") || args.includes("--test");
const open = !test && (args.includes("-o") || args.includes("--open"));
const aozoraRefresh = args.includes("--aozora-refresh");
const aozoraIndexUrl = "https://www.aozora.gr.jp/index_pages/list_person_all_extended_utf8.zip";
const cacheDir = join(homedir(), "Library", "Caches", "agent-rsvp");
const aozoraIndexCsv = join(cacheDir, "list_person_all_extended_utf8.csv");
const aozoraTextCacheVersion = "v5";

if (args.includes("-h") || args.includes("--help")) {
  console.log(`agent-rsvp

Usage:
  agent-rsvp [file] [-w 350]
  agent-rsvp 坊っちゃん [-w 350]
  agent-rsvp -o [file] [-w 350]
  cat article.md | agent-rsvp -o -w 350

Options:
  -o, --open      Launch a detached native window
  -w, --wpm N    Starting speed
  -t, --test      Print the display chunks, one per line
  --test-layout   Print chunks with the highlighted focus character
  --dump-text     Print the readable text and exit
  --aozora-refresh Refresh the cached Aozora Bunko index
  -h, --help     Show this help

Keys:
  o / Cmd-O      Open file
  f              Toggle fullscreen
  h / l          Slower / faster
  j / k          Fewer / more visible lines
  m / Tab        Toggle minimal / context mode
  Cmd- / Cmd+    Smaller / larger font
  space          Pause / resume
  r              Restart
  q / Esc        Quit`);
  process.exit(0);
}

async function readStdin(): Promise<string> {
  let data = "";
  process.stdin.setEncoding("utf8");
  for await (const chunk of process.stdin) data += chunk;
  return data;
}

function withoutOpenFlag(argv: string[]) {
  return argv.filter((arg) => arg !== "-o" && arg !== "--open");
}

function withoutWrapperFlags(argv: string[]) {
  return argv.filter((arg) => arg !== "--aozora-refresh");
}

function positionalFile(argv: string[]) {
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]!;
    if (arg === "-w" || arg === "--wpm") {
      i++;
      continue;
    }
    if (!arg.startsWith("-")) return arg;
  }
  return undefined;
}

function resolveInputFile(file: string) {
  if (existsSync(file)) return file;
  for (const candidate of [join("_posts", file), join("_posts", "zenn", file)]) {
    if (existsSync(candidate)) return candidate;
  }
  return file;
}

function cacheReady(path: string, maxAgeMs: number) {
  if (!existsSync(path)) return false;
  if (aozoraRefresh) return false;
  return Date.now() - statSync(path).mtimeMs < maxAgeMs;
}

async function download(url: string) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`HTTP ${response.status} while fetching ${url}`);
  return Buffer.from(await response.arrayBuffer());
}

async function cachedAozoraIndex() {
  mkdirSync(cacheDir, { recursive: true });
  if (cacheReady(aozoraIndexCsv, 1000 * 60 * 60 * 24 * 7)) {
    return readFileSync(aozoraIndexCsv, "utf8").replace(/^\uFEFF/, "");
  }

  const zipPath = join(cacheDir, "list_person_all_extended_utf8.zip");
  writeFileSync(zipPath, await download(aozoraIndexUrl));
  const unzip = spawnSync("unzip", ["-p", zipPath], { maxBuffer: 64 * 1024 * 1024 });
  if (unzip.status !== 0) {
    throw new Error(`Could not unzip the Aozora Bunko index: ${unzip.stderr.toString().trim()}`);
  }
  const csv = unzip.stdout.toString("utf8").replace(/^\uFEFF/, "");
  writeFileSync(aozoraIndexCsv, csv);
  return csv;
}

function parseCsv(text: string) {
  const rows: string[][] = [];
  let row: string[] = [];
  let cell = "";
  let quoted = false;

  for (let i = 0; i < text.length; i++) {
    const c = text[i]!;
    if (quoted) {
      if (c === '"' && text[i + 1] === '"') {
        cell += '"';
        i++;
      } else if (c === '"') {
        quoted = false;
      } else {
        cell += c;
      }
      continue;
    }

    if (c === '"') quoted = true;
    else if (c === ",") {
      row.push(cell);
      cell = "";
    } else if (c === "\n") {
      row.push(cell.replace(/\r$/, ""));
      rows.push(row);
      row = [];
      cell = "";
    } else {
      cell += c;
    }
  }
  if (cell || row.length) {
    row.push(cell);
    rows.push(row);
  }
  return rows;
}

function normalizeTitle(title: string) {
  const aliases = new Map([
    ["ぼっちゃん", "坊っちゃん"],
    ["坊ちゃん", "坊っちゃん"],
    ["吾輩は猫", "吾輩は猫である"],
    ["猫", "吾輩は猫である"],
    ["ゴーシュ", "セロ弾きのゴーシュ"],
    ["セロひきのゴーシュ", "セロ弾きのゴーシュ"],
    ["ジュゲム", "寿限無"],
    ["じゅげむ", "寿限無"],
  ]);
  const compact = title.normalize("NFKC").replace(/[\s　「」『』"'`]/g, "");
  return aliases.get(compact) ?? compact;
}

type AozoraWork = {
  id: string;
  title: string;
  author: string;
  textUrl: string;
  encoding: string;
  kana: string;
  cardUrl: string;
  orthography: string;
};

async function findAozoraWork(rawTitle: string): Promise<AozoraWork | undefined> {
  const title = normalizeTitle(rawTitle);
  const rows = parseCsv(await cachedAozoraIndex());
  const header = rows.shift() ?? [];
  const at = (name: string) => header.indexOf(name);
  const idx = {
    id: at("作品ID"),
    title: at("作品名"),
    kana: at("作品名読み"),
    family: at("姓"),
    given: at("名"),
    textUrl: at("テキストファイルURL"),
    encoding: at("テキストファイル符号化方式"),
    cardUrl: at("図書カードURL"),
    orthography: at("文字遣い種別"),
  };

  const works = rows
    .map((row) => ({
      id: row[idx.id] ?? "",
      title: row[idx.title] ?? "",
      author: `${row[idx.family] ?? ""} ${row[idx.given] ?? ""}`.trim(),
      textUrl: row[idx.textUrl] ?? "",
      encoding: row[idx.encoding] ?? "ShiftJIS",
      kana: row[idx.kana] ?? "",
      cardUrl: row[idx.cardUrl] ?? "",
      orthography: row[idx.orthography] ?? "",
    }))
    .filter((work) => normalizeTitle(work.title) === title && /^https:\/\/www\.aozora\.gr\.jp\/.+\.zip$/i.test(work.textUrl));

  works.sort((a, b) => {
    const modern = (work: AozoraWork) => (work.orthography === "新字新仮名" ? 0 : 1);
    return modern(a) - modern(b) || a.title.localeCompare(b.title, "ja");
  });
  return works[0];
}

function decodeAozora(buffer: Buffer, encoding: string) {
  const label = /utf-?8/i.test(encoding) ? "utf-8" : "shift_jis";
  return new TextDecoder(label).decode(buffer);
}

function stripAozoraText(text: string) {
  let out = text.replace(/^\uFEFF/, "").replace(/\r\n?/g, "\n");
  const sep = "-------------------------------------------------------";
  const firstSep = out.indexOf(sep);
  const secondSep = firstSep >= 0 ? out.indexOf(sep, firstSep + sep.length) : -1;
  if (secondSep >= 0) out = out.slice(secondSep + sep.length);

  const bottom = out.search(/\n底本：|\n入力：|\n校正：/);
  if (bottom >= 0) out = out.slice(0, bottom);

  out = out
    .replace(/\n\s*[一二三四五六七八九十百千]+\s*\n/g, "\n")
    .replace(/｜([^《\n]+?)《[^》]+》/g, "$1")
    .replace(/([一-龠々〆ヶぁ-んァ-ヶー]+)《[^》]+》/g, "$1")
    .replace(/［＃[^］]*］/g, "")
    .replace(/｜/g, "")
    .replace(/\n\s*[一二三四五六七八九十百千]+\s*\n/g, "\n")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
  return out;
}

function compactHeading(text: string) {
  return text.normalize("NFKC").replace(/[\s　「」『』"'`]/g, "");
}

function dropLeadingAozoraHeading(body: string, work: AozoraWork) {
  const lines = body.split("\n");
  const title = normalizeTitle(work.title);
  const author = compactHeading(work.author);
  while (lines.length > 0 && !lines[0]!.trim()) lines.shift();
  if (lines.length > 0 && normalizeTitle(lines[0]!.trim()) === title) lines.shift();
  while (lines.length > 0 && !lines[0]!.trim()) lines.shift();
  if (author && lines.length > 0 && compactHeading(lines[0]!.trim()) === author) lines.shift();
  return lines.join("\n").trim();
}

async function materializeAozoraWork(work: AozoraWork) {
  mkdirSync(cacheDir, { recursive: true });
  const safeTitle = work.title.replace(/[^\p{Letter}\p{Number}ぁ-んァ-ヶー一-龠々〆ヶ]+/gu, "_");
  const textPath = join(cacheDir, `aozora-${aozoraTextCacheVersion}-${work.id}-${safeTitle}.txt`);
  if (cacheReady(textPath, 1000 * 60 * 60 * 24 * 30)) return textPath;

  const zipPath = join(cacheDir, `aozora-${work.id}.zip`);
  writeFileSync(zipPath, await download(work.textUrl));
  const unzip = spawnSync("unzip", ["-p", zipPath], { maxBuffer: 32 * 1024 * 1024 });
  if (unzip.status !== 0) {
    throw new Error(`Could not unzip ${work.title}: ${unzip.stderr.toString().trim()}`);
  }

  const source = decodeAozora(unzip.stdout, work.encoding);
  const body = dropLeadingAozoraHeading(stripAozoraText(source), work);
  const cleaned = [
    `${work.title}`,
    work.author ? `${work.author}` : "",
    "",
    body,
    "",
    `出典: ${work.cardUrl}`,
  ].join("\n");
  writeFileSync(textPath, cleaned, "utf8");
  return textPath;
}

async function resolveInputArg(input: string) {
  const file = resolveInputFile(input);
  if (existsSync(file)) return file;

  const work = await findAozoraWork(input);
  if (!work) {
    throw new Error(`File or Aozora Bunko title not found: ${input}`);
  }
  return await materializeAozoraWork(work);
}

async function resolveArgs(argv: string[]) {
  const childArgs = withoutWrapperFlags(argv);
  const file = positionalFile(childArgs);
  if (!file) return childArgs;
  const resolved = await resolveInputArg(file);
  childArgs[childArgs.indexOf(file)] = resolved;
  return childArgs;
}

if (open) {
  const childArgs = withoutOpenFlag(withoutWrapperFlags(args));
  if (!process.stdin.isTTY) {
    const text = await readStdin();
    if (text.trim()) {
      const file = join(tmpdir(), `speed-read-${Date.now()}.md`);
      writeFileSync(file, text);
      const existing = positionalFile(childArgs);
      if (existing) childArgs[childArgs.indexOf(existing)] = file;
      else childArgs.push(file);
    }
  } else {
    const file = positionalFile(childArgs);
    const resolved = file ? await resolveInputArg(file) : undefined;
    if (file && !resolved) {
      console.error(`File or Aozora Bunko title not found: ${file}`);
      process.exit(1);
    }
    if (file && resolved) {
      readFileSync(resolved);
      childArgs[childArgs.indexOf(file)] = resolved;
    }
  }

  const child = spawn(binary, childArgs, {
    detached: true,
    stdio: "ignore",
  });
  child.unref();
  console.log("Opened the speed reader in a native window.");
  process.exit(0);
}

let childArgs: string[];
try {
  childArgs = await resolveArgs(args);
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}

const result = spawnSync(binary, childArgs, { stdio: "inherit" });

if (result.error) {
  console.error(`Failed to launch native agent-rsvp binary: ${result.error.message}`);
  process.exit(1);
}

process.exit(result.status ?? 0);
