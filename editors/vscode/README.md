# Prerequisites

**Before using this extension, you must have the `fun` compiler and `fls` language server installed and accessible in your system PATH.**

- Install the Fun language and ensure both `fun` and `fls` are available globally (e.g., by running `fun --version` and `fls --version` in your terminal).
- The extension will use the default values (`fun`, `fls`) unless you override them in the settings.

If you install the language using the official installer or release, these binaries should be available globally. If not, please follow the installation instructions in the main Fun language repository.

# Fun VS Code Extension (WIP)

This extension wires VS Code up to the `fls` language server.

## What you get

- Diagnostics (via `fun -no-exec`)
- Formatting (via `fun -fmt -no-exec`)

## Requirements

- Build the tools:
  - `zig build`
  - Ensure `zig-out/bin` is on your `PATH`, or set explicit paths in settings.

## Setup (dev)

1) In VS Code, open the `editors/vscode` folder.
2) Run `npm install`.
3) Run `npm run compile`.
4) Press `F5` to launch the Extension Development Host.

## Settings

- `fun.fls.path`: path to `fls` (default: `fls`)
- `fun.fls.funPath`: optional path to `fun` (sets `FLS_FUN_PATH`)
