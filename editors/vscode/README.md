# Fun (FLS) for VS Code

Official VS Code support for the Fun language. This extension provides syntax highlighting and connects VS Code to the `fls` language server.

## Features

- Syntax highlighting for `.fn` files
- Language Server support via `fls` (hover, completion, diagnostics, go-to-definition, formatting, etc. as provided by `fls`)
- Output channel: **Fun Language Server** (useful for debugging startup issues)

## Requirements

You need the Fun tooling installed:

- `fls` language server
- `fun` compiler (optional but recommended; used by `fls` for deeper analysis)

By default the extension will try, in order:

1. Workspace-local binaries: `zig-out/bin/fls(.exe)` and `zig-out/bin/fun(.exe)`
2. Your system `PATH` (e.g. `fls`, `fun`)

## Getting Started

1. Install the extension.
2. Open a `.fn` file.
3. If the server doesn’t start, open **View → Output** and select **Fun Language Server**.

## Settings

These settings live under **Settings → Extensions → Fun**:

- `fun.fls.path`
  - Path to the `fls` executable.
  - Default: `fls` (falls back to `zig-out/bin/fls` when available)
- `fun.fls.funPath`
  - Optional path to the `fun` executable.
  - When set to a valid executable, it is passed to `fls` via the `FLS_FUN_PATH` environment variable.

Notes:

- Settings support `${workspaceFolder}` / `${workspaceRoot}`.
- On Windows, `%VAR%` environment variables inside paths are expanded (best-effort).

## Commands

Open the Command Palette and run:

- **Fun: Restart Language Server**
- **Fun: Show Language Server Output**

## Troubleshooting

**No hover / completions / diagnostics**

- Verify `fls` is found:
  - Either ensure it’s on `PATH`, or set `fun.fls.path` to the full path.
- If you’re building Fun from source, ensure `zig-out/bin` exists (or point settings at the built executables).

**Standard library isn’t found**

- The extension attempts to derive `FUN_STDLIB_DIR` from the directory containing `fls` / `fun`.
- Check the **Fun Language Server** output for the resolved paths.

## Developing This Extension

From this folder (`editors/vscode`):

1. `npm install`
2. `npm run compile`
3. Press `F5` in VS Code (Extension Development Host)

Packaging a `.vsix`:

```sh
npm install
npm run package
code --install-extension fun-language-*.vsix
```

See [CONTRIBUTING.md](../../CONTRIBUTING.md) for repo-wide contribution guidelines.
