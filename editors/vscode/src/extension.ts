import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import * as vscode from "vscode";

import {
  CloseAction,
  ErrorAction,
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  StreamInfo,
} from "vscode-languageclient/node";

import { spawn } from "child_process";

declare const process: any;

let client: LanguageClient | undefined;

function workspaceRootPath(): string | undefined {
  const folder = vscode.workspace.workspaceFolders?.[0];
  return folder?.uri.fsPath;
}

function expandWorkspaceVars(p: string, root: string | undefined): string {
  if (!root) return p;
  return p.replace(/\$\{workspaceFolder\}|\$\{workspaceRoot\}/g, root);
}

function stripOuterQuotes(p: string): string {
  const s = (p ?? "").trim();
  if (
    (s.startsWith('"') && s.endsWith('"')) ||
    (s.startsWith("'") && s.endsWith("'"))
  ) {
    return s.slice(1, -1);
  }
  return s;
}

function expandWindowsEnvVars(p: string): string {
  // Expand %VAR% on Windows (best-effort).
  return p.replace(/%([^%]+)%/g, (_, name: string) => {
    const v = process?.env?.[name];
    return typeof v === "string" ? v : `%${name}%`;
  });
}

function resolveExe(
  configured: string,
  root: string | undefined,
  defaultRel: string,
): string {
  const trimmed = stripOuterQuotes(configured ?? "");
  const expanded = expandWindowsEnvVars(expandWorkspaceVars(trimmed, root));

  // If user left it as default, try workspace-local fun-out first.
  if (!expanded || expanded === "fls" || expanded === "fun") {
    if (root) {
      const candidate = path.join(root, defaultRel);
      if (fs.existsSync(candidate)) return candidate;
    }
    return expanded || path.basename(defaultRel);
  }

  // If relative path, resolve against workspace.
  if (
    root &&
    !path.isAbsolute(expanded) &&
    (expanded.includes("/") || expanded.includes("\\"))
  )
    return path.join(root, expanded);

  return expanded;
}

function platformExeName(base: string): string {
  return process?.platform === "win32" ? `${base}.exe` : base;
}

function isWindows(): boolean {
  return process?.platform === "win32";
}

// Builds the shell fragment that invokes `exe` in the integrated terminal.
// On Windows (PowerShell), a quoted string is a value, not a command — `& `
// is required to invoke it. On POSIX shells, quoting a command name is fine.
function shellInvoke(exe: string): string {
  return isWindows() ? `& "${exe}"` : `"${exe}"`;
}

// Escapes a string to be safely embedded inside double quotes in the terminal.
// PowerShell uses backtick as the escape character; POSIX shells use backslash.
function shellEscapeArg(s: string): string {
  if (isWindows()) {
    return s.replace(/["`$]/g, "`$&");
  }
  return s.replace(/(["\\$`])/g, "\\$1");
}

function splitPathList(p: string | undefined): string[] {
  if (!p) return [];
  return String(p)
    .split(isWindows() ? ";" : ":")
    .map((s) => s.trim())
    .filter(Boolean);
}

function resolveCommandOnPath(command: string): string {
  const cmd = (command ?? "").trim();
  if (!cmd) return "";
  if (cmd.includes("/") || cmd.includes("\\") || path.isAbsolute(cmd))
    return "";

  const pathDirs = splitPathList(process?.env?.PATH);
  const hasExt = path.extname(cmd).length > 0;

  const pathext = isWindows()
    ? splitPathList(process?.env?.PATHEXT).map((e) => e.toLowerCase())
    : [];

  const candidates = isWindows()
    ? hasExt
      ? [cmd]
      : [cmd, ...pathext.map((ext) => `${cmd}${ext}`), `${cmd}.exe`]
    : [cmd];

  for (const dir of pathDirs) {
    for (const c of candidates) {
      const full = path.join(dir, c);
      try {
        if (fs.existsSync(full)) return full;
      } catch {
        // ignore
      }
    }
  }

  return "";
}

function looksLikeBinDir(dirPath: string): boolean {
  const base = path.basename(dirPath).toLowerCase();
  return base === "bin";
}

function isStdlibRoot(dirPath: string): boolean {
  try {
    return fs.existsSync(path.join(dirPath, "std"));
  } catch {
    return false;
  }
}

function normalizeStdlibRoot(p: string): string {
  const s = stripOuterQuotes(p ?? "").trim();
  if (!s) return "";
  if (isStdlibRoot(s)) return s;

  // Common installer/env mismatch: FUN_STDLIB_DIR points at .../stdlib but
  // the actual layout is .../std directly under the parent.
  try {
    if (path.basename(s).toLowerCase() === "stdlib") {
      const parent = path.dirname(s);
      if (parent && isStdlibRoot(parent)) return parent;
    }
  } catch {
    // Best-effort only.
  }

  return "";
}

function deriveStdlibDirFromExe(exePath: string): string {
  try {
    const exeDir = path.dirname(exePath);
    const prefix = looksLikeBinDir(exeDir) ? path.dirname(exeDir) : exeDir;

    // Support both layouts:
    // - <prefix>/share/fun/std/...
    // - <prefix>/share/fun/stdlib/std/...
    const cand1 = path.join(prefix, "share", "fun");
    if (isStdlibRoot(cand1)) return cand1;
    const cand2 = path.join(prefix, "share", "fun", "stdlib");
    if (isStdlibRoot(cand2)) return cand2;
  } catch {
    // Best-effort only.
  }
  return "";
}

// ---------------------------------------------------------------------------
// Helpers for Run / Debug code lenses
// ---------------------------------------------------------------------------

/** Spawn a process with an args array (no shell), resolve stdout on success. */
function runProcess(
  cmd: string,
  args: string[],
  cwd: string,
  extraEnv?: Record<string, string>,
): Promise<string> {
  return new Promise((resolve, reject) => {
    const env = extraEnv ? { ...(process?.env ?? {}), ...extraEnv } : undefined;
    const child = spawn(cmd, args, {
      cwd,
      env,
      stdio: "pipe",
      windowsHide: true,
    });
    let stdout = "";
    let stderr = "";
    child.stdout?.on("data", (d: Buffer) => (stdout += d.toString()));
    child.stderr?.on("data", (d: Buffer) => (stderr += d.toString()));
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) resolve(stdout);
      else {
        const parts = [stderr.trim(), stdout.trim()].filter(Boolean);
        reject(
          new Error(parts.join("\n") || `exited with code ${code}`),
        );
      }
    });
  });
}

