import type { ReactNode } from "react";

const FUN_KEYWORDS = [
  "imp",
  "as",
  "pub",
  "fun",
  "compound",
  "quirk",
  "impl",
  "enum",
  "let",
  "asm",
  "volatile",
  "arch",
  "if",
  "elif",
  "else",
  "fit",
  "ret",
  "for",
  "async",
  "await",
  "break",
  "continue",
  "defer",
  "assert",
  "allow",
  "expect",
];

const FUN_BUILTIN_TYPES = [
  "void",
  "raw",
  "num",
  "dec",
  "f32",
  "f64",
  "str",
  "bin",
  "chr",
];

const FUN_SUPPORT_TYPES = [
  "size_t",
  "ptrdiff_t",
  "ssize_t",
  "intptr_t",
  "uintptr_t",
  "int8_t",
  "uint8_t",
  "int16_t",
  "uint16_t",
  "int32_t",
  "uint32_t",
  "int64_t",
  "uint64_t",
  "time_t",
  "clock_t",
];

const TYPE_DECL_REGEX =
  /\b(?:compound|quirk|enum|impl)\s+([A-Za-z_][A-Za-z0-9_]*)/g;
const TYPE_REF_REGEX =
  /\b([A-Z][A-Za-z0-9_]*)\b(?=\s*(?:\*+)?\s*[A-Za-z_][A-Za-z0-9_]*\b)/g;

function escapeRegExp(text: string) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function collectCustomTypeNames(code: string) {
  const out = new Set<string>();
  for (const match of code.matchAll(TYPE_DECL_REGEX)) {
    const name = match[1] ?? "";
    if (name) out.add(name);
  }
  for (const match of code.matchAll(TYPE_REF_REGEX)) {
    const name = match[1] ?? "";
    if (name) out.add(name);
  }
  return [...out];
}

const FUN_NON_FUNCTION_IDENTIFIERS = [...FUN_KEYWORDS, "true", "false"];

function buildTokenRegex(code: string) {
  const customTypeNames = collectCustomTypeNames(code);
  const escapedCustomTypeNames = customTypeNames.map(escapeRegExp);
  const customTypePattern = escapedCustomTypeNames.length
    ? `(?<customType>\\b(?:${escapedCustomTypeNames.join("|")})\\b)`
    : "(?!)";

  const nonFunctionIdentifiers = [
    ...FUN_NON_FUNCTION_IDENTIFIERS,
    ...customTypeNames,
  ];

  return new RegExp(
    [
      "(?<comment>//.*$)",
      "(?<string>\"(?:[^\\\"\\\\]|\\\\.)*\"|'(?:[^'\\\\]|\\\\.)*')",
      "(?<number>\\b(?:0x[0-9a-fA-F]+|\\d+(?:\\.\\d+)?)\\b)",
      "(?<operator>(?:->|::|\\+\\=|\\-\\=|\\*\\=|\\/\\=|\\%\\=|\\=\\=|\\!\\=|\\<\\=|\\>\\=|\\&\\&|\\|\\||\\<\\<|\\>\\>|\\+\\+|\\-\\-|[+\\-*/%=<>!&|^~.,;:]))",
      `(?<keyword>\\b(?:${FUN_KEYWORDS.join("|")})\\b)`,
      `(?<type>\\b(?:${FUN_BUILTIN_TYPES.join("|")}|i[1-9][0-9]*|u[1-9][0-9]*)\\b)`,
      `(?<support>\\b(?:${FUN_SUPPORT_TYPES.join("|")})\\b)`,
      customTypePattern,
      `(?<function>\\b(?!${nonFunctionIdentifiers.map((keyword) => `${escapeRegExp(keyword)}\\b`).join("|")})(?:[A-Za-z_][A-Za-z0-9_]*)\\b(?=\\s*\\())`,
      "(?<boolean>\\b(?:true|false)\\b)",
    ].join("|"),
    "gm",
  );
}

export function highlightFun(code: string): ReactNode[] {
  const tokenRegex = buildTokenRegex(code);
  const nodes: ReactNode[] = [];
  let lastIndex = 0;

  for (const match of code.matchAll(tokenRegex)) {
    const index = match.index ?? 0;
    if (index > lastIndex) {
      nodes.push(code.slice(lastIndex, index));
    }

    const token = match[0];
    const groups = match.groups ?? {};
    let className = "";

    if (groups.comment) className = "tok-comment";
    else if (groups.string) className = "tok-string";
    else if (groups.number) className = "tok-number";
    else if (groups.operator) className = "tok-operator";
    else if (groups.customType) className = "tok-custom-type";
    else if (groups.function) className = "tok-function";
    else if (groups.keyword) className = "tok-keyword";
    else if (groups.type) className = "tok-type";
    else if (groups.support) className = "tok-support-type";
    else if (groups.boolean) className = "tok-boolean";

    nodes.push(
      <span key={`${index}-${className}`} className={className}>
        {token}
      </span>,
    );

    lastIndex = index + token.length;
  }

  if (lastIndex < code.length) {
    nodes.push(code.slice(lastIndex));
  }

  return nodes;
}
