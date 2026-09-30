// Pre-compiles every runnable ```fun code block across the docs into a
// real WebAssembly module at build time, so the site's own Run button can
// execute these specific examples with no backend at all (works on
// static hosting like GitHub Pages) - the interactive playground for
// arbitrary, freshly-typed code still needs a live backend, that's a
// separate, later piece of work.
//
// Output is content-addressed: each block's own raw text (exactly what
// `RunCodeBlock`'s `initialCode` prop receives) is hashed, and the wasm
// module lands at `public/wasm/<hash>.js`/`<hash>.wasm`. The frontend
// computes the same hash from the code it already has in hand and looks
// for a matching file - no extra plumbing needed through content.json.
import { fileURLToPath } from "node:url";
import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import crypto from "node:crypto";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { samples } from "./playground-samples.mjs";

const execFileAsync = promisify(execFile);

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, "../../..");
const siteRoot = path.resolve(__dirname, "..");
const funBinary = path.join(
  repoRoot,
  process.platform === "win32" ? "fun-out/bin/fun.exe" : "fun-out/bin/fun",
);
const stdlibDir = path.join(repoRoot, "stdlib");
const outputDir = path.join(siteRoot, "public", "wasm");

const FENCE_RE = /^```fun\r?\n([\s\S]*?)\r?\n```/gm;
const FILE_MARKER = /^\s*\/\/\s*file:\s*(.+?)\s*$/i;

function normalizeSnippetPath(rawPath) {
  const trimmed = rawPath.trim().replaceAll("\\", "/");
  if (!trimmed) return null;
  if (path.isAbsolute(trimmed)) return null;
  const normalized = path.normalize(trimmed).replaceAll("\\", "/");
  if (normalized.startsWith("..") || normalized.includes("/..")) return null;
  if (!normalized.endsWith(".fn")) return null;
  return normalized;
}

// Mirrors `server/index.ts`'s own `parseSnippetFiles` (same `// file:`
// marker convention the live Run API already understands) - kept as its
// own small copy rather than shared, since one runs under plain Node at
// build time and the other under the TypeScript server at request time.
function parseSnippetFiles(code) {
  const lines = code.split(/\r?\n/);
  const files = [];
  let currentPath = "snippet.fn";
  let currentLines = [];
  let sawMarker = false;

  const flush = () => {
    if (currentLines.length === 0) return;
    files.push({ path: currentPath, contents: `${currentLines.join("\n")}\n` });
  };

  for (const line of lines) {
    const marker = line.match(FILE_MARKER);
    if (marker) {
      flush();
      const nextPath = normalizeSnippetPath(marker[1] ?? "");
      if (!nextPath) return null;
      currentPath = nextPath;
      currentLines = [];
      sawMarker = true;
      continue;
    }
    currentLines.push(line);
  }
  flush();

  if (!sawMarker) {
    return { files: [{ path: "snippet.fn", contents: `${code}\n` }], entryFile: "snippet.fn" };
  }
  if (files.length === 0) return null;
  const entry =
    files.find((f) => f.path === "main.fn" || f.path.endsWith("/main.fn"))?.path ??
    files[0].path;
  return { files, entryFile: entry };
}

const docFiles = [
  "docs/get-started.md",
  "docs/language.md",
  "docs/concurrency.md",
  "docs/tooling.md",
  "docs/platforms.md",
  "stdlib/README.md",
];

// Normalized the same way the frontend hashes `initialCode` before
// looking a module up (`RunCodeBlock.tsx`) - trimmed and CRLF-normalized,
// so the two independent extraction paths (this file's own regex here,
// react-markdown's parser there) don't have to produce byte-identical
// strings, just the same *content*.
function hashCode(code) {
  const normalized = code.replace(/\r\n/g, "\n").trim();
  return crypto.createHash("sha256").update(normalized).digest("hex");
}

