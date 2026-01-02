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