/**
 * Build extra env vars needed by the `fun` compiler subprocess.
 * Ensures FUN_STDLIB_DIR is set even when VS Code is launched from the Dock
 * (where shell env vars like FUN_STDLIB_DIR are not inherited).
 */
function buildFunEnv(root: string | undefined): Record<string, string> {
  const config = vscode.workspace.getConfiguration("fun");
  const funCfg = config.get<string>("fls.funPath", "");
  const stdlibCfg = config.get<string>("fls.stdlibDir", "");
  const funDefaultRel = path.join("fun-out", "bin", platformExeName("fun"));
  const funPath = resolveExe(funCfg, root, funDefaultRel);

  const existingStdlibRaw =
    typeof process?.env?.FUN_STDLIB_DIR === "string"
      ? String(process.env.FUN_STDLIB_DIR)
      : "";
  const existingStdlib = normalizeStdlibRoot(existingStdlibRaw);

  const stdlibCfgExpanded = expandWindowsEnvVars(
    expandWorkspaceVars(stripOuterQuotes(stdlibCfg ?? ""), root),
  );
  const stdlibCfgResolved =
    root &&
    !path.isAbsolute(stdlibCfgExpanded) &&
    (stdlibCfgExpanded.includes("/") || stdlibCfgExpanded.includes("\\"))
      ? path.join(root, stdlibCfgExpanded)
      : stdlibCfgExpanded;
  const stdlibCfgNormalized = normalizeStdlibRoot(stdlibCfgResolved);

  const resolvedFunExe =
    funPath && funPath.trim().length > 0 && fs.existsSync(funPath)
      ? funPath
      : "";
  const resolvedFunExeOnPath = !resolvedFunExe
    ? resolveCommandOnPath(funPath)
    : "";

  const derivedStdlib =
    stdlibCfgNormalized ||
    existingStdlib ||
    (resolvedFunExe ? deriveStdlibDirFromExe(resolvedFunExe) : "") ||
    (resolvedFunExeOnPath
      ? deriveStdlibDirFromExe(resolvedFunExeOnPath)
      : "") ||
    (root
      ? deriveStdlibDirFromExe(
          path.join(root, "fun-out", "bin", platformExeName("fun")),
        )
      : "");

  const extra: Record<string, string> = {};
  if (derivedStdlib) extra["FUN_STDLIB_DIR"] = derivedStdlib;
  return extra;
}

/** Resolve the `fun` compiler executable from VS Code settings or defaults. */
function resolveFunCompilerExe(root: string | undefined): string {
  const config = vscode.workspace.getConfiguration("fun");
  const funCfg = config.get<string>("fls.funPath", "");
  const funDefaultRel = path.join("fun-out", "bin", platformExeName("fun"));
  const resolved = resolveExe(funCfg, root, funDefaultRel);
  return resolved || "fun";
}

/**
 * Cache for the MSVC developer environment sourced from vcvarsall.bat.
 * null = not yet fetched; {} = fetched but not found; otherwise the full env map.
 */
let _cachedMsvcEnv: Record<string, string> | null = null;

/**
 * On Windows, locate the MSVC toolchain via vswhere.exe and source
 * vcvarsall.bat x64 in a cmd subshell to obtain the full developer
 * environment (INCLUDE, LIB, PATH with cl.exe, etc.).
 * Returns an empty map when VS or vswhere is not found.
 * The result is cached for the lifetime of the VS Code session.
 */
async function findMsvcEnv(root: string): Promise<Record<string, string>> {
  if (_cachedMsvcEnv !== null) return _cachedMsvcEnv;
  try {
    const progFilesX86 =
      (process?.env?.["ProgramFiles(x86)"] as string | undefined) ??
      "C:\\Program Files (x86)";
    const vswhere = path.join(
      progFilesX86,
      "Microsoft Visual Studio",
      "Installer",
      "vswhere.exe",
    );
    if (!fs.existsSync(vswhere)) {
      _cachedMsvcEnv = {};
      return _cachedMsvcEnv;
    }
    const installPath = (
      await runProcess(
        vswhere,
        ["-latest", "-property", "installationPath"],
        root,
      )
    ).trim();
    if (!installPath) {
      _cachedMsvcEnv = {};
      return _cachedMsvcEnv;
    }
    const vcvarsall = path.join(
      installPath,
      "VC",
      "Auxiliary",
      "Build",
      "vcvarsall.bat",
    );
    if (!fs.existsSync(vcvarsall)) {
      _cachedMsvcEnv = {};
      return _cachedMsvcEnv;
    }
    // Write a temp batch file to invoke vcvarsall.bat and capture `set` output.
    // A temp file avoids cmd.exe quoting issues when vcvarsall's path has spaces.
    const batFile = path.join(os.tmpdir(), `fun_msvc_${Date.now()}.bat`);
    fs.writeFileSync(
      batFile,
      `@echo off\r\ncall "${vcvarsall}" x64 > NUL 2>&1\r\nset\r\n`,
    );
    let envText: string;
    try {
      envText = await runProcess("cmd.exe", ["/c", batFile], root);
    } finally {
      fs.unlink(batFile, () => {});
    }
    const env: Record<string, string> = {};
    for (const line of envText.split(/\r?\n/)) {
      const eq = line.indexOf("=");
      if (eq > 0) {
        env[line.substring(0, eq)] = line.substring(eq + 1);
      }
    }
    _cachedMsvcEnv = env;
    return env;
  } catch {
    _cachedMsvcEnv = {};
    return _cachedMsvcEnv;
  }
}

/**
 * Compile a C file to a native binary for debugging.
 * On Windows tries clang → clang-cl → cl. On POSIX tries cc → clang → gcc.
 * Returns null on success, or the last error string on failure.
 */
async function compileCToNative(
  cFile: string,
  binFile: string,
  root: string,
  extraEnv?: Record<string, string>,
  output?: vscode.OutputChannel,
): Promise<string | null> {
  const linkArgs = isWindows() ? ["-lws2_32"] : ["-lm", "-pthread"];

  function isMsvcCompiler(cc: string): boolean {
    const base = path.basename(cc).toLowerCase();
    return base === "cl" || base === "cl.exe";
  }

  async function tryCompile(cc: string, env: Record<string, string> | undefined): Promise<void> {
    if (isMsvcCompiler(cc)) {
      const pdbFile = binFile.replace(/\.exe$/i, ".pdb");
      await runProcess(
        cc,
        ["/nologo", "/std:c17", cFile, `/Fe:${binFile}`, `/Fd:${pdbFile}`, "/Zi", "/Od"],
        root,
        env,
      );
    } else if (isWindows() && path.basename(cc).toLowerCase() === "clang-cl") {
      await runProcess(cc, ["-Z7", "-Od", cFile, `-Fe${binFile}`], root, env);
    } else {
      await runProcess(cc, ["-g", cFile, "-o", binFile, ...linkArgs], root, env);
    }
  }

  const compilers = isWindows()
    ? ["clang", "clang-cl", "cl"]
    : ["cc", "clang", "gcc"];
  let lastErr = "";
  for (const cc of compilers) {
    try {
      await tryCompile(cc, extraEnv);
      output?.appendLine(`[debug] compiled with ${cc}`);
      return null;
    } catch (e: any) {
      lastErr = e?.message ?? String(e);
      output?.appendLine(`[debug] ${cc} failed: ${lastErr}`);
    }
  }
  return lastErr;
}

