// Copies the real stdlib tree into `public/stdlib-src/` as plain,
// fetchable text - what the Playground's own goto-definition reaches
// for when a jump lands outside the person's own project (a `std.*`
// symbol, say): `wasm_fls_main.js` already has the whole stdlib
// preloaded inside its own sandboxed filesystem for resolving imports
// (see `prebake-wasm-fls.mjs`'s own `--preload-file`), but that content
// never reaches back out to the website's own JS - this is the
// website's own copy, served statically, for showing that same file in
// a read-only tab. Same cache-busting story as the wasm prebakes: a
// fixed output path with a content hash written alongside it.
import { fileURLToPath } from "node:url";
import fs from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, "../../..");
const siteRoot = path.resolve(__dirname, "..");
const stdlibDir = path.join(repoRoot, "stdlib");
const outputDir = path.join(siteRoot, "public", "stdlib-src");

// `.fn` modules, plus `README.md` - the only two shapes a goto-
// definition/hover can actually land on for an import path segment
// (`_file_start_location_result`/`_import_hover_result` in
// navigation.fn: "a whole file or README, not a specific declaration
// inside it"). Anything else in the real tree (this file itself, a
// `.gitignore`, ...) is never a jump target, so it's left out rather
// than shipped for nothing.
function isServedStdlibFile(name) {
  return name.endsWith(".fn") || name === "README.md";
}

async function copyServedFiles(srcDir, destDir, hash) {
  const entries = await fs.readdir(srcDir, { withFileTypes: true });
  for (const entry of entries) {
    const srcPath = path.join(srcDir, entry.name);
    if (entry.isDirectory()) {
      await copyServedFiles(srcPath, path.join(destDir, entry.name), hash);
      continue;
    }
    if (!isServedStdlibFile(entry.name)) continue;
    await fs.mkdir(destDir, { recursive: true });
    const content = await fs.readFile(srcPath);
    hash.update(content);
    await fs.writeFile(path.join(destDir, entry.name), content);
  }
}

async function main() {
  await fs.rm(outputDir, { recursive: true, force: true });
  const hash = crypto.createHash("sha256");
  await copyServedFiles(stdlibDir, outputDir, hash);
  const digest = hash.digest("hex").slice(0, 10);
  await fs.writeFile(path.join(outputDir, "manifest.json"), JSON.stringify({ hash: digest }));
  console.log(`prebake-stdlib-src: copied stdlib's .fn modules and READMEs into public/stdlib-src (hash ${digest})`);
}

await main();
