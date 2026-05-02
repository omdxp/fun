# Neovim support

## Syntax highlighting and filetype

Copy `editors/vim` into `~/.config/nvim` (or merge it into your runtimepath).

Alternatively, using [lazy.nvim](https://github.com/folke/lazy.nvim) you can add the vim runtime files as a local plugin:

```lua
{ dir = "/path/to/fun/editors/vim" }
```

Register the `.fn` extension (put this in your `init.lua`):

```lua
vim.filetype.add({ extension = { fn = "fun" } })
```

Then enable the bundled website-matching colorscheme:

```lua
vim.cmd.colorscheme("funweb")
```

## LSP (fls) — Neovim 0.11+

Neovim 0.11 ships a built-in LSP client that no longer requires `nvim-lspconfig`.

```lua
-- Define the server (no plugin needed)
vim.lsp.config("fls", {
  cmd = { "fls" },
  filetypes = { "fun" },
  root_dir = vim.fs.root(0, { "build.zig", "build.zig.zon", ".git" }),
})

-- Enable it
vim.lsp.enable("fls")
```

Set `FUN_STDLIB_DIR` in your environment if the stdlib is not auto-detected.

### LSP keymaps

```lua
vim.api.nvim_create_autocmd("LspAttach", {
  callback = function(args)
    local opts = { buffer = args.buf }
    vim.keymap.set("n", "gd", vim.lsp.buf.definition, opts)
    vim.keymap.set("n", "K",  vim.lsp.buf.hover,      opts)
    vim.keymap.set("n", "gr", vim.lsp.buf.references,  opts)
  end,
})
```

### Autoformat on save

```lua
vim.api.nvim_create_autocmd("BufWritePre", {
  pattern = "*.fn",
  callback = function()
    vim.lsp.buf.format({ async = false })
  end,
})
```

## LSP (fls) — older Neovim with nvim-lspconfig

If you are on Neovim < 0.11 and use [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig):

```lua
require("lspconfig").fls.setup({
  cmd = { "fls" },
  filetypes = { "fun" },
  root_dir = require("lspconfig.util").root_pattern("build.zig", "build.zig.zon", ".git"),
})
```

