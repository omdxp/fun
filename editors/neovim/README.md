# Neovim support

Use the Vim runtime files and optionally enable LSP.

## Syntax highlighting

Add this repo's vim files to your runtimepath:

- Copy `editors/vim` into `~/.config/nvim` (or add it to `runtimepath`).

Then enable the bundled website-matching colorscheme:

```lua
vim.cmd.colorscheme('funweb')
```

## LSP (fls)

If you use `nvim-lspconfig`:

```lua
require('lspconfig').fls.setup({
  cmd = { 'fls' },
  filetypes = { 'fun' },
  root_dir = require('lspconfig.util').root_pattern('build.zig', 'build.zig.zon', '.git'),
})
```

Set `FUN_STDLIB_DIR` if needed.
