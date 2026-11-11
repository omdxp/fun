// Everything a fls-backed CodeMirror editor needs that isn't specific
// to *which* document it's editing - diagnostics, hover, completion,
// signature help, inlay hints, goto-definition's own click/keymap
// wiring, and the VS Code-style "hold Cmd/Ctrl, the symbol under the
// mouse underlines" affordance. `Playground.tsx` (a real multi-file
// project) and `RunCodeBlock.tsx` (one isolated snippet per runnable
// doc example) both build on this rather than each wiring the same
// requests/tooltips/decorations by hand - the fix for a real bug in
// one of these behaviors should only ever need to land once.
//
// Each caller supplies its own notion of "the files fls should see"
// and "what happens when a jump/link fires" through `FunEditorOptions`
// below; this module never reaches into React state or a project tree
// directly.

import type { Extension } from "@codemirror/state";
import { EditorState, StateField, StateEffect } from "@codemirror/state";
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
  ViewPlugin,
} from "@codemirror/view";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { syntaxHighlighting, indentUnit } from "@codemirror/language";
import { linter, lintGutter, type Diagnostic as CMDiagnostic } from "@codemirror/lint";
import { autocompletion, type CompletionSource, type Completion } from "@codemirror/autocomplete";

import { funLanguage, funHighlightDark, funHighlightLight, funEditorTheme } from "./funLanguage";
import { getDiagnostics, getHover, getCompletions, getSignatureHelp, getInlayHints } from "./compileInBrowser";

// Fun Web/Fun Web Light (the same two editor themes this project ships
// for VS Code) rather than CodeMirror's own generic default style, so
// every fls-backed editor on the site matches what the rest of it
// already uses for every other code sample.
export function isDarkTheme(): boolean {
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

function offsetFor(doc: EditorView["state"]["doc"], line: number, character: number): number {
  const clampedLine = Math.min(Math.max(line, 0), doc.lines - 1);
  const lineInfo = doc.line(clampedLine + 1);
  return Math.min(lineInfo.from + Math.max(character, 0), lineInfo.to);
}

function posFor(doc: EditorView["state"]["doc"], offset: number): { line: number; character: number } {
  const lineInfo = doc.lineAt(offset);
  return { line: lineInfo.number - 1, character: offset - lineInfo.from };
}

function severityFor(n: number): "error" | "warning" | "info" {
  return n === 2 ? "warning" : n >= 3 ? "info" : "error";
}

// VS Code's own "Cmd/Ctrl+hover underlines the symbol you're about to
// jump to" affordance - purely visual feedback that the thing under
// the mouse is clickable, no fls request of its own: `wordAt` reads
// straight off the document already in memory. Tracked at `window`
// level, not just the editor's own DOM, so releasing the modifier key
// while the mouse hasn't moved (tabbing away and back, say) still
// clears the underline the instant it comes up, the same as a real
// editor.
const setDefLinkHover = StateEffect.define<{ from: number; to: number } | null>();
const defLinkHoverField = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(value, tr) {
    for (const e of tr.effects) {
      if (e.is(setDefLinkHover)) {
        if (!e.value) return Decoration.none;
        return Decoration.set([Decoration.mark({ class: "cm-fun-def-link" }).range(e.value.from, e.value.to)]);
      }
    }
    if (tr.docChanged) return Decoration.none;
    return value;
  },
  provide: (f) => EditorView.decorations.from(f),
});

