// Test Explorer integration: every `test "..."` block in the workspace becomes
// a test item, so VS Code draws its own run/debug/coverage buttons in the
// gutter beside each one, and the Testing view lists, runs and filters them by
// test, file and folder. Running with the Coverage profile passes `-cover` to
// `fun test`, reads the JSON report it writes and hands it to VS Code, which
// then shades covered and uncovered lines in the editor and shows a
// percentage per file and in total.

import * as vscode from "vscode";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { spawn } from "child_process";
import {
  DiscoveredTest,
  attachMessages,
  parseAssertionLine,
  parseResultLine,
  buildTestArgs,
  countLines,
  discoverTests,
  mergeCoverage,
  parseCoverageJson,
  CoverageReport,
  FileLines,
} from "./testing-core";

/** What the integration needs from the rest of the extension. */
export interface TestingHost {
  /** The `fun` executable, from settings or the default location. */
  resolveExe(root: string | undefined): string;
  /** Extra environment `fun` needs (FUN_STDLIB_DIR when launched from a dock). */
  buildEnv(root: string | undefined): Record<string, string>;
}

// Files a scan of the workspace leaves out: build output, dependencies and
// test fixtures (deliberately odd inputs, the same rule `fun test <dir>` uses).
const excludeGlob =
  "{**/node_modules/**,**/fun-out/**,**/.git/**,**/fixtures/**,**/*_fixtures/**}";

const maxFiles = 5000;
const maxParallelFiles = 3;

/** The lines a coverage run counted, kept for `loadDetailedCoverage`. */
const detailsByCoverage = new WeakMap<vscode.FileCoverage, FileLines>();

function workspaceFolderFor(uri: vscode.Uri): string | undefined {
  return vscode.workspace.getWorkspaceFolder(uri)?.uri.fsPath;
}

/** Splits a stream chunk into complete lines, holding a partial last line back. */
function lineSplitter(onLine: (line: string) => void): {
  push(chunk: string): void;
  flush(): void;
} {
  let rest = "";
  return {
    push(chunk: string) {
      rest += chunk;
      let nl = rest.indexOf("\n");
      while (nl >= 0) {
        onLine(rest.slice(0, nl));
        rest = rest.slice(nl + 1);
        nl = rest.indexOf("\n");
      }
    },
    flush() {
      if (rest.length > 0) onLine(rest);
      rest = "";
    },
  };
}

