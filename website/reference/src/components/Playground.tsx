import { useEffect, useMemo, useRef, useState } from "react";
import { EditorState, StateField, StateEffect, type Text } from "@codemirror/state";
import {
  EditorView,
  keymap,
  lineNumbers,
  highlightActiveLine,
  hoverTooltip,
  showTooltip,
  Decoration,
  type DecorationSet,
  WidgetType,
  type Tooltip,
} from "@codemirror/view";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { syntaxHighlighting, indentUnit } from "@codemirror/language";
import { linter, lintGutter, type Diagnostic as CMDiagnostic } from "@codemirror/lint";
import { autocompletion, type CompletionSource, type Completion } from "@codemirror/autocomplete";

import { funLanguage, funHighlightDark, funHighlightLight, funEditorTheme } from "../utils/funLanguage";
import {
  FunCompileError,
  runEditedCode,
  getDiagnostics,
  getHover,
  getCompletions,
  getDefinition,
  getSignatureHelp,
  getInlayHints,
  warmPlaygroundRuntime,
  fetchStdlibSource,
} from "../utils/compileInBrowser";

// Fun Web/Fun Web Light (the same two editor themes this project ships
// for VS Code) rather than CodeMirror's own generic default style, so
// the Playground's colors match what the rest of the site already
// uses for every other code sample.
function isDarkTheme(): boolean {
  const explicit = document.documentElement.dataset.theme;
  if (explicit === "light") return false;
  if (explicit === "dark") return true;
  return window.matchMedia?.("(prefers-color-scheme: dark)").matches ?? true;
}

// LSP's own `CompletionItemKind` numbering (the only part of the LSP
// response shape a plain `any` doesn't self-document) mapped to
// CodeMirror's own completion `type` strings, which drive its built-in
// per-kind icon.
function completionKind(kind: number | undefined): string {
  switch (kind) {
    case 3: return "function";
    case 2: return "method";
    case 5: return "property";
    case 6: return "variable";
    case 7: return "class";
    case 8: return "interface";
    case 9: return "module";
    case 13: return "enum";
    case 20: return "enum-member";
    case 14: return "keyword";
    case 21: return "constant";
    default: return "text";
  }
}

// A hover/signature-help result's `contents` can be a plain string, a
// `{language, value}` pair, or (fls's own shape) `{kind, value}`
// markdown - every form reduces to one string either way.
function contentsToText(contents: any): string {
  if (!contents) return "";
  if (typeof contents === "string") return contents;
  if (typeof contents.value === "string") return contents.value;
  if (Array.isArray(contents)) return contents.map(contentsToText).join("\n\n");
  return "";
}

// One `textDocument/inlayHint` result rendered as CodeMirror ghost
// text - a `let`-inferred local's own real type, a call's own
// parameter name, exactly as VS Code already shows them for the same
// server. `InlayHintKind` (LSP's own numbering): 2 is a parameter
// name, anything else (1, or absent) a type.
class InlayHintWidget extends WidgetType {
  constructor(
    private readonly label: string,
    private readonly kind: number | undefined,
  ) {
    super();
  }
  eq(other: InlayHintWidget) {
    return other.label === this.label && other.kind === this.kind;
  }
  toDOM() {
    const span = document.createElement("span");
    span.className = "pg-inlay-hint" + (this.kind === 2 ? " pg-inlay-hint-param" : "");
    span.textContent = this.label;
    return span;
  }
  ignoreEvent() {
    return true;
  }
}

const setInlayHints = StateEffect.define<DecorationSet>();
const inlayHintsField = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(value, tr) {
    for (const e of tr.effects) {
      if (e.is(setInlayHints)) return e.value;
    }
    // An edit without a fresh response yet (still in flight, or this
    // file isn't the active fls session) keeps showing the last known
    // hints, remapped across the change, rather than flashing empty -
    // the same tolerance every other fls-backed feature here already
    // has for a stale-but-still-roughly-right answer.
    return value.map(tr.changes);
  },
  provide: (f) => EditorView.decorations.from(f),
});