/** Return which native debugger type to use (CodeLLDB or cpptools). */
function detectDebugType(): string {
  const configured = vscode.workspace
    .getConfiguration("fun")
    .get<string>("debugger.type", "");
  if (configured) return configured;
  if (vscode.extensions.getExtension("vadimcn.vscode-lldb")) return "lldb";
  if (vscode.extensions.getExtension("ms-vscode.cpptools"))
    return process?.platform === "win32" ? "cppvsdbg" : "cppdbg";
  // On Windows, cppvsdbg (Visual Studio native engine) is most likely available.
  return process?.platform === "win32" ? "cppvsdbg" : "lldb";
}

/** Build the VS Code debug configuration for a compiled Fun binary. */
function buildDebugConfig(
  program: string,
  cwd: string,
  args: string[] = [],
): vscode.DebugConfiguration {
  // Arm the runtime deadlock watchdog for debug sessions (warn-only, ~1s
  // threshold). A hang while debugging then surfaces a "possible deadlock"
  // diagnostic on stderr instead of stalling silently. Plain "Run" (fun.runFile)
  // does NOT set this, so production runs stay byte-identical. Configurable via
  // the `fun.debug.watchdogMs` / `fun.debug.watchdogAbort` settings.
  const wdConfig = vscode.workspace.getConfiguration("fun");
  const wdMs = wdConfig.get<number>("debug.watchdogMs", 1000);
  const wdAbort = wdConfig.get<boolean>("debug.watchdogAbort", false);
  // As a name/value map (CodeLLDB) and as a name/value list (cpptools).
  const envMap: Record<string, string> = {};
  if (wdMs > 0) {
    envMap["FUN_DEADLOCK_WATCHDOG_MS"] = String(wdMs);
    if (wdAbort) envMap["FUN_DEADLOCK_ABORT"] = "1";
  }
  const envList = Object.entries(envMap).map(([name, value]) => ({
    name,
    value,
  }));

  const debugType = detectDebugType();
  if (debugType === "cppvsdbg") {
    // cpptools Windows-native engine (Visual Studio debugger). Reads PDB
    // debug info produced by cl.exe /Zi — no MIMode, no GDB/LLDB required.
    return {
      type: "cppvsdbg",
      request: "launch",
      name: "Debug Fun Program",
      program,
      args,
      cwd,
      environment: envList,
      stopAtEntry: false,
    };
  }
  if (debugType === "cppdbg") {
    // cpptools on macOS/Linux uses LLDB as the MI backend.
    return {
      type: "cppdbg",
      request: "launch",
      name: "Debug Fun Program",
      program,
      args,
      cwd,
      environment: envList,
      stopAtEntry: false,
      MIMode: "lldb",
      setupCommands: [
        {
          description: "Enable pretty-printing",
          text: "-enable-pretty-printing",
          ignoreFailures: true,
        },
      ],
    };
  }
  // CodeLLDB ("lldb") — works on macOS, Linux, and Windows.
  return {
    type: "lldb",
    request: "launch",
    name: "Debug Fun Program",
    program,
    args,
    cwd,
    env: envMap,
    stopAtEntry: false,
  };
}

// ---------------------------------------------------------------------------
// DAP type-remapping tracker — C types → Fun types in Variables/Evaluate
// ---------------------------------------------------------------------------

/** Exact C type → Fun type reverse mapping, mirroring codegen/typedefs.fn's map_type_to_c(). */
const C_TO_FUN_TYPES: ReadonlyMap<string, string> = new Map([
  // Numeric primitives
  ["int64_t", "num"],
  ["double", "dec"],
  ["float", "f32"],
  ["int8_t", "i8"],
  ["int16_t", "i16"],
  ["int32_t", "i32"],
  ["uint8_t", "u8"],
  ["uint16_t", "u16"],
  ["uint32_t", "u32"],
  ["uint64_t", "u64"],
  // Other primitives
  ["char *", "str"],
  ["char*", "str"],
  ["const char *", "str"],
  ["const char*", "str"],
  ["bool", "bin"],
  ["_Bool", "bin"],
  ["char", "chr"],
  // void* → raw* (opaque pointer); plain void stays as void (Fun's own void keyword)
  ["void *", "raw*"],
  ["void*", "raw*"],
]);

function remapFunType(cType: string | undefined): string | undefined {
  if (!cType) return cType;
  const direct = C_TO_FUN_TYPES.get(cType.trim());
  if (direct) return direct;

  // Pointer types: "SomeStruct *" → keep as-is (user-defined), but handle
  // primitive pointers already covered above. Strip const qualifiers first.
  const noConst = cType
    .replace(/\bconst\b/g, "")
    .replace(/\s+/g, " ")
    .trim();
  const directNoConst = C_TO_FUN_TYPES.get(noConst);
  if (directNoConst) return directNoConst;

  return cType; // Unknown → leave unchanged
}

function remapVariableBody(body: Record<string, unknown>): void {
  if (typeof body["type"] === "string") {
    body["type"] = remapFunType(body["type"] as string);
  }
}

/**
 * DAP tracker that rewrites C type strings in `variables` and `evaluate`
 * responses so the Variables panel and Watch panel show Fun types instead of
 * their C equivalents.
 *
 * We only activate this tracker for sessions whose configuration name is
 * "Debug Fun Program" so it doesn't interfere with unrelated C/C++ sessions.
 */
