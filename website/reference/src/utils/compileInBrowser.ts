// Compiles and runs arbitrary, freshly-edited Fun code entirely
// client-side, no backend - the Tier 2 half of the project's own
// WebAssembly initiative. Three real wasm modules:
//
// 1. `wasm_frontend_main.js` (built by `prebake-wasm-frontend.mjs` from
//    `src/cli/wasm_frontend_main.fn`) - the compiler's own lex/parse/
//    typecheck/codegen pipeline, with no `std.process` dependency,
//    lowering the given source to C (or a real compile error).
// 2. A real C compiler, itself compiled to WebAssembly and running in
//    the browser (`@wasmer/sdk`'s `clang/clang` package, a genuine
//    clang+lld+wasm-ld toolchain targeting wasm32-wasi) - takes that C,
//    produces a runnable wasm binary, and runs it.
// 3. `wasm_fls_main.js` (built by `prebake-wasm-fls.mjs` from
//    `src/fls/wasm_fls_main.fn`) - one real language-server request per
//    module load (reload-per-call, not a persistent server - see that
//    file's own doc comment for why), used for diagnostics-on-change.
//
// The first two are large (the frontend is a few MB; `clang/clang` is
// ~105 MB) and loaded lazily, only on the first Run click for edited
// code, and cached as module-level singletons so a second run in the
// same page session reuses them rather than reloading either.

type RunOutcome = { stdout: string; stderr: string };

export type Diagnostic = {
  from: { line: number; character: number };
  to: { line: number; character: number };
  severity: number;
  message: string;
};

// Resolves once per `dir` to that build's content hash (the matching
// `prebake-*.mjs` script writes it alongside the artifacts it hashes).
// Each module's own files live at a fixed path, so a returning
// visitor's browser would otherwise keep serving last release's cached
// copy forever - the hash is appended as a `?v=` query param to every
// request for these files instead, the same cache-busting effect
// `Vite`'s own hashed asset filenames get everywhere else on this
// site. `cache: "no-store"` on the manifest itself (the one thing that
// must never be stale) costs nothing: it's a few bytes, fetched at
// most once per page load.
const manifestHashPromises = new Map<string, Promise<string>>();
function manifestHash(dir: string): Promise<string> {
  let p = manifestHashPromises.get(dir);
  if (!p) {
    const base = import.meta.env.BASE_URL || "/";
    p = fetch(`${base}${dir}/manifest.json`, { cache: "no-store" })
      .then((res) => res.json())
      .then((data) => data.hash as string)
      .catch(() => "");
    manifestHashPromises.set(dir, p);
  }
  return p;
}

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
//
// `files` is the Playground's whole virtual project (every path the
// person's file tree holds), `entryPath` names which one is the
// program's real entry point. `wasm_frontend_main.fn`'s own contract
// hardcodes a single fixed input path, `/playground.fn` - every file
// in the project is still written to its own real path too (parent
// directories created as needed via `FS.mkdirTree`), which is what
// lets the entry file's own `use mod1;`/`use sub.other;` imports
// resolve against the project's other files at all: the import
// resolver looks each one up relative to the importing file's own
// directory, on the module's virtual filesystem, exactly as it would
// on a real one.
async function runFrontend(files: Record<string, string>, entryPath: string): Promise<string> {
  const base = import.meta.env.BASE_URL || "/";
  const hash = await manifestHash("wasm-frontend");
  const versioned = (path: string) => (hash ? `${path}?v=${hash}` : path);
  const src = versioned(`${base}wasm-frontend/wasm_frontend_main.js`);
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
      locateFile: (path: string) => versioned(`${base}wasm-frontend/${path}`),
      print: (line: string) => stdoutLines.push(line),
      printErr: (line: string) => stderrLines.push(line),
      // Mounts every project file at its own real path, plus the
      // entry file's content again at the fixed path the module always
      // reads from.
      preRun: [
        (mod: any) => {
          const writeAt = (path: string, content: string) => {
            const slash = path.lastIndexOf("/");
            if (slash > 0) {
              mod.FS.mkdirTree(path.slice(0, slash));
            }
            mod.FS.writeFile(path, content);
          };
          for (const [path, content] of Object.entries(files)) {
            writeAt(path.startsWith("/") ? path : `/${path}`, content);
          }
          writeAt("/playground.fn", files[entryPath] ?? "");
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
      // A real, substantive answer - the C compiler actually rejected
      // the generated program - not an infrastructure failure, so it's
      // thrown as the same authoritative type as a Fun-level compile
      // error rather than one the caller falls back to a backend for.
      throw new FunCompileError(
        compile.stderr.text() || "the C compiler rejected the generated program",
      );
    }
    wasmBytes = await compileSandbox.fs.readFile("/workspace/program.wasm");
  } finally {
    await compileSandbox.close();
  }

  const programPkg = await wasmer.packages.load(wasmBytes);
  const runSandbox = await wasmer.sandboxes.create({ packages: [programPkg] });
  try {
    const out = await runSandbox.command(programPkg).run();
    return { stdout: out.stdout.text(), stderr: out.stderr.text() };
  } finally {
    await runSandbox.close();
  }
}

