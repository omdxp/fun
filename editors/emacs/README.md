# Emacs support

## Syntax highlighting

Load `fun-mode.el`:

```elisp
(add-to-list 'load-path "/path/to/fun/editors/emacs")
(require 'fun-mode)
```

## LSP (lsp-mode)

```elisp
(with-eval-after-load 'lsp-mode
  (add-to-list 'lsp-language-id-configuration '(fun-mode . "fun"))
  (lsp-register-client
   (make-lsp-client :new-connection (lsp-stdio-connection '("fls"))
                    :major-modes '(fun-mode)
                    :server-id 'fls)))
```

Set `FUN_STDLIB_DIR` if needed.