// Inline markdown within one line/paragraph: a link (`[label](url)`,
// fls's own "See also" footer wraps the label in backticks too, which
// this strips rather than rendering literally) and a code span
// (`` `x` ``). Deliberately narrow - this only ever renders text fls
// itself generates, not arbitrary user markdown - so a small regex
// pass is enough, and building real DOM nodes (never `innerHTML`)
// keeps it safe regardless.
function appendInlineMarkdown(parent: HTMLElement, text: string, onLink: (href: string) => void) {
  const re = /\[`?([^\]]+?)`?\]\(([^)]+)\)|`([^`]+)`/g;
  let last = 0;
  let m: RegExpExecArray | null;
  while ((m = re.exec(text))) {
    if (m.index > last) parent.appendChild(document.createTextNode(text.slice(last, m.index)));
    if (m[2] !== undefined) {
      // `href`/`label` are their own `const`s, not read off `m` inside
      // the listener - `m` is one `let` reused by every loop iteration
      // (reassigned by the next `re.exec` call, `null` once the loop
      // ends), so every link's listener would otherwise close over the
      // same binding and see `null` by the time anyone actually clicks.
      const href = m[2];
      const label = m[1];
      const a = document.createElement("a");
      a.href = href;
      a.textContent = label;
      a.addEventListener("click", (e) => {
        e.preventDefault();
        onLink(href);
      });
      parent.appendChild(a);
    } else if (m[3] !== undefined) {
      const code = document.createElement("code");
      code.textContent = m[3];
      parent.appendChild(code);
    }
    last = re.lastIndex;
  }
  if (last < text.length) parent.appendChild(document.createTextNode(text.slice(last)));
}

// Renders fls's own hover/completion-doc markdown (plain paragraphs,
// fenced code blocks, a `---` rule, and the "See also" footer's
// links) as real DOM - CodeMirror's tooltips and completion `info`
// panels take a DOM node directly, not React, so this builds one by
// hand rather than pulling in a full markdown library for a handful
// of block types fls itself is the only producer of.
function renderDocMarkdown(text: string, onLink: (href: string) => void): HTMLElement {
  const root = document.createElement("div");
  root.className = "pg-md";
  const lines = text.split("\n");
  let para: string[] = [];
  const flushPara = () => {
    if (para.length === 0) return;
    const p = document.createElement("p");
    appendInlineMarkdown(p, para.join(" ").trim(), onLink);
    root.appendChild(p);
    para = [];
  };
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (/^```/.test(line)) {
      flushPara();
      const codeLines: string[] = [];
      i += 1;
      while (i < lines.length && !/^```\s*$/.test(lines[i])) {
        codeLines.push(lines[i]);
        i += 1;
      }
      i += 1;
      const pre = document.createElement("pre");
      const code = document.createElement("code");
      code.textContent = codeLines.join("\n");
      pre.appendChild(code);
      root.appendChild(pre);
      continue;
    }
    if (/^---\s*$/.test(line)) {
      flushPara();
      root.appendChild(document.createElement("hr"));
      i += 1;
      continue;
    }
    const heading = line.match(/^(#{1,6})\s+(.+)$/);
    if (heading) {
      flushPara();
      // Every level maps to the same small, bold block rather than a
      // real h1..h6 - a hover tooltip is a few hundred pixels wide at
      // most, so a doc's own `#`/`##` structure is never deep enough
      // here to need visually distinct sizes.
      const h = document.createElement("div");
      h.className = "pg-md-heading";
      appendInlineMarkdown(h, heading[2].trim(), onLink);
      root.appendChild(h);
      i += 1;
      continue;
    }
    if (/^[-*]\s+/.test(line)) {
      flushPara();
      const ul = document.createElement("ul");
      while (i < lines.length && /^[-*]\s+/.test(lines[i])) {
        const li = document.createElement("li");
        appendInlineMarkdown(li, lines[i].replace(/^[-*]\s+/, "").trim(), onLink);
        ul.appendChild(li);
        i += 1;
      }
      root.appendChild(ul);
      continue;
    }
    if (line.trim() === "") {
      flushPara();
      i += 1;
      continue;
    }
    para.push(line.trim());
    i += 1;
  }
  flushPara();
  return root;
}

