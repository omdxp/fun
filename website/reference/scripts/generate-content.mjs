import { fileURLToPath } from "node:url";
import fs from "node:fs/promises";
import path from "node:path";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, "../..", "..");
const siteRoot = path.resolve(__dirname, "..");

function parseFunVersion(zon) {
  const m = zon.match(/\.version\s*=\s*"([^"]+)"/);
  if (!m) return "0.0.0";
  return m[1];
}

const zonRaw = await fs.readFile(path.join(repoRoot, "build.zig.zon"), "utf8");
const rawFunVersion = process.env.FUN_VERSION || parseFunVersion(zonRaw);
const funVersion = rawFunVersion.startsWith("v")
  ? rawFunVersion.slice(1)
  : rawFunVersion;

const publicVersionsRoot = path.join(siteRoot, "public", "versions");

const docs = {
  language: await fs.readFile(path.join(repoRoot, "docs/language.md"), "utf8"),
  reference: await fs.readFile(
    path.join(repoRoot, "docs/reference.md"),
    "utf8",
  ),
  stdlibReadme: await fs.readFile(
    path.join(repoRoot, "stdlib/README.md"),
    "utf8",
  ),
};

const stdRoot = path.join(repoRoot, "stdlib/std");

async function walk(dir) {
  const entries = await fs.readdir(dir, { withFileTypes: true });
  const out = [];
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      out.push(...(await walk(full)));
    } else if (entry.isFile() && entry.name.endsWith(".fn")) {
      out.push(full);
    }
  }
  return out;
}

