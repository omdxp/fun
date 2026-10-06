// A minimal CodeMirror 6 language mode for Fun, built as a
// `StreamLanguage` (a single-pass line tokenizer, not a full Lezer
// grammar) - enough for real syntax highlighting and bracket matching
// in the Playground's editor without maintaining a second, parallel
// grammar alongside `editors/vscode/syntaxes/fun.tmLanguage.json`. The
// keyword/builtin-type lists below are taken directly from that
// grammar so the two don't drift apart silently.
//
// Colors come from this project's own VS Code themes
// (`editors/vscode/themes/fun-web-color-theme.json`/
// `fun-web-light-color-theme.json`) - the same colors a person sees
// if they install Fun's VS Code extension and pick "Fun Web"/"Fun Web
// Light", not CodeMirror's own generic default style, so the
// Playground's editor and this project's own editor theme actually
// agree with each other.
import { StreamLanguage, HighlightStyle, type StringStream } from "@codemirror/language";
import { tags as t, Tag } from "@lezer/highlight";

const KEYWORDS = new Set([
  "use", "as", "pub", "fun", "als", "compound", "shape", "impl", "enum",
  "let", "const", "asm", "volatile", "arch", "if", "elif", "else", "fit",
  "ret", "for", "async", "await", "fork", "break", "continue", "defer",
  "assert", "panic", "test", "sequential", "fuzz", "allow", "expect",
]);

const BUILTIN_TYPES = new Set([
  "void", "raw", "num", "dec", "f32", "f64", "str", "flag", "chr",
  "size_t", "ptrdiff_t", "ssize_t", "intptr_t", "uintptr_t",
  "int8_t", "uint8_t", "int16_t", "uint16_t", "int32_t", "uint32_t",
  "int64_t", "uint64_t", "time_t", "clock_t",
]);

function isWidthType(word: string): boolean {
  return /^[iu][1-9][0-9]*$/.test(word);
}

// Distinct from `t.typeName` (a user-declared `compound`/`enum`/`shape`
// name) so each can take fun-web's own two different colors
// ("storage.type"/"support.type.primitive" vs "entity.name.type").
const builtinType = Tag.define();
const functionName = Tag.define();

type FunState = { inBlockComment: boolean };

export const funStreamParser = {
  startState(): FunState {
    return { inBlockComment: false };
  },
  token(stream: StringStream, state: FunState): string | null {
    if (state.inBlockComment) {
      if (stream.match(/^[^*]*\*\//)) {
        state.inBlockComment = false;
      } else {
        stream.skipToEnd();
      }
      return "comment";
    }
    if (stream.eatSpace()) return null;

    if (stream.match("//")) {
      stream.skipToEnd();
      return "comment";
    }
    if (stream.match("/*")) {
      state.inBlockComment = true;
      return "comment";
    }
    if (stream.match(/^"(?:[^"\\]|\\.)*"?/)) return "string";
    if (stream.match(/^'(?:[^'\\]|\\.)*'?/)) return "string";
    if (stream.match("`")) {
      stream.skipToEnd();
      return "string";
    }
    if (stream.match(/^0x[0-9a-fA-F]+/)) return "number";
    if (stream.match(/^\d+(\.\d+)?/)) return "number";

    if (stream.match(/^[A-Za-z_][A-Za-z0-9_]*/)) {
      const word = stream.current();
      if (word === "true" || word === "false") return "bool";
      if (word === "nil") return "null";
      if (KEYWORDS.has(word)) return "keyword";
      if (BUILTIN_TYPES.has(word) || isWidthType(word)) return "builtinType";
      if (/^[A-Z]/.test(word)) return "typeName";
      // A lowercase identifier directly followed by `(` (ignoring
      // whitespace) is a call or declaration - fun-web colors both the
      // same way (`entity.name.function`).
      const ahead = stream.string.slice(stream.pos).match(/^\s*\(/);
      if (ahead) return "functionName";
      return "variableName";
    }

    if (stream.match(/^[+\-*/%=<>!&|^~]+/)) return "operator";
    if (stream.match(/^[{}()\[\]]/)) return "bracket";
    if (stream.match(/^[;,.]/)) return "punctuation";

    stream.next();
    return null;
  },
  tokenTable: {
    keyword: t.keyword,
    builtinType: builtinType,
    typeName: t.typeName,
    variableName: t.variableName,
    functionName: functionName,
    string: t.string,
    number: t.number,
    comment: t.lineComment,
    bool: t.bool,
    null: t.null,
    operator: t.operator,
    bracket: t.bracket,
    punctuation: t.punctuation,
  },
};

export const funLanguage = StreamLanguage.define(funStreamParser);

// fun-web-color-theme.json's own `tokenColors`, by scope:
// source/text #E8EDFF, comment #7F8DB8, string #F1C38F, constant.numeric
// #9DE0FF, keyword #7AA2FF (bold), storage.type/support.type.primitive
// #9BDC8A, entity.name.type #B6A6FF, constant.language.{boolean,null}
// #FFB3C0, entity.name.function #A9E4FF.
export const funHighlightDark = HighlightStyle.define([
  { tag: t.keyword, color: "#7AA2FF", fontWeight: "bold" },
  { tag: builtinType, color: "#9BDC8A" },
  { tag: t.typeName, color: "#B6A6FF" },
  { tag: t.variableName, color: "#E8EDFF" },
  { tag: functionName, color: "#A9E4FF" },
  { tag: t.string, color: "#F1C38F" },
  { tag: t.number, color: "#9DE0FF" },
  { tag: t.lineComment, color: "#7F8DB8", fontStyle: "italic" },
  { tag: t.bool, color: "#FFB3C0" },
  { tag: t.null, color: "#FFB3C0" },
  { tag: t.operator, color: "#8FB3FF" },
  { tag: t.punctuation, color: "#8FB3FF" },
]);

// fun-web-light-color-theme.json's own `tokenColors`, same scopes.
export const funHighlightLight = HighlightStyle.define([
  { tag: t.keyword, color: "#2F5BD0", fontWeight: "bold" },
  { tag: builtinType, color: "#2E7D32" },
  { tag: t.typeName, color: "#6A4FD0" },
  { tag: t.variableName, color: "#1B2340" },
  { tag: functionName, color: "#1E7FA8" },
  { tag: t.string, color: "#9A5B12" },
  { tag: t.number, color: "#1F6F9E" },
  { tag: t.lineComment, color: "#6A78A0", fontStyle: "italic" },
  { tag: t.bool, color: "#C0325A" },
  { tag: t.null, color: "#C0325A" },
  { tag: t.operator, color: "#3F63C0" },
  { tag: t.punctuation, color: "#3F63C0" },
]);