function defLinkHoverPlugin() {
  return ViewPlugin.fromClass(
    class {
      view: EditorView;
      clear = () => {
        if (this.view.state.field(defLinkHoverField).size > 0) {
          this.view.dispatch({ effects: setDefLinkHover.of(null) });
        }
      };
      onMouseMove = (event: MouseEvent) => {
        if (!(event.metaKey || event.ctrlKey)) {
          this.clear();
          return;
        }
        const rect = this.view.dom.getBoundingClientRect();
        if (
          event.clientX < rect.left ||
          event.clientX > rect.right ||
          event.clientY < rect.top ||
          event.clientY > rect.bottom
        ) {
          this.clear();
          return;
        }
        const pos = this.view.posAtCoords({ x: event.clientX, y: event.clientY });
        if (pos == null) {
          this.clear();
          return;
        }
        const word = this.view.state.wordAt(pos);
        if (!word) {
          this.clear();
          return;
        }
        this.view.dispatch({ effects: setDefLinkHover.of({ from: word.from, to: word.to }) });
      };
      onKeyUp = (event: KeyboardEvent) => {
        if (event.key === "Meta" || event.key === "Control") this.clear();
      };
      onBlur = () => this.clear();
      constructor(view: EditorView) {
        this.view = view;
        window.addEventListener("mousemove", this.onMouseMove);
        window.addEventListener("keyup", this.onKeyUp);
        window.addEventListener("blur", this.onBlur);
      }
      destroy() {
        window.removeEventListener("mousemove", this.onMouseMove);
        window.removeEventListener("keyup", this.onKeyUp);
        window.removeEventListener("blur", this.onBlur);
      }
    },
  );
}

export type FunEditorOptions = {
  // The document's own identity, as fls sees it (`file:///<path>`
  // elsewhere) - a project file's real path for `Playground.tsx`, a
  // small synthetic per-block name for `RunCodeBlock.tsx`.
  path: string;
  isDark: boolean;
  // Read-only display with every fls-backed feature below skipped
  // outright (a stdlib reference file in the Playground - mounting it
  // for real would reproduce the hang `externalFiles` exists to
  // avoid) rather than firing requests that would either hang or
  // answer against the wrong document.
  isExternal?: boolean;
  getFiles: () => Record<string, string>;
  getFlsReady: () => boolean;
  // What hover/signature-help send as `textOverride` instead of
  // `getFiles()[path]` - the one thing an external file needs (its
  // real content reaches fls through the request directly, with no
  // need for it to also exist on the mounted filesystem). Omit this
  // entirely (or return `undefined`) when `getFiles()` already mounts
  // every path a request could resolve to - `RunCodeBlock.tsx`'s own
  // case, both in and out of multi-file mode, where supplying the
  // combined editor's *whole* raw text here regardless of which
  // split file was actually resolved would silently send the wrong
  // document's content.
  getText?: () => string | undefined;
  onDocChanged?: (text: string) => void;
  onDocLink: (view: EditorView, href: string) => void;
  onGotoDefinition: (view: EditorView, pos?: number) => void;
  onGoBack?: (view: EditorView) => void;
  onGoForward?: (view: EditorView) => void;
  // A multi-file snippet (the `// file: name.fn` convention) shown as
  // one continuous editor rather than real separate tabs
  // (`RunCodeBlock.tsx`'s own case - `Playground.tsx` never sets
  // this, since each of its files already has its own independently-
  // numbered editor) - every fls request below has to name the real
  // split file a position falls in, and its *local* line within it,
  // not `path` and the combined editor's own line. `allPaths` is
  // every split file diagnostics needs to check, not just the one
  // directly under the cursor.
  multiFile?: {
    allPaths: string[];
    toLocal: (globalLine: number, globalCharacter: number) => { path: string; line: number; character: number };
    toGlobalLine: (path: string, localLine: number) => number;
  };
};

// Where a document position (as the caller's own combined editor
// numbers it) actually resolves to for fls: `path`/`line`/`character`
// unchanged for an ordinary single-file document, or the real split
// file and its own local line/character for a multi-file one.
function resolveDocPosition(
  opts: FunEditorOptions,
  line: number,
  character: number,
): { path: string; line: number; character: number } {
  if (!opts.multiFile) return { path: opts.path, line, character };
  return opts.multiFile.toLocal(line, character);
}

