# Fun for Zed

Language support for [Fun](https://github.com/omdxp/fun) in [Zed](https://zed.dev).

- Syntax highlighting, brackets, indents, outline and text objects, from the [tree-sitter-fun](https://github.com/omdxp/tree-sitter-fun) grammar.
- The `fls` language server: diagnostics, hover, completion, goto definition, formatting and references.
- Gutter run buttons for `main`, `test` and `fuzz` blocks.

## Language server

The extension looks for `fls` in this order:

1. `lsp.fls.binary.path` in your Zed settings.
2. `fls` on your `PATH`.
3. The latest Fun release, downloaded on first use.

```json
{
  "lsp": {
    "fls": {
      "binary": { "path": "/path/to/fls" },
      "settings": {
        "fun_path": "/path/to/fun",
        "stdlib_dir": "/path/to/share/fun",
        "debug": false
      }
    }
  }
}
```

`fun_path` and `stdlib_dir` are optional and reach `fls` as `FLS_FUN_PATH` and `FUN_STDLIB_DIR`.

## Run buttons

The extension ships tasks and tags the code they apply to, so Zed shows a run button in the gutter:

- `fun main`: runs the file (`fun -in <file>`).
- Each `test "..."` block: runs that one test.
- Each `fuzz "..."` block: runs that fuzz target.

The same tasks, plus running the whole file's tests, running them with coverage and linting the file, are in the task picker (`task: spawn`). `fun` must be on your `PATH`.

## Not available in Zed

Zed has no Test Explorer or coverage API, so coverage shading and the Testing view exist only in the VS Code extension. Use the coverage task and read the printed percentage.

## Develop

Open the command palette, run `zed: install dev extension` and pick this folder.
