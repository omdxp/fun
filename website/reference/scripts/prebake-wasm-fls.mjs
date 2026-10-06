// Compiles fls's own reload-per-call wasm entry point
// (`src/fls/wasm_fls_main.fn`) to WebAssembly at build time - the
// Playground's diagnostics-on-change support, alongside
// `prebake-wasm-frontend.mjs`'s compile-to-C frontend. Same
// cache-busting story: a fixed output path, `public/wasm-fls/`, with a
// hash of the built `.wasm` bytes written alongside it so a new release
// doesn't keep serving a returning visitor's stale cached copy.
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
const entryPath = path.join(repoRoot, "src/fls/wasm_fls_main.fn");
const outputDir = path.join(siteRoot, "public", "wasm-fls");

async function main() {
  try {
    await fs.access(funBinary);
  } catch {
    console.log(
      "prebake-wasm-fls: fun-out/bin/fun not found, skipping (run `fun build` from the repo root first if you want this step to do anything).",
    );
    return;
  }
  try {
    await execFileAsync("emcc", ["--version"]);
  } catch {
    console.log(
      "prebake-wasm-fls: emcc not found on PATH, skipping (install the emscripten SDK if you want this step to do anything).",
    );
    return;
  }

  try {
    // Same deliberate "not -no-exec" and same auto-run-fails-but-that's-
    // fine shape as `prebake-wasm-frontend.mjs` - the module auto-runs
    // once at prebake time with no real `/fls_request.json` present,
    // which it reports as a real, expected failure; compilation itself
    // has already finished by then regardless.
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
    if (!/no request provided|wasm_fls_main\.data/.test(output)) {
      throw err;
    }
  }

  const builtBase = path.join(repoRoot, "fun-out", "bin", "wasm_fls_main");
  await fs.mkdir(outputDir, { recursive: true });
  await fs.copyFile(`${builtBase}.js`, path.join(outputDir, "wasm_fls_main.js"));
  await fs.copyFile(`${builtBase}.wasm`, path.join(outputDir, "wasm_fls_main.wasm"));
  await fs.copyFile(`${builtBase}.data`, path.join(outputDir, "wasm_fls_main.data"));

  const wasmBytes = await fs.readFile(`${builtBase}.wasm`);
  const hash = crypto.createHash("sha256").update(wasmBytes).digest("hex").slice(0, 10);
  await fs.writeFile(path.join(outputDir, "manifest.json"), JSON.stringify({ hash }));
  console.log(`prebake-wasm-fls: built wasm_fls_main.js/.wasm/.data (hash ${hash})`);
}

await main();