async function collectBlocks() {
  const seen = new Map();
  for (const rel of docFiles) {
    const text = await fs.readFile(path.join(repoRoot, rel), "utf8");
    for (const match of text.matchAll(FENCE_RE)) {
      const code = match[1];
      const hash = hashCode(code);
      if (!seen.has(hash)) {
        seen.set(hash, code);
      }
    }
  }
  // The "Interactive Playground" tab's curated samples are the same
  // fixed-at-build-time category as a docs example, just not sourced
  // from a markdown fence - pre-bake these too.
  for (const sample of samples) {
    const hash = hashCode(sample.code);
    if (!seen.has(hash)) {
      seen.set(hash, sample.code);
    }
  }
  return seen;
}

async function compileOne(hash, code) {
  const jsOut = path.join(outputDir, `${hash}.js`);
  try {
    await fs.access(jsOut);
    return { hash, status: "cached" };
  } catch {
    // Not built yet, fall through and compile it.
  }

  const parsed = parseSnippetFiles(code);
  if (!parsed) {
    return { hash, status: "skipped", reason: "invalid file markers" };
  }

  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "fun-wasm-prebake-"));
  try {
    for (const file of parsed.files) {
      const dest = path.join(tempDir, file.path);
      await fs.mkdir(path.dirname(dest), { recursive: true });
      await fs.writeFile(dest, file.contents, "utf8");
    }
    const entryPath = path.join(tempDir, parsed.entryFile);

    // Deliberately not `-no-exec`: running it here too (via `node`, as
    // part of `fun -in`'s own ordinary flow) is a real safety check, not
    // just a compile - an example that crashes or hangs when actually run
    // is correctly skipped instead of shipped as a broken "working" module.
    await execFileAsync(funBinary, ["-in", entryPath], {
      cwd: tempDir,
      env: { ...process.env, FUN_STDLIB_DIR: stdlibDir, FUN_CC: "emcc" },
      timeout: 30000,
      maxBuffer: 1024 * 1024,
    });

    const builtBase = path.join(
      tempDir,
      "fun-out",
      "bin",
      path.basename(parsed.entryFile, ".fn"),
    );
    await fs.mkdir(outputDir, { recursive: true });
    await fs.copyFile(`${builtBase}.js`, path.join(outputDir, `${hash}.js`));
    await fs.copyFile(`${builtBase}.wasm`, path.join(outputDir, `${hash}.wasm`));
    return { hash, status: "built" };
  } catch (err) {
    // Expected for examples that use std.net/std.process (rejected with a
    // real message, see codegen.fn's emscripten_mode check), that need
    // interactive/`-- <args>` input this static form can't provide, or
    // that are documentation fragments rather than a complete standalone
    // program - these just aren't runnable client-side, not a build
    // failure. `fun`'s own CLI errors print as a bare "[Error]" line
    // followed by the real message on the next one; skip past that
    // marker line so the logged reason is actually useful.
    const lines = (err?.stderr || err?.message || "compile failed")
      .split("\n")
      .map((l) => l.trim())
      .filter(Boolean);
    const reason = lines[0] === "[Error]" ? (lines[1] ?? lines[0]) : lines[0];
    return { hash, status: "skipped", reason: reason ?? "compile failed" };
  } finally {
    await fs.rm(tempDir, { recursive: true, force: true });
  }
}

async function main() {
  try {
    await fs.access(funBinary);
  } catch {
    console.log(
      "prebake-wasm: fun-out/bin/fun not found, skipping (run `fun build` from the repo root first if you want this step to do anything).",
    );
    return;
  }
  try {
    await execFileAsync("emcc", ["--version"]);
  } catch {
    console.log(
      "prebake-wasm: emcc not found on PATH, skipping (install the emscripten SDK if you want this step to do anything).",
    );
    return;
  }

  const blocks = await collectBlocks();
  let built = 0;
  let cached = 0;
  let skipped = 0;
  for (const [hash, code] of blocks) {
    const result = await compileOne(hash, code);
    if (result.status === "built") built += 1;
    else if (result.status === "cached") cached += 1;
    else {
      skipped += 1;
      console.log(`prebake-wasm: skipped ${hash.slice(0, 12)} - ${result.reason}`);
    }
  }
  console.log(
    `prebake-wasm: ${built} built, ${cached} already cached, ${skipped} skipped, out of ${blocks.size} runnable code blocks.`,
  );
}

await main();
