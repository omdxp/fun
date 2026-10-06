import { useEffect, useMemo, useRef, useState } from "react";
import { EditorState, type Text } from "@codemirror/state";
import { EditorView, keymap, lineNumbers, highlightActiveLine } from "@codemirror/view";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { syntaxHighlighting, defaultHighlightStyle, indentUnit } from "@codemirror/language";
import { linter, lintGutter, type Diagnostic as CMDiagnostic } from "@codemirror/lint";

import { funLanguage } from "../utils/funLanguage";
import { FunCompileError, runEditedCode, getDiagnostics } from "../utils/compileInBrowser";

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

  const severityFor = (n: number): "error" | "warning" | "info" =>
    n === 2 ? "warning" : n >= 3 ? "info" : "error";

  const stateFor = (path: string, content: string): EditorState => {
    const existing = statesRef.current.get(path);
    if (existing) return existing;
    const state = EditorState.create({
      doc: content,
      extensions: [
        lineNumbers(),
        history(),
        highlightActiveLine(),
        syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
        funLanguage,
        indentUnit.of("  "),
        keymap.of([...defaultKeymap, ...historyKeymap, indentWithTab]),
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
        EditorView.updateListener.of((update) => {
          if (!update.docChanged) return;
          const text = update.state.doc.toString();
          setFiles((prev) => ({ ...prev, [path]: text }));
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
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [activeFile, generation]);

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

