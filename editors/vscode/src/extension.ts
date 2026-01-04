import * as fs from 'fs';
import * as path from 'path';
import * as vscode from 'vscode';

import {
  CloseAction,
  ErrorAction,
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  StreamInfo,
} from 'vscode-languageclient/node';

import { spawn } from 'child_process';

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
  const s = (p ?? '').trim();
  if ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'"))) {
    return s.slice(1, -1);
  }
  return s;
}

function expandWindowsEnvVars(p: string): string {
  // Expand %VAR% on Windows (best-effort).
  return p.replace(/%([^%]+)%/g, (_, name: string) => {
    const v = process?.env?.[name];
    return typeof v === 'string' ? v : `%${name}%`;
  });
}

function resolveExe(configured: string, root: string | undefined, defaultRel: string): string {
  const trimmed = stripOuterQuotes(configured ?? '');
  const expanded = expandWindowsEnvVars(expandWorkspaceVars(trimmed, root));

  // If user left it as default, try workspace-local zig-out first.
  if (!expanded || expanded === 'fls' || expanded === 'fun') {
    if (root) {
      const candidate = path.join(root, defaultRel);
      if (fs.existsSync(candidate)) return candidate;
    }
    return expanded || path.basename(defaultRel);
  }

  // If relative path, resolve against workspace.
  if (root && !path.isAbsolute(expanded) && (expanded.includes('/') || expanded.includes('\\')))
    return path.join(root, expanded);

  return expanded;
}

function platformExeName(base: string): string {
  return process?.platform === 'win32' ? `${base}.exe` : base;
}

function looksLikeBinDir(dirPath: string): boolean {
  const base = path.basename(dirPath).toLowerCase();
  return base === 'bin';
}

function isStdlibRoot(dirPath: string): boolean {
  try {
    return fs.existsSync(path.join(dirPath, 'std'));
  } catch {
    return false;
  }
}

function normalizeStdlibRoot(p: string): string {
  const s = stripOuterQuotes(p ?? '').trim();
  if (!s) return '';
  if (isStdlibRoot(s)) return s;

  // Common installer/env mismatch: FUN_STDLIB_DIR points at .../stdlib but
  // the actual layout is .../std directly under the parent.
  try {
    if (path.basename(s).toLowerCase() === 'stdlib') {
      const parent = path.dirname(s);
      if (parent && isStdlibRoot(parent)) return parent;
    }
  } catch {
    // Best-effort only.
  }

  return '';
}

function deriveStdlibDirFromExe(exePath: string): string {
  try {
    const exeDir = path.dirname(exePath);
    const prefix = looksLikeBinDir(exeDir) ? path.dirname(exeDir) : exeDir;

    // Support both layouts:
    // - <prefix>/share/fun/std/...
    // - <prefix>/share/fun/stdlib/std/...
    const cand1 = path.join(prefix, 'share', 'fun');
    if (isStdlibRoot(cand1)) return cand1;
    const cand2 = path.join(prefix, 'share', 'fun', 'stdlib');
    if (isStdlibRoot(cand2)) return cand2;
  } catch {
    // Best-effort only.
  }
  return '';
}

function openOutput(output: vscode.OutputChannel): void {
  // `toggleOutput` can actually hide the panel if it's already visible.
  // Keep this deterministic: just reveal our channel.
  try {
    output.show(true);
  } catch {
    // Best-effort: never throw from a helper used in activation/commands.
  }
}

