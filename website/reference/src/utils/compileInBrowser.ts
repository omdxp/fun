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
async function warmDir(dir: string, baseName: string): Promise<void> {
  const hash = await manifestHash(dir);
  const base = import.meta.env.BASE_URL || "/";
  const versioned = (path: string) => (hash ? `${path}?v=${hash}` : path);
  await Promise.all(
    ["js", "wasm", "data"].map((ext) =>
      fetch(versioned(`${base}${dir}/${baseName}.${ext}`), { cache: "force-cache" }).catch(() => {}),
    ),
  );
}

export type PlaygroundReadiness = {
  // Resolves once `wasm_fls_main`'s own (small) assets are fetched at
  // least once - the signal every live-as-you-type feature
  // (diagnostics/hover/completion/signature help) waits on before its
  // first real call, rather than racing a cold download against
  // whatever the person happens to be doing right then. Confirmed
  // directly as worth gating on: before this, typing into a fresh page
  // load could fire several *overlapping* first-time module loads
  // (lint, hover, signature help each independently triggering), heavy
  // enough together to make the page feel unresponsive - the queue in
  // `runFlsSessionQueued` prevents the overlap now regardless, but
  // starting from a warm cache is still strictly better than starting
  // cold the moment someone's mid-keystroke.
  flsReady: Promise<void>;
  // Resolves once `wasm_frontend_main`'s own (small) assets are
  // fetched - not `clang/clang` itself (~105 MB, `getClang()`'s own
  // job, still lazy): Run already shows its own "Running..." state
  // while that downloads, which is the right affordance for something
  // that large; this is only about the much smaller frontend module.
  compileReady: Promise<void>;
};

// Starts loading every wasm module in the background, well before any
// click needs them - called once from `App.tsx` shortly after the page
// itself has settled (not blocking first paint). Every individual
// fetch failure is swallowed: a warm-up that couldn't reach the
// network changes nothing about correctness, the same path just tries
// again, for real, on the next actual use. Returns promises a caller
// can use to gate a loading indicator on, rather than only firing
// fetches blind.
// Memoized: `App.tsx` calls this once on page mount to start the warm-up
// as early as possible, and `Playground.tsx` calls it again on its own
// mount to get the same readiness promises to gate its loading
// indicator on (the Playground tab may not even be the one the page
// opened on). A second call must not re-issue the warm-up fetches.
let playgroundReadiness: PlaygroundReadiness | null = null;