class FunDapTracker implements vscode.DebugAdapterTracker {
  onDidSendMessage(message: unknown): void {
    if (!message || typeof message !== "object") return;
    const msg = message as Record<string, unknown>;
    if (msg["type"] !== "response") return;

    const command = msg["command"] as string | undefined;
    const body = msg["body"];
    if (!body || typeof body !== "object") return;
    const b = body as Record<string, unknown>;

    if (command === "variables") {
      const vars = b["variables"];
      if (Array.isArray(vars)) {
        for (const v of vars) {
          if (v && typeof v === "object")
            remapVariableBody(v as Record<string, unknown>);
        }
      }
    } else if (command === "evaluate") {
      remapVariableBody(b);
    } else if (command === "stackTrace") {
      // Stack frames already show Fun source via #line directives.
      // Clean up any residual C frame names that CodeLLDB may show for
      // inlined/synthetic frames (e.g., "__fun_thread_entry_win").
      const frames = b["stackFrames"];
      if (Array.isArray(frames)) {
        for (const f of frames) {
          if (f && typeof f === "object") {
            const frame = f as Record<string, unknown>;
            const src = frame["source"] as Record<string, unknown> | undefined;
            // Mark frames whose source is our temp .c file as non-primary
            // so they are collapsed by default.
            if (src && typeof src["path"] === "string") {
              const p = src["path"] as string;
              if (p.endsWith(".c") && p.includes("fun_dbg_")) {
                frame["presentationHint"] = "subtle";
              }
            }
          }
        }
      }
    }
  }
}

class FunDapTrackerFactory implements vscode.DebugAdapterTrackerFactory {
  createDebugAdapterTracker(
    session: vscode.DebugSession,
  ): vscode.DebugAdapterTracker | undefined {
    if (session.configuration.name === "Debug Fun Program") {
      return new FunDapTracker();
    }
    return undefined;
  }
}

// ---------------------------------------------------------------------------
// Code Lens Provider — shows "▶ Run  ⚙ Debug" above fn main(
// ---------------------------------------------------------------------------

class FunCodeLensProvider implements vscode.CodeLensProvider {
  private readonly _onDidChange = new vscode.EventEmitter<void>();
  readonly onDidChangeCodeLenses: vscode.Event<void> = this._onDidChange.event;

  refresh(): void {
    this._onDidChange.fire();
  }

  provideCodeLenses(document: vscode.TextDocument): vscode.CodeLens[] {
    const lenses: vscode.CodeLens[] = [];
    // Matches `test "name" {`, allowing an escaped `\"` inside the name the
    // same way the lexer does for any other string literal.
    const testLineRe = /^\s*test\s+"((?:[^"\\]|\\.)*)"\s*\{/;
    // Matches `fuzz "name" (raw* data, num len) {` -- same name-escaping
    // rule as `test`; the params themselves aren't matched here (any
    // explicitly-typed two-param list is accepted at the `(`, and their
    // fixed shape is validated by the compiler's own parse_fuzz).
    const fuzzLineRe = /^\s*fuzz\s+"((?:[^"\\]|\\.)*)"\s*\(/;
    let sawMain = false;
    for (let i = 0; i < document.lineCount; i++) {
      const text = document.lineAt(i).text;
      if (!sawMain && /^\s*(async\s+)?fun\s+main\s*\(/.test(text)) {
        const range = new vscode.Range(i, 0, i, 0);
        lenses.push(
          new vscode.CodeLens(range, {
            title: "▶ Run",
            command: "fun.runFile",
            arguments: [document.uri],
          }),
          new vscode.CodeLens(range, {
            title: "⚙ Debug",
            command: "fun.debugFile",
            arguments: [document.uri],
          }),
        );
        sawMain = true; // only one main per file
        continue;
      }
      const testMatch = testLineRe.exec(text);
      if (testMatch) {
        const testName = testMatch[1].replace(/\\(.)/g, "$1");
        const range = new vscode.Range(i, 0, i, 0);
        lenses.push(
          new vscode.CodeLens(range, {
            title: "▶ Run Test",
            command: "fun.runTest",
            arguments: [document.uri, testName],
          }),
          new vscode.CodeLens(range, {
            title: "⚙ Debug Test",
            command: "fun.debugTest",
            arguments: [document.uri, testName],
          }),
        );
        continue;
      }
      const fuzzMatch = fuzzLineRe.exec(text);
      if (fuzzMatch) {
        const fuzzName = fuzzMatch[1].replace(/\\(.)/g, "$1");
        const range = new vscode.Range(i, 0, i, 0);
        lenses.push(
          new vscode.CodeLens(range, {
            title: "▶ Fuzz",
            command: "fun.fuzzTarget",
            arguments: [document.uri, fuzzName],
          }),
        );
      }
    }
    return lenses;
  }
}

function openOutput(output: vscode.LogOutputChannel): void {
  // Keep this deterministic: just reveal our channel.
  try {
    output.show(true);
  } catch {
    // Best-effort: never throw from a helper used in activation/commands.
  }
}

