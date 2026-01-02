"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.activate = activate;
exports.deactivate = deactivate;
const fs = __importStar(require("fs"));
const path = __importStar(require("path"));
const vscode = __importStar(require("vscode"));
const node_1 = require("vscode-languageclient/node");
const child_process_1 = require("child_process");
let client;
function workspaceRootPath() {
    const folder = vscode.workspace.workspaceFolders?.[0];
    return folder?.uri.fsPath;
}
function expandWorkspaceVars(p, root) {
    if (!root)
        return p;
    return p.replace(/\$\{workspaceFolder\}|\$\{workspaceRoot\}/g, root);
}
function stripOuterQuotes(p) {
    const s = (p ?? '').trim();
    if ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'"))) {
        return s.slice(1, -1);
    }
    return s;
}
function expandWindowsEnvVars(p) {
    // Expand %VAR% on Windows (best-effort).
    return p.replace(/%([^%]+)%/g, (_, name) => {
        const v = process?.env?.[name];
        return typeof v === 'string' ? v : `%${name}%`;
    });
}
function resolveExe(configured, root, defaultRel) {
    const trimmed = stripOuterQuotes(configured ?? '');
    const expanded = expandWindowsEnvVars(expandWorkspaceVars(trimmed, root));
    // If user left it as default, try workspace-local zig-out first.
    if (!expanded || expanded === 'fls' || expanded === 'fun') {
        if (root) {
            const candidate = path.join(root, defaultRel);
            if (fs.existsSync(candidate))
                return candidate;
        }
        return expanded || path.basename(defaultRel);
    }
    // If relative path, resolve against workspace.
    if (root && !path.isAbsolute(expanded) && (expanded.includes('/') || expanded.includes('\\')))
        return path.join(root, expanded);
    return expanded;
}
function platformExeName(base) {
    return process?.platform === 'win32' ? `${base}.exe` : base;
}
function maybePreferNextExe(resolvedFlsPath, root, output) {
    if (!root)
        return resolvedFlsPath;
    const nextCandidate = path.join(root, 'zig-out', 'bin', platformExeName('fls-next'));
    if (!fs.existsSync(nextCandidate))
        return resolvedFlsPath;
    // If the configured path is a plain command (fls/fls.exe), prefer fls-next when available.
    const base = path.basename(resolvedFlsPath);
    const looksLikeCommand = base === 'fls' || base === 'fls.exe';
    if (looksLikeCommand) {
        output.appendLine(`Detected ${path.basename(nextCandidate)}; preferring it over ${base}.`);
        return nextCandidate;
    }
    // If the resolved path is the workspace-local zig-out fls, prefer fls-next if it exists and is newer.
    try {
        const normalized = path.normalize(resolvedFlsPath);
        const defaultFls = path.normalize(path.join(root, 'zig-out', 'bin', platformExeName('fls')));
        if (normalized === defaultFls) {
            if (!fs.existsSync(resolvedFlsPath)) {
                output.appendLine(`Detected ${path.basename(nextCandidate)}; ${path.basename(resolvedFlsPath)} is missing, using fls-next.`);
                return nextCandidate;
            }
            const nextStat = fs.statSync(nextCandidate);
            const curStat = fs.statSync(resolvedFlsPath);
            if (nextStat.mtimeMs > curStat.mtimeMs) {
                output.appendLine(`Detected newer ${path.basename(nextCandidate)}; preferring it over ${path.basename(resolvedFlsPath)}.`);
                return nextCandidate;
            }
        }
    }
    catch {
        // Best-effort only; never block startup due to stat errors.
    }
    return resolvedFlsPath;
}
function openOutput(output) {
    // `toggleOutput` can actually hide the panel if it's already visible.
    // Keep this deterministic: just reveal our channel.
    try {
        output.show(true);
    }
    catch {
        // Best-effort: never throw from a helper used in activation/commands.
    }
}
function createClient(output) {
    const root = workspaceRootPath();
    const config = vscode.workspace.getConfiguration('fun');
    const flsCfg = config.get('fls.path', 'fls');
    const funCfg = config.get('fls.funPath', '');
    const flsDefaultRel = path.join('zig-out', 'bin', platformExeName('fls'));
    const funDefaultRel = path.join('zig-out', 'bin', platformExeName('fun'));
    const flsResolved = resolveExe(flsCfg, root, flsDefaultRel);
    const flsPath = maybePreferNextExe(flsResolved, root, output);
    const funPath = resolveExe(funCfg, root, funDefaultRel);
    output.appendLine(`workspaceRoot = ${root ?? '(none)'}`);
    output.appendLine(`workspaceTrusted = ${vscode.workspace.isTrusted}`);
    output.appendLine(`fun.fls.path (raw) = ${flsCfg}`);
    output.appendLine(`fun.fls.path (resolved) = ${flsPath}`);
    output.appendLine(`fun.fls.funPath (raw) = ${funCfg || '(empty)'}`);
    output.appendLine(`fun.fls.funPath (resolved) = ${funPath || '(empty)'}`);
    // If flsPath looks like a path but doesn't exist, fail fast with a clear message.
    const flsLooksLikePath = flsPath.includes('\\') || flsPath.includes('/') || path.isAbsolute(flsPath);
    if (flsLooksLikePath && !fs.existsSync(flsPath)) {
        output.appendLine(`ERROR: fls executable not found at: ${flsPath}`);
        output.appendLine('Fix: set Fun settings `fun.fls.path` to a valid fls executable path.');
    }
    // Only set FLS_FUN_PATH if we have a real executable.
    const resolvedFunExe = funPath && funPath.trim().length > 0 && fs.existsSync(funPath) ? funPath : '';
    const env = {
        ...(process?.env ?? {}),
        ...(resolvedFunExe ? { FLS_FUN_PATH: resolvedFunExe } : {}),
    };
    const serverOptions = async () => {
        // Fail fast with a clear, actionable error.
        const looksLikePath = flsPath.includes('\\') || flsPath.includes('/') || path.isAbsolute(flsPath);
        if (looksLikePath && !fs.existsSync(flsPath)) {
            const msg = `fls executable not found at: ${flsPath}`;
            output.appendLine(`ERROR: ${msg}`);
            openOutput(output);
            throw new Error(msg);
        }
        output.appendLine(`Spawning fls: ${flsPath}`);
        const child = (0, child_process_1.spawn)(flsPath, [], {
            cwd: root,
            env,
            stdio: 'pipe',
            windowsHide: true,
        });
        child.on('error', (err) => {
            output.appendLine(`Failed to spawn fls: ${err?.message ?? String(err)}`);
            output.appendLine(`Command: ${flsPath}`);
            output.appendLine('Tip: remove quotes from fun.fls.path and ensure the file exists.');
            openOutput(output);
        });
        child.stderr?.on('data', (chunk) => {
            const s = chunk.toString('utf8');
            if (s.trim().length)
                output.appendLine(`[fls stderr] ${s.trimEnd()}`);
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
    const clientOptions = {
        documentSelector: [
            { scheme: 'file', language: 'fun' },
            { scheme: 'untitled', language: 'fun' },
        ],
        outputChannel: output,
        errorHandler: {
            error: (err) => {
                output.appendLine(`client error: ${err?.message ?? String(err)}`);
                return { action: node_1.ErrorAction.Continue };
            },
            closed: () => {
                output.appendLine('client: server closed, restarting...');
                return { action: node_1.CloseAction.Restart };
            },
        },
    };
    return new node_1.LanguageClient('fls', 'Fun Language Server', serverOptions, clientOptions);
}
function activate(context) {
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
        .catch((err) => {
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
    context.subscriptions.push(vscode.commands.registerCommand('fun.showLanguageServerOutput', async () => {
        try {
            openOutput(output);
        }
        catch (err) {
            const msg = err?.message ?? String(err);
            void vscode.window.showErrorMessage(`Fun: failed to show output: ${msg}`);
        }
    }));
    context.subscriptions.push(vscode.commands.registerCommand('fun.restartLanguageServer', async () => {
        openOutput(output);
        output.appendLine('Restarting fls...');
        try {
            if (client) {
                await client.stop();
            }
            client = createClient(output);
            await client.start();
            output.appendLine('fls restarted.');
        }
        catch (err) {
            const msg = err?.message ?? String(err);
            output.appendLine(`ERROR: restart failed: ${msg}`);
            openOutput(output);
            void vscode.window.showErrorMessage(`Fun: restart language server failed: ${msg}`);
        }
    }));
    output.appendLine('Activation complete.');
}
async function deactivate() {
    if (!client)
        return;
    await client.stop();
    client = undefined;
}
//# sourceMappingURL=extension.js.map