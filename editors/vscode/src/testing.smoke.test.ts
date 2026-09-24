// Runs registerFunTesting against a small fake of the `vscode` module and the
// real `fun` binary, so the glue (discovery, running, failure messages,
// coverage) is exercised without an editor. Needs FUN_SMOKE_EXE, the path to a
// built `fun`, and FUN_STDLIB_DIR; it is skipped when they are absent.

import { test } from "node:test";
import * as assert from "node:assert";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import Module = require("module");

const exe = process.env.FUN_SMOKE_EXE;
const skip = !exe || !fs.existsSync(exe);

// ---- a fake `vscode` -------------------------------------------------------

class Position {
  constructor(public line: number, public character: number) {}
}
class Range {
  start: Position;
  end: Position;
  constructor(a: number, b: number, c: number, d: number) {
    this.start = new Position(a, b);
    this.end = new Position(c, d);
  }
}
class Location {
  constructor(public uri: unknown, public range: unknown) {}
}
class Uri {
  constructor(public fsPath: string) {}
  static file(p: string) {
    return new Uri(p);
  }
  toString() {
    return "file://" + this.fsPath;
  }
}
class TestMessage {
  location?: unknown;
  constructor(public message: string) {}
}
class TestCoverageCount {
  constructor(public covered: number, public total: number) {}
}
class FileCoverage {
  constructor(public uri: Uri, public statementCoverage: TestCoverageCount) {}
}
class StatementCoverage {
  constructor(public executed: number | boolean, public location: Position | Range) {}
}

class Collection {
  map = new Map<string, Item>();
  get size() {
    return this.map.size;
  }
  add(i: Item) {
    this.map.set(i.id, i);
  }
  delete(id: string) {
    this.map.delete(id);
  }
  replace(items: Item[]) {
    this.map = new Map(items.map((i) => [i.id, i]));
    items.forEach((i) => (i.parent = this.owner));
  }
  forEach(f: (i: Item) => void) {
    this.map.forEach(f);
  }
  [Symbol.iterator]() {
    return this.map.entries();
  }
  constructor(public owner?: Item) {}
}
class Item {
  children: Collection;
  parent?: Item;
  range?: Range;
  description?: string;
  canResolveChildren = false;
  constructor(public id: string, public label: string, public uri?: Uri) {
    this.children = new Collection(this);
  }
}

const events: string[] = [];
const messages = new Map<string, string>();
let captured: {
  root: Collection;
  profiles: Record<string, { run: (r: unknown, t: unknown) => Promise<void>; load?: unknown }>;
  coverage: FileCoverage[];
  loadDetailed?: (run: unknown, fc: FileCoverage) => Promise<StatementCoverage[]>;
} | undefined;

function makeVscode(workspace: string) {
  const root = new Collection();
  const profiles: Record<string, { run: (r: unknown, t: unknown) => Promise<void> }> = {};
  const coverage: FileCoverage[] = [];
  const cap: NonNullable<typeof captured> = { root, profiles, coverage };
  captured = cap;
  const folder = { uri: Uri.file(workspace), name: "ws", index: 0 };
  return {
    Position, Range, Location, Uri, TestMessage, TestCoverageCount, FileCoverage, StatementCoverage,
    TestRunProfileKind: { Run: 1, Debug: 2, Coverage: 3 },
    tests: {
      createTestController: () => ({
        items: root,
        dispose() {},
        createTestItem: (id: string, label: string, uri?: Uri) => new Item(id, label, uri),
        createRunProfile: (label: string, _kind: number, run: (r: unknown, t: unknown) => Promise<void>) => {
          const profile: {
            loadDetailedCoverage?: (run: unknown, fc: FileCoverage) => Promise<StatementCoverage[]>;
            dispose(): void;
          } = { dispose() {} };
          profiles[label] = { run };
          Object.defineProperty(profile, "loadDetailedCoverage", {
            set(v) { cap.loadDetailed = v; },
            get() { return cap.loadDetailed; },
          });
          return profile;
        },
        createTestRun: () => ({
          enqueued: (i: Item) => events.push(`enqueued ${i.label}`),
          started: (i: Item) => events.push(`started ${i.label}`),
          passed: (i: Item) => events.push(`passed ${i.label}`),
          failed: (i: Item, m: TestMessage) => {
            events.push(`failed ${i.label}`);
            messages.set(i.label, m.message);
          },
          errored: (i: Item, m: TestMessage) => {
            events.push(`errored ${i.label}`);
            messages.set(i.label, m.message);
          },
          skipped: (i: Item) => events.push(`skipped ${i.label}`),
          appendOutput: () => {},
          addCoverage: (fc: FileCoverage) => coverage.push(fc),
          end: () => events.push("end"),
        }),
      }),
    },
    workspace: {
      workspaceFolders: [folder],
      textDocuments: [],
      getWorkspaceFolder: () => folder,
      findFiles: async () => {
        const out: Uri[] = [];
        const walk = (d: string) => {
          for (const e of fs.readdirSync(d, { withFileTypes: true })) {
            const p = path.join(d, e.name);
            if (e.isDirectory()) walk(p);
            else if (p.endsWith(".fn")) out.push(Uri.file(p));
          }
        };
        walk(workspace);
        return out;
      },
      fs: { readFile: async (u: Uri) => fs.readFileSync(u.fsPath) },
      createFileSystemWatcher: () => ({
        onDidCreate: () => ({ dispose() {} }),
        onDidChange: () => ({ dispose() {} }),
        onDidDelete: () => ({ dispose() {} }),
        dispose() {},
      }),
      onDidOpenTextDocument: () => ({ dispose() {} }),
      onDidChangeTextDocument: () => ({ dispose() {} }),
      saveAll: async () => true,
    },
    commands: { executeCommand: async () => undefined },
  };
}