// Starts loading both wasm modules in the background, well before any
// click needs them - called once from `App.tsx` shortly after the page
// itself has settled (not blocking first paint). A run still works
// without this (`getClang`/`runFrontend` load lazily on demand either
// way); this just means the first real click usually finds both already
// warm instead of starting a ~105 MB download right when the person is
// waiting on it. Every failure here is swallowed: a warm-up that
// couldn't reach the network changes nothing about correctness, the
// same path just tries again, for real, on the next actual run.
export function warmPlaygroundRuntime(): void {
  getClang().catch(() => {});
  for (const [dir, base_name] of [
    ["wasm-frontend", "wasm_frontend_main"],
    ["wasm-fls", "wasm_fls_main"],
  ] as const) {
    manifestHash(dir)
      .then((hash) => {
        const base = import.meta.env.BASE_URL || "/";
        const versioned = (path: string) => (hash ? `${path}?v=${hash}` : path);
        for (const ext of ["js", "wasm", "data"]) {
          fetch(versioned(`${base}${dir}/${base_name}.${ext}`), { cache: "force-cache" }).catch(() => {});
        }
      })
      .catch(() => {});
  }
}

// Mounts every project file at its own real path (the shared
// convention `runFrontend` also uses, so cross-file imports resolve
// identically for both halves of the pipeline), creating intermediate
// directories as needed.
function mountProjectFiles(mod: any, files: Record<string, string>) {
  const writeAt = (path: string, content: string) => {
    const slash = path.lastIndexOf("/");
    if (slash > 0) {
      mod.FS.mkdirTree(path.slice(0, slash));
    }
    mod.FS.writeFile(path, content);
  };
  for (const [path, content] of Object.entries(files)) {
    writeAt(path.startsWith("/") ? path : `/${path}`, content);
  }
}

// One `textDocument/didOpen` against `wasm_fls_main.js` (see that
// file's own doc comment: reload-per-call, not a persistent server),
// for `activePath`'s current content within the project `files` holds
// (mounted so any cross-file reference the language server's own
// analysis follows still resolves). Returns `[]` for any failure at
// all - a module that failed to load, a timeout, a malformed response,
// anything - diagnostics are a nice-to-have overlay on top of the
// editor, never something that should visibly break it or compete
// with a real compile error for the person's attention.
export async function getDiagnostics(
  files: Record<string, string>,
  activePath: string,
): Promise<Diagnostic[]> {
  try {
    const base = import.meta.env.BASE_URL || "/";
    const hash = await manifestHash("wasm-fls");
    const versioned = (path: string) => (hash ? `${path}?v=${hash}` : path);
    const src = versioned(`${base}wasm-fls/wasm_fls_main.js`);
    const uri = `file:///${activePath.replace(/^\/+/, "")}`;
    const text = files[activePath] ?? "";
    const stdoutChunks: string[] = [];

    const raw = await new Promise<string>((resolve, reject) => {
      let settled = false;
      const iframe = document.createElement("iframe");
      iframe.style.display = "none";
      document.body.appendChild(iframe);

      const cleanup = () => {
        window.clearTimeout(timeoutId);
        window.setTimeout(() => iframe.remove(), 0);
      };
      const finish = () => {
        if (settled) return;
        settled = true;
        cleanup();
        resolve(stdoutChunks.join("\n"));
      };
      const fail = () => {
        if (settled) return;
        settled = true;
        cleanup();
        reject(new Error("diagnostics unavailable"));
      };

      const timeoutId = window.setTimeout(fail, 10000);

      const iframeWindow = iframe.contentWindow as any;
      const iframeDocument = iframe.contentDocument;
      if (!iframeWindow || !iframeDocument) {
        fail();
        return;
      }

      iframeWindow.Module = {
        locateFile: (path: string) => versioned(`${base}wasm-fls/${path}`),
        print: (line: string) => stdoutChunks.push(line),
        printErr: () => {},
        preRun: [
          (mod: any) => {
            mountProjectFiles(mod, files);
            mod.FS.writeFile("/fls_request.json", JSON.stringify({ uri, text }));
          },
        ],
        onExit: () => finish(),
        onAbort: () => fail(),
      };

      const script = iframeDocument.createElement("script");
      script.src = src;
      script.onerror = fail;
      iframeDocument.body.appendChild(script);
    });

    // `write_message`'s own wire format: a `Content-Length` header, a
    // blank line, then exactly that many bytes of JSON body with no
    // trailing newline - `print()`'s per-line calls, rejoined with
    // `\n`, reconstruct this exactly (the header line itself ends in
    // a real newline; the unterminated JSON body arrives as emscripten's
    // own buffered-stdout flush at exit, one final `print()` call).
    const match = raw.match(/Content-Length: (\d+)\r?\n\r?\n([\s\S]*)$/);
    if (!match) return [];
    const body = match[2].slice(0, Number(match[1]));
    const parsed = JSON.parse(body);
    const items = parsed?.params?.diagnostics;
    if (!Array.isArray(items)) return [];
    return items.map((d: any) => ({
      from: { line: d.range.start.line, character: d.range.start.character },
      to: { line: d.range.end.line, character: d.range.end.character },
      severity: d.severity ?? 1,
      message: d.message ?? "",
    }));
  } catch {
    return [];
  }
}

// The full pipeline for a Playground project - every file the person's
// file tree holds, plus which one is the entry point. Throws a plain
// `Error` only for an infrastructure failure (a module failed to load,
// a timeout) - the caller falls back to a live backend for those.
// Every substantive rejection, whether the Fun frontend's own
// parse/typecheck or the C compiler's, is a `FunCompileError`: the
// authoritative answer a backend would give too, shown directly.
export async function runEditedCode(
  files: Record<string, string>,
  entryPath: string,
): Promise<RunOutcome> {
  const c = await runFrontend(files, entryPath);
  return compileAndRun(c);
}