function createClient(output: vscode.LogOutputChannel): LanguageClient {
  const root = workspaceRootPath();
  const config = vscode.workspace.getConfiguration("fun");
  const flsCfg = config.get<string>("fls.path", "fls");
  const funCfg = config.get<string>("fls.funPath", "");
  const stdlibCfg = config.get<string>("fls.stdlibDir", "");
  const debugAll = config.get<boolean>("fls.debug", false);
  const debugImports = config.get<boolean>("fls.debugImports", false);
  const debugDefinitions = config.get<boolean>("fls.debugDefinitions", false);

  const flsDefaultRel = path.join("fun-out", "bin", platformExeName("fls"));
  const funDefaultRel = path.join("fun-out", "bin", platformExeName("fun"));

  const flsResolved = resolveExe(flsCfg, root, flsDefaultRel);
  const flsPath = flsResolved;
  const funPath = resolveExe(funCfg, root, funDefaultRel);

  output.appendLine(`workspaceRoot = ${root ?? "(none)"}`);
  output.appendLine(`workspaceTrusted = ${vscode.workspace.isTrusted}`);
  output.appendLine(`fun.fls.path (raw) = ${flsCfg}`);
  output.appendLine(`fun.fls.path (resolved) = ${flsPath}`);
  output.appendLine(`fun.fls.funPath (raw) = ${funCfg || "(empty)"}`);
  output.appendLine(`fun.fls.funPath (resolved) = ${funPath || "(empty)"}`);
  output.appendLine(`fun.fls.stdlibDir (raw) = ${stdlibCfg || "(empty)"}`);
  output.appendLine(`fun.fls.debug = ${debugAll}`);
  output.appendLine(`fun.fls.debugImports = ${debugImports}`);
  output.appendLine(`fun.fls.debugDefinitions = ${debugDefinitions}`);

  // If flsPath looks like a path but doesn't exist, fail fast with a clear message.
  const flsLooksLikePath =
    flsPath.includes("\\") || flsPath.includes("/") || path.isAbsolute(flsPath);
  if (flsLooksLikePath && !fs.existsSync(flsPath)) {
    output.appendLine(`ERROR: fls executable not found at: ${flsPath}`);
    output.appendLine(
      "Fix: set Fun settings `fun.fls.path` to a valid fls executable path.",
    );
  }

  // If configured as a bare command (e.g. "fls"), resolve it via PATH so we can derive
  // the install prefix and stdlib root even when VS Code doesn't inherit FUN_STDLIB_DIR.
  const flsResolvedOnPath = !flsLooksLikePath
    ? resolveCommandOnPath(flsPath)
    : "";
  if (flsResolvedOnPath)
    output.appendLine(`fun.fls.path (resolved on PATH) = ${flsResolvedOnPath}`);

  // Only set FLS_FUN_PATH if we have a real executable.
  const resolvedFunExe =
    funPath && funPath.trim().length > 0 && fs.existsSync(funPath)
      ? funPath
      : "";
  const resolvedFunExeOnPath = !resolvedFunExe
    ? resolveCommandOnPath(funPath)
    : "";
  if (resolvedFunExeOnPath)
    output.appendLine(
      `fun.fls.funPath (resolved on PATH) = ${resolvedFunExeOnPath}`,
    );

  // Ensure FUN_STDLIB_DIR is available even when VS Code doesn't inherit installer env vars.
  // We only set it if the environment doesn't already define it.
  const existingStdlibRaw =
    typeof process?.env?.FUN_STDLIB_DIR === "string"
      ? String(process.env.FUN_STDLIB_DIR)
      : "";
  const existingStdlib = normalizeStdlibRoot(existingStdlibRaw);

  const stdlibCfgExpanded = expandWindowsEnvVars(
    expandWorkspaceVars(stripOuterQuotes(stdlibCfg ?? ""), root),
  );
  const stdlibCfgResolved =
    root &&
    !path.isAbsolute(stdlibCfgExpanded) &&
    (stdlibCfgExpanded.includes("/") || stdlibCfgExpanded.includes("\\"))
      ? path.join(root, stdlibCfgExpanded)
      : stdlibCfgExpanded;
  const stdlibCfgNormalized = normalizeStdlibRoot(stdlibCfgResolved);

  const derivedStdlib =
    stdlibCfgNormalized ||
    existingStdlib ||
    (flsLooksLikePath && fs.existsSync(flsPath)
      ? deriveStdlibDirFromExe(flsPath)
      : "") ||
    (flsResolvedOnPath ? deriveStdlibDirFromExe(flsResolvedOnPath) : "") ||
    (resolvedFunExe ? deriveStdlibDirFromExe(resolvedFunExe) : "") ||
    (resolvedFunExeOnPath ? deriveStdlibDirFromExe(resolvedFunExeOnPath) : "");

  output.appendLine(`FUN_STDLIB_DIR (env) = ${existingStdlibRaw || "(unset)"}`);
  if (stdlibCfgNormalized)
    output.appendLine(`FUN_STDLIB_DIR (config) = ${stdlibCfgNormalized}`);
  if (existingStdlib && existingStdlib !== existingStdlibRaw) {
    output.appendLine(`FUN_STDLIB_DIR (normalized) = ${existingStdlib}`);
  }
  if (derivedStdlib && derivedStdlib !== existingStdlibRaw) {
    output.appendLine(`FUN_STDLIB_DIR (derived) = ${derivedStdlib}`);
  }

  const env = {
    ...(process?.env ?? {}),
    ...(resolvedFunExe ? { FLS_FUN_PATH: resolvedFunExe } : {}),
    ...(derivedStdlib ? { FUN_STDLIB_DIR: derivedStdlib } : {}),
    ...(debugAll ? { FLS_DEBUG: "1" } : {}),
    ...(!debugAll && debugImports ? { FLS_DEBUG_IMPORTS: "1" } : {}),
    ...(!debugAll && debugDefinitions ? { FLS_DEBUG_DEFINITIONS: "1" } : {}),
  };

  const serverOptions: ServerOptions = async (): Promise<StreamInfo> => {
    // Fail fast with a clear, actionable error.
    const looksLikePath =
      flsPath.includes("\\") ||
      flsPath.includes("/") ||
      path.isAbsolute(flsPath);
    if (looksLikePath && !fs.existsSync(flsPath)) {
      const msg = `fls executable not found at: ${flsPath}`;
      output.appendLine(`ERROR: ${msg}`);
      openOutput(output);
      throw new Error(msg);
    }

    output.appendLine(`Spawning fls: ${flsPath}`);
    const child = spawn(flsPath, [], {
      cwd: root,
      env,
      stdio: "pipe",
      windowsHide: true,
    });

    child.on("error", (err: any) => {
      output.appendLine(`Failed to spawn fls: ${err?.message ?? String(err)}`);
      output.appendLine(`Command: ${flsPath}`);
      output.appendLine(
        "Tip: remove quotes from fun.fls.path and ensure the file exists.",
      );
      openOutput(output);
    });

    child.stderr?.on("data", (chunk: Buffer) => {
      const s = chunk.toString("utf8");
      if (s.trim().length) output.appendLine(`[fls stderr] ${s.trimEnd()}`);
    });

    child.on("exit", (code, signal) => {
      output.appendLine(
        `fls exited (code=${code}, signal=${signal ?? "none"})`,
      );
    });

    if (!child.stdout || !child.stdin) {
      const msg = "fls stdio not available";
      output.appendLine(`ERROR: ${msg}`);
      openOutput(output);
      throw new Error(msg);
    }

    return { reader: child.stdout, writer: child.stdin };
  };

  // Bound how many times `fls` gets auto-restarted after crashing. Without
  // this, a DETERMINISTIC crash (e.g. one that happens again during the very
  // next startup indexing pass) restarts forever in a tight loop, pinning a
  // CPU core until the user force-quits VS Code -- observed for real with a
  // crash that reproduced on every workspace-index pass. `restartTimestamps`
  // is a rolling window so a server that's merely flaky (crashes rarely, runs
  // fine for a long stretch in between) isn't penalized the same as one stuck
  // in a loop.
  const restartTimestamps: number[] = [];
  const maxRestartsInWindow = 5;
  const restartWindowMs = 3 * 60 * 1000;

  const clientOptions: LanguageClientOptions = {
    documentSelector: [
      { scheme: "file", language: "fun" },
      { scheme: "untitled", language: "fun" },
    ],
    outputChannel: output,
    errorHandler: {
      error: (err) => {
        output.appendLine(`client error: ${err?.message ?? String(err)}`);
        return { action: ErrorAction.Continue };
      },
      closed: () => {
        const now = Date.now();
        restartTimestamps.push(now);
        while (
          restartTimestamps.length > 0 &&
          now - restartTimestamps[0] > restartWindowMs
        ) {
          restartTimestamps.shift();
        }
        if (restartTimestamps.length > maxRestartsInWindow) {
          const msg = `fls crashed ${restartTimestamps.length} times in the last ${Math.round(restartWindowMs / 1000)}s and will not be restarted automatically. Check the "Fun Language Server" output channel, then run "Fun: Restart Language Server" once the cause is fixed.`;
          output.appendLine(`client: ${msg}`);
          vscode.window.showErrorMessage(msg);
          return { action: CloseAction.DoNotRestart, message: msg, handled: true };
        }
        output.appendLine("client: server closed, restarting...");
        return { action: CloseAction.Restart };
      },
    },
    middleware: {
      // Gate parameter-name inlay hints on the user setting (default on).
      // Returning an empty list (without calling the server) hides them while
      // keeping the capability registered, so toggling the setting takes effect
      // immediately without a server restart.
      provideInlayHints: (document, viewPort, token, next) => {
        const enabled = vscode.workspace
          .getConfiguration("fun")
          .get<boolean>("inlayHints.parameterNames.enabled", true);
        if (!enabled) return [];
        return next(document, viewPort, token);
      },
    },
  };

  return new LanguageClient(
    "fls",
    "Fun Language Server",
    serverOptions,
    clientOptions,
  );
}
export function activate(context: vscode.ExtensionContext) {
  const output = vscode.window.createOutputChannel("Fun Language Server", {
    log: true,
  });
  context.subscriptions.push(output);
  openOutput(output);
  output.appendLine("Activating Fun Language extension...");

  // Non-blocking activation: never await during activate().
  void vscode.window.showInformationMessage("Fun Language extension activated");

  if (!vscode.workspace.isTrusted) {
    output.appendLine(
      "Workspace is not trusted (Restricted Mode). Extension activation may be limited until you trust the workspace.",
    );
  }

  client = createClient(output);

  // Do not await `client.start()` here; if fls hangs/crashes during init,
  // VS Code will keep the extension stuck in "Activating...".
  const startPromise = client
    .start()
    .then(() => {
      output.appendLine("fls started.");
    })
    .catch((err: any) => {
      output.appendLine(`Failed to start fls: ${err?.message ?? String(err)}`);
      openOutput(output);
      void vscode.window.showErrorMessage(
        `Fun Language Server failed to start: ${err?.message ?? String(err)}`,
      );
    });

  // Warn if startup takes too long, but keep the extension activated.
  const timeoutMs = 8000;
  const timer = setTimeout(() => {
    output.appendLine(`fls still starting after ${timeoutMs}ms...`);
    output.appendLine(
      "If this persists, check that fun.fls.path points to an existing fls.exe and that the workspace is trusted.",
    );
    openOutput(output);
  }, timeoutMs);
  startPromise.finally(() => clearTimeout(timer));

  context.subscriptions.push({ dispose: () => void client?.stop() });

  // Toggling the inlay-hints setting takes effect on the next inlay-hint query
  // (the client middleware reads the setting live). Nudge VS Code to re-query
  // immediately so the change feels instant rather than waiting for an edit.
  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration("fun.inlayHints.parameterNames.enabled")) {
        // A no-op selection re-set on visible Fun editors triggers a re-query
        // of inlay hints for their visible ranges.
        for (const ed of vscode.window.visibleTextEditors) {
          if (ed.document.languageId === "fun") {
            const sel = ed.selections;
            ed.selections = sel; // touch -> provider re-invoked
          }
        }
      }
    }),
  );

  context.subscriptions.push(
    vscode.commands.registerCommand(
      "fun.showLanguageServerOutput",
      async () => {
        try {
          openOutput(output);
        } catch (err: any) {
          const msg = err?.message ?? String(err);
          void vscode.window.showErrorMessage(
            `Fun: failed to show output: ${msg}`,
          );
        }
      },
    ),
  );

  context.subscriptions.push(
    vscode.commands.registerCommand("fun.restartLanguageServer", async () => {
      openOutput(output);
      output.appendLine("Restarting fls...");
      try {
        if (client) {
          await client.stop();
        }
        client = createClient(output);
        await client.start();
        output.appendLine("fls restarted.");
      } catch (err: any) {
        const msg = err?.message ?? String(err);
        output.appendLine(`ERROR: restart failed: ${msg}`);
        openOutput(output);
        void vscode.window.showErrorMessage(
          `Fun: restart language server failed: ${msg}`,
        );
      }
    }),
  );

  // ---------------------------------------------------------------------------
  // Code Lenses — "▶ Run" and "⚙ Debug" above fn main(
  // ---------------------------------------------------------------------------

  const codeLensProvider = new FunCodeLensProvider();
  context.subscriptions.push(
    vscode.languages.registerCodeLensProvider(
      { language: "fun", scheme: "file" },
      codeLensProvider,
    ),
  );

  // Register the DAP tracker for both lldb and cppdbg sessions.
  // The tracker factory only activates for "Debug Fun Program" sessions.
  const dapTrackerFactory = new FunDapTrackerFactory();
  context.subscriptions.push(
    vscode.debug.registerDebugAdapterTrackerFactory("lldb", dapTrackerFactory),
    vscode.debug.registerDebugAdapterTrackerFactory(
      "cppdbg",
      dapTrackerFactory,
    ),
  );

  // Reuse a single terminal across Run invocations; recreate it if closed.
  let runTerminal: vscode.Terminal | undefined;
  context.subscriptions.push(
    vscode.window.onDidCloseTerminal((t) => {
      if (t === runTerminal) runTerminal = undefined;
    }),
  );

  // Track temp files produced for each debug session so we can clean them up.
  const debugCleanup = new Map<string, string[]>();
  context.subscriptions.push(
    vscode.debug.onDidTerminateDebugSession((session) => {
      const files = debugCleanup.get(session.id);
      if (files) {
        for (const f of files) fs.unlink(f, () => {});
        debugCleanup.delete(session.id);
      }
    }),
  );

  // ▶ Run — compile-and-run in an integrated terminal
  context.subscriptions.push(
    vscode.commands.registerCommand("fun.runFile", async (uri?: vscode.Uri) => {
      const fileUri = uri ?? vscode.window.activeTextEditor?.document.uri;
      if (!fileUri || fileUri.scheme !== "file") return;

      // Save before running.
      const doc = vscode.workspace.textDocuments.find(
        (d) => d.uri.toString() === fileUri.toString(),
      );
      if (doc?.isDirty) await doc.save();

      const root = workspaceRootPath();
      const funExe = resolveFunCompilerExe(root);

      if (!runTerminal || runTerminal.exitStatus !== undefined) {
        runTerminal = vscode.window.createTerminal({ name: "Fun: Run" });
      }
      runTerminal.show(true);
      runTerminal.sendText(`${shellInvoke(funExe)} -in "${fileUri.fsPath}"`);
    }),
  );

  // ▶ Run Test — compile in test mode and run just the one named test,
  // via the runner's own argv[1] exact-name filter (`fun test file.fn --
  // "name"`, see stdlib/std/testing.fn / emit_test_mode_functions_and_runner).
  context.subscriptions.push(
    vscode.commands.registerCommand(
      "fun.runTest",
      async (uri?: vscode.Uri, testName?: string) => {
        const fileUri = uri ?? vscode.window.activeTextEditor?.document.uri;
        if (!fileUri || fileUri.scheme !== "file" || !testName) return;

        const doc = vscode.workspace.textDocuments.find(
          (d) => d.uri.toString() === fileUri.toString(),
        );
        if (doc?.isDirty) await doc.save();

        const root = workspaceRootPath();
        const funExe = resolveFunCompilerExe(root);

        if (!runTerminal || runTerminal.exitStatus !== undefined) {
          runTerminal = vscode.window.createTerminal({ name: "Fun: Run" });
        }
        runTerminal.show(true);
        const escapedName = shellEscapeArg(testName);
        runTerminal.sendText(
          `${shellInvoke(funExe)} -in "${fileUri.fsPath}" -test -- "${escapedName}"`,
        );
      },
    ),
  );

  // ▶ Fuzz — compile in fuzz mode and run the named fuzz target in an
  // integrated terminal, via `-fuzz -fuzz-target "name"` (see
  // emit_fuzz_mode_harness). Unlike Run Test, there's no separate Debug
  // variant: the fuzzing engine's own driver takes over the process and
  // runs indefinitely, so attaching a debugger up front isn't the useful
  // workflow the way it is for a single deterministic test run -- a crash
  // found by fuzzing is reproduced/debugged from its saved input instead.
  context.subscriptions.push(
    vscode.commands.registerCommand(
      "fun.fuzzTarget",
      async (uri?: vscode.Uri, fuzzName?: string) => {
        const fileUri = uri ?? vscode.window.activeTextEditor?.document.uri;
        if (!fileUri || fileUri.scheme !== "file" || !fuzzName) return;

        const doc = vscode.workspace.textDocuments.find(
          (d) => d.uri.toString() === fileUri.toString(),
        );
        if (doc?.isDirty) await doc.save();

        const root = workspaceRootPath();
        const funExe = resolveFunCompilerExe(root);

        if (!runTerminal || runTerminal.exitStatus !== undefined) {
          runTerminal = vscode.window.createTerminal({ name: "Fun: Run" });
        }
        runTerminal.show(true);
        const escapedName = shellEscapeArg(fuzzName);
        runTerminal.sendText(
          `${shellInvoke(funExe)} -in "${fileUri.fsPath}" -fuzz -fuzz-target "${escapedName}"`,
        );
      },
    ),
  );

  // Bridges the "N references" code lens to the built-in references
  // view. fls's own arguments are plain JSON (an LSP Command carries
  // no richer shape than that), but editor.action.showReferences
  // validates its own arguments by type (instanceof Uri/Position) and
  // rejects a plain object outright -- this wrapper is what actually
  // constructs those before handing off to it.
  context.subscriptions.push(
    vscode.commands.registerCommand(
      "fun.showReferences",
      async (
        uriStr: string,
        position: { line: number; character: number },
        locations: {
          uri: string;
          range: {
            start: { line: number; character: number };
            end: { line: number; character: number };
          };
        }[],
      ) => {
        const uri = vscode.Uri.parse(uriStr);
        const pos = new vscode.Position(position.line, position.character);
        const vsLocations = locations.map(
          (loc) =>
            new vscode.Location(
              vscode.Uri.parse(loc.uri),
              new vscode.Range(
                new vscode.Position(
                  loc.range.start.line,
                  loc.range.start.character,
                ),
                new vscode.Position(
                  loc.range.end.line,
                  loc.range.end.character,
                ),
              ),
            ),
        );
        await vscode.commands.executeCommand(
          "editor.action.showReferences",
          uri,
          pos,
          vsLocations,
        );
      },
    ),
  );

  // ⚙ Debug — compile with -g, then launch native debugger
  context.subscriptions.push(
    vscode.commands.registerCommand(
      "fun.debugFile",
      async (uri?: vscode.Uri) => {
        const fileUri = uri ?? vscode.window.activeTextEditor?.document.uri;
        if (!fileUri || fileUri.scheme !== "file") return;

        // Save before compiling.
        const doc = vscode.workspace.textDocuments.find(
          (d) => d.uri.toString() === fileUri.toString(),
        );
        if (doc?.isDirty) await doc.save();

        const root = workspaceRootPath() ?? path.dirname(fileUri.fsPath);
        const funExe = resolveFunCompilerExe(workspaceRootPath());

        // Temp paths for the generated C file and compiled binary.
        const stem = path.basename(
          fileUri.fsPath,
          path.extname(fileUri.fsPath),
        );
        const uid = Date.now();
        const tmpDir = os.tmpdir();
        const cFile = path.join(tmpDir, `fun_dbg_${stem}_${uid}.c`);
        const binFile = path.join(
          tmpDir,
          process?.platform === "win32"
            ? `fun_dbg_${stem}_${uid}.exe`
            : `fun_dbg_${stem}_${uid}`,
        );

        // Fetch MSVC env first so it can be passed to both fun.exe (so it finds
        // cl.exe and emits MSVC-compatible C) and to compileCToNative (so
        // cl.exe can find its headers/libs). Fetching is cached after the first call.
        const msvcEnv = isWindows() ? await findMsvcEnv(root) : undefined;
        if (isWindows()) {
          const envCount = msvcEnv ? Object.keys(msvcEnv).length : 0;
          output.appendLine(`[debug] MSVC env: ${envCount} vars found`);
        }

        try {
          // Step 1: transpile with #line directives, write C file.
          // Passing the absolute path as -in ensures #line directives embed
          // absolute Fun source paths that the debugger can resolve directly.
          // Merging MSVC env so fun.exe can probe cl.exe via resolve_c_compiler
          // and emit MSVC-compatible C (msvc_mode=true in codegen) rather than
          // GNU C (which cl.exe cannot compile).
          const funEnv = {
            ...buildFunEnv(workspaceRootPath()),
            ...(msvcEnv ?? {}),
          };
          await runProcess(
            funExe,
            ["-in", fileUri.fsPath, "-g", "-no-exec", "-outf", "-out", cFile],
            root,
            funEnv,
          );
        } catch (err: any) {
          void vscode.window.showErrorMessage(
            `Fun: compilation failed:\n${err?.message ?? String(err)}`,
          );
          return;
        }

        // Step 2: compile C → native binary with CodeView debug info (cl.exe /Zi).
        {
          const compileErr = await compileCToNative(
            cFile,
            binFile,
            root,
            msvcEnv && Object.keys(msvcEnv).length ? msvcEnv : undefined,
            output,
          );
          if (compileErr !== null) {
            output.appendLine(`[debug] C compilation failed:\n${compileErr}`);
            void vscode.window
              .showErrorMessage(
                "Fun: C compilation failed — see 'Fun Language Server' output for details.",
                "Show Output",
              )
              .then((choice) => {
                if (choice === "Show Output") openOutput(output);
              });
            fs.unlink(cFile, () => {});
            return;
          }
        }

        // Step 3: launch the native debugger.
        const debugType = detectDebugType();
        const noDebugExtMsg =
          debugType === "lldb"
            ? 'Install the "CodeLLDB" extension (vadimcn.vscode-lldb) to debug Fun programs.'
            : 'Install the "C/C++" extension (ms-vscode.cpptools) to debug Fun programs.';

        const folder = vscode.workspace.workspaceFolders?.[0];
        const config = buildDebugConfig(binFile, root);

        const started = await vscode.debug.startDebugging(folder, config).then(
          (ok) => ok,
          (e: any) => {
            void vscode.window.showErrorMessage(
              `Fun: failed to start debugger: ${e?.message ?? String(e)}\n${noDebugExtMsg}`,
            );
            return false;
          },
        );

        if (started) {
          // Register cleanup for when the session ends.
          const disposable = vscode.debug.onDidStartDebugSession((session) => {
            if (session.configuration.name === config.name) {
              debugCleanup.set(session.id, [cFile, binFile]);
              disposable.dispose();
            }
          });
          context.subscriptions.push(disposable);
        } else {
          fs.unlink(cFile, () => {});
          fs.unlink(binFile, () => {});
        }
      },
    ),
  );

  // ⚙ Debug Test — same as ⚙ Debug, but compiles in test mode (-test) and
  // passes the test's exact name as the one program arg, so the compiled
  // runner's own argv[1] filter (see stdlib/std/testing.fn) runs and stops
  // at just that one test under the debugger.
  context.subscriptions.push(
    vscode.commands.registerCommand(
      "fun.debugTest",
      async (uri?: vscode.Uri, testName?: string) => {
        const fileUri = uri ?? vscode.window.activeTextEditor?.document.uri;
        if (!fileUri || fileUri.scheme !== "file" || !testName) return;

        const doc = vscode.workspace.textDocuments.find(
          (d) => d.uri.toString() === fileUri.toString(),
        );
        if (doc?.isDirty) await doc.save();

        const root = workspaceRootPath() ?? path.dirname(fileUri.fsPath);
        const funExe = resolveFunCompilerExe(workspaceRootPath());

        const stem = path.basename(
          fileUri.fsPath,
          path.extname(fileUri.fsPath),
        );
        const uid = Date.now();
        const tmpDir = os.tmpdir();
        const cFile = path.join(tmpDir, `fun_dbg_test_${stem}_${uid}.c`);
        const binFile = path.join(
          tmpDir,
          process?.platform === "win32"
            ? `fun_dbg_test_${stem}_${uid}.exe`
            : `fun_dbg_test_${stem}_${uid}`,
        );

        const msvcEnv = isWindows() ? await findMsvcEnv(root) : undefined;
        if (isWindows()) {
          const envCount = msvcEnv ? Object.keys(msvcEnv).length : 0;
          output.appendLine(`[debug] MSVC env: ${envCount} vars found`);
        }

        try {
          const funEnv = {
            ...buildFunEnv(workspaceRootPath()),
            ...(msvcEnv ?? {}),
          };
          await runProcess(
            funExe,
            [
              "-in",
              fileUri.fsPath,
              "-g",
              "-no-exec",
              "-outf",
              "-out",
              cFile,
              "-test",
            ],
            root,
            funEnv,
          );
        } catch (err: any) {
          void vscode.window.showErrorMessage(
            `Fun: compilation failed:\n${err?.message ?? String(err)}`,
          );
          return;
        }

        {
          const compileErr = await compileCToNative(
            cFile,
            binFile,
            root,
            msvcEnv && Object.keys(msvcEnv).length ? msvcEnv : undefined,
            output,
          );
          if (compileErr !== null) {
            output.appendLine(`[debug] C compilation failed:\n${compileErr}`);
            void vscode.window
              .showErrorMessage(
                "Fun: C compilation failed — see 'Fun Language Server' output for details.",
                "Show Output",
              )
              .then((choice) => {
                if (choice === "Show Output") openOutput(output);
              });
            fs.unlink(cFile, () => {});
            return;
          }
        }

        const debugType = detectDebugType();
        const noDebugExtMsg =
          debugType === "lldb"
            ? 'Install the "CodeLLDB" extension (vadimcn.vscode-lldb) to debug Fun programs.'
            : 'Install the "C/C++" extension (ms-vscode.cpptools) to debug Fun programs.';

        const folder = vscode.workspace.workspaceFolders?.[0];
        const config = buildDebugConfig(binFile, root, [testName]);

        const started = await vscode.debug.startDebugging(folder, config).then(
          (ok) => ok,
          (e: any) => {
            void vscode.window.showErrorMessage(
              `Fun: failed to start debugger: ${e?.message ?? String(e)}\n${noDebugExtMsg}`,
            );
            return false;
          },
        );

        if (started) {
          const disposable = vscode.debug.onDidStartDebugSession((session) => {
            if (session.configuration.name === config.name) {
              debugCleanup.set(session.id, [cFile, binFile]);
              disposable.dispose();
            }
          });
          context.subscriptions.push(disposable);
        } else {
          fs.unlink(cFile, () => {});
          fs.unlink(binFile, () => {});
        }
      },
    ),
  );

  output.appendLine("Activation complete.");
}

export async function deactivate() {
  if (!client) return;
  await client.stop();
  client = undefined;
}
