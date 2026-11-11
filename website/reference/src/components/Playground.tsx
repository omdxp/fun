import { useEffect, useMemo, useRef, useState } from "react";
import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";

import {
  FunCompileError,
  runEditedCode,
  parseSnippetFiles,
  getDefinition,
  warmPlaygroundRuntime,
  fetchStdlibSource,
} from "../utils/compileInBrowser";
import {
  isDarkTheme,
  buildBaseFunEditorExtensions,
  buildFunEditorExtensions,
  offsetFor,
  posFor,
  refreshInlayHints,
  type FunEditorOptions,
} from "../utils/funEditorExtensions";

type ProjectFiles = Record<string, string>;

type Sample = { title: string; code: string };

type RunOutcome = { stdout: string; stderr: string };

// `parseSnippetFiles` (compileInBrowser.ts) already does the real
// splitting work, shared with `RunCodeBlock.tsx`; this just drops the
// `fileRanges` it also returns, which only a single-editor runnable
// example (not a real multi-tab project like this one) ever needs.
function parseSample(code: string): { files: ProjectFiles; entry: string } {
  const { files, entry } = parseSnippetFiles(code);
  return { files, entry };
}

const DEFAULT_FILES: ProjectFiles = {
  "main.fn": `use std.io;\n\nfun main() {\n  print("hello from the playground");\n}\n`,
};

type TreeNode = { name: string; path: string; isFile: boolean; children: TreeNode[] };

function buildTree(paths: string[]): TreeNode[] {
  const root: TreeNode[] = [];
  for (const path of paths) {
    const parts = path.split("/");
    let level = root;
    let acc = "";
    parts.forEach((part, i) => {
      acc = acc ? `${acc}/${part}` : part;
      const isFile = i === parts.length - 1;
      let node = level.find((n) => n.name === part && n.isFile === isFile);
      if (!node) {
        node = { name: part, path: acc, isFile, children: [] };
        level.push(node);
      }
      level = node.children;
    });
  }
  const sortTree = (nodes: TreeNode[]) => {
    nodes.sort((a, b) => Number(a.isFile) - Number(b.isFile) || a.name.localeCompare(b.name));
    for (const n of nodes) sortTree(n.children);
  };
  sortTree(root);
  return root;
}

function FileTree({
  nodes,
  activeFile,
  entry,
  onSelect,
  onSetEntry,
  onDelete,
  depth = 0,
}: {
  nodes: TreeNode[];
  activeFile: string;
  entry: string;
  onSelect: (path: string) => void;
  onSetEntry: (path: string) => void;
  onDelete: (path: string) => void;
  depth?: number;
}) {
  return (
    <>
      {nodes.map((node) => (
        <div key={node.path}>
          <div
            className={`pg-tree-row${node.isFile && node.path === activeFile ? " active" : ""}`}
            style={{ paddingLeft: 10 + depth * 14 }}
            onClick={() => node.isFile && onSelect(node.path)}
          >
            <span className="pg-tree-name">
              {node.isFile ? "" : "\u{1F4C1} "}
              {node.name}
              {node.isFile && node.path === entry ? " ★" : ""}
            </span>
            {node.isFile && (
              <span className="pg-tree-actions">
                {node.path !== entry && (
                  <button
                    type="button"
                    className="pg-tree-btn"
                    title="Set as entry point"
                    onClick={(e) => {
                      e.stopPropagation();
                      onSetEntry(node.path);
                    }}
                  >
                    entry
                  </button>
                )}
                <button
                  type="button"
                  className="pg-tree-btn"
                  title="Delete file"
                  onClick={(e) => {
                    e.stopPropagation();
                    onDelete(node.path);
                  }}
                >
                  &times;
                </button>
              </span>
            )}
          </div>
          {node.children.length > 0 && (
            <FileTree
              nodes={node.children}
              activeFile={activeFile}
              entry={entry}
              onSelect={onSelect}
              onSetEntry={onSetEntry}
              onDelete={onDelete}
              depth={depth + 1}
            />
          )}
        </div>
      ))}
    </>
  );
}