// Whatever's actually scrolled into view, not the whole document - a
// long file would otherwise pay for (and show stale types for)
// hundreds of off-screen lines every single edit.
async function refreshInlayHints(view: EditorView, opts: FunEditorOptions) {
  if (!opts.getFlsReady() || opts.isExternal) return;
  // A visible range can straddle more than one split file in multi-
  // file mode, each needing its own request and its own local-to-
  // global line remap - skipped outright for now rather than half-
  // implementing it; hover/completion/diagnostics/signature-help
  // (the features actually reported missing) all still fully work.
  if (opts.multiFile) return;
  const firstLine = view.state.doc.lineAt(view.viewport.from).number - 1;
  const lastLine = view.state.doc.lineAt(view.viewport.to).number - 1;
  const hints = await getInlayHints(opts.getFiles(), opts.path, firstLine, lastLine, opts.getText?.());
  if (!Array.isArray(hints) || hints.length === 0) {
    view.dispatch({ effects: setInlayHints.of(Decoration.none) });
    return;
  }
  const decorations = hints
    .filter((h: any) => h?.position)
    .map((h: any) => {
      const pos = offsetFor(view.state.doc, h.position.line, h.position.character);
      const label = (h.paddingLeft ? " " : "") + String(h.label) + (h.paddingRight ? " " : "");
      return Decoration.widget({ widget: new InlayHintWidget(label, h.kind), side: 1 }).range(pos);
    })
    .sort((a: any, b: any) => a.from - b.from);
  view.dispatch({ effects: setInlayHints.of(Decoration.set(decorations)) });
}

// The ordinary, non-fls editing basics every `FunEditorOptions`
// document needs regardless of whether fls has loaded yet (or ever
// will, for a read-only one): line numbers, undo history, the active-
// line highlight, this project's own Fun Web syntax theme, the
// language mode, two-space indent, line wrapping, and the plain
// editing keymap. Kept separate from `buildFunEditorExtensions` below
// (the fls-backed half) specifically so a caller that defers the fls
// half behind a `Compartment` - `RunCodeBlock.tsx`, mounting this
// immediately but only reconfiguring the fls half in once a block is
// actually near the viewport - never ends up with two of each: every
// one of these is a single-instance CodeMirror facet (two `lineNumbers()`
// extensions render two gutters, not one, confirmed directly), unlike
// `EditorView.updateListener`/`keymap`, which are designed to be added
// more than once and merge instead of duplicating.
export function buildBaseFunEditorExtensions(isDark: boolean, readOnly?: boolean): Extension[] {
  return [
    lineNumbers(),
    history(),
    highlightActiveLine(),
    syntaxHighlighting(isDark ? funHighlightDark : funHighlightLight, { fallback: true }),
    funEditorTheme(isDark),
    funLanguage,
    indentUnit.of("  "),
    EditorState.readOnly.of(readOnly ?? false),
    EditorView.lineWrapping,
    keymap.of([...defaultKeymap, ...historyKeymap, indentWithTab]),
  ];
}