test("the Test Explorer integration discovers, runs, reports failures and coverage", { skip }, async () => {
  const ws = fs.mkdtempSync(path.join(os.tmpdir(), "fun-smoke-"));
  fs.mkdirSync(path.join(ws, "src"));
  fs.mkdirSync(path.join(ws, "fun-out"));
  fs.writeFileSync(
    path.join(ws, "src", "calc.fn"),
    [
      "pub fun half(num x) num {",
      "  ret x / 2;",
      "}",
      "",
      "pub fun unused() num {",
      "  ret 9;",
      "}",
      "",
      'test "halves four" {',
      '  assert half(4) == 2, "half of four";',
      "}",
      "",
      'test "halves wrongly" {',
      '  assert half(4) == 3, "expected three";',
      "}",
      "",
    ].join("\n"),
  );
  fs.writeFileSync(path.join(ws, "fun-out", "skipped.fn"), 'test "not listed" { assert true, "x"; }\n');

  const fake = makeVscode(ws);
  const originalLoad = (Module as any)._load;
  (Module as any)._load = function (request: string, ...rest: unknown[]) {
    if (request === "vscode") return fake;
    return originalLoad.call(this, request, ...rest);
  };
  process.env.FUN_STDLIB_DIR = process.env.FUN_STDLIB_DIR ?? "";
  const { registerFunTesting } = require("./testing");

  registerFunTesting(
    { subscriptions: [] },
    { resolveExe: () => exe as string, buildEnv: () => ({}) },
    { info() {}, warn() {} },
  );
  await new Promise((r) => setTimeout(r, 200));

  const cap = captured!;
  const srcDir = [...cap.root.map.values()][0];
  assert.ok(srcDir, "expected a folder item for src");
  const file = [...srcDir.children.map.values()][0];
  assert.strictEqual(file.label, "calc.fn");
  const testLabels = [...file.children.map.values()].map((t) => t.label);
  assert.deepStrictEqual(testLabels, ["halves four", "halves wrongly"]);
  assert.strictEqual(cap.root.size, 1, "the fun-out directory must not be listed");

  // A plain run of the whole file.
  events.length = 0;
  await cap.profiles["Run"].run({ include: [file], exclude: [] }, { isCancellationRequested: false, onCancellationRequested: () => ({ dispose() {} }) });
  assert.ok(events.includes("passed halves four"), events.join(" | "));
  assert.ok(events.includes("failed halves wrongly"), events.join(" | "));
  assert.match(messages.get("halves wrongly") ?? "", /expected three/);

  // One test on its own, with coverage.
  events.length = 0;
  const single = [...file.children.map.values()][0];
  await cap.profiles["Coverage"].run({ include: [single], exclude: [] }, { isCancellationRequested: false, onCancellationRequested: () => ({ dispose() {} }) });
  assert.ok(events.includes("passed halves four"), events.join(" | "));
  assert.ok(!events.includes("failed halves wrongly"), "only the chosen test should run");
  assert.strictEqual(cap.coverage.length >= 1, true, "expected a file's coverage");
  const calc = cap.coverage.find((c) => c.uri.fsPath.endsWith("calc.fn"))!;
  assert.ok(calc, "expected coverage for calc.fn");
  assert.strictEqual(calc.statementCoverage.total, 2, "half's ret and unused's ret");
  assert.strictEqual(calc.statementCoverage.covered, 1);
  const detail = await cap.loadDetailed!(undefined, calc);
  assert.deepStrictEqual(
    detail.map((d) => [(d.location as Position).line, d.executed]),
    [[1, 1], [5, 0]],
  );

  (Module as any)._load = originalLoad;
});
