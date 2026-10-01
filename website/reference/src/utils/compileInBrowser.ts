// Compiles and runs arbitrary, freshly-edited Fun code entirely
// client-side, no backend - the Tier 2 half of the project's own
// WebAssembly initiative. Two real wasm modules running in sequence:
//
// 1. `wasm_frontend_main.js` (built by `prebake-wasm-frontend.mjs` from
//    `src/cli/wasm_frontend_main.fn`) - the compiler's own lex/parse/
//    typecheck/codegen pipeline, with no `std.process` dependency,
//    lowering the given source to C (or a real compile error).
// 2. A real C compiler, itself compiled to WebAssembly and running in
//    the browser (`@wasmer/sdk`'s `clang/clang` package, a genuine
//    clang+lld+wasm-ld toolchain targeting wasm32-wasi) - takes that C,
//    produces a runnable wasm binary, and runs it.
//
// Both artifacts are large (the frontend is a few MB; `clang/clang` is
// ~105 MB) and loaded lazily, only on the first Run click for edited
// code, and cached as module-level singletons so a second run in the
// same page session reuses them rather than reloading either.

type RunOutcome = { stdout: string; stderr: string };

// A real Fun-level compile error (bad syntax, a real type error, a
// rejected `std.net`/`std.process` import for this target) is the
// authoritative answer - the backend would return the exact same
// thing, so this is thrown as a distinct type the caller shows
// directly rather than treating as an infrastructure failure to fall
// back from.
export class FunCompileError extends Error {}

// Runs `wasm_frontend_main.js` in a fresh, isolated iframe - the exact
// same technique `RunCodeBlock.tsx`'s own `runWasm` already uses for
// pre-baked examples, and for the identical reason (a second run's
// top-level `class`/`let`/`const` declarations collide in whatever
// shared scope first ran them). Unlike that helper, this one needs the
// real exit code: 0 means stdout is the generated C, nonzero means
// stderr is the real compiler error - `runWasm`'s own `onExit` never
// looks at the code at all, since a pre-baked example is always
// expected to succeed.
async function runFrontend(source: string): Promise<string> {
  const base = import.meta.env.BASE_URL || "/";
  const src = `${base}wasm-frontend/wasm_frontend_main.js`;
  const stdoutLines: string[] = [];
  const stderrLines: string[] = [];

  return new Promise<string>((resolve, reject) => {
    let settled = false;

    const iframe = document.createElement("iframe");
    iframe.style.display = "none";
    document.body.appendChild(iframe);

    const cleanup = () => {
      window.clearTimeout(timeoutId);
      window.setTimeout(() => iframe.remove(), 0);
    };
    const finish = (code: number) => {
      if (settled) return;
      settled = true;
      cleanup();
      if (code === 0) {
        resolve(stdoutLines.join("\n"));
      } else {
        reject(new FunCompileError(stderrLines.join("\n") || "the program did not compile"));
      }
    };
    const fail = (reason: Error) => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(reason);
    };

    const timeoutId = window.setTimeout(
      () => fail(new Error("Timed out waiting for the Fun compiler frontend to finish.")),
      15000,
    );

    const iframeWindow = iframe.contentWindow as any;
    const iframeDocument = iframe.contentDocument;
    if (!iframeWindow || !iframeDocument) {
      fail(new Error("Could not create an isolated frame to run the compiler frontend in."));
      return;
    }

    iframeWindow.Module = {
      // The `--preload-file`-generated package (the real stdlib tree
      // this module needs for `use std.io;` and friends to resolve)
      // bakes its own `.data` file's path as a bare filename, not one
      // relative to the `.js`/`.wasm` pair's own directory the way the
      // wasm binary itself already is - confirmed directly: without
      // this, it fetches `/wasm_frontend_main.data` instead of
      // `${base}wasm-frontend/wasm_frontend_main.data`, silently gets
      // back whatever a dev server's own SPA fallback serves at that
      // wrong path instead of a real 404, and the stdlib tree never
      // actually mounts - every import then fails as if the stdlib
      // simply didn't exist, with no clearer signal than that.
      locateFile: (path: string) => `${base}wasm-frontend/${path}`,
      print: (line: string) => stdoutLines.push(line),
      printErr: (line: string) => stderrLines.push(line),
      // Writes the source into the module's own virtual filesystem
      // before it runs - the contract `wasm_frontend_main.fn` itself
      // documents: it reads from a fixed path, `/playground.fn`.
      preRun: [
        (mod: any) => {
          mod.FS.writeFile("/playground.fn", source);
        },
      ],
      onExit: (code: number) => finish(code),
      onAbort: (what: unknown) => fail(new Error(String(what))),
    };

    const script = iframeDocument.createElement("script");
    script.src = src;
    script.onerror = () => fail(new Error("Could not load the Fun compiler frontend module."));
    iframeDocument.body.appendChild(script);
  });
}

// Lazily created once per page session, reused by every subsequent
// run - `@wasmer/sdk`'s own client and the ~105 MB `clang/clang`
// package are too expensive to load on every click, or before the
// first one.
let wasmerClientPromise: Promise<any> | null = null;
let clangPackagePromise: Promise<any> | null = null;

async function getClang() {
  if (!wasmerClientPromise) {
    wasmerClientPromise = import("@wasmer/sdk").then(({ Wasmer }) => Wasmer.create());
  }
  const wasmer = await wasmerClientPromise;
  if (!clangPackagePromise) {
    clangPackagePromise = wasmer.packages.load("clang/clang");
  }
  const clangPkg = await clangPackagePromise;
  return { wasmer, clangPkg };
}

// Compiles `c` to a real wasm32-wasi binary via the browser-hosted
// clang package, then runs that binary through the same SDK - two
// separate sandboxes, matching the pattern confirmed working during
// this feature's own research spike (a compile sandbox producing wasm
// bytes, then a fresh sandbox loading and running those bytes as their
// own package).
async function compileAndRun(c: string): Promise<RunOutcome> {
  const { wasmer, clangPkg } = await getClang();

  const compileSandbox = await wasmer.sandboxes.create({ packages: [clangPkg] });
  let wasmBytes: Uint8Array;
  try {
    await compileSandbox.fs.writeFile("/workspace/program.c", c);
    const compile = await compileSandbox
      .command(clangPkg, [
        "-O0",
        "/workspace/program.c",
        "-o",
        "/workspace/program.wasm",
        "--target=wasm32-wasi",
      ])
      .run();
    if (compile.exitCode !== 0) {
      throw new Error(compile.stderr || "the C compiler rejected the generated program");
    }
    wasmBytes = await compileSandbox.fs.readFile("/workspace/program.wasm");
  } finally {
    await compileSandbox.close();
  }

  const programPkg = await wasmer.packages.load(wasmBytes);
  const runSandbox = await wasmer.sandboxes.create({ packages: [programPkg] });
  try {
    const out = await runSandbox.command(programPkg).run();
    return { stdout: out.stdout ?? "", stderr: out.stderr ?? "" };
  } finally {
    await runSandbox.close();
  }
}

// The full pipeline for a piece of freshly-edited Fun source. Throws
// for an infrastructure failure (a module failed to load, a timeout,
// the C-to-wasm compile itself choked) - the caller falls back to a
// live backend for those. A real `FunCompileError` is also thrown,
// but callers should treat it as the authoritative answer (the
// backend would say the same thing) rather than retry there.
export async function runEditedCode(source: string): Promise<RunOutcome> {
  const c = await runFrontend(source);
  return compileAndRun(c);
}