type ProjectFiles = Record<string, string>;

type Sample = { title: string; code: string };

type RunOutcome = { stdout: string; stderr: string };

const FILE_MARKER_RE = /^\s*\/\/\s*file:\s*(.+?)\s*$/i;

// Mirrors `server/index.ts`'s own `parseSnippetFiles` and
// `prebake-wasm.mjs`'s copy of it - the same `// file: path` marker
// convention this project already uses to represent a multi-file
// snippet as one block of text. A sample with no marker at all is
// treated as a single file named `main.fn`.
function parseSample(code: string): { files: ProjectFiles; entry: string } {
  const lines = code.split(/\r?\n/);
  const files: ProjectFiles = {};
  let currentPath: string | null = null;
  let currentLines: string[] = [];
  let sawMarker = false;

  const flush = () => {
    if (currentPath && currentLines.length > 0) {
      files[currentPath] = currentLines.join("\n").replace(/\n+$/, "");
    }
  };

  for (const line of lines) {
    const m = line.match(FILE_MARKER_RE);
    if (m) {
      flush();
      sawMarker = true;
      currentPath = m[1].replace(/^\.?\//, "");
      currentLines = [];
      continue;
    }
    if (currentPath === null && !sawMarker) {
      currentPath = "main.fn";
    }
    currentLines.push(line);
  }
  flush();

  if (!sawMarker) {
    return { files: { "main.fn": code.trimEnd() }, entry: "main.fn" };
  }
  const entry = files["main.fn"] !== undefined ? "main.fn" : Object.keys(files)[0];
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

  // LSP positions are `{line, character}` (0-indexed); CodeMirror wants
  // a flat document offset. Clamped to the document's own current
  // length - the diagnostics call is async and debounced, so by the
  // time a response comes back the document the position was computed
  // against may already be shorter.
  const offsetFor = (doc: Text, line: number, character: number): number => {
    const clampedLine = Math.min(Math.max(line, 0), doc.lines - 1);
    const lineInfo = doc.line(clampedLine + 1);
    return Math.min(lineInfo.from + Math.max(character, 0), lineInfo.to);
  };

  const posFor = (doc: Text, offset: number): { line: number; character: number } => {
    const lineInfo = doc.lineAt(offset);
    return { line: lineInfo.number - 1, character: offset - lineInfo.from };
  };

  const severityFor = (n: number): "error" | "warning" | "info" =>
    n === 2 ? "warning" : n >= 3 ? "info" : "error";

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
  const jumpTo = async (
    view: EditorView,
    currentPath: string,
    targetPath: string,
    targetLine: number,
    targetCharacter: number,
  ) => {
    if (targetPath === currentPath) {
      const off = offsetFor(view.state.doc, targetLine, targetCharacter);
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
    pendingJumpRef.current = { line: targetLine, character: targetCharacter };
    setActiveFile(targetPath);
  };

  const gotoDefinition = async (view: EditorView, path: string, atPos?: number) => {
    const pos = atPos ?? view.state.selection.main.head;
    const { line, character } = posFor(view.state.doc, pos);
    const result = await getDefinition(filesRef.current, path, line, character, textFor(path));
    const loc = Array.isArray(result) ? result[0] : result;
    if (!loc?.uri || !loc?.range?.start) return;
    const targetPath = String(loc.uri).replace(/^file:\/\/\//, "").replace(/^\/+/, "");
    const targetLine = loc.range.start.line ?? 0;
    const targetCharacter = loc.range.start.character ?? 0;
    await jumpTo(view, path, targetPath, targetLine, targetCharacter);
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
    void jumpTo(view, currentPath, targetPath, targetLine, 0);
  };

  // Whatever's actually scrolled into view, not the whole document - a
  // long file would otherwise pay for (and show stale types for)
  // hundreds of off-screen lines every single edit. Component-level
  // rather than closed over inside `stateFor` so both an edit/scroll
  // (through the state's own updateListener) and a fresh mount/file
  // switch (no update event of its own to hook) can call the same
  // function instead of duplicating it.
  const refreshInlayHints = async (view: EditorView, path: string) => {
    if (!flsReadyRef.current) return;
    const firstLine = view.state.doc.lineAt(view.viewport.from).number - 1;
    const lastLine = view.state.doc.lineAt(view.viewport.to).number - 1;
    const hints = await getInlayHints(filesRef.current, path, firstLine, lastLine, textFor(path));
    if (!Array.isArray(hints) || hints.length === 0) {
      view.dispatch({ effects: setInlayHints.of(Decoration.none) });
      return;
    }
    const decorations = hints
      .filter((h) => h?.position)
      .map((h) => {
        const pos = offsetFor(view.state.doc, h.position.line, h.position.character);
        const label = (h.paddingLeft ? " " : "") + String(h.label) + (h.paddingRight ? " " : "");
        return Decoration.widget({ widget: new InlayHintWidget(label, h.kind), side: 1 }).range(pos);
      })
      .sort((a, b) => a.from - b.from);
    view.dispatch({ effects: setInlayHints.of(Decoration.set(decorations)) });
  };

  const stateFor = (path: string, content: string): EditorState => {
    const existing = statesRef.current.get(path);
    if (existing) return existing;

    // A stdlib reference file (see `externalFiles`' own comment) is
    // read-only display, nothing more - fls has no mounted content
    // for it to analyze (mounting it would reproduce the exact hang
    // `externalFiles` exists to avoid), so every fls-backed feature
    // below is skipped outright for it rather than firing requests
    // that would either hang or answer against the wrong document.
    const isExternal = externalFilesRef.current[path] !== undefined;

    const setSignatureTooltip = StateEffect.define<Tooltip | null>();
    const signatureTooltipField = StateField.define<Tooltip | null>({
      create: () => null,
      update(value, tr) {
        for (const e of tr.effects) {
          if (e.is(setSignatureTooltip)) return e.value;
        }
        return value;
      },
      provide: (f) => showTooltip.from(f),
    });

    const completionSource: CompletionSource = async (context) => {
      if (!flsReadyRef.current || isExternal) return null;
      const { line, character } = posFor(context.state.doc, context.pos);
      const result = await getCompletions(filesRef.current, path, line, character);
      const items = Array.isArray(result) ? result : result?.items;
      if (!Array.isArray(items) || items.length === 0) return null;
      const word = context.matchBefore(/[A-Za-z_][A-Za-z0-9_]*/);
      const from = word ? word.from : context.pos;
      const options: Completion[] = items.map((it: any) => ({
        label: it.label,
        type: completionKind(it.kind),
        detail: it.detail,
        info: () => {
          const text = contentsToText(it.documentation);
          if (!text) return null;
          const view = context.view ?? viewRef.current;
          const dom = renderDocMarkdown(text, (href) => {
            if (view) navigateToDocLink(view, path, href);
          });
          return { dom };
        },
        apply: it.insertText || it.label,
      }));
      return { from, options };
    };

    let signatureTimer: number | undefined;
    let inlayHintTimer: number | undefined;

    const state = EditorState.create({
      doc: content,
      extensions: [
        lineNumbers(),
        history(),
        highlightActiveLine(),
        syntaxHighlighting(isDarkTheme() ? funHighlightDark : funHighlightLight, { fallback: true }),
        funEditorTheme(isDarkTheme()),
        funLanguage,
        indentUnit.of("  "),
        EditorState.readOnly.of(isExternal),
        keymap.of([
          { key: "F12", run: (view) => { gotoDefinition(view, path); return true; } },
          { key: "Alt-d", run: (view) => { gotoDefinition(view, path); return true; } },
          ...defaultKeymap,
          ...historyKeymap,
          indentWithTab,
        ]),
        EditorView.lineWrapping,
        lintGutter(),
        linter(
          async (view) => {
            if (!flsReadyRef.current || isExternal) return [];
            const diags = await getDiagnostics(filesRef.current, path);
            const out: CMDiagnostic[] = [];
            for (const d of diags) {
              const from = offsetFor(view.state.doc, d.from.line, d.from.character);
              const to = Math.max(from, offsetFor(view.state.doc, d.to.line, d.to.character));
              out.push({ from, to, severity: severityFor(d.severity), message: d.message });
            }
            return out;
          },
          { delay: 600 },
        ),
        hoverTooltip(async (view, pos) => {
          if (!flsReadyRef.current) return null;
          const { line, character } = posFor(view.state.doc, pos);
          const result = await getHover(filesRef.current, path, line, character, textFor(path));
          const text = contentsToText(result?.contents);
          if (!text) return null;
          const range = result?.range;
          const from = range ? offsetFor(view.state.doc, range.start.line, range.start.character) : pos;
          const to = range ? offsetFor(view.state.doc, range.end.line, range.end.character) : pos;
          return {
            pos: from,
            end: Math.max(from, to),
            above: true,
            create: () => {
              const dom = renderDocMarkdown(text, (href) => navigateToDocLink(view, path, href));
              dom.classList.add("pg-hover-tooltip");
              return { dom };
            },
          };
        }),
        autocompletion({ override: [completionSource] }),
        // Cmd/Ctrl+click as the primary goto-definition gesture - the
        // standard one in every mainstream editor, and it sidesteps
        // `F12`'s own real-world problem: most browsers treat it as a
        // global DevTools shortcut and a page's own key handler never
        // sees it, keybinding or not.
        EditorView.domEventHandlers({
          mousedown: (event, view) => {
            if (!event.metaKey && !event.ctrlKey) return false;
            const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
            if (pos == null) return false;
            event.preventDefault();
            gotoDefinition(view, path, pos);
            return true;
          },
        }),
        signatureTooltipField,
        inlayHintsField,
        EditorView.updateListener.of((update) => {
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
          if (update.docChanged || update.selectionSet) {
            statesRef.current.set(path, update.state);
          }
          if (update.docChanged) {
            const text = update.state.doc.toString();
            setFiles((prev) => ({ ...prev, [path]: text }));
          }
          if (update.docChanged || update.selectionSet) {
            window.clearTimeout(signatureTimer);
            signatureTimer = window.setTimeout(async () => {
              if (!flsReadyRef.current) return;
              const view = update.view;
              const pos = view.state.selection.main.head;
              const { line, character } = posFor(view.state.doc, pos);
              const result = await getSignatureHelp(filesRef.current, path, line, character, textFor(path));
              const sig = result?.signatures?.[result.activeSignature ?? 0];
              if (!sig) {
                view.dispatch({ effects: setSignatureTooltip.of(null) });
                return;
              }
              view.dispatch({
                effects: setSignatureTooltip.of({
                  pos,
                  above: true,
                  create: () => {
                    const dom = document.createElement("div");
                    dom.className = "pg-signature-tooltip";
                    dom.textContent = sig.label;
                    return { dom };
                  },
                }),
              });
            }, 400);
          }
          // Re-requested on scroll too (`viewportChanged`, with no doc
          // edit), not just on edit - a file long enough to scroll
          // means the lines just scrolled into view were never in any
          // earlier request's own range.
          if (update.docChanged || update.viewportChanged) {
            window.clearTimeout(inlayHintTimer);
            inlayHintTimer = window.setTimeout(() => refreshInlayHints(update.view, path), 400);
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
    refreshInlayHints(view, activeFile);
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
          Cmd/Ctrl+click or F12 to jump to a definition &middot; hover a symbol for its docs &middot; start typing for completions
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