// Every fls-backed CodeMirror extension a `FunEditorOptions` document
// needs: diagnostics, hover, completion, signature help, inlay hints,
// goto-definition (Cmd/Ctrl+click and F12/Alt-d, plus the Cmd/Ctrl+
// hover underline above), and Alt-Left/Alt-Right for whichever nav
// history the caller supplies. Pair with `buildBaseFunEditorExtensions`
// above for a complete editor - this half omits those basics
// deliberately (see that function's own comment for why), not an
// oversight.
export function buildFunEditorExtensions(opts: FunEditorOptions): Extension[] {
  let signatureTimer: number | undefined;
  let inlayHintTimer: number | undefined;

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
    if (!opts.getFlsReady() || opts.isExternal) return null;
    const { line, character } = posFor(context.state.doc, context.pos);
    const resolved = resolveDocPosition(opts, line, character);
    const result = await getCompletions(opts.getFiles(), resolved.path, resolved.line, resolved.character);
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
        const view = context.view;
        const dom = renderDocMarkdown(text, (href) => {
          if (view) opts.onDocLink(view, href);
        });
        return { dom };
      },
      apply: it.insertText || it.label,
    }));
    return { from, options };
  };

  const keys: Array<{ key: string; run: (view: EditorView) => boolean }> = [
    { key: "F12", run: (view) => { opts.onGotoDefinition(view); return true; } },
    { key: "Alt-d", run: (view) => { opts.onGotoDefinition(view); return true; } },
  ];
  if (opts.onGoBack) {
    keys.push({ key: "Alt-ArrowLeft", run: (view) => { opts.onGoBack!(view); return true; } });
  }
  if (opts.onGoForward) {
    keys.push({ key: "Alt-ArrowRight", run: (view) => { opts.onGoForward!(view); return true; } });
  }

  return [
    keymap.of(keys),
    lintGutter(),
    linter(
      async (view) => {
        if (!opts.getFlsReady() || opts.isExternal) return [];
        const out: CMDiagnostic[] = [];
        // A multi-file snippet needs one check per split file (each
        // file's own diagnostics only ever come back in that file's
        // own local line numbers), remapped to the one combined
        // editor's real lines below - not just the file the cursor
        // happens to be in, since fls might report a problem in any
        // of them.
        const targets = opts.multiFile ? opts.multiFile.allPaths : [opts.path];
        for (const target of targets) {
          const diags = await getDiagnostics(opts.getFiles(), target);
          for (const d of diags) {
            const fromLine = opts.multiFile ? opts.multiFile.toGlobalLine(target, d.from.line) : d.from.line;
            const toLine = opts.multiFile ? opts.multiFile.toGlobalLine(target, d.to.line) : d.to.line;
            const from = offsetFor(view.state.doc, fromLine, d.from.character);
            const to = Math.max(from, offsetFor(view.state.doc, toLine, d.to.character));
            out.push({ from, to, severity: severityFor(d.severity), message: d.message });
          }
        }
        return out;
      },
      { delay: 600 },
    ),
    hoverTooltip(async (view, pos) => {
      if (!opts.getFlsReady()) return null;
      const { line, character } = posFor(view.state.doc, pos);
      const resolved = resolveDocPosition(opts, line, character);
      const result = await getHover(opts.getFiles(), resolved.path, resolved.line, resolved.character, opts.getText?.());
      const text = contentsToText(result?.contents);
      if (!text) return null;
      // The response's own range is in the resolved file's local
      // line numbers when `multiFile` is set - remapped back to the
      // one combined editor's real lines before building an offset
      // from it, or the tooltip would anchor itself to the wrong
      // line entirely for any split file after the first.
      const range = result?.range;
      const from = range
        ? offsetFor(
          view.state.doc,
          opts.multiFile ? opts.multiFile.toGlobalLine(resolved.path, range.start.line) : range.start.line,
          range.start.character,
        )
        : pos;
      const to = range
        ? offsetFor(
          view.state.doc,
          opts.multiFile ? opts.multiFile.toGlobalLine(resolved.path, range.end.line) : range.end.line,
          range.end.character,
        )
        : pos;
      return {
        pos: from,
        end: Math.max(from, to),
        above: true,
        create: () => {
          const dom = renderDocMarkdown(text, (href) => opts.onDocLink(view, href));
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
        opts.onGotoDefinition(view, pos);
        return true;
      },
    }),
    defLinkHoverField,
    defLinkHoverPlugin(),
    signatureTooltipField,
    inlayHintsField,
    EditorView.updateListener.of((update) => {
      if (update.docChanged) {
        opts.onDocChanged?.(update.state.doc.toString());
      }
      if (update.docChanged || update.selectionSet) {
        window.clearTimeout(signatureTimer);
        signatureTimer = window.setTimeout(async () => {
          if (!opts.getFlsReady()) return;
          const view = update.view;
          const pos = view.state.selection.main.head;
          const { line, character } = posFor(view.state.doc, pos);
          const resolved = resolveDocPosition(opts, line, character);
          const result = await getSignatureHelp(opts.getFiles(), resolved.path, resolved.line, resolved.character, opts.getText?.());
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
      // edit), not just on edit - a file long enough to scroll means
      // the lines just scrolled into view were never in any earlier
      // request's own range.
      if (update.docChanged || update.viewportChanged) {
        window.clearTimeout(inlayHintTimer);
        inlayHintTimer = window.setTimeout(() => void refreshInlayHints(update.view, opts), 400);
      }
    }),
  ];
}

export { offsetFor, posFor, contentsToText, renderDocMarkdown, refreshInlayHints, setInlayHints };