export function warmPlaygroundRuntime(): PlaygroundReadiness {
  if (!playgroundReadiness) {
    getClang().catch(() => {});
    playgroundReadiness = {
      compileReady: warmDir("wasm-frontend", "wasm_frontend_main").catch(() => {}),
      flsReady: warmDir("wasm-fls", "wasm_fls_main").catch(() => {}),
    };
  }
  return playgroundReadiness;
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

const uriFor = (path: string): string => `file:///${path.replace(/^\/+/, "")}`;

const didOpenMessage = (uri: string, text: string): string =>
  JSON.stringify({
    jsonrpc: "2.0",
    method: "textDocument/didOpen",
    params: { textDocument: { uri, languageId: "fun", version: 1, text } },
  });

const requestMessage = (id: string, method: string, params: unknown): string =>
  JSON.stringify({ jsonrpc: "2.0", id, method, params });

// `write_message`'s own wire format, one message after another with
// nothing between them: a `Content-Length` header, a blank line, then
// exactly that many bytes of JSON body, immediately followed by the
// next header. `print()`'s per-line calls, rejoined with `\n`,
// reconstruct the original bytes exactly (every header line ends in a
// real newline; the last message's own unterminated JSON body arrives
// as emscripten's own buffered-stdout flush at exit, one final
// `print()` call) - this just walks that reconstructed text one framed
// message at a time.
function parseFramedMessages(raw: string): any[] {
  const out: any[] = [];
  let rest = raw;
  for (;;) {
    const m = rest.match(/^Content-Length: (\d+)\r?\n\r?\n/);
    if (!m) break;
    const len = Number(m[1]);
    const start = m[0].length;
    const body = rest.slice(start, start + len);
    try {
      out.push(JSON.parse(body));
    } catch {
      // Malformed framing (a truncated response, say) - stop rather
      // than risk reading a later message's bytes as this one's body.
      break;
    }
    rest = rest.slice(start + len);
  }
  return out;
}

// Runs one fls session against `wasm_fls_main.js` (see that file's own
// doc comment: reload-per-call, not a persistent server): every
// project file is mounted so cross-file analysis resolves, then
// `messages` (raw JSON-RPC message bodies, in order - the caller's own
// job to build them, this function is protocol-agnostic) is replayed
// through `Server.handle`, one call each. Returns every message the
// session wrote back, parsed and in order - a `textDocument/didOpen`
// always produces a `publishDiagnostics` notification first; a later
// request message (if any) produces its own response after that.
async function runFlsSession(files: Record<string, string>, messages: string[]): Promise<any[]> {
  const base = import.meta.env.BASE_URL || "/";
  const hash = await manifestHash("wasm-fls");
  const versioned = (path: string) => (hash ? `${path}?v=${hash}` : path);
  const src = versioned(`${base}wasm-fls/wasm_fls_main.js`);
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
      reject(new Error("fls session unavailable"));
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
          mod.FS.writeFile("/fls_request.json", JSON.stringify({ messages }));
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

  return parseFramedMessages(raw);
}

// Every fls feature (diagnostics, hover, completion, signature help,
// goto-definition) independently debounces its own trigger and then
// calls into `wasm_fls_main.js` - each call spins up a fresh iframe
// and instantiates a fresh wasm module (see `runFlsSession`'s own doc
// comment for why it's reload-per-call, not persistent). Nothing
// previously stopped several of these from firing within the same
// couple hundred milliseconds - confirmed directly against the real
// deployed site: typing a short program at a normal pace fired three
// *overlapping* `wasm_fls_main.js` loads, two of them 191ms apart.
// Three concurrent wasm instantiations is genuinely heavy, and was
// the real cause of the page going sluggish-to-unusable while typing.
//
// This serializes every fls call through one queue (never more than
// one iframe/wasm instantiation in flight at a time) and additionally
// drops a call outright, before it ever reaches the expensive part, if
// a newer call for the same `key` (feature + file) has superseded it
// while it was waiting its turn - fast typing shouldn't leave a long
// backlog of now-irrelevant diagnostics/signature-help requests still
// grinding through one at a time.
const latestFlsRequestToken = new Map<string, number>();
let flsRequestCounter = 0;
let flsQueueTail: Promise<void> = Promise.resolve();

async function runFlsSessionQueued(
  key: string,
  files: Record<string, string>,
  messages: string[],
): Promise<any[]> {
  const myToken = ++flsRequestCounter;
  latestFlsRequestToken.set(key, myToken);

  const prevTail = flsQueueTail;
  let releaseNext: () => void = () => {};
  flsQueueTail = new Promise((resolve) => {
    releaseNext = resolve;
  });
  await prevTail;

  try {
    if (latestFlsRequestToken.get(key) !== myToken) {
      return [];
    }
    return await runFlsSession(files, messages);
  } finally {
    releaseNext();
  }
}

// One request (hover/definition/completion/signatureHelp, all the
// same shape: a document position in, one response back) against
// `activePath`'s current content. Returns `null` for any failure at
// all - a module that failed to load, a timeout, a malformed or empty
// response - every one of these features is a nice-to-have overlay on
// top of the editor, never something that should visibly break it.
async function flsPositionRequest(
  files: Record<string, string>,
  activePath: string,
  method: string,
  line: number,
  character: number,
): Promise<any | null> {
  try {
    const uri = uriFor(activePath);
    const text = files[activePath] ?? "";
    const id = "1";
    const messages = [
      didOpenMessage(uri, text),
      requestMessage(id, method, { textDocument: { uri }, position: { line, character } }),
    ];
    const results = await runFlsSessionQueued(`${method}:${activePath}`, files, messages);
    const response = results.find((r) => r && r.id === id);
    return response?.result ?? null;
  } catch {
    return null;
  }
}

export async function getHover(
  files: Record<string, string>,
  activePath: string,
  line: number,
  character: number,
): Promise<any | null> {
  return flsPositionRequest(files, activePath, "textDocument/hover", line, character);
}

export async function getDefinition(
  files: Record<string, string>,
  activePath: string,
  line: number,
  character: number,
): Promise<any | null> {
  return flsPositionRequest(files, activePath, "textDocument/definition", line, character);
}

export async function getSignatureHelp(
  files: Record<string, string>,
  activePath: string,
  line: number,
  character: number,
): Promise<any | null> {
  return flsPositionRequest(files, activePath, "textDocument/signatureHelp", line, character);
}

export async function getCompletions(
  files: Record<string, string>,
  activePath: string,
  line: number,
  character: number,
): Promise<any | null> {
  return flsPositionRequest(files, activePath, "textDocument/completion", line, character);
}

// `textDocument/didOpen` alone - `Server.opened`'s own synchronous
// `report()` always publishes exactly one `publishDiagnostics`
// notification as a side effect, so no second message is needed.
export async function getDiagnostics(
  files: Record<string, string>,
  activePath: string,
): Promise<Diagnostic[]> {
  try {
    const uri = uriFor(activePath);
    const text = files[activePath] ?? "";
    const results = await runFlsSessionQueued(`diagnostics:${activePath}`, files, [
      didOpenMessage(uri, text),
    ]);
    const published = results.find((r) => r?.method === "textDocument/publishDiagnostics");
    const items = published?.params?.diagnostics;
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
