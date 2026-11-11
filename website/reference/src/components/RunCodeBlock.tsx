import { useEffect, useId, useMemo, useRef, useState } from "react";
import { Compartment, EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";

import {
  isDarkTheme,
  buildBaseFunEditorExtensions,
  buildFunEditorExtensions,
  refreshInlayHints,
  offsetFor,
  posFor,
  type FunEditorOptions,
} from "../utils/funEditorExtensions";
import { copyTextToClipboard } from "../utils/clipboard";
import {
  FunCompileError,
  runEditedCode,
  getDefinition,
  warmPlaygroundRuntime,
  fetchStdlibSource,
  parseSnippetFiles,
  fileAtLine,
  lineToGlobal,
} from "../utils/compileInBrowser";

type Props = {
  initialCode: string;
  title?: string;
};

type RunResponse = {
  ok: boolean;
  stdout?: string;
  stderr?: string;
  error?: string;
};

type RunOutcome = { stdout: string; stderr: string };

// Matches `prebake-wasm.mjs`'s own `hashCode`: trimmed and CRLF-normalized,
// so this component's react-markdown-derived text and that script's
// regex-derived text don't have to be byte-identical, just the same
// *content*, before hashing.
async function hashCode(code: string): Promise<string> {
  const normalized = code.replace(/\r\n/g, "\n").trim();
  const bytes = new TextEncoder().encode(normalized);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

// Runs a pre-baked wasm module (built by `prebake-wasm.mjs`, see #189) for
// `hash` entirely client-side - no backend at all. The module is emscripten's
// own default (non-modularized) output: it auto-runs on load, reading
// `print`/`printErr`/`onExit`/`onAbort` off a pre-existing global `Module`
// object when one is set before the script loads (`var Module = typeof
// Module != "undefined" ? Module : {}` at the top of every such file) -
// the classic, well-supported emscripten integration pattern, chosen over
// `-sMODULARIZE` specifically so the artifact `prebake-wasm.mjs` already
// produces (and already verified working end to end, #189) needs no
// compile-flag changes here.
//
// Each run gets its own fresh, throwaway iframe rather than injecting the
// script into the main document - confirmed necessary directly, not just
// a defensive choice: the module's own top-level `class`/`let`/`const`
// declarations (an internal emscripten helper, `EmscriptenEH`, among
// others) persist in whatever global lexical scope they first execute
// in, even after the `<script>` tag that declared them is removed from
// the DOM - a real, unrelated-to-this-project browser platform
// limitation, not something `-sMODULARIZE` or any compile flag changes.
// Loading a second module (or re-running the same one) into the shared
// main-document scope throws "Identifier already declared" instead of
// running. A fresh iframe is a fresh JS realm every time, so this can
// never collide, regardless of which example ran there before.
//
// Rejects (falling back to the backend, or the "nothing available"
// message) when no module exists for this hash - a 404 is the normal,
// expected case for any edited or non-pre-baked code.
async function runWasm(hash: string): Promise<RunOutcome> {
  const base = import.meta.env.BASE_URL || "/";
  const src = `${base}wasm/${hash}.js`;
  const stdoutLines: string[] = [];
  const stderrLines: string[] = [];

  return new Promise<RunOutcome>((resolve, reject) => {
    let settled = false;

    const iframe = document.createElement("iframe");
    iframe.style.display = "none";
    document.body.appendChild(iframe);

    const cleanup = () => {
      window.clearTimeout(timeoutId);
      // Deferred, not immediate: `onExit` fires from inside emscripten's
      // own exit-handling code, which can still touch `Module` itself a
      // moment later in the same tick (its own pthread-worker teardown,
      // observed directly) - tearing the iframe down synchronously here
      // raced that, producing a real (if harmless) console error. A
      // zero-delay timeout runs after the current callstack unwinds,
      // giving that a chance to finish first.
      window.setTimeout(() => iframe.remove(), 0);
    };
    const finish = () => {
      if (settled) return;
      settled = true;
      cleanup();
      resolve({ stdout: stdoutLines.join("\n"), stderr: stderrLines.join("\n") });
    };
    const fail = (reason: Error) => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(reason);
    };

    const timeoutId = window.setTimeout(
      () => fail(new Error("Timed out waiting for the wasm module to finish.")),
      15000,
    );

    const iframeWindow = iframe.contentWindow as any;
    const iframeDocument = iframe.contentDocument;
    if (!iframeWindow || !iframeDocument) {
      fail(new Error("Could not create an isolated frame to run the module in."));
      return;
    }

    iframeWindow.Module = {
      print: (line: string) => stdoutLines.push(line),
      printErr: (line: string) => stderrLines.push(line),
      onExit: () => finish(),
      onAbort: (what: unknown) => fail(new Error(String(what))),
    };

    const script = iframeDocument.createElement("script");
    script.src = src;
    script.onerror = () => fail(new Error("No pre-baked wasm module for this example."));
    iframeDocument.body.appendChild(script);
  });
}

export default function RunCodeBlock({ initialCode, title }: Props) {
  const [code, setCode] = useState(initialCode.trimEnd());
  const codeRef = useRef(code);
  codeRef.current = code;
  const [stdout, setStdout] = useState("");
  const [stderr, setStderr] = useState("");
  const [isRunning, setIsRunning] = useState(false);
  const [hasRun, setHasRun] = useState(false);
  const [copyStatus, setCopyStatus] = useState<"idle" | "ok" | "err">("idle");
  const hostRef = useRef<HTMLDivElement | null>(null);
  const viewRef = useRef<EditorView | null>(null);
  const configuredApiBase = (import.meta.env.VITE_RUN_API_BASE ?? "")
    .trim()
    .replace(/\/+$/, "");
  const runEndpoint = configuredApiBase
    ? `${configuredApiBase}/api/run`
    : "/api/run";
  const isGithubPages =
    typeof window !== "undefined" &&
    window.location.hostname.endsWith("github.io");
  // A pre-baked wasm module only ever exists for the example's own
  // original text (see `prebake-wasm.mjs`) - an edit means there's
  // nothing to look up, only the backend (if any) can run it.
  const isUnedited = code === initialCode.trimEnd();
  const backendUnavailable = isGithubPages && configuredApiBase === "";

  // The `// file: name.fn` convention (`parseSnippetFiles`, shared
  // with `Playground.tsx`'s own sample loader) lets one runnable
  // example demonstrate imports/modularity across more than one real
  // file, still shown as a single continuous editor here (no tabs) -
  // `fileRanges` is what maps a position in that one editor back to
  // which split file, and which *local* line within it, fls actually
  // needs to hear about.
  const snippet = useMemo(() => parseSnippetFiles(code), [code]);
  const snippetRef = useRef(snippet);
  snippetRef.current = snippet;

  const runViaBackend = async (): Promise<RunOutcome> => {
    const res = await fetch(runEndpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code }),
    });
    const data = (await res.json()) as RunResponse;
    return { stdout: data.stdout ?? "", stderr: data.error ?? data.stderr ?? "" };
  };

  const run = async () => {
    setIsRunning(true);
    setHasRun(true);
    setStdout("");
    setStderr("");
    try {
      if (isUnedited) {
        try {
          const hash = await hashCode(initialCode);
          const outcome = await runWasm(hash);
          setStdout(outcome.stdout);
          setStderr(outcome.stderr);
          return;
        } catch {
          // No pre-baked module for this example (or it failed to load/
          // run) - every example is still expected to run with no
          // backend at all, so this falls through to the exact same
          // live in-browser compile edited code always uses, just
          // below, before ever reaching the backend.
        }
      }
      try {
        // Real multi-file splitting (`parseSnippetFiles`), the same
        // as `Playground.tsx`'s own project - a naive single-file
        // compile of the raw, marker-laden text would otherwise choke
        // on an "imports and modularity" example the instant it was
        // edited (the prebaked-wasm fast path above never hits this
        // for an unedited one, which is why this went unnoticed).
        const outcome = await runEditedCode(snippet.files, snippet.entry);
        setStdout(outcome.stdout);
        setStderr(outcome.stderr);
        return;
      } catch (e) {
        if (e instanceof FunCompileError) {
          // The authoritative answer - a live backend would reject
          // the same program the same way, so there's nothing to
          // gain by falling through to one.
          setStderr(e.message);
          return;
        }
        // An infrastructure failure (a module failed to load, a
        // timeout, the in-browser C compiler itself choked) - fall
        // through to the backend below.
      }
      if (backendUnavailable) {
        setStderr(
          "Could not run this in your browser and there is no backend API available to fall back to. Run the site locally, or set up a remote runner API (see project README).",
        );
        return;
      }
      const outcome = await runViaBackend();
      setStdout(outcome.stdout);
      setStderr(outcome.stderr);
    } catch (e: any) {
      setStderr(e?.message ?? "Request failed");
    } finally {
      setIsRunning(false);
    }
  };

  const copyCode = async () => {
    try {
      await copyTextToClipboard(code);
      setCopyStatus("ok");
    } catch {
      setCopyStatus("err");
    }
    window.setTimeout(() => setCopyStatus("idle"), 1600);
  };

  const resetCode = () => {
    const reset = initialCode.trimEnd();
    setCode(reset);
    const view = viewRef.current;
    // A reset while looking at an external stdlib file (see below)
    // has nothing in the live view to replace - the snippet's own
    // `EditorState` is rebuilt from `code` the ordinary way (the
    // `[code]`-keyed effect further down), and switching back to it
    // picks up the reset text from there.
    if (view && activeView === path) {
      view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: reset } });
    }
  };

  // A small, filesystem-safe name unique to this one block - every
  // fls request is keyed by `${method}:${path}` (`compileInBrowser.ts`'s
  // own `runFlsSessionQueued`) to drop a now-stale request when a
  // newer one for the *same* document supersedes it; without a unique
  // path here, two different runnable examples on the same doc page
  // would instead supersede *each other's* requests.
  const rawId = useId();
  const path = useMemo(() => `playground-${rawId.replace(/[^a-zA-Z0-9]/g, "")}.fn`, [rawId]);

  const [flsReady, setFlsReady] = useState(false);
  const flsReadyRef = useRef(false);
  flsReadyRef.current = flsReady;

  // `stdlib/std/io.fn` fetched once a goto-definition or a hover's
  // own "See also" link names it - the one external source a
  // runnable example can actually show (never a person's own code,
  // so nothing ever writes here from an edit). Mirrors `Playground.
  // tsx`'s own `externalFiles`, just capped at whichever single
  // external file is currently being looked at rather than a whole
  // tree of them, since this block has no project view to list more
  // than one in anyway.
  const [externalFiles, setExternalFiles] = useState<Record<string, string>>({});
  const externalFilesRef = useRef(externalFiles);
  externalFilesRef.current = externalFiles;

  // Which document the one editor here is currently showing - this
  // block's own `path` (the editable snippet) or an external stdlib
  // path fetched into `externalFiles` above. `Playground.tsx` calls
  // the equivalent `activeFile`; named differently here only because
  // there's no real file *tree* behind it, just this one slot.
  const [activeView, setActiveView] = useState(path);
  const activeViewRef = useRef(activeView);
  activeViewRef.current = activeView;

  const statesRef = useRef(new Map<string, EditorState>());
  const pendingJumpRef = useRef<{ line: number; character: number } | null>(null);

  // Every position a jump moved away from/returned to, most recent
  // last - the same back/forward pairing `Playground.tsx`'s own
  // project-wide nav history gives, just over two possible views
  // (the snippet, or whichever stdlib file is currently fetched)
  // instead of a whole tree.
  const backRef = useRef<{ view: string; line: number; character: number }[]>([]);
  const forwardRef = useRef<{ view: string; line: number; character: number }[]>([]);
  const [hasBack, setHasBack] = useState(false);
  const [hasForward, setHasForward] = useState(false);
  const NAV_LIMIT = 50;

  // `fromLine`/`fromCharacter` is the position the jump was actually
  // invoked *from*, captured by the caller before its own async fls
  // round-trip - see `Playground.tsx`'s own `jumpTo` for why re-
  // deriving it from `view.state.selection.main.head` here instead
  // would silently drift from the real trigger site (a Cmd/Ctrl+
  // click's own `preventDefault()` stops the browser from ever moving
  // the live selection there).
  const jumpTo = async (
    view: EditorView,
    fromView: string,
    fromLine: number,
    fromCharacter: number,
    targetView: string,
    targetLine: number,
    targetCharacter: number,
  ) => {
    const pushHistory = () => {
      backRef.current.push({ view: fromView, line: fromLine, character: fromCharacter });
      if (backRef.current.length > NAV_LIMIT) backRef.current.shift();
      setHasBack(true);
      if (forwardRef.current.length > 0) {
        forwardRef.current = [];
        setHasForward(false);
      }
    };
    if (targetView === fromView) {
      const off = offsetFor(view.state.doc, targetLine, targetCharacter);
      const fromOff = offsetFor(view.state.doc, fromLine, fromCharacter);
      // Goto-definition invoked while already standing on the
      // definition itself (or invoked twice in a row without moving)
      // resolves to this exact spot - nothing to jump to, and
      // nothing worth remembering.
      if (off === fromOff) return;
      pushHistory();
      view.dispatch({ selection: { anchor: off }, effects: EditorView.scrollIntoView(off, { y: "center" }) });
      view.focus();
      return;
    }
    if (targetView !== path && externalFilesRef.current[targetView] === undefined) {
      if (!targetView.startsWith("stdlib/")) return;
      const content = await fetchStdlibSource(targetView.slice("stdlib/".length));
      if (content == null) return;
      setExternalFiles((prev) => (prev[targetView] !== undefined ? prev : { ...prev, [targetView]: content }));
    }
    pushHistory();
    pendingJumpRef.current = { line: targetLine, character: targetCharacter };
    setActiveView(targetView);
  };

  // Pops the most recent position a jump left behind and returns
  // there - same mental model as `Playground.tsx`'s own `goBack`,
  // including the stdlib case: a fetched file never disappears from
  // `externalFiles` once fetched, so "Back" into one always has
  // something to show.
  const goBack = (view: EditorView, currentView: string) => {
    const from = posFor(view.state.doc, view.state.selection.main.head);
    let forwardPushed = false;
    const pushForwardOnce = () => {
      if (forwardPushed) return;
      forwardPushed = true;
      forwardRef.current.push({ view: currentView, line: from.line, character: from.character });
      setHasForward(true);
    };
    const prev = backRef.current.pop();
    setHasBack(backRef.current.length > 0);
    if (!prev) return;
    pushForwardOnce();
    if (prev.view === currentView) {
      const off = offsetFor(view.state.doc, prev.line, prev.character);
      view.dispatch({ selection: { anchor: off }, effects: EditorView.scrollIntoView(off, { y: "center" }) });
      view.focus();
      return;
    }
    pendingJumpRef.current = { line: prev.line, character: prev.character };
    setActiveView(prev.view);
  };

  const goForward = (view: EditorView, currentView: string) => {
    const from = posFor(view.state.doc, view.state.selection.main.head);
    let backPushed = false;
    const pushBackOnce = () => {
      if (backPushed) return;
      backPushed = true;
      backRef.current.push({ view: currentView, line: from.line, character: from.character });
      if (backRef.current.length > NAV_LIMIT) backRef.current.shift();
      setHasBack(true);
    };
    const next = forwardRef.current.pop();
    setHasForward(forwardRef.current.length > 0);
    if (!next) return;
    pushBackOnce();
    if (next.view === currentView) {
      const off = offsetFor(view.state.doc, next.line, next.character);
      view.dispatch({ selection: { anchor: off }, effects: EditorView.scrollIntoView(off, { y: "center" }) });
      view.focus();
      return;
    }
    pendingJumpRef.current = { line: next.line, character: next.character };
    setActiveView(next.view);
  };

  // A hover/completion doc's own "See also" link (`file:///path#L3`)
  // already names its target directly - no `getDefinition` round-trip
  // needed, just the same jump `gotoDefinitionLocal` uses. `#L3` is
  // 1-indexed, so it's converted to 0-indexed before use here.
  const navigateToDocLink = (view: EditorView, href: string) => {
    const m = href.match(/^file:\/\/\/(.+?)(?:#L(\d+))?$/);
    if (!m) return;
    const targetFile = decodeURIComponent(m[1]);
    const targetLocalLine = m[2] ? Math.max(0, parseInt(m[2], 10) - 1) : 0;
    const fromView = activeViewRef.current;
    const from = posFor(view.state.doc, view.state.selection.main.head);
    // fls names this target by the snippet's own internal file name
    // (e.g. "main.fn"), never by this block's synthetic `path` - the
    // same mismatch `gotoDefinitionLocal` already remaps below. Without
    // this, a "See also" link pointing back into the snippet itself
    // (the common case: a user-defined type declared right there)
    // always resolved to a view neither "stdlib/"-prefixed nor equal
    // to `path`, so `jumpTo` silently treated it as unresolvable.
    if (fromView === path && snippetRef.current.files[targetFile] !== undefined) {
      const targetGlobalLine = lineToGlobal(snippetRef.current.fileRanges, targetFile, targetLocalLine);
      void jumpTo(view, path, from.line, from.character, path, targetGlobalLine, 0);
      return;
    }
    void jumpTo(view, fromView, from.line, from.character, targetFile, targetLocalLine, 0);
  };

  // Resolves a goto-definition anywhere this block can reach: within
  // the snippet itself (any of its own split files, if it's a multi-
  // file example), or out into the real stdlib - the one external
  // source a runnable example can actually fetch and show, the same
  // as `Playground.tsx`'s own `externalFiles`. Any other target (an
  // import this sandbox has no source for at all) is still a no-op,
  // the same ceiling the full Playground already has.
  const gotoDefinitionLocal = async (view: EditorView, pos?: number) => {
    // Captured now, before the `await` below - see `jumpTo`'s own
    // comment on why this can't be re-derived from `view.state.
    // selection.main.head` once the fls round-trip finishes instead.
    const p = pos ?? view.state.selection.main.head;
    const { line, character } = posFor(view.state.doc, p);
    const fromView = activeViewRef.current;
    let requestPath = fromView;
    let requestLine = line;
    let requestCharacter = character;
    // The sandbox's own filesystem already preloads the real stdlib
    // tree at these exact paths (see `flsPositionRequest`'s own
    // comment on `textOverride`) - mounting a stdlib file's content a
    // second time at the same path here throws a real Emscripten FS
    // error (confirmed directly: an uncaught `ErrnoError`, silently
    // swallowed by `flsPositionRequest`'s catch-all, so every fls
    // request issued while viewing one - this chained goto-definition
    // included - just quietly returned nothing). `requestFiles` is
    // always just the snippet's own files, whichever view triggered
    // this; the externally-fetched file's own content reaches fls
    // through `requestText` (`textOverride`) instead, never `files`.
    let requestFiles: Record<string, string> = snippetRef.current.files;
    let requestText: string | undefined;
    if (fromView === path) {
      const resolved = snippetRef.current.fileRanges.length > 1
        ? fileAtLine(snippetRef.current.fileRanges, line)
        : { path: snippetRef.current.entry, localLine: line };
      requestPath = resolved.path;
      requestLine = resolved.localLine;
    } else {
      requestText = externalFilesRef.current[fromView] ?? "";
    }
    const result = await getDefinition(requestFiles, requestPath, requestLine, requestCharacter, requestText);
    const loc = Array.isArray(result) ? result[0] : result;
    if (!loc?.uri || !loc?.range?.start) return;
    const targetFile = String(loc.uri).replace(/^file:\/\/\//, "").replace(/^\/+/, "");
    const targetLocalLine = loc.range.start.line ?? 0;
    const targetCharacter = loc.range.start.character ?? 0;

    if (fromView === path && snippetRef.current.files[targetFile] !== undefined) {
      // Landed back inside one of the snippet's own split files -
      // remapped from that file's local line to the one combined
      // editor's real line.
      const targetGlobalLine = lineToGlobal(snippetRef.current.fileRanges, targetFile, targetLocalLine);
      await jumpTo(view, path, line, character, path, targetGlobalLine, targetCharacter);
      return;
    }
    if (targetFile === fromView) {
      await jumpTo(view, fromView, line, character, fromView, targetLocalLine, targetCharacter);
      return;
    }
    // Anything else: either a real stdlib target (`jumpTo` fetches
    // it) or an unresolvable one (`jumpTo` is a no-op for that, same
    // as the full Playground).
    await jumpTo(view, fromView, line, character, targetFile, targetLocalLine, targetCharacter);
  };

  // Deferred until the block is actually near the viewport (see the
  // `IntersectionObserver` effect below) - a doc page can hold dozens
  // of these (`language.md` alone has over 30), and every fls feature
  // funnels through one shared, serialized queue (one wasm module
  // instantiation in flight at a time, see `compileInBrowser.ts`'s own
  // `runFlsSessionQueued`): mounting that many at once would queue
  // that many diagnostics passes back-to-back on page load, each
  // paying a fresh wasm instantiation, instead of staying one quick
  // check per block as a reader actually scrolls to it.
  const flsCompartment = useRef<Compartment | null>(null);
  if (!flsCompartment.current) flsCompartment.current = new Compartment();
  // Holds `buildBaseFunEditorExtensions`'s own output (syntax theme
  // included) separately from the fls half above - reconfigured on
  // its own the moment the site's theme toggles (see the
  // `MutationObserver` effect below), rather than only ever picking
  // up the theme this block happened to mount under.
  const baseCompartment = useRef<Compartment | null>(null);
  if (!baseCompartment.current) baseCompartment.current = new Compartment();

  const [dark, setDark] = useState(isDarkTheme());

  // Built fresh per `view` (the snippet itself, or a fetched stdlib
  // file) rather than once for the whole block - an external file is
  // read-only and single-file, with none of the snippet's own multi-
  // file position mapping to carry.
  const funEditorOptionsFor = (view: string): FunEditorOptions => {
    const isSnippet = view === path;
    const multi = isSnippet && snippetRef.current.fileRanges.length > 1
      ? {
        allPaths: Object.keys(snippetRef.current.files),
        toLocal: (globalLine: number, globalCharacter: number) => {
          const r = fileAtLine(snippetRef.current.fileRanges, globalLine);
          return { path: r.path, line: r.localLine, character: globalCharacter };
        },
        toGlobalLine: (filePath: string, localLine: number) => lineToGlobal(snippetRef.current.fileRanges, filePath, localLine),
      }
      : undefined;
    return {
      path: isSnippet ? snippetRef.current.entry : view,
      isDark: dark,
      isExternal: !isSnippet,
      // Always the snippet's own files, whether or not it's the view
      // currently showing - never a stdlib file's content, which the
      // sandbox's own filesystem already preloads at this exact path
      // (see `gotoDefinitionLocal`'s own comment on the real,
      // confirmed `ErrnoError` a second mount there throws). An
      // external file's content reaches fls through `getText` instead.
      getFiles: () => snippetRef.current.files,
      getText: () => (isSnippet ? undefined : externalFilesRef.current[view]),
      getFlsReady: () => flsReadyRef.current,
      multiFile: multi,
      onDocLink: (view2, href) => navigateToDocLink(view2, href),
      onGotoDefinition: (view2, pos) => { void gotoDefinitionLocal(view2, pos); },
      onGoBack: (view2) => goBack(view2, view),
      onGoForward: (view2) => goForward(view2, view),
    };
  };

  const stateFor = (view: string, content: string): EditorState => {
    const existing = statesRef.current.get(view);
    if (existing) return existing;
    const opts = funEditorOptionsFor(view);
    const extensions = [
      baseCompartment.current!.of(buildBaseFunEditorExtensions(dark, opts.isExternal)),
      flsCompartment.current!.of(flsReadyRef.current ? buildFunEditorExtensions(opts) : []),
      // `stateFor` caches one `EditorState` per view and reuses it
      // unconditionally on every later visit (so undo history/
      // selection survive switching to a stdlib file and back) - but
      // a transaction produces a brand new, immutable `EditorState`
      // object each time, so without re-caching it here, both an
      // edit and a same-view goto-definition jump (`jumpTo`'s own
      // `view.dispatch({selection: ...})`, which never goes through
      // `stateFor` either) would otherwise vanish the instant "Back"
      // (or "Forward") swaps this view out and back in - the exact
      // same staleness the fls-ready and theme-toggle reconfigure
      // dispatches above also needed their own re-cache line for.
      EditorView.updateListener.of((update) => {
        if (update.docChanged || update.selectionSet) {
          statesRef.current.set(view, update.state);
        }
      }),
    ];
    if (view === path) {
      extensions.push(
        EditorView.updateListener.of((update) => {
          if (update.docChanged) {
            setCode(update.state.doc.toString());
          }
        }),
      );
    }
    const state = EditorState.create({ doc: content, extensions });
    statesRef.current.set(view, state);
    return state;
  };

  // One real CodeMirror view, reused across the snippet/stdlib
  // switch - swapping `EditorState` (so each keeps its own selection)
  // rather than tearing the view down and rebuilding it.
  useEffect(() => {
    if (!hostRef.current) return;
    const view = new EditorView({
      state: stateFor(path, code),
      parent: hostRef.current,
    });
    viewRef.current = view;

    let cancelled = false;
    const observer = new IntersectionObserver(
      (entries) => {
        if (cancelled || !entries.some((e) => e.isIntersecting)) return;
        observer.disconnect();
        warmPlaygroundRuntime().flsReady.then(() => {
          if (cancelled) return;
          flsReadyRef.current = true;
          setFlsReady(true);
          const currentView = activeViewRef.current;
          const opts = funEditorOptionsFor(currentView);
          view.dispatch({ effects: flsCompartment.current!.reconfigure(buildFunEditorExtensions(opts)) });
          // `view.dispatch` just updated `view.state` to a brand new
          // object - but `statesRef`'s own cached entry for this view
          // still points at the *old*, pre-fls one (dispatch has no
          // way to know a separate cache even exists). Setting
          // `flsReady` just above re-renders, which runs the
          // `activeView`-sync effect below (keyed on `flsReady` too,
          // precisely so a block scrolled into view *while already
          // active* still gets its hints refreshed) - that effect
          // calls `stateFor`, sees this view "already cached," and
          // hands back the stale pre-fls state, which then looks
          // *different* from `view.state` (the correctly-reconfigured
          // live one) and gets swapped in via `view.setState`,
          // silently reverting the reconfigure that just ran.
          // Confirmed directly: every fls feature worked for exactly
          // one tick and then vanished. Re-caching here is what keeps
          // the two in sync.
          statesRef.current.set(currentView, view.state);
          void refreshInlayHints(view, opts);
        });
      },
      { rootMargin: "200px" },
    );
    observer.observe(hostRef.current);

    return () => {
      cancelled = true;
      observer.disconnect();
      view.destroy();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Swaps in whichever view is now active (snippet or a stdlib file)
  // and applies any jump that just switched to it - the cross-view
  // half of `jumpTo`/`goBack`/`goForward` above, which can only set
  // `activeView`/`pendingJumpRef` directly, not touch the view itself
  // before its own new `EditorState` actually exists.
  useEffect(() => {
    const view = viewRef.current;
    if (!view) return;
    const content = activeView === path ? codeRef.current : (externalFilesRef.current[activeView] ?? "");
    const nextState = stateFor(activeView, content);
    if (view.state !== nextState) {
      view.setState(nextState);
    }
    const jump = pendingJumpRef.current;
    if (jump) {
      pendingJumpRef.current = null;
      const off = offsetFor(view.state.doc, jump.line, jump.character);
      view.dispatch({ selection: { anchor: off }, effects: EditorView.scrollIntoView(off, { y: "center" }) });
      view.focus();
    }
    void refreshInlayHints(view, funEditorOptionsFor(activeView));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [activeView, flsReady]);

  // The snippet's own live edits need to reach its cached `EditorState`
  // too (`stateFor` only ever builds a view's state once and reuses
  // it) - mirrors `Playground.tsx`'s own identical re-caching
  // comment: without this, switching to a stdlib file and back would
  // resurrect the *pre-edit* snippet text instead of the current one.
  useEffect(() => {
    const view = viewRef.current;
    if (!view || activeView !== path) return;
    if (view.state.doc.toString() === code) return;
    view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: code } });
  }, [code, activeView, path]);

  // Same mechanism as `Playground.tsx`'s own identical effect: the
  // syntax theme is baked into `baseCompartment`'s own contents at
  // build time, not read live, so toggling the site's theme after
  // this block already mounted left it showing the *old* theme (and,
  // since CodeMirror's own default/dark-mode-ish chrome and this
  // project's actual Fun Web theme can clash visually, made the whole
  // block look broken/unresponsive rather than just stale-colored)
  // until a full page reload.
  useEffect(() => {
    const root = document.documentElement;
    const observer = new MutationObserver(() => {
      const nowDark = isDarkTheme();
      setDark(nowDark);
      const view = viewRef.current;
      if (view) {
        const currentView = activeViewRef.current;
        view.dispatch({
          effects: baseCompartment.current!.reconfigure(
            buildBaseFunEditorExtensions(nowDark, funEditorOptionsFor(currentView).isExternal),
          ),
        });
        // Same re-cache `setFlsReady`'s own dispatch above needs, and
        // for the identical reason: `statesRef`'s entry for this view
        // would otherwise still point at the pre-toggle state, ready
        // to silently revert this reconfigure the moment anything
        // else calls `stateFor` for the same view and applies what it
        // hands back.
        statesRef.current.set(currentView, view.state);
      }
    });
    observer.observe(root, { attributes: true, attributeFilter: ["data-theme"] });
    return () => observer.disconnect();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const isViewingStdlib = activeView !== path;

  return (
    <div className="run-block">
      <div className="run-editor">
        <div className="pg-toolbar run-toolbar">
          <span className="pg-toolbar-left">
            <button
              type="button"
              className="ghost pg-nav-button"
              disabled={!hasBack}
              onClick={() => { if (viewRef.current) goBack(viewRef.current, activeView); }}
              title="Go back (Alt+Left)"
            >
              ← Back
            </button>
            <button
              type="button"
              className="ghost pg-nav-button"
              disabled={!hasForward}
              onClick={() => { if (viewRef.current) goForward(viewRef.current, activeView); }}
              title="Go forward (Alt+Right)"
            >
              Forward →
            </button>
            {isViewingStdlib && (
              <span className="pg-active-file">
                {activeView}
                <span className="pg-readonly-badge">read-only</span>
              </span>
            )}
            {!flsReady && (
              <span className="pg-loading-badge" title="Diagnostics, hover, completion, and signature help become available once this example scrolls into view and finishes loading">
                language features load on scroll...
              </span>
            )}
          </span>
          <div className="run-actions pg-static-actions">
            <button
              onClick={copyCode}
              className="ghost"
              type="button"
              title="Copy code"
            >
              {copyStatus === "ok"
                ? "Copied"
                : copyStatus === "err"
                  ? "Copy failed"
                  : "Copy"}
            </button>
            <button onClick={resetCode} className="ghost" type="button">
              Reset
            </button>
            <button onClick={run} disabled={isRunning} type="button">
              {isRunning ? "Running..." : "Run"}
            </button>
          </div>
        </div>
        <div
          ref={hostRef}
          className={`pg-editor-host run-cm-host${isViewingStdlib ? " viewing-stdlib" : ""}`}
          aria-label={title ?? "Runnable Fun code"}
        />
      </div>
      {hasRun && (
        <div className="output-grid">
          <div>
            <div className="output-title">stdout</div>
            <pre>{stdout || "(empty)"}</pre>
          </div>
          <div>
            <div className="output-title">stderr</div>
            <pre className={stderr ? "err" : ""}>{stderr || "(empty)"}</pre>
          </div>
        </div>
      )}
    </div>
  );
}
