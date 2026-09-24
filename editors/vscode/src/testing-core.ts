// The parts of the Test Explorer integration that need nothing from VS Code:
// finding `test` blocks in source text, reading what `fun test` prints, and
// combining coverage reports. Kept apart so they can be unit tested on their
// own (src/testing-core.test.ts) instead of only inside a running editor.

/** A `test "name" { ... }` block found in a file. */
export interface DiscoveredTest {
  name: string;
  /** Zero-based line the block starts on. */
  line: number;
  /** Zero-based line of its closing brace, or the start line if not found. */
  endLine: number;
  sequential: boolean;
}

// `test "name" {`, optionally `sequential test`, allowing an escaped quote in
// the name the same way the lexer does for any other string literal.
const testLineRe = /^\s*(sequential\s+)?test\s+"((?:[^"\\]|\\.)*)"\s*\{/;

/** Decodes the escapes a test name is written with. */
function unescapeName(raw: string): string {
  return raw.replace(/\\(.)/g, "$1");
}

/**
 * Finds the `test` blocks in `text`. The end of a block is found by counting
 * braces from its opening line, skipping string and character literals and
 * line comments so a brace inside one does not throw the count off.
 */
export function discoverTests(text: string): DiscoveredTest[] {
  const lines = text.split(/\r?\n/);
  const found: DiscoveredTest[] = [];
  for (let i = 0; i < lines.length; i++) {
    const m = testLineRe.exec(lines[i]);
    if (!m) continue;
    found.push({
      name: unescapeName(m[2]),
      line: i,
      endLine: findBlockEnd(lines, i),
      sequential: m[1] !== undefined,
    });
  }
  return found;
}

/** Index of the line holding the brace that closes the block opened on `start`. */
function findBlockEnd(lines: string[], start: number): number {
  let depth = 0;
  let opened = false;
  for (let i = start; i < lines.length; i++) {
    const s = lines[i];
    let j = 0;
    while (j < s.length) {
      const c = s[j];
      if (c === "/" && s[j + 1] === "/") break;
      if (c === '"' || c === "'" || c === "`") {
        const quote = c;
        j++;
        while (j < s.length && s[j] !== quote) {
          if (s[j] === "\\" && quote !== "`") j++;
          j++;
        }
      } else if (c === "{") {
        depth++;
        opened = true;
      } else if (c === "}") {
        depth--;
        if (opened && depth === 0) return i;
      }
      j++;
    }
  }
  return start;
}

/** One test's outcome as `fun test` printed it. */
export interface TestOutcome {
  name: string;
  passed: boolean;
  /** Assertion messages printed for it. Empty for a pass. */
  messages: string[];
}

// `test: <name> ... PASS` / `... FAIL`. The name is everything up to the last
// " ... " so a name that itself contains dots survives.
const resultRe = /^test: (.*) \.\.\. (PASS|FAIL)\s*$/;
const assertionRe = /^Assertion failed: (.*)$/;

/** Reads a line of standard output as a test result, if it is one. */
export function parseResultLine(
  line: string,
): { name: string; passed: boolean } | undefined {
  const m = resultRe.exec(line.replace(/\r$/, ""));
  if (!m) return undefined;
  return { name: m[1], passed: m[2] === "PASS" };
}

/** Reads a line of standard error as an assertion message, if it is one. */
export function parseAssertionLine(line: string): string | undefined {
  const m = assertionRe.exec(line.replace(/\r$/, ""));
  return m ? m[1] : undefined;
}

/**
 * Pairs each failed test with its assertion message. Results go to standard
 * output and assertion messages to standard error, and the two streams reach
 * the editor in no guaranteed order, so they cannot be matched by arrival. A
 * failing test stops at its first failed assertion, which prints exactly one
 * message, so the k-th message belongs to the k-th failure. That holds when
 * tests run one at a time, which is why the editor asks for that
 * (FUN_TEST_INTRA_JOBS=1). A failure with no message gets an empty list.
 */
export function attachMessages(
  outcomes: { name: string; passed: boolean }[],
  messages: string[],
): TestOutcome[] {
  let next = 0;
  return outcomes.map((o) => ({
    name: o.name,
    passed: o.passed,
    messages: o.passed ? [] : next < messages.length ? [messages[next++]] : [],
  }));
}

/** Hit counts for the counted lines of one file. */
export interface FileLines {
  path: string;
  /** One-based line number to how many times it ran. */
  lines: Map<number, number>;
}

/** A parsed coverage report. */
export interface CoverageReport {
  files: FileLines[];
}

/** Reads the JSON `fun test -cover-report json=...` writes. */
export function parseCoverageJson(text: string): CoverageReport {
  const doc = JSON.parse(text);
  if (!doc || doc.format !== "fun-coverage" || !Array.isArray(doc.files)) {
    throw new Error("not a fun coverage report");
  }
  const files: FileLines[] = [];
  for (const f of doc.files) {
    const lines = new Map<number, number>();
    for (const pair of f.lines ?? []) {
      lines.set(Number(pair[0]), Number(pair[1]));
    }
    files.push({ path: String(f.path), lines });
  }
  return { files };
}

/**
 * Combines reports from several runs: the lines of a file are the union of
 * what each run counted, and a line's hits add up.
 */
export function mergeCoverage(reports: CoverageReport[]): CoverageReport {
  const byPath = new Map<string, Map<number, number>>();
  for (const r of reports) {
    for (const f of r.files) {
      let lines = byPath.get(f.path);
      if (!lines) {
        lines = new Map();
        byPath.set(f.path, lines);
      }
      for (const [line, hits] of f.lines) {
        lines.set(line, (lines.get(line) ?? 0) + hits);
      }
    }
  }
  const files: FileLines[] = [];
  for (const [p, lines] of [...byPath.entries()].sort((a, b) =>
    a[0].localeCompare(b[0]),
  )) {
    files.push({ path: p, lines });
  }
  return { files };
}

/** How many of a file's counted lines ran at least once, and how many there are. */
export function countLines(file: FileLines): { covered: number; total: number } {
  let covered = 0;
  for (const hits of file.lines.values()) if (hits > 0) covered++;
  return { covered, total: file.lines.size };
}

/**
 * The arguments for running `file`'s tests. `only` names a single test to run
 * alone; `coverageJson` asks for a coverage report written there.
 */
export function buildTestArgs(
  file: string,
  only?: string,
  coverageJson?: string,
): string[] {
  const args = ["test", file];
  if (coverageJson) {
    args.push("-cover", "-cover-report", `json=${coverageJson}`);
  }
  if (only !== undefined) {
    args.push("--", only);
  }
  return args;
}
