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
  "break",
  "continue",
  "defer",
  "assert",
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

const TOKEN_REGEX = new RegExp(
  [
    "(?<comment>//.*$)",
    "(?<string>\"(?:[^\\\"\\\\]|\\\\.)*\"|'(?:[^'\\\\]|\\\\.)*')",
    "(?<number>\\b(?:0x[0-9a-fA-F]+|\\d+(?:\\.\\d+)?)\\b)",
    `(?<keyword>\\b(?:${FUN_KEYWORDS.join("|")})\\b)`,
    `(?<type>\\b(?:${FUN_BUILTIN_TYPES.join("|")}|i[1-9][0-9]*|u[1-9][0-9]*)\\b)`,
    `(?<support>\\b(?:${FUN_SUPPORT_TYPES.join("|")})\\b)`,
    "(?<boolean>\\b(?:true|false)\\b)",
  ].join("|"),
  "gm",
);

export function highlightFun(code: string): ReactNode[] {
  const nodes: ReactNode[] = [];
  let lastIndex = 0;

  for (const match of code.matchAll(TOKEN_REGEX)) {
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
