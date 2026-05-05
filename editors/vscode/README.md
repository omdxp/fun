# Fun (FLS) for VS Code

Official VS Code support for the Fun language. This extension provides syntax highlighting and connects VS Code to the `fls` language server.

## Features

- Syntax highlighting for `.fn` files
- Language Server support via `fls` (hover, completion, diagnostics, go-to-definition, formatting, etc. as provided by `fls`)
- **▶ Run** and **⚙ Debug** code lenses above every `fun main(` — one click to run or debug
- Full debugger experience: breakpoints on `.fn` files, call stack, variables panel with Fun type names
- Output channel: **Fun Language Server** (useful for debugging startup issues)
- Bundled color theme: **Fun Web** (matches the reference website palette)

## Requirements

You need the Fun tooling installed:

- `fls` language server
- `fun` compiler (required for Run / Debug)

For the **Debug** feature you also need:

- A native debugger extension — **[CodeLLDB](https://marketplace.visualstudio.com/items?itemName=vadimcn.vscode-lldb)** (recommended on macOS/Linux/Windows) or **[C/C++](https://marketplace.visualstudio.com/items?itemName=ms-vscode.cpptools)** (cpptools)
- A system C compiler: `cc`/`clang`/`gcc` on macOS/Linux, `clang-cl` or `cl.exe` on Windows

By default the extension will try, in order:

1. Workspace-local binaries: `zig-out/bin/fls(.exe)` and `zig-out/bin/fun(.exe)`
2. Your system `PATH` (e.g. `fls`, `fun`)

## Getting Started

1. Install the extension.
2. Open a `.fn` file.
3. If the server doesn’t start, open **View → Output** and select **Fun Language Server**.

Optional: set **Preferences → Theme → Color Theme → Fun Web** to use the same code palette as the website.

## Settings

These settings live under **Settings → Extensions → Fun**:

- `fun.fls.path`
  - Path to the `fls` executable.
  - Default: `fls` (falls back to `zig-out/bin/fls` when available)
- `fun.fls.funPath`
  - Optional path to the `fun` executable.
  - When set to a valid executable, it is passed to `fls` via the `FLS_FUN_PATH` environment variable.
- `fun.fls.stdlibDir`
  - Optional stdlib root (folder containing `std/`).
  - Passed to `fls` via `FUN_STDLIB_DIR` and takes precedence over derived paths.
- `fun.debugger.type`
  - Debugger to use for **⚙ Debug**. One of `lldb` (CodeLLDB) or `cppdbg` (cpptools).
  - Leave empty for auto-detection.

Notes:

- Settings support `${workspaceFolder}` / `${workspaceRoot}`.
- On Windows, `%VAR%` environment variables inside paths are expanded (best-effort).

## Run and Debug

Every `.fn` file that defines `fun main(` shows two buttons above it:

- **▶ Run** — compiles and runs the file in an integrated terminal (equivalent to `fun -in file.fn`).
- **⚙ Debug** — compiles with debug info, then launches the native debugger.

### Debug experience

Breakpoints are set directly on `.fn` source lines. When a breakpoint is hit:

- **Call stack** shows Fun function names and `.fn` file/line numbers.
- **Variables panel** shows variable names from your Fun code with Fun type names (`num`, `str`, `bin`, `dec`, `raw*`, etc.) instead of C equivalents.
- **Watch** and **Debug Console** expressions also display Fun types.
- Internal C boilerplate frames (e.g. async helpers) are marked as secondary and collapsed by default.

### Debugging async functions

`await` expressions lower to a chain of C trampoline functions (`__fun_async_call_`, `__fun_async_spawn_`, `__fun_async_entry_`, then the real function body). The actual function call goes through `pthread_create` (or `CreateThread` on Windows) — which is opaque C runtime code the debugger cannot step through at the Fun source level.

This means **step into on an `await` line will not automatically land inside the called async function**. Instead the debugger follows the C runtime path:

```
await to_consumer.send_async(out);   // step into → enters trampoline C code
```

**The right way to debug async calls:**

1. **Set a breakpoint inside the async function you want to inspect** (e.g. a line inside `send_async` in `channel.fn`). The debugger will break there when the spawned thread executes it, and you can step normally from that point.
2. Alternatively, set a breakpoint on the line *after* the `await` to resume once the call has returned.

Step-over (`F10`) on an `await` line works correctly — it blocks until the async call completes and advances to the next Fun source line.

### How it works

1. The compiler is invoked with `-g` which embeds `#line N "file.fn"` directives in the generated C. These tell the C compiler to attribute all DWARF symbols to the original Fun source locations.
2. The C file is compiled with `-g` (or `/Zi` on Windows) to produce a native binary with full DWARF/CodeView debug info.
3. VS Code launches the native debugger (CodeLLDB or cpptools) against the binary. Because DWARF points to `.fn` files, the debugger shows Fun source natively — no extra mapping layer.
4. A DAP message tracker intercepts variable type strings and remaps them from C types back to Fun types in real time.
5. Temp files (`.c` and compiled binary) are cleaned up automatically when the debug session ends.

### Debugger auto-detection

The extension picks the debugger in this order:

1. `fun.debugger.type` setting (if set explicitly)
2. CodeLLDB (`vadimcn.vscode-lldb`) if installed
3. cpptools (`ms-vscode.cpptools`) if installed
4. CodeLLDB on macOS/Linux, cpptools on Windows (best-effort fallback)

On Windows the extension tries `clang-cl` first (produces DWARF-compatible debug info for CodeLLDB), then `cl.exe` (MSVC, works with cpptools).

## Commands

Open the Command Palette and run:

- **Fun: Restart Language Server**
- **Fun: Show Language Server Output**
- **Fun: Run** — run the current file
- **Fun: Debug** — debug the current file

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