function createClient(output: vscode.OutputChannel): LanguageClient {
  const root = workspaceRootPath();
  const config = vscode.workspace.getConfiguration('fun');
  const flsCfg = config.get<string>('fls.path', 'fls');
  const funCfg = config.get<string>('fls.funPath', '');
  const debugAll = config.get<boolean>('fls.debug', false);
  const debugImports = config.get<boolean>('fls.debugImports', false);
  const debugDefinitions = config.get<boolean>('fls.debugDefinitions', false);

  const flsDefaultRel = path.join('zig-out', 'bin', platformExeName('fls'));
  const funDefaultRel = path.join('zig-out', 'bin', platformExeName('fun'));

  const flsResolved = resolveExe(flsCfg, root, flsDefaultRel);
  const flsPath = flsResolved;
  const funPath = resolveExe(funCfg, root, funDefaultRel);

  output.appendLine(`workspaceRoot = ${root ?? '(none)'}`);
  output.appendLine(`workspaceTrusted = ${vscode.workspace.isTrusted}`);
  output.appendLine(`fun.fls.path (raw) = ${flsCfg}`);
  output.appendLine(`fun.fls.path (resolved) = ${flsPath}`);
  output.appendLine(`fun.fls.funPath (raw) = ${funCfg || '(empty)'}`);
  output.appendLine(`fun.fls.funPath (resolved) = ${funPath || '(empty)'}`);
  output.appendLine(`fun.fls.debug = ${debugAll}`);
  output.appendLine(`fun.fls.debugImports = ${debugImports}`);
  output.appendLine(`fun.fls.debugDefinitions = ${debugDefinitions}`);

  // If flsPath looks like a path but doesn't exist, fail fast with a clear message.
  const flsLooksLikePath = flsPath.includes('\\') || flsPath.includes('/') || path.isAbsolute(flsPath);
  if (flsLooksLikePath && !fs.existsSync(flsPath)) {
    output.appendLine(`ERROR: fls executable not found at: ${flsPath}`);
    output.appendLine('Fix: set Fun settings `fun.fls.path` to a valid fls executable path.');
  }

  // Only set FLS_FUN_PATH if we have a real executable.
  const resolvedFunExe = funPath && funPath.trim().length > 0 && fs.existsSync(funPath) ? funPath : '';

  // Ensure FUN_STDLIB_DIR is available even when VS Code doesn't inherit installer env vars.
  // We only set it if the environment doesn't already define it.
  const existingStdlibRaw = typeof process?.env?.FUN_STDLIB_DIR === 'string' ? String(process.env.FUN_STDLIB_DIR) : '';
  const existingStdlib = normalizeStdlibRoot(existingStdlibRaw);

  const derivedStdlib =
    existingStdlib ||
    (flsLooksLikePath && fs.existsSync(flsPath) ? deriveStdlibDirFromExe(flsPath) : '') ||
    (resolvedFunExe ? deriveStdlibDirFromExe(resolvedFunExe) : '');

  output.appendLine(`FUN_STDLIB_DIR (env) = ${existingStdlibRaw || '(unset)'}`);
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
    ...(debugAll ? { FLS_DEBUG: '1' } : {}),
    ...(!debugAll && debugImports ? { FLS_DEBUG_IMPORTS: '1' } : {}),
    ...(!debugAll && debugDefinitions ? { FLS_DEBUG_DEFINITIONS: '1' } : {}),
  };

  const serverOptions: ServerOptions = async (): Promise<StreamInfo> => {
    // Fail fast with a clear, actionable error.
    const looksLikePath = flsPath.includes('\\') || flsPath.includes('/') || path.isAbsolute(flsPath);
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
      stdio: 'pipe',
      windowsHide: true,
    });

    child.on('error', (err: any) => {
      output.appendLine(`Failed to spawn fls: ${err?.message ?? String(err)}`);
      output.appendLine(`Command: ${flsPath}`);
      output.appendLine('Tip: remove quotes from fun.fls.path and ensure the file exists.');
      openOutput(output);
    });

    child.stderr?.on('data', (chunk: Buffer) => {
      const s = chunk.toString('utf8');
      if (s.trim().length) output.appendLine(`[fls stderr] ${s.trimEnd()}`);
    });

    child.on('exit', (code, signal) => {
      output.appendLine(`fls exited (code=${code}, signal=${signal ?? 'none'})`);
    });

    if (!child.stdout || !child.stdin) {
      const msg = 'fls stdio not available';
      output.appendLine(`ERROR: ${msg}`);
      openOutput(output);
      throw new Error(msg);
    }

    return { reader: child.stdout, writer: child.stdin };
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [
      { scheme: 'file', language: 'fun' },
      { scheme: 'untitled', language: 'fun' },
    ],
    outputChannel: output,
    errorHandler: {
      error: (err) => {
        output.appendLine(`client error: ${err?.message ?? String(err)}`);
        return { action: ErrorAction.Continue };
      },
      closed: () => {
        output.appendLine('client: server closed, restarting...');
        return { action: CloseAction.Restart };
      },
    },
  };

  return new LanguageClient('fls', 'Fun Language Server', serverOptions, clientOptions);
}
export function activate(context: vscode.ExtensionContext) {
  const output = vscode.window.createOutputChannel('Fun Language Server');
  context.subscriptions.push(output);
  openOutput(output);
  output.appendLine('Activating Fun Language extension...');

  // Non-blocking activation: never await during activate().
  void vscode.window.showInformationMessage('Fun Language extension activated');

  if (!vscode.workspace.isTrusted) {
    output.appendLine('Workspace is not trusted (Restricted Mode). Extension activation may be limited until you trust the workspace.');
  }

  client = createClient(output);

  // Do not await `client.start()` here; if fls hangs/crashes during init,
  // VS Code will keep the extension stuck in "Activating...".
  const startPromise = client
    .start()
    .then(() => {
      output.appendLine('fls started.');
    })
    .catch((err: any) => {
      output.appendLine(`Failed to start fls: ${err?.message ?? String(err)}`);
      openOutput(output);
      void vscode.window.showErrorMessage(`Fun Language Server failed to start: ${err?.message ?? String(err)}`);
    });

  // Warn if startup takes too long, but keep the extension activated.
  const timeoutMs = 8000;
  const timer = setTimeout(() => {
    output.appendLine(`fls still starting after ${timeoutMs}ms...`);
    output.appendLine('If this persists, check that fun.fls.path points to an existing fls.exe and that the workspace is trusted.');
    openOutput(output);
  }, timeoutMs);
  startPromise.finally(() => clearTimeout(timer));

  context.subscriptions.push({ dispose: () => void client?.stop() });

  context.subscriptions.push(
    vscode.commands.registerCommand('fun.showLanguageServerOutput', async () => {
      try {
        openOutput(output);
      } catch (err: any) {
        const msg = err?.message ?? String(err);
        void vscode.window.showErrorMessage(`Fun: failed to show output: ${msg}`);
      }
    }),
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('fun.restartLanguageServer', async () => {
      openOutput(output);
      output.appendLine('Restarting fls...');
      try {
        if (client) {
          await client.stop();
        }
        client = createClient(output);
        await client.start();
        output.appendLine('fls restarted.');
      } catch (err: any) {
        const msg = err?.message ?? String(err);
        output.appendLine(`ERROR: restart failed: ${msg}`);
        openOutput(output);
        void vscode.window.showErrorMessage(`Fun: restart language server failed: ${msg}`);
      }
    }),
  );

  output.appendLine('Activation complete.');
}

export async function deactivate() {
  if (!client) return;
  await client.stop();
  client = undefined;
}