export function registerFunTesting(
  context: vscode.ExtensionContext,
  host: TestingHost,
  log: vscode.LogOutputChannel,
): void {
  const controller = vscode.tests.createTestController("fun.tests", "Fun");
  context.subscriptions.push(controller);

  // -------------------------------------------------------------- discovery

  const dirItems = new Map<string, vscode.TestItem>();
  const fileItems = new Map<string, vscode.TestItem>();
  /** The tests parsed from each file, by item id, so a run knows their names. */
  const testInfo = new Map<string, DiscoveredTest>();

  function isExcluded(uri: vscode.Uri): boolean {
    const p = uri.fsPath.replace(/\\/g, "/");
    return /\/(node_modules|fun-out|\.git|fixtures)\//.test(p) || /_fixtures\//.test(p);
  }

  /** The item for the directory holding `fileUri`, creating the chain of parents. */
  function parentFor(fileUri: vscode.Uri): vscode.TestItem | undefined {
    const folder = vscode.workspace.getWorkspaceFolder(fileUri);
    if (!folder) return undefined;
    const rel = path.relative(folder.uri.fsPath, path.dirname(fileUri.fsPath));
    const segments = rel === "" ? [] : rel.split(path.sep);
    let collection = controller.items;
    let cursor = folder.uri.fsPath;
    let parent: vscode.TestItem | undefined = undefined;
    // The workspace folder itself is the top item in a multi-root workspace,
    // and is skipped for a single folder to keep the tree shallow.
    const multiRoot = (vscode.workspace.workspaceFolders?.length ?? 0) > 1;
    if (multiRoot) {
      const key = folder.uri.toString();
      let item = dirItems.get(key);
      if (!item) {
        item = controller.createTestItem(key, folder.name, folder.uri);
        dirItems.set(key, item);
        collection.add(item);
      }
      parent = item;
      collection = item.children;
    }
    for (const segment of segments) {
      cursor = path.join(cursor, segment);
      const dirUri = vscode.Uri.file(cursor);
      const key = dirUri.toString();
      let item = dirItems.get(key);
      if (!item) {
        item = controller.createTestItem(key, segment, dirUri);
        dirItems.set(key, item);
        collection.add(item);
      }
      parent = item;
      collection = item.children;
    }
    return parent;
  }

  function removeFile(uri: vscode.Uri): void {
    const key = uri.toString();
    const item = fileItems.get(key);
    if (!item) return;
    fileItems.delete(key);
    for (const [id] of item.children) testInfo.delete(id);
    const owner = item.parent?.children ?? controller.items;
    owner.delete(item.id);
    pruneEmptyDirs(item.parent);
  }

  function pruneEmptyDirs(dir: vscode.TestItem | undefined): void {
    let current = dir;
    while (current && current.children.size === 0) {
      const above: vscode.TestItem | undefined = current.parent;
      (above?.children ?? controller.items).delete(current.id);
      dirItems.delete(current.id);
      current = above;
    }
  }

  function updateFile(uri: vscode.Uri, text: string): void {
    if (isExcluded(uri)) return;
    const tests = discoverTests(text);
    if (tests.length === 0) {
      removeFile(uri);
      return;
    }
    const key = uri.toString();
    let fileItem = fileItems.get(key);
    if (!fileItem) {
      fileItem = controller.createTestItem(key, path.basename(uri.fsPath), uri);
      fileItem.canResolveChildren = false;
      fileItems.set(key, fileItem);
      const parent = parentFor(uri);
      (parent?.children ?? controller.items).add(fileItem);
    }
    for (const [id] of fileItem.children) testInfo.delete(id);
    const children = tests.map((t, index) => {
      const id = `${key}#${index}:${t.name}`;
      const item = controller.createTestItem(id, t.name, uri);
      item.range = new vscode.Range(t.line, 0, t.endLine, 0);
      if (t.sequential) item.description = "sequential";
      testInfo.set(id, t);
      return item;
    });
    fileItem.children.replace(children);
  }

  async function scanFile(uri: vscode.Uri): Promise<void> {
    try {
      const open = vscode.workspace.textDocuments.find(
        (d) => d.uri.toString() === uri.toString(),
      );
      const text = open
        ? open.getText()
        : Buffer.from(await vscode.workspace.fs.readFile(uri)).toString("utf8");
      updateFile(uri, text);
    } catch (err) {
      log.warn(`Test discovery skipped ${uri.fsPath}: ${String(err)}`);
    }
  }

  async function scanWorkspace(): Promise<void> {
    const files = await vscode.workspace.findFiles("**/*.fn", excludeGlob, maxFiles);
    await Promise.all(files.map(scanFile));
  }

  controller.refreshHandler = () => scanWorkspace();
  void scanWorkspace();

  const watcher = vscode.workspace.createFileSystemWatcher("**/*.fn");
  context.subscriptions.push(
    watcher,
    watcher.onDidCreate((u) => void scanFile(u)),
    watcher.onDidChange((u) => void scanFile(u)),
    watcher.onDidDelete((u) => removeFile(u)),
  );

  // An open document holds text the file does not have yet, and a test
  // written there should show up as it is typed.
  const pending = new Map<string, NodeJS.Timeout>();
  context.subscriptions.push(
    vscode.workspace.onDidOpenTextDocument((d) => {
      if (d.languageId === "fun" && d.uri.scheme === "file") updateFile(d.uri, d.getText());
    }),
    vscode.workspace.onDidChangeTextDocument((e) => {
      const d = e.document;
      if (d.languageId !== "fun" || d.uri.scheme !== "file") return;
      const key = d.uri.toString();
      clearTimeout(pending.get(key));
      pending.set(
        key,
        setTimeout(() => {
          pending.delete(key);
          updateFile(d.uri, d.getText());
        }, 300),
      );
    }),
  );

  // ---------------------------------------------------------------- running

  interface FileRun {
    file: vscode.TestItem;
    /** `undefined` runs every test in the file. */
    tests: vscode.TestItem[] | undefined;
  }

  function collectRuns(request: vscode.TestRunRequest): FileRun[] {
    const excluded = new Set((request.exclude ?? []).map((i) => i.id));
    const byFile = new Map<string, FileRun>();

    const addFile = (file: vscode.TestItem, tests?: vscode.TestItem[]) => {
      if (excluded.has(file.id)) return;
      const existing = byFile.get(file.id);
      if (!existing) {
        byFile.set(file.id, { file, tests });
        return;
      }
      if (existing.tests === undefined || tests === undefined) existing.tests = undefined;
      else existing.tests.push(...tests);
    };

    const visit = (item: vscode.TestItem) => {
      if (excluded.has(item.id)) return;
      if (fileItems.get(item.id) === item) {
        addFile(item);
      } else if (testInfo.has(item.id) && item.parent) {
        addFile(item.parent, [item]);
      } else {
        item.children.forEach(visit);
      }
    };

    if (request.include) request.include.forEach(visit);
    else controller.items.forEach(visit);
    return [...byFile.values()];
  }

  /** Runs one `fun test` process and streams its result into `run`. */
  function runProcess(
    run: vscode.TestRun,
    file: vscode.TestItem,
    only: vscode.TestItem | undefined,
    coverageJson: string | undefined,
    token: vscode.CancellationToken,
  ): Promise<void> {
    const uri = file.uri!;
    const root = workspaceFolderFor(uri) ?? path.dirname(uri.fsPath);
    const exe = host.resolveExe(root);
    const onlyName = only ? testInfo.get(only.id)?.name : undefined;
    // Relative to the workspace, so the compiler sees the file as part of the
    // project (and measures it) whatever directory the editor was started in.
    const args = buildTestArgs(path.relative(root, uri.fsPath), onlyName, coverageJson);
    const env = {
      ...process.env,
      ...host.buildEnv(root),
      // Serial, so an assertion message is printed right before the FAIL line
      // of the test it belongs to and can be attached to it.
      FUN_TEST_INTRA_JOBS: "1",
      // What a shell would have set: the compiler reads it to show absolute
      // paths of project files relative to the workspace.
      PWD: root,
    };

    const targets = only ? [only] : collectChildren(file);
    const byName = new Map<string, vscode.TestItem[]>();
    for (const t of targets) {
      const name = testInfo.get(t.id)?.name;
      if (name === undefined) continue;
      const list = byName.get(name) ?? [];
      list.push(t);
      byName.set(name, list);
      run.started(t);
    }
    const settled = new Set<string>();
    const outcomes: { name: string; passed: boolean }[] = [];
    const assertions: string[] = [];
    const otherLines: string[] = [];
    const started = Date.now();

    const settle = (
      outcome: { name: string; passed: boolean; messages: string[] },
    ) => {
      for (const item of byName.get(outcome.name) ?? []) {
        settled.add(item.id);
        if (outcome.passed) {
          run.passed(item);
        } else {
          const text = outcome.messages.length > 0 ? outcome.messages.join("\n") : "Test failed";
          const message = new vscode.TestMessage(text);
          if (item.range) message.location = new vscode.Location(item.uri!, item.range.start);
          run.failed(item, message);
        }
      }
    };

    return new Promise<void>((resolve) => {
      const child = spawn(exe, args, { cwd: root, env, windowsHide: true });
      const sub = token.onCancellationRequested(() => child.kill());
      const onStdout = (line: string) => {
        run.appendOutput(line + "\r\n", undefined, only);
        const result = parseResultLine(line);
        if (!result) {
          if (line.trim() !== "") otherLines.push(line);
          return;
        }
        outcomes.push(result);
        // A pass is known at once; a failure waits for its message, which
        // arrives on the other stream (see attachMessages).
        if (result.passed) settle({ ...result, messages: [] });
      };
      const onStderr = (line: string) => {
        run.appendOutput(line + "\r\n", undefined, only);
        const assertion = parseAssertionLine(line);
        if (assertion !== undefined) assertions.push(assertion);
        else if (line.trim() !== "") otherLines.push(line);
      };
      const out = lineSplitter(onStdout);
      const err = lineSplitter(onStderr);
      child.stdout.on("data", (d: Buffer) => out.push(d.toString()));
      child.stderr.on("data", (d: Buffer) => err.push(d.toString()));
      child.on("error", (e) => {
        run.appendOutput(`Could not run ${exe}: ${e.message}\r\n`);
        for (const t of targets) {
          if (!settled.has(t.id)) run.errored(t, new vscode.TestMessage(`Could not run ${exe}: ${e.message}`));
        }
        sub.dispose();
        resolve();
      });
      child.on("close", (code) => {
        out.flush();
        err.flush();
        sub.dispose();
        for (const outcome of attachMessages(outcomes, assertions)) {
          if (!outcome.passed) settle(outcome);
        }
        const unsettled = targets.filter((t) => !settled.has(t.id));
        if (unsettled.length > 0) {
          const detail = otherLines.join("\n").trim();
          if (token.isCancellationRequested) {
            unsettled.forEach((t) => run.skipped(t));
          } else if (code !== 0) {
            const message = new vscode.TestMessage(
              detail !== "" ? detail : `fun test exited with code ${code}`,
            );
            unsettled.forEach((t) => run.errored(t, message));
          } else {
            unsettled.forEach((t) => run.skipped(t));
          }
        }
        log.info(`fun ${args.join(" ")} finished in ${Date.now() - started}ms (exit ${code})`);
        resolve();
      });
    });
  }

  function collectChildren(file: vscode.TestItem): vscode.TestItem[] {
    const out: vscode.TestItem[] = [];
    file.children.forEach((c) => out.push(c));
    return out;
  }

  async function runTests(
    request: vscode.TestRunRequest,
    token: vscode.CancellationToken,
    withCoverage: boolean,
  ): Promise<void> {
    const run = controller.createTestRun(request);
    const files = collectRuns(request);
    if (files.length === 0) {
      run.end();
      return;
    }

    // Save what is being tested first, so the run sees what is on screen.
    await vscode.workspace.saveAll(false);

    for (const { file, tests } of files) {
      const list = tests ?? collectChildren(file);
      list.forEach((t) => run.enqueued(t));
    }

    const coverageDir = withCoverage
      ? fs.mkdtempSync(path.join(os.tmpdir(), "fun-coverage-"))
      : undefined;
    const reports: CoverageReport[] = [];
    let counter = 0;

    const runOne = async (job: FileRun) => {
      const tests = job.tests;
      const all = collectChildren(job.file);
      const wholeFile = tests === undefined || tests.length === all.length;
      const jsonFor = () =>
        coverageDir ? path.join(coverageDir, `run-${counter++}.json`) : undefined;
      const jobs = wholeFile ? [undefined] : tests!;
      for (const single of jobs) {
        if (token.isCancellationRequested) break;
        const json = jsonFor();
        await runProcess(run, job.file, single, json, token);
        if (json && fs.existsSync(json)) {
          try {
            reports.push(parseCoverageJson(fs.readFileSync(json, "utf8")));
          } catch (err) {
            log.warn(`Could not read coverage for ${job.file.uri?.fsPath}: ${String(err)}`);
          }
        }
      }
    };

    // A few files at a time: each is its own compile and process.
    const queue = [...files];
    const workers = Array.from({ length: Math.min(maxParallelFiles, queue.length) }, async () => {
      for (let job = queue.shift(); job; job = queue.shift()) {
        await runOne(job);
      }
    });
    await Promise.all(workers);

    if (coverageDir) {
      const merged = mergeCoverage(reports);
      const rootFor = (p: string): string => {
        // Report paths are relative to the workspace folder the process ran in.
        const folders = vscode.workspace.workspaceFolders ?? [];
        for (const f of folders) {
          if (fs.existsSync(path.join(f.uri.fsPath, p))) return f.uri.fsPath;
        }
        return folders[0]?.uri.fsPath ?? "";
      };
      for (const file of merged.files) {
        const uri = vscode.Uri.file(path.join(rootFor(file.path), file.path));
        const { covered, total } = countLines(file);
        const fc = new vscode.FileCoverage(uri, new vscode.TestCoverageCount(covered, total));
        detailsByCoverage.set(fc, file);
        run.addCoverage(fc);
      }
      fs.rmSync(coverageDir, { recursive: true, force: true });
    }
    run.end();
  }

  // ---------------------------------------------------------------- profiles

  const runProfile = controller.createRunProfile(
    "Run",
    vscode.TestRunProfileKind.Run,
    (request, token) => runTests(request, token, false),
    true,
  );
  const coverageProfile = controller.createRunProfile(
    "Coverage",
    vscode.TestRunProfileKind.Coverage,
    (request, token) => runTests(request, token, true),
    false,
  );
  coverageProfile.loadDetailedCoverage = async (_run, fileCoverage) => {
    const file = detailsByCoverage.get(fileCoverage);
    if (!file) return [];
    const details: vscode.StatementCoverage[] = [];
    for (const [line, hits] of [...file.lines.entries()].sort((a, b) => a[0] - b[0])) {
      details.push(new vscode.StatementCoverage(hits, new vscode.Position(line - 1, 0)));
    }
    return details;
  };
  const debugProfile = controller.createRunProfile(
    "Debug",
    vscode.TestRunProfileKind.Debug,
    async (request, token) => {
      const run = controller.createTestRun(request);
      const wanted = collectRuns(request).flatMap((j) =>
        (j.tests ?? collectChildren(j.file)).map((t) => ({ file: j.file, test: t })),
      );
      for (const { file, test } of wanted) {
        if (token.isCancellationRequested) break;
        const name = testInfo.get(test.id)?.name;
        if (!name) continue;
        run.started(test);
        // The debugger runs in its own session, so its result is not read back.
        await vscode.commands.executeCommand("fun.debugTest", file.uri, name);
        run.skipped(test);
      }
      run.end();
    },
    false,
  );
  context.subscriptions.push(runProfile, coverageProfile, debugProfile);
}
