// Compiles the compiler's own in-browser frontend entry point
// (`src/cli/wasm_frontend_main.fn`) to WebAssembly at build time, so the
// Interactive Playground's "Run" button can lower arbitrary, freshly-
// edited code to C client-side, with no backend at all - the second
// half of that pipeline (a real C-to-wasm compiler, also running
// client-side) is wired up separately in `RunCodeBlock.tsx`, using the
// output this script produces as its input.
//
// Unlike `prebake-wasm.mjs`, this isn't content-addressed per example:
// there is exactly one of these artifacts, so it lands at a fixed path,
// `public/wasm-frontend/`. It still needs cache-busting across releases
// though - a returning visitor's browser has last release's copy cached
// under that same fixed path - so a hash of the built `.wasm` bytes is
// written to a small manifest alongside it; the frontend appends that
// hash as a `?v=` query parameter to every request for these files, the
// same effect as Vite's own hashed asset filenames, without needing to
// rename files emscripten's own generated glue expects by a fixed name.
import { fileURLToPath } from "node:url";
import fs from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

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
const entryPath = path.join(repoRoot, "src/cli/wasm_frontend_main.fn");
const outputDir = path.join(siteRoot, "public", "wasm-frontend");

async function main() {
  try {
    await fs.access(funBinary);
  } catch {
    console.log(
      "prebake-wasm-frontend: fun-out/bin/fun not found, skipping (run `fun build` from the repo root first if you want this step to do anything).",
    );
    return;
  }
  try {
    await execFileAsync("emcc", ["--version"]);
  } catch {
    console.log(
      "prebake-wasm-frontend: emcc not found on PATH, skipping (install the emscripten SDK if you want this step to do anything).",
    );
    return;
  }

  // Run from `repoRoot`, not a tempdir: `wasm_frontend_main.fn` is a
  // real, fixed file already in the repo, not a dynamically generated
  // snippet, and `--preload-file stdlib@stdlib` resolves its source
  // path (`stdlib`) relative to the working directory the compile runs
  // from - it needs to find the repo's own real `stdlib/` tree here.
  //
  // `-sEXPORTED_RUNTIME_METHODS=FS` exposes `Module.FS` so a caller can
  // write the program's source into the module's virtual filesystem
  // before running it (Tier 1's pre-baked examples never needed this -
  // they have no runtime input at all). `--preload-file stdlib@stdlib`
  // bundles the real stdlib source tree into the module's own virtual
  // filesystem at the same relative path the import resolver already
  // looks for by default, so `use std.io;` and friends resolve with no
  // environment variable needed inside the sandboxed module.
  try {
    // Deliberately not `-no-exec`: that flag stops at generating C,
    // skipping the real compile step entirely (see `prebake-wasm.mjs`'s
    // own identical note) - the whole point here is getting emcc to
    // actually run. It auto-runs the result afterward too, which always
    // "fails" (exit 1, "no source provided") since there's no real
    // `/playground.fn` at prebake time - caught below and tolerated,
    // since compilation itself already succeeded by then regardless of
    // what the subsequent run does.
    await execFileAsync(funBinary, ["-in", entryPath], {
      cwd: repoRoot,
      env: {
        ...process.env,
        FUN_STDLIB_DIR: stdlibDir,
        FUN_CC: "emcc",
        FUN_CC_ARGS: "-sEXPORTED_RUNTIME_METHODS=FS --preload-file stdlib@stdlib",
      },
      timeout: 120000,
      maxBuffer: 4 * 1024 * 1024,
    });
  } catch (err) {
    const output = err?.stderr ?? err?.stdout ?? "";
    // Both benign: "no source provided" is the module's own real check
    // (no `/playground.fn` at prebake time); the `.data` ENOENT is
    // `fun -in`'s own auto-run invoking `node` from a working directory
    // where the preload package's CWD-relative lookup doesn't find it -
    // a real browser instead fetches it by URL, unaffected by this.
    // Either way, compilation (the only thing this script needs) has
    // already finished by the time the auto-run step fails.
    if (!/no source provided|wasm_frontend_main\.data/.test(output)) {
      throw err;
    }
  }

  const builtBase = path.join(repoRoot, "fun-out", "bin", "wasm_frontend_main");
  await fs.mkdir(outputDir, { recursive: true });
  await fs.copyFile(`${builtBase}.js`, path.join(outputDir, "wasm_frontend_main.js"));
  await fs.copyFile(`${builtBase}.wasm`, path.join(outputDir, "wasm_frontend_main.wasm"));
  await fs.copyFile(`${builtBase}.data`, path.join(outputDir, "wasm_frontend_main.data"));

  const wasmBytes = await fs.readFile(`${builtBase}.wasm`);
  const hash = crypto.createHash("sha256").update(wasmBytes).digest("hex").slice(0, 10);
  await fs.writeFile(
    path.join(outputDir, "manifest.json"),
    JSON.stringify({ hash }),
  );
  console.log(`prebake-wasm-frontend: built wasm_frontend_main.js/.wasm/.data (hash ${hash})`);
}

await main();
