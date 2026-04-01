fun portable Windows package
============================

This archive is portable: no installer is required.

Contents
- bin\\fun.exe
- share\\fun\\... (stdlib and runtime data)

Quick start
1. Extract this archive anywhere you have write access.
2. Open PowerShell in the extracted folder.
3. Run:
   .\\bin\\fun.exe -version

Optional: add fun to PATH for this shell session
$env:Path = "$PWD\\bin;" + $env:Path

Compiler configuration
- This portable package does not set environment variables automatically.
- By default, fun tries platform compilers.
- Recommended stable setup:
  $env:FUN_CC = "zig"
  $env:FUN_CC_ARGS = "cc"

Language Server (fls)
- The package also includes the Fun language server: .\bin\fls.exe
- This is used by editor integrations for diagnostics/completion/formatting.
- If your editor asks for the server path, point it to:
  <extracted-folder>\bin\fls.exe

Optional: add fls to PATH for this shell session
$env:Path = "$PWD\\bin;" + $env:Path

If you use MSVC cl.exe, run from Developer PowerShell for Visual Studio.
