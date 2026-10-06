// A minimal CodeMirror 6 language mode for Fun, built as a
// `StreamLanguage` (a single-pass line tokenizer, not a full Lezer
// grammar) - enough for real syntax highlighting and bracket matching
// in the Playground's editor without maintaining a second, parallel
// grammar alongside `editors/vscode/syntaxes/fun.tmLanguage.json`. The
// keyword/builtin-type lists below are taken directly from that
// grammar so the two don't drift apart silently.
import { StreamLanguage, type StringStream } from "@codemirror/language";

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
      if (BUILTIN_TYPES.has(word) || isWidthType(word)) return "typeName";
      if (/^[A-Z]/.test(word)) return "typeName";
      return "variableName";
    }

    if (stream.match(/^[+\-*/%=<>!&|^~]+/)) return "operator";
    if (stream.match(/^[{}()\[\]]/)) return "bracket";
    if (stream.match(/^[;,.]/)) return "punctuation";

    stream.next();
    return null;
  },
};

// `StreamLanguage` already maps common legacy-mode token names
// ("keyword", "string", "number", "comment", "typeName",
// "variableName", "bool", "null", "operator", "bracket",
// "punctuation" - every name `token()` above returns) to the standard
// highlighting tags on its own; no separate `styleTags` table needed.
export const funLanguage = StreamLanguage.define(funStreamParser);
