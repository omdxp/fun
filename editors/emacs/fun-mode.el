;;; fun-mode.el --- Major mode for Fun -*- lexical-binding: t; -*-

(defvar fun-mode-hook nil)

(defvar fun-mode-syntax-table
  (let ((st (make-syntax-table)))
    ;; // comments
    (modify-syntax-entry ?/ ". 124b" st)
    (modify-syntax-entry ?\n "> b" st)
    st)
  "Syntax table for fun-mode.")

(defconst fun-keywords
  '("imp" "as" "pub" "fun" "compound" "quirk" "impl" "enum" "asm" "volatile" "arch"
    "defer" "ret" "if" "elif" "else" "for" "fit" "async" "await" "break" "continue" "assert" "allow" "expect" "let"))

(defconst fun-types
  '("void" "raw" "num" "dec" "f32" "f64" "str" "bin" "chr"))

(defconst fun-constants
  '("true" "false"))

(defvar fun-font-lock-keywords
  `((,(regexp-opt fun-keywords 'words) . font-lock-keyword-face)
    (,(regexp-opt fun-types 'words) . font-lock-type-face)
    ("\\_<[iu][1-9][0-9]*\\_>" . font-lock-type-face)
    (,(regexp-opt fun-constants 'words) . font-lock-constant-face)))

;;;###autoload
(define-derived-mode fun-mode prog-mode "Fun"
  "Major mode for editing Fun language files."
  :syntax-table fun-mode-syntax-table
  (setq font-lock-defaults '(fun-font-lock-keywords))
  (setq-local comment-start "// ")
  (setq-local comment-end ""))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.fn\\'" . fun-mode))

(provide 'fun-mode)
;;; fun-mode.el ends here