export default function Playground({ samples }: { samples: Sample[] }) {
  const [files, setFiles] = useState<ProjectFiles>(DEFAULT_FILES);
  const [entry, setEntry] = useState("main.fn");
  const [activeFile, setActiveFile] = useState("main.fn");
  // Bumped whenever the whole project is replaced wholesale (a sample
  // load, a reset) - `activeFile` alone isn't a reliable signal for
  // "the editor needs to re-sync," since a new project can keep the
  // same active filename (every sample's entry is `main.fn`) while its
  // *content* is entirely different; without this the view effect
  // below never re-fires and keeps showing the old file's stale text.
  const [generation, setGeneration] = useState(0);
  const [stdout, setStdout] = useState("");
  const [stderr, setStderr] = useState("");
  const [isRunning, setIsRunning] = useState(false);
  const [hasRun, setHasRun] = useState(false);
  // Gates the live-as-you-type fls features (diagnostics, hover,
  // completion, signature help): false until `wasm_fls_main`'s own
  // assets are confirmed fetched at least once. Each extension checks
  // `flsReadyRef` (not this state directly - they're created once per
  // file and cached, so a plain closure over `flsReady` would freeze
  // whatever its value was at that moment) and returns nothing rather
  // than attempting a session while this is still false, so the very
  // first real session a person triggers isn't also racing a cold
  // download of the module it needs.
  const [flsReady, setFlsReady] = useState(false);
  const flsReadyRef = useRef(false);

  // Stdlib reference source, fetched on demand when a goto-definition/
  // doc-link jump lands outside the person's own project
  // (`fetchStdlibSource`) - deliberately its OWN store, never merged
  // into `files`. `files` is what gets mounted into the wasm fls
  // sandbox for every feature call (`mountProjectFiles`) - but the
  // sandbox's own `--preload-file` package already owns every one of
  // these exact paths (that's how `use std.*` resolves at all), and
  // mounting a second, different file at a path the preload package
  // is about to create throws inside its own (uncaught) mount step,
  // which never recovers: `removeRunDependency` for that package never
  // runs, so the module's run-dependency count never reaches zero and
  // the ENTIRE session hangs - confirmed directly against the real
  // generated `wasm_fls_main.js`, not theoretical, and not limited to
  // the stdlib file itself: every later fls call for ANY file remounts
  // the same now-colliding `files` map, so one visited stdlib symbol
  // silently breaks hover/completion/signature-help/diagnostics
  // project-wide until the page reloads. Shown read-only (`stateFor`
  // below) and skipped entirely by every fls-backed extension (same
  // functions, each checked against `externalFilesRef` first) - a
  // reference-only file has nothing for fls to analyze anyway. Read
  // via `externalFilesRef` inside closures created once per file and
  // cached, the same reason `flsReadyRef` mirrors `flsReady`.
  const [externalFiles, setExternalFiles] = useState<Record<string, string>>({});
  const externalFilesRef = useRef(externalFiles);
  externalFilesRef.current = externalFiles;

  const editorHostRef = useRef<HTMLDivElement | null>(null);
  const viewRef = useRef<EditorView | null>(null);
  const statesRef = useRef<Map<string, EditorState>>(new Map());
  const filesRef = useRef(files);
  filesRef.current = files;

  // `path`'s own current text regardless of which store it lives in -
  // a project file (`files`) or a stdlib reference one (`externalFiles`,
  // never mounted; see that state's own comment). What every fls call
  // below sends as `textOverride` so a reference file's own hover/
  // goto-definition/signature-help/inlay-hints still have real content
  // to analyze, without ever mounting it at the path that collides.
  const textFor = (path: string): string =>
    filesRef.current[path] ?? externalFilesRef.current[path] ?? "";

  // Every position a jump left behind, most recent last - what "Go
  // back" (`goBack` below) pops from. User-reported: jumping from one
  // stdlib reference file to another had no way back at all, since an
  // external file never appears in the project tree to click back to
  // (deliberately - see `externalFiles`' own comment) and there was no
  // navigation stack of any kind, for project files either. A plain
  // ref, not state: the stack's own contents never need to drive a
  // render, only `hasBack` (below) does, kept in sync on every push/
  // pop for the toolbar button's own enabled state.
  const navHistoryRef = useRef<{ path: string; line: number; character: number }[]>([]);
  const NAV_HISTORY_LIMIT = 50;
  const [hasBack, setHasBack] = useState(false);

  // Every position "Go back" moved away from, most recent last - what
  // "Go forward" (`goForward` below) pops from, the standard back/
  // forward pairing every browser/IDE history already gives: going
  // back then forward again lands exactly where "back" left from. A
  // fresh jump through `jumpTo` (anything other than "Go forward"
  // itself) clears this, the same "new navigation discards whatever
  // was ahead" rule that pairing already follows elsewhere.
  const forwardHistoryRef = useRef<{ path: string; line: number; character: number }[]>([]);
  const [hasForward, setHasForward] = useState(false);

  useEffect(() => {
    let cancelled = false;
    warmPlaygroundRuntime().flsReady.then(() => {
      if (cancelled) return;
      flsReadyRef.current = true;
      setFlsReady(true);
    });
    return () => {
      cancelled = true;
    };
  }, []);
  // Set by a goto-definition jump that lands on a *different* file -
  // the active-file sync effect applies it (moving the cursor there)
  // right after it swaps in that file's freshly-created state, then
  // clears it. A same-file jump never touches this; it moves the
  // cursor directly, no file switch involved.
  const pendingJumpRef = useRef<{ line: number; character: number } | null>(null);

  const tree = useMemo(() => buildTree(Object.keys(files)), [files]);

  // Shared by `gotoDefinition` and `navigateToDocLink`: jumps within
  // the same file directly; a different project file sets
  // `pendingJumpRef` and switches to it (the sync effect applies the
  // position once that file's state is live). A target outside the
  // project entirely (a `stdlib/std/io.fn`, say - never written by the
  // person, so never in `files`) is fetched once into `externalFiles`
  // (never `files` - see that state's own comment for why) from the
  // site's own static copy of the real stdlib tree
  // (`fetchStdlibSource`, `prebake-stdlib-src.mjs`), so there's
  // somewhere to actually show it rather than a silent no-op. Any
  // other target outside the project (nothing recognized as `stdlib/`)
  // is still a no-op - there's no source for it to fetch.
  // `fromLine`/`fromCharacter` is the position the jump was actually
  // invoked *from* - the caller's own job to capture, at the moment
  // the jump was triggered, not re-derived here from `view.state.
  // selection.main.head`. That distinction is real, not defensive:
  // every caller (`gotoDefinition` chief among them) awaits an async
  // fls round-trip between reading the trigger position and calling
  // this function, and a Cmd/Ctrl+click's own `event.preventDefault()`
  // deliberately stops the browser from ever moving the live selection
  // to the clicked spot - so by the time this runs, `main.head` is
  // wherever the cursor was sitting *before* that click, not where the
  // reader actually clicked. Pushing that stale position onto history
  // used to mean "Back" after a jump never actually returned to the
  // real click site.
  const jumpTo = async (
    view: EditorView,
    currentPath: string,
    fromLine: number,
    fromCharacter: number,
    targetPath: string,
    targetLine: number,
    targetCharacter: number,
  ) => {
    // Pushed only once the jump is actually about to happen - an
    // unrecognized target below returns before this, and a dead entry
    // that just bounces back to the same spot isn't worth leaving on
    // the stack.
    const pushHistory = () => {
      navHistoryRef.current.push({ path: currentPath, line: fromLine, character: fromCharacter });
      if (navHistoryRef.current.length > NAV_HISTORY_LIMIT) {
        navHistoryRef.current.shift();
      }
      setHasBack(true);
      // A fresh jump discards whatever "Go forward" could have
      // returned to - `goForward` itself never reaches this function
      // (it moves the view directly, the same way `goBack` already
      // does), so every call here really is a *new* branch of
      // navigation, not a replay of one "Go back" already visited.
      if (forwardHistoryRef.current.length > 0) {
        forwardHistoryRef.current = [];
        setHasForward(false);
      }
    };
    if (targetPath === currentPath) {
      const off = offsetFor(view.state.doc, targetLine, targetCharacter);
      const fromOff = offsetFor(view.state.doc, fromLine, fromCharacter);
      // Goto-definition invoked while already standing on the
      // definition itself (or invoked twice in a row without moving)
      // resolves to this exact spot - nothing to jump to, and
      // nothing worth remembering: pushing history anyway would leave
      // a dead "Back" entry that just bounces right back to here.
      if (off === fromOff) {
        return;
      }
      pushHistory();
      // `scrollIntoView: true` only scrolls the minimum distance needed -
      // a jump landing just past the bottom edge of the viewport stays
      // pinned there instead of settling in view the way a real editor's
      // goto-definition does. Centering it is what `EditorView.
      // scrollIntoView`'s own `y: "center"` effect is for.
      view.dispatch({
        selection: { anchor: off },
        effects: EditorView.scrollIntoView(off, { y: "center" }),
      });
      view.focus();
      return;
    }
    if (filesRef.current[targetPath] === undefined && externalFilesRef.current[targetPath] === undefined) {
      if (!targetPath.startsWith("stdlib/")) return;
      const content = await fetchStdlibSource(targetPath.slice("stdlib/".length));
      if (content == null) return;
      setExternalFiles((prev) => (prev[targetPath] !== undefined ? prev : { ...prev, [targetPath]: content }));
    }
    pushHistory();
    pendingJumpRef.current = { line: targetLine, character: targetCharacter };
    setActiveFile(targetPath);
  };

  // Pops the most recent position a jump left behind (`navHistoryRef`,
  // pushed by `jumpTo`) and returns there - "Go back", the standard
  // mental model for undoing a goto-definition chain every mainstream
  // editor has, which this Playground had none of at all: a stdlib
  // reference file especially has nowhere else to return to, since it
  // never appears in the project tree (see `externalFiles`' own
  // comment) - the only way back to one is this stack.
  //
  // Where we are *right now*, snapshotted once before any popping
  // below, is pushed onto `forwardHistoryRef` so "Go forward" can
  // return here afterward - but only once per call, when a hop
  // actually lands somewhere, not once per stale project-file skip
  // (several deleted files in a row would otherwise leave several
  // bogus forward entries for what's really just one move).
  const goBack = (view: EditorView, currentPath: string) => {
    const from = posFor(view.state.doc, view.state.selection.main.head);
    let forwardPushed = false;
    const pushForwardOnce = () => {
      if (forwardPushed) return;
      forwardPushed = true;
      forwardHistoryRef.current.push({ path: currentPath, line: from.line, character: from.character });
      setHasForward(true);
    };
    const step = () => {
      const prev = navHistoryRef.current.pop();
      setHasBack(navHistoryRef.current.length > 0);
      if (!prev) return;
      if (prev.path === currentPath) {
        pushForwardOnce();
        const off = offsetFor(view.state.doc, prev.line, prev.character);
        view.dispatch({
          selection: { anchor: off },
          effects: EditorView.scrollIntoView(off, { y: "center" }),
        });
        view.focus();
        return;
      }
      if (filesRef.current[prev.path] === undefined && externalFilesRef.current[prev.path] === undefined) {
        // Gone - a project file the person deleted since. Nothing to
        // return to; try the entry before it instead.
        step();
        return;
      }
      pushForwardOnce();
      pendingJumpRef.current = { line: prev.line, character: prev.character };
      setActiveFile(prev.path);
    };
    step();
  };

  // The mirror image of `goBack`: pops the most recent position "Go
  // back" moved away from (`forwardHistoryRef`) and returns there,
  // pushing where we are now back onto `navHistoryRef` so "Go back"
  // still works afterward - the same back/forward pairing every
  // browser/IDE history already gives. Deliberately does not go
  // through `jumpTo` (which would clear this very stack, reading a
  // "forward" hop as a brand-new branch of navigation instead of a
  // replay of one "Go back" already visited).
  const goForward = (view: EditorView, currentPath: string) => {
    const from = posFor(view.state.doc, view.state.selection.main.head);
    let backPushed = false;
    const pushBackOnce = () => {
      if (backPushed) return;
      backPushed = true;
      navHistoryRef.current.push({ path: currentPath, line: from.line, character: from.character });
      if (navHistoryRef.current.length > NAV_HISTORY_LIMIT) {
        navHistoryRef.current.shift();
      }
      setHasBack(true);
    };
    const step = () => {
      const next = forwardHistoryRef.current.pop();
      setHasForward(forwardHistoryRef.current.length > 0);
      if (!next) return;
      if (next.path === currentPath) {
        pushBackOnce();
        const off = offsetFor(view.state.doc, next.line, next.character);
        view.dispatch({
          selection: { anchor: off },
          effects: EditorView.scrollIntoView(off, { y: "center" }),
        });
        view.focus();
        return;
      }
      if (filesRef.current[next.path] === undefined && externalFilesRef.current[next.path] === undefined) {
        // Gone - same recovery as `goBack`'s own identical case.
        step();
        return;
      }
      pushBackOnce();
      pendingJumpRef.current = { line: next.line, character: next.character };
      setActiveFile(next.path);
    };
    step();
  };

  const gotoDefinition = async (view: EditorView, path: string, atPos?: number) => {
    // Captured now, before the `await` below - see `jumpTo`'s own
    // comment on why re-reading `view.state.selection.main.head` once
    // the fls round-trip finishes instead would silently drift from
    // where this was actually invoked.
    const pos = atPos ?? view.state.selection.main.head;
    const { line, character } = posFor(view.state.doc, pos);
    const result = await getDefinition(filesRef.current, path, line, character, textFor(path));
    const loc = Array.isArray(result) ? result[0] : result;
    if (!loc?.uri || !loc?.range?.start) return;
    const targetPath = String(loc.uri).replace(/^file:\/\/\//, "").replace(/^\/+/, "");
    const targetLine = loc.range.start.line ?? 0;
    const targetCharacter = loc.range.start.character ?? 0;
    await jumpTo(view, path, line, character, targetPath, targetLine, targetCharacter);
  };

  // A hover/completion doc's own "See also" link (`file:///path#L3`,
  // built by `_see_also_footer` in `navigation.fn`) already names its
  // target directly - no `getDefinition` round-trip needed, just the
  // same jump `gotoDefinition` uses. `#L3` is 1-indexed (a GitHub-style
  // anchor, matching `td.pos.line`'s own convention), so it's
  // converted to 0-indexed before use here.
  const navigateToDocLink = (view: EditorView, currentPath: string, href: string) => {
    const m = href.match(/^file:\/\/\/(.+?)(?:#L(\d+))?$/);
    if (!m) return;
    const targetPath = decodeURIComponent(m[1]);
    const targetLine = m[2] ? Math.max(0, parseInt(m[2], 10) - 1) : 0;
    const from = posFor(view.state.doc, view.state.selection.main.head);
    void jumpTo(view, currentPath, from.line, from.character, targetPath, targetLine, 0);
  };

  // Every option `buildFunEditorExtensions` (and `refreshInlayHints`,
  // called directly on mount/file-switch below) needs for `path` -
  // one place building it so `stateFor` and the mount effect can't
  // drift apart on what "this document, as fls sees it" means.
  const funEditorOptionsFor = (path: string): FunEditorOptions => ({
    path,
    isDark: isDarkTheme(),
    isExternal: externalFilesRef.current[path] !== undefined,
    getFiles: () => filesRef.current,
    getFlsReady: () => flsReadyRef.current,
    getText: () => textFor(path),
    onDocChanged: (text) => setFiles((prev) => ({ ...prev, [path]: text })),
    onDocLink: (view, href) => navigateToDocLink(view, path, href),
    onGotoDefinition: (view, pos) => { void gotoDefinition(view, path, pos); },
    onGoBack: (view) => goBack(view, path),
    onGoForward: (view) => goForward(view, path),
  });

  const stateFor = (path: string, content: string): EditorState => {
    const existing = statesRef.current.get(path);
    if (existing) return existing;

    const opts = funEditorOptionsFor(path);
    const state = EditorState.create({
      doc: content,
      extensions: [
        ...buildBaseFunEditorExtensions(opts.isDark, opts.isExternal),
        ...buildFunEditorExtensions(opts),
        // `stateFor` caches one `EditorState` per path and reuses it
        // unconditionally on every later visit to that file (so undo
        // history/selection survive a switch away and back) - but a
        // transaction produces a brand new, immutable `EditorState`
        // object each time, so without re-caching it here, every
        // live edit effectively vanishes the moment the user leaves
        // the file: switching back resurrects the *original*,
        // pre-edit object instead. Confirmed directly as a real,
        // severe, pre-existing bug - `files` (the React-visible copy
        // used for compiling/saving) stayed correct the whole time,
        // only the editor's own cached state silently reverted.
        EditorView.updateListener.of((update) => {
          if (update.docChanged || update.selectionSet) {
            statesRef.current.set(path, update.state);
          }
        }),
      ],
    });
    statesRef.current.set(path, state);
    return state;
  };

  // One real CodeMirror view, reused across files - switching the
  // active file swaps in that file's own `EditorState` (so each file
  // keeps its own undo history and selection) rather than tearing the
  // view down and rebuilding it, which would lose both.
  useEffect(() => {
    if (!editorHostRef.current) return;
    const view = new EditorView({
      state: stateFor(activeFile, files[activeFile] ?? externalFiles[activeFile] ?? ""),
      parent: editorHostRef.current,
    });
    viewRef.current = view;
    return () => view.destroy();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    const view = viewRef.current;
    if (!view) return;
    const nextState = stateFor(activeFile, filesRef.current[activeFile] ?? externalFilesRef.current[activeFile] ?? "");
    if (view.state !== nextState) {
      view.setState(nextState);
    }
    const jump = pendingJumpRef.current;
    if (jump) {
      pendingJumpRef.current = null;
      const off = offsetFor(view.state.doc, jump.line, jump.character);
      // Same centering as the same-file jump above (`jumpTo`) - this is
      // the cross-file half, applied once the target file's own state
      // is live.
      view.dispatch({
        selection: { anchor: off },
        effects: EditorView.scrollIntoView(off, { y: "center" }),
      });
      view.focus();
    }
    // A freshly created/restored state has no inlay hints of its own
    // yet - nothing dispatches an update here, so without this a newly
    // opened or switched-to file would stay blank until the next edit
    // or scroll.
    void refreshInlayHints(view, funEditorOptionsFor(activeFile));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [activeFile, generation, flsReady]);

  // The dark/light Fun Web highlight style is baked into each file's
  // `EditorState` at creation time (no reconfigurable compartment -
  // every state would need its own anyway, since each file keeps its
  // own cached state). A theme toggle instead just drops every cached
  // state and bumps `generation`, so the active file's state is
  // rebuilt with the now-current theme on the next render - the same
  // small undo-history cost `loadSample`/`resetProject` already pay.
  useEffect(() => {
    const root = document.documentElement;
    const observer = new MutationObserver(() => {
      statesRef.current.clear();
      setGeneration((g) => g + 1);
    });
    observer.observe(root, { attributes: true, attributeFilter: ["data-theme"] });
    return () => observer.disconnect();
  }, []);

  // A CSS-only "maximized" overlay (`.pg-shell.pg-fullscreen`, fixed
  // over the whole viewport) rather than the real Fullscreen API -
  // that API needs a user-gesture-chained permission that an embedded
  // doc-site iframe/sandbox isn't guaranteed to have, and this gives
  // the same "more room to work" outcome without any of that.
  const [isFullscreen, setIsFullscreen] = useState(false);
  useEffect(() => {
    if (!isFullscreen) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setIsFullscreen(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [isFullscreen]);

  // "+ New" asks for a name instead of silently picking `file1.fn`,
  // `file2.fn`, ... - a nested path (`sub/dir/name.fn`) works too,
  // since `FileTree`/`buildTree` already group files by `/`.
  const [creatingFile, setCreatingFile] = useState(false);
  const [newFileDraft, setNewFileDraft] = useState("");
  const newFileInputRef = useRef<HTMLInputElement | null>(null);

  useEffect(() => {
    if (creatingFile) newFileInputRef.current?.focus();
  }, [creatingFile]);

  // Takes the raw name directly rather than reading `newFileDraft` off
  // the closure - `onKeyDown`'s Escape branch clears the input and
  // blurs it in the same synchronous tick, before React has a chance
  // to re-render with the cleared state, so a closure-captured
  // `newFileDraft` would still see the old, about-to-be-discarded
  // text at the moment `onBlur` actually fires.
  const confirmAddFile = (rawName: string) => {
    let name = rawName.trim().replace(/^\/+/, "");
    setCreatingFile(false);
    if (!name) return;
    if (!/\.fn$/i.test(name)) name += ".fn";
    if (files[name] !== undefined) {
      // Already exists - treat it as "go to" rather than silently
      // discarding what was typed.
      setActiveFile(name);
      return;
    }
    setFiles((prev) => ({ ...prev, [name]: "" }));
    statesRef.current.delete(name);
    setActiveFile(name);
  };

  const deleteFile = (path: string) => {
    if (Object.keys(files).length <= 1) return;
    setFiles((prev) => {
      const next = { ...prev };
      delete next[path];
      return next;
    });
    statesRef.current.delete(path);
    if (entry === path) {
      const remaining = Object.keys(files).filter((p) => p !== path);
      setEntry(remaining[0]);
    }
    if (activeFile === path) {
      const remaining = Object.keys(files).filter((p) => p !== path);
      setActiveFile(remaining[0]);
    }
  };

  const loadSample = (sample: Sample) => {
    const { files: sampleFiles, entry: sampleEntry } = parseSample(sample.code);
    setFiles(sampleFiles);
    setEntry(sampleEntry);
    setActiveFile(sampleEntry);
    setExternalFiles({});
    navHistoryRef.current = [];
    setHasBack(false);
    forwardHistoryRef.current = [];
    setHasForward(false);
    statesRef.current.clear();
    setGeneration((g) => g + 1);
    setHasRun(false);
    setStdout("");
    setStderr("");
  };

  const resetProject = () => {
    setFiles(DEFAULT_FILES);
    setEntry("main.fn");
    setActiveFile("main.fn");
    setExternalFiles({});
    navHistoryRef.current = [];
    setHasBack(false);
    forwardHistoryRef.current = [];
    setHasForward(false);
    statesRef.current.clear();
    setGeneration((g) => g + 1);
    setHasRun(false);
    setStdout("");
    setStderr("");
  };

  const run = async () => {
    setIsRunning(true);
    setHasRun(true);
    setStdout("");
    setStderr("");
    try {
      const outcome: RunOutcome = await runEditedCode(filesRef.current, entry);
      setStdout(outcome.stdout);
      setStderr(outcome.stderr);
    } catch (e) {
      if (e instanceof FunCompileError) {
        setStderr(e.message);
      } else {
        setStderr(
          (e as any)?.message ??
            "Could not run this in your browser. Run the site locally, or try again.",
        );
      }
    } finally {
      setIsRunning(false);
    }
  };

  return (
    <div className={`pg-shell${isFullscreen ? " pg-fullscreen" : ""}`}>
      <div className="pg-sidebar">
        <div className="pg-sidebar-head">
          <strong>Files</strong>
          <button type="button" className="ghost pg-small" onClick={() => setCreatingFile(true)}>
            + New
          </button>
        </div>
        <div className="pg-tree">
          {creatingFile && (
            <div className="pg-tree-row pg-tree-new">
              <input
                ref={newFileInputRef}
                className="pg-tree-new-input"
                value={newFileDraft}
                placeholder="name.fn"
                onChange={(e) => setNewFileDraft(e.target.value)}
                onBlur={(e) => confirmAddFile(e.target.value)}
                onKeyDown={(e) => {
                  // Both branches blur rather than confirming directly -
                  // `onBlur` is the single place that actually commits,
                  // so Enter can't double-create a file by firing both
                  // its own handler and the blur that follows it. Escape
                  // clears the input's own live value (not just React
                  // state) before blurring, since `onBlur` reads that
                  // live value directly.
                  const input = e.target as HTMLInputElement;
                  if (e.key === "Enter") {
                    input.blur();
                  } else if (e.key === "Escape") {
                    input.value = "";
                    input.blur();
                  }
                }}
              />
            </div>
          )}
          <FileTree
            nodes={tree}
            activeFile={activeFile}
            entry={entry}
            onSelect={setActiveFile}
            onSetEntry={setEntry}
            onDelete={deleteFile}
          />
        </div>
        {samples.length > 0 && (
          <div className="pg-samples">
            <div className="pg-sidebar-head">
              <strong>Samples</strong>
            </div>
            <div className="pg-sample-list">
              {samples.map((s) => (
                <button
                  type="button"
                  key={s.title}
                  className="pg-sample-item"
                  onClick={() => loadSample(s)}
                  title={s.title}
                >
                  {s.title}
                </button>
              ))}
            </div>
          </div>
        )}
      </div>
      <div className="pg-main">
        <div className="pg-toolbar">
          <span className="pg-toolbar-left">
            {
              // Always present, just disabled with nothing to go to -
              // VS Code's own back/forward pair never pops in or out
              // of its toolbar either, so clicking through several
              // jumps doesn't also shift everything else in this row
              // sideways each time.
            }
            <button
              type="button"
              className="ghost pg-nav-button"
              disabled={!hasBack}
              onClick={() => {
                if (viewRef.current) goBack(viewRef.current, activeFile);
              }}
              title="Go back (Alt+Left)"
            >
              ← Back
            </button>
            <button
              type="button"
              className="ghost pg-nav-button"
              disabled={!hasForward}
              onClick={() => {
                if (viewRef.current) goForward(viewRef.current, activeFile);
              }}
              title="Go forward (Alt+Right)"
            >
              Forward →
            </button>
            <span className="pg-active-file">
              {activeFile}
              {externalFiles[activeFile] !== undefined && (
                <span className="pg-readonly-badge">read-only</span>
              )}
              {!flsReady && (
                <span className="pg-loading-badge" title="Diagnostics, hover, completion, and signature help become available once this finishes loading">
                  loading language features...
                </span>
              )}
            </span>
          </span>
          <div className="run-actions pg-static-actions">
            <button
              type="button"
              className="ghost"
              onClick={() => setIsFullscreen((v) => !v)}
              title={isFullscreen ? "Exit full screen (Esc)" : "Full screen"}
            >
              {isFullscreen ? "Exit full screen" : "Full screen"}
            </button>
            <button type="button" className="ghost" onClick={resetProject}>
              Reset
            </button>
            <button type="button" onClick={run} disabled={isRunning}>
              {isRunning ? "Running..." : "Run"}
            </button>
          </div>
        </div>
        <div className="pg-hint">
          Cmd/Ctrl+click or F12 to jump to a definition, Alt+Left/Alt+Right to go back/forward &middot; hold Cmd/Ctrl and hover a symbol to see it's jumpable &middot; hover a symbol for its docs &middot; start typing for completions
        </div>
        <div ref={editorHostRef} className="pg-editor-host" />
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
    </div>
  );
}