function parseStdFile(filePath, source) {
  const rel = path.relative(stdRoot, filePath).replaceAll("\\", "/");
  const lines = source.split(/\r?\n/);
  const topComment = collectTopComment(lines);
  const moduleDocs = parseCommentBlock(topComment);

  const symbols = [];
  let implTarget = "";
  let implDepth = 0;

  for (let i = 0; i < lines.length; i += 1) {
    const rawLine = lines[i];
    const line = rawLine.trim();

    if (!implTarget) {
      const implMatch = line.match(/^impl\s+(.+?)\s*\{\s*$/);
      if (implMatch) {
        implTarget = implMatch[1].trim();
        implDepth = countChar(rawLine, "{") - countChar(rawLine, "}");
      }
    } else {
      const methodMatch = line.match(/^pub\s+([^\s(<{]+)\s*\(/);
      if (methodMatch) {
        const symbolComment = collectCommentAbove(lines, i);
        const symbolDocs = parseCommentBlock(symbolComment);
        const symbolMarkdown = buildDocsMarkdown(symbolDocs);
        symbols.push({
          kind: "method",
          name: methodMatch[1],
          signature: line,
          line: i + 1,
          owner: implTarget,
          docs: symbolDocs,
          docsMarkdown: symbolMarkdown,
        });
      }

      implDepth += countChar(rawLine, "{") - countChar(rawLine, "}");
      if (implDepth <= 0) {
        implTarget = "";
        implDepth = 0;
      }
    }

    const m = line.match(/^pub\s+(fun|compound|quirk|enum)\s+([^\s(<{]+)/);
    if (m) {
      const symbolComment = collectCommentAbove(lines, i);
      const symbolDocs = parseCommentBlock(symbolComment);
      const symbolMarkdown = buildDocsMarkdown(symbolDocs);
      const fields = m[1] === "compound" ? extractCompoundFields(lines, i) : [];
      const members = m[1] === "quirk" ? extractQuirkMembers(lines, i) : [];
      symbols.push({
        kind: m[1],
        name: m[2],
        signature: line,
        line: i + 1,
        docs: symbolDocs,
        docsMarkdown: symbolMarkdown,
        fields,
        members,
      });
    }
  }

  const nonMethodSymbols = symbols.filter((s) => s.kind !== "method");
  const methodSymbols = symbols
    .filter((s) => s.kind === "method")
    .sort((a, b) => {
      const ownerCmp = (a.owner ?? "").localeCompare(b.owner ?? "", undefined, {
        sensitivity: "base",
      });
      if (ownerCmp !== 0) return ownerCmp;

      const nameCmp = a.name.localeCompare(b.name, undefined, {
        sensitivity: "base",
      });
      if (nameCmp !== 0) return nameCmp;

      return a.line - b.line;
    });

  const moduleMarkdown = buildDocsMarkdown(moduleDocs);

  return {
    module: rel,
    summary: moduleDocs.summary,
    docs: moduleDocs,
    docsMarkdown: moduleMarkdown,
    symbols: [...nonMethodSymbols, ...methodSymbols],
  };
}

function extractCompoundFields(lines, declLineIdx) {
  const fields = [];

  let depth = 0;
  let enteredBody = false;

  for (let i = declLineIdx; i < lines.length; i += 1) {
    const rawLine = lines[i];
    const trimmed = rawLine.trim();

    if (!enteredBody) {
      if (rawLine.includes("{")) {
        enteredBody = true;
      }
      depth += countChar(rawLine, "{") - countChar(rawLine, "}");
      continue;
    }

    if (depth === 1 && trimmed && !trimmed.startsWith("//")) {
      const fieldMatch = trimmed.match(
        /^(.+?)\s+([A-Za-z_][A-Za-z0-9_]*)\s*;\s*$/,
      );
      if (fieldMatch) {
        const fieldCommentLines = collectCommentAbove(lines, i);
        const fieldDocs = parseCommentBlock(fieldCommentLines);
        const inlineDoc = parseFieldInlineDoc(fieldCommentLines);

        const typeText = fieldMatch[1].trim();
        const nameText = fieldMatch[2].trim();

        fields.push({
          name: nameText,
          type: typeText,
          signature: `${typeText} ${nameText};`,
          line: i + 1,
          docs: fieldDocs,
          docsMarkdown: fieldDocs.raw
            ? buildDocsMarkdown(fieldDocs)
            : inlineDoc,
          inlineDoc,
        });
      }
    }

    depth += countChar(rawLine, "{") - countChar(rawLine, "}");
    if (enteredBody && depth <= 0) {
      break;
    }
  }

  return fields;
}

function extractQuirkMembers(lines, declLineIdx) {
  const members = [];

  let depth = 0;
  let enteredBody = false;

  for (let i = declLineIdx; i < lines.length; i += 1) {
    const rawLine = lines[i];
    const trimmed = rawLine.trim();

    if (!enteredBody) {
      if (rawLine.includes("{")) {
        enteredBody = true;
      }
      depth += countChar(rawLine, "{") - countChar(rawLine, "}");
      continue;
    }

    if (depth === 1 && trimmed && !trimmed.startsWith("//")) {
      const memberMatch = trimmed.match(
        /^([A-Za-z_][A-Za-z0-9_]*)\s*\(([^)]*)\)\s*([^;{]*)\s*;\s*$/,
      );
      if (memberMatch) {
        const memberCommentLines = collectCommentAbove(lines, i);
        const memberDocs = parseCommentBlock(memberCommentLines);
        const inlineDoc = parseFieldInlineDoc(memberCommentLines);

        const nameText = memberMatch[1].trim();
        const retText = (memberMatch[3] ?? "").trim();

        members.push({
          name: nameText,
          type: retText,
          signature: trimmed,
          line: i + 1,
          docs: memberDocs,
          docsMarkdown: memberDocs.raw
            ? buildDocsMarkdown(memberDocs)
            : inlineDoc,
          inlineDoc,
        });
      }
    }

    depth += countChar(rawLine, "{") - countChar(rawLine, "}");
    if (enteredBody && depth <= 0) {
      break;
    }
  }

  return members;
}

function parseFieldInlineDoc(commentLines) {
  if (!commentLines || commentLines.length === 0) return "";

  for (let i = commentLines.length - 1; i >= 0; i -= 1) {
    const trimmed = commentLines[i].trim();
    const match = trimmed.match(/^[A-Za-z_][A-Za-z0-9_]*\s*:\s*(.+)$/);
    if (match) {
      return match[1].trim();
    }
  }

  return "";
}

function countChar(text, ch) {
  let n = 0;
  for (const c of text) {
    if (c === ch) n += 1;
  }
  return n;
}

function collectTopComment(lines) {
  const out = [];
  let seenComment = false;
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed.startsWith("//")) {
      out.push(trimmed.replace(/^\/\/\s?/, ""));
      seenComment = true;
      continue;
    }
    if (trimmed === "") {
      if (seenComment) {
        out.push("");
      }
      continue;
    }
    break;
  }
  return trimEmptyLines(out);
}

function collectCommentAbove(lines, declLineIdx) {
  const chunk = [];
  let sawComment = false;
  let i = declLineIdx - 1;

  while (i >= 0) {
    const trimmed = lines[i].trim();
    if (trimmed.startsWith("//")) {
      chunk.unshift(trimmed.replace(/^\/\/\s?/, ""));
      sawComment = true;
      i -= 1;
      continue;
    }
    if (trimmed === "" && sawComment) {
      chunk.unshift("");
      i -= 1;
      continue;
    }
    break;
  }

  return trimEmptyLines(chunk);
}

function trimEmptyLines(lines) {
  let start = 0;
  let end = lines.length;
  while (start < end && lines[start].trim() === "") start += 1;
  while (end > start && lines[end - 1].trim() === "") end -= 1;
  return lines.slice(start, end);
}

function isSectionHeader(line) {
  return /^(Params|Returns|Fields|Usage|Example|Examples|Notes):\s*$/i.test(
    line.trim(),
  );
}

function parseCommentBlock(lines) {
  const cleaned = trimEmptyLines(lines);
  const summary = cleaned.find((line) => line.trim() !== "") ?? "";
  const descriptionLines = [];
  const sectionLines = [];
  let inSections = false;

  for (const line of cleaned) {
    if (isSectionHeader(line)) {
      inSections = true;
    }
    if (inSections) {
      sectionLines.push(line);
    } else {
      descriptionLines.push(line);
    }
  }

  const raw = cleaned.join("\n");
  const description = trimEmptyLines(descriptionLines).join("\n");
  const sections = splitSections(sectionLines);
  const example = extractFirstExampleBlock(raw);

  return {
    summary,
    description,
    raw,
    sections,
    example,
  };
}

function splitSections(lines) {
  const sections = {
    params: [],
    returns: [],
    fields: [],
    usage: [],
    examples: [],
    notes: [],
  };

  let current = null;
  for (const line of lines) {
    const trimmed = line.trim();
    const m = trimmed.match(
      /^(Params|Returns|Fields|Usage|Example|Examples|Notes):\s*$/i,
    );
    if (m) {
      const label = m[1].toLowerCase();
      if (label === "example" || label === "examples") {
        current = "examples";
      } else {
        current = label;
      }
      continue;
    }
    if (!current) continue;
    sections[current].push(line);
  }

  for (const key of Object.keys(sections)) {
    sections[key] = trimEmptyLines(sections[key]);
  }

  return sections;
}

function extractFirstExampleBlock(markdown) {
  const withLang = markdown.match(/```fun\s*\n([\s\S]*?)```/i);
  if (withLang) return withLang[1].trimEnd();
  const plain = markdown.match(/```\s*\n([\s\S]*?)```/);
  if (plain) return plain[1].trimEnd();
  return "";
}

function buildDocsMarkdown(docs) {
  if (!docs.raw) return "";
  const parts = [];
  if (docs.description) {
    parts.push(docs.description);
  }

  const sectionTitle = {
    params: "Params",
    returns: "Returns",
    fields: "Fields",
    usage: "Usage",
    examples: "Examples",
    notes: "Notes",
  };

  for (const key of [
    "params",
    "returns",
    "fields",
    "usage",
    "examples",
    "notes",
  ]) {
    const lines = docs.sections[key];
    if (!lines || lines.length === 0) continue;
    parts.push(`### ${sectionTitle[key]}\n${lines.join("\n")}`);
  }

  return parts.join("\n\n").trim();
}

const stdFiles = await walk(stdRoot);
stdFiles.sort((a, b) => a.localeCompare(b));

const stdlib = [];
for (const file of stdFiles) {
  const src = await fs.readFile(file, "utf8");
  stdlib.push(parseStdFile(file, src));
}

const samples = [
  {
    title: "Hello World",
    code: `imp std.c.io;

fun main() {
  printf("hello from fun\\n");
}
`,
  },
  {
    title: "Alias Imports",
    code: `// file: main.fn
imp mod1 as one;
imp mod2 as two;

fun main() {
  num a = one.pick();
  num b = two.pick();
  _ = a + b;
}

// file: mod1.fn
pub fun pick() num {
  ret 10;
}

// file: mod2.fn
pub fun pick() num {
  ret 32;
}
`,
  },
  {
    title: "Compounds + Impl",
    code: `imp std.c.io;

compound Point {
  num x;
  num y;
}

impl Point {
  move_by(num dx, num dy) {
    self.x = self.x + dx;
    self.y = self.y + dy;
  }
}

fun main() {
  Point p;
  p.x = 1; p.y = 2;
  p.move_by(3, 4);
  printf("%d,%d\\n", p.x, p.y);
}
`,
  },
];

const generated = {
  generatedAt: new Date().toISOString(),
  funVersion,
  versions: {
    latest: funVersion,
    available: [funVersion],
  },
  docs,
  stdlib,
  samples,
};

await fs.mkdir(path.join(siteRoot, "src/generated"), { recursive: true });
await fs.writeFile(
  path.join(siteRoot, "src/generated/content.json"),
  `${JSON.stringify(generated, null, 2)}\n`,
  "utf8",
);

await fs.mkdir(path.join(publicVersionsRoot, funVersion), { recursive: true });
await fs.writeFile(
  path.join(publicVersionsRoot, funVersion, "content.json"),
  `${JSON.stringify(generated, null, 2)}\n`,
  "utf8",
);

let availableVersions = [];
try {
  const entries = await fs.readdir(publicVersionsRoot, { withFileTypes: true });
  availableVersions = entries
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort((a, b) => compareVersionDescending(a, b));
} catch {
  availableVersions = [funVersion];
}

const versionsIndex = {
  latest: availableVersions[0] ?? funVersion,
  available: availableVersions,
};

await fs.writeFile(
  path.join(publicVersionsRoot, "index.json"),
  `${JSON.stringify(versionsIndex, null, 2)}\n`,
  "utf8",
);

console.log(`Generated reference content for ${stdlib.length} std modules.`);

function compareVersionDescending(a, b) {
  return compareVersionAscending(b, a);
}

function compareVersionAscending(a, b) {
  const pa = normalizeVersion(a);
  const pb = normalizeVersion(b);
  const maxLen = Math.max(pa.length, pb.length);

  for (let i = 0; i < maxLen; i += 1) {
    const av = pa[i] ?? 0;
    const bv = pb[i] ?? 0;
    if (av !== bv) return av - bv;
  }

  return a.localeCompare(b, undefined, { sensitivity: "base" });
}

function normalizeVersion(raw) {
  return String(raw)
    .replace(/^v/i, "")
    .split(/[-+]/)[0]
    .split(".")
    .map((part) => Number.parseInt(part, 10))
    .map((n) => (Number.isFinite(n) ? n : 0));
}
