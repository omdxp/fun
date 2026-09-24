import { test } from "node:test";
import * as assert from "node:assert";
import {
  attachMessages,
  parseAssertionLine,
  parseResultLine,
  buildTestArgs,
  countLines,
  discoverTests,
  mergeCoverage,
  parseCoverageJson,
} from "./testing-core";

test("discoverTests finds test blocks with their lines and flags", () => {
  const text = [
    'fun main() {}',
    '',
    'test "adds two numbers" {',
    '  assert 1 + 1 == 2, "math";',
    '}',
    'sequential test "touches the environment" {',
    '  let x = "}";',
    '  // a } in a comment',
    '  assert true, "ok";',
    '}',
    'test "quote \\" inside" { assert true, "q"; }',
  ].join("\n");
  const found = discoverTests(text);
  assert.strictEqual(found.length, 3);
  assert.deepStrictEqual(
    found.map((t) => [t.name, t.line, t.endLine, t.sequential]),
    [
      ["adds two numbers", 2, 4, false],
      ["touches the environment", 5, 9, true],
      ['quote " inside', 10, 10, false],
    ],
  );
});

test("discoverTests ignores things that only look like tests", () => {
  const text = [
    '// test "commented out" {',
    'fun test_helper() {}',
    'let s = "test \\"x\\" {";',
    '  test  "indented and spaced"   {',
    '}',
  ].join("\n");
  const found = discoverTests(text);
  assert.strictEqual(found.length, 1);
  assert.strictEqual(found[0].name, "indented and spaced");
});

test("discoverTests copes with Windows line endings and an unclosed block", () => {
  const found = discoverTests('test "a" {\r\n  assert true, "x";\r\n');
  assert.strictEqual(found.length, 1);
  assert.strictEqual(found[0].line, 0);
  assert.strictEqual(found[0].endLine, 0);
});

test("parseResultLine reads results, including names with dots and CRLF", () => {
  assert.deepStrictEqual(parseResultLine("test: first ... PASS"), { name: "first", passed: true });
  assert.deepStrictEqual(parseResultLine("test: second ... FAIL\r"), { name: "second", passed: false });
  assert.strictEqual(parseResultLine("test: reads a.b ... c ... PASS")?.name, "reads a.b ... c");
  assert.strictEqual(parseResultLine("1/2 tests passed"), undefined);
  assert.strictEqual(parseResultLine("Assertion failed: x"), undefined);
});

test("parseAssertionLine reads assertion messages only", () => {
  assert.strictEqual(parseAssertionLine("Assertion failed: expected 3"), "expected 3");
  assert.strictEqual(parseAssertionLine("Assertion failed: with CR\r"), "with CR");
  assert.strictEqual(parseAssertionLine("[Error]"), undefined);
});

test("attachMessages pairs the k-th message with the k-th failure", () => {
  const outcomes = [
    { name: "a", passed: true },
    { name: "b", passed: false },
    { name: "c", passed: true },
    { name: "d", passed: false },
    { name: "e", passed: false },
  ];
  const paired = attachMessages(outcomes, ["msg b", "msg d"]);
  assert.deepStrictEqual(paired.map((o) => o.messages), [[], ["msg b"], [], ["msg d"], []]);
  assert.deepStrictEqual(attachMessages([{ name: "x", passed: false }], []), [
    { name: "x", passed: false, messages: [] },
  ]);
});

const report = (files: Record<string, [number, number][]>) =>
  JSON.stringify({
    format: "fun-coverage",
    version: 1,
    files: Object.entries(files).map(([path, lines]) => ({ path, lines })),
  });

test("parseCoverageJson reads files and their line counts", () => {
  const r = parseCoverageJson(report({ "a.fn": [[1, 3], [2, 0]] }));
  assert.strictEqual(r.files.length, 1);
  assert.strictEqual(r.files[0].path, "a.fn");
  assert.strictEqual(r.files[0].lines.get(1), 3);
  assert.deepStrictEqual(countLines(r.files[0]), { covered: 1, total: 2 });
  assert.throws(() => parseCoverageJson('{"format":"other"}'));
  assert.throws(() => parseCoverageJson("not json"));
});

test("mergeCoverage adds hits and unions the counted lines", () => {
  const a = parseCoverageJson(report({ "b.fn": [[1, 1], [2, 0]], "a.fn": [[5, 0]] }));
  const b = parseCoverageJson(report({ "b.fn": [[1, 2], [3, 4]] }));
  const merged = mergeCoverage([a, b]);
  assert.deepStrictEqual(
    merged.files.map((f) => f.path),
    ["a.fn", "b.fn"],
  );
  const bfile = merged.files[1];
  assert.strictEqual(bfile.lines.get(1), 3);
  assert.strictEqual(bfile.lines.get(2), 0);
  assert.strictEqual(bfile.lines.get(3), 4);
  assert.deepStrictEqual(countLines(bfile), { covered: 2, total: 3 });
});

test("buildTestArgs asks for one test and a coverage report only when needed", () => {
  assert.deepStrictEqual(buildTestArgs("x.fn"), ["test", "x.fn"]);
  assert.deepStrictEqual(buildTestArgs("x.fn", "does it"), ["test", "x.fn", "--", "does it"]);
  assert.deepStrictEqual(buildTestArgs("x.fn", undefined, "/tmp/c.json"), [
    "test", "x.fn", "-cover", "-cover-report", "json=/tmp/c.json",
  ]);
  assert.deepStrictEqual(buildTestArgs("x.fn", "n", "/tmp/c.json"), [
    "test", "x.fn", "-cover", "-cover-report", "json=/tmp/c.json", "--", "n",
  ]);
});
