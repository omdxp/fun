# Fun for Zed

Language support for [Fun](https://github.com/omdxp/fun) in [Zed](https://zed.dev).

- Syntax highlighting, brackets, indents, outline and text objects, from the [tree-sitter-fun](https://github.com/omdxp/tree-sitter-fun) grammar.
- The `fls` language server: diagnostics, hover, completion, goto definition, formatting and references.
- Runnable tags for `fun main` and `test` blocks.

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

`fun main` and every `test "..."` block carry the runnable tags `fun-main` and `fun-test`. Zed shows a run button for a tag once a task uses it. Add these to `~/.config/zed/tasks.json` or `.zed/tasks.json`:

```json
[
  {
    "label": "fun run $ZED_FILE",
    "command": "fun",
    "args": ["run", "$ZED_FILE"],
    "tags": ["fun-main"]
  },
  {
    "label": "fun test $ZED_FILE",
    "command": "fun",
    "args": ["test", "$ZED_FILE"],
    "tags": ["fun-test"]
  },
  {
    "label": "fun test $ZED_FILE with coverage",
    "command": "fun",
    "args": ["test", "$ZED_FILE", "-cover"]
  }
]
```

## Not available in Zed

Zed has no Test Explorer or coverage API, so coverage shading and the Testing view exist only in the VS Code extension. Use the coverage task above and read the printed percentage.

## Develop

Open the command palette, run `zed: install dev extension` and pick this folder.
