import { useEffect, useMemo, useRef, useState } from "react";
import { EditorState, StateField, StateEffect, type Text } from "@codemirror/state";
import {
  EditorView,
  keymap,
  lineNumbers,
  highlightActiveLine,
  hoverTooltip,
  showTooltip,
  type Tooltip,
} from "@codemirror/view";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { syntaxHighlighting, indentUnit } from "@codemirror/language";
import { linter, lintGutter, type Diagnostic as CMDiagnostic } from "@codemirror/lint";
import { autocompletion, type CompletionSource, type Completion } from "@codemirror/autocomplete";

import { funLanguage, funHighlightDark, funHighlightLight } from "../utils/funLanguage";
import {
  FunCompileError,
  runEditedCode,
  getDiagnostics,
  getHover,
  getCompletions,
  getDefinition,
  getSignatureHelp,
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

  const editorHostRef = useRef<HTMLDivElement | null>(null);
  const viewRef = useRef<EditorView | null>(null);
  const statesRef = useRef<Map<string, EditorState>>(new Map());
  const filesRef = useRef(files);
  filesRef.current = files;
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

  // Goto-definition's own target: jumps within the same file directly;
  // a different project file sets `pendingJumpRef` and switches to it
  // (the sync effect applies the position once that file's state is
  // live). A target outside the project (stdlib, say) is silently a
  // no-op - there's nowhere in this editor to show it.
  const gotoDefinition = async (view: EditorView, path: string, atPos?: number) => {
    const pos = atPos ?? view.state.selection.main.head;
    const { line, character } = posFor(view.state.doc, pos);
    const result = await getDefinition(filesRef.current, path, line, character);
    const loc = Array.isArray(result) ? result[0] : result;
    if (!loc?.uri || !loc?.range?.start) return;
    const targetPath = String(loc.uri).replace(/^file:\/\/\//, "").replace(/^\/+/, "");
    const targetLine = loc.range.start.line ?? 0;
    const targetCharacter = loc.range.start.character ?? 0;
    if (filesRef.current[targetPath] === undefined) return;
    if (targetPath === path) {
      const off = offsetFor(view.state.doc, targetLine, targetCharacter);
      view.dispatch({ selection: { anchor: off }, scrollIntoView: true });
      return;
    }
    pendingJumpRef.current = { line: targetLine, character: targetCharacter };
    setActiveFile(targetPath);
  };

  const stateFor = (path: string, content: string): EditorState => {
    const existing = statesRef.current.get(path);
    if (existing) return existing;

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
        info: contentsToText(it.documentation) || undefined,
        apply: it.insertText || it.label,
      }));
      return { from, options };
    };

    let signatureTimer: number | undefined;

    const state = EditorState.create({
      doc: content,
      extensions: [
        lineNumbers(),
        history(),
        highlightActiveLine(),
        syntaxHighlighting(isDarkTheme() ? funHighlightDark : funHighlightLight, { fallback: true }),
        funLanguage,
        indentUnit.of("  "),
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
          const { line, character } = posFor(view.state.doc, pos);
          const result = await getHover(filesRef.current, path, line, character);
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
              const dom = document.createElement("div");
              dom.className = "pg-hover-tooltip";
              const pre = document.createElement("pre");
              pre.textContent = text.replace(/^```fun\n?/, "").replace(/\n?```$/, "");
              dom.appendChild(pre);
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
        EditorView.updateListener.of((update) => {
          if (update.docChanged) {
            const text = update.state.doc.toString();
            setFiles((prev) => ({ ...prev, [path]: text }));
          }
          if (update.docChanged || update.selectionSet) {
            window.clearTimeout(signatureTimer);
            signatureTimer = window.setTimeout(async () => {
              const view = update.view;
              const pos = view.state.selection.main.head;
              const { line, character } = posFor(view.state.doc, pos);
              const result = await getSignatureHelp(filesRef.current, path, line, character);
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
      state: stateFor(activeFile, files[activeFile] ?? ""),
      parent: editorHostRef.current,
    });
    viewRef.current = view;
    return () => view.destroy();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    const view = viewRef.current;
    if (!view) return;
    const nextState = stateFor(activeFile, filesRef.current[activeFile] ?? "");
    if (view.state !== nextState) {
      view.setState(nextState);
    }
    const jump = pendingJumpRef.current;
    if (jump) {
      pendingJumpRef.current = null;
      const off = offsetFor(view.state.doc, jump.line, jump.character);
      view.dispatch({ selection: { anchor: off }, scrollIntoView: true });
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [activeFile, generation]);

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

  const addFile = () => {
    let n = 1;
    let name = "file1.fn";
    while (files[name] !== undefined) {
      n += 1;
      name = `file${n}.fn`;
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
    <div className="pg-shell">
      <div className="pg-sidebar">
        <div className="pg-sidebar-head">
          <strong>Files</strong>
          <button type="button" className="ghost pg-small" onClick={addFile}>
            + New
          </button>
        </div>
        <div className="pg-tree">
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
          <span className="pg-active-file">{activeFile}</span>
          <div className="run-actions pg-static-actions">
            <button type="button" className="ghost" onClick={resetProject}>
              Reset
            </button>
            <button type="button" onClick={run} disabled={isRunning}>
              {isRunning ? "Running..." : "Run"}
            </button>
          </div>
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

