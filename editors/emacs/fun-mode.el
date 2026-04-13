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

(defconst fun-support-types
  '("size_t" "ptrdiff_t" "ssize_t" "intptr_t" "uintptr_t"
    "int8_t" "uint8_t" "int16_t" "uint16_t"
    "int32_t" "uint32_t" "int64_t" "uint64_t"
    "time_t" "clock_t"))

(defconst fun-constants
  '("true" "false"))

(defface fun-boolean-face
  '((t :inherit font-lock-constant-face))
  "Face used for Fun boolean literals.")

(defface fun-custom-type-face
  '((t :inherit font-lock-type-face))
  "Face used for Fun custom type names.")

(defface fun-operator-face
  '((t :inherit font-lock-builtin-face))
  "Face used for Fun operators and separators.")

(defvar fun-font-lock-keywords
  `((,(regexp-opt fun-keywords 'words) . font-lock-keyword-face)
    ("\\(->\\|::\\|\\+=\\|-=\\|\\*=\\|/=\\|%=\\|==\\|!=\\|<=\\|>=\\|&&\\|[|][|]\\|<<\\|>>\\|\\+\\+\\|--\\|[+\\-*/%=<>!&|^~.:;,]\\)"
     . fun-operator-face)
    ("\\_<\\(compound\\|quirk\\|enum\\|impl\\)\\_>\\s-+\\([A-Za-z_][A-Za-z0-9_]*\\)"
     (1 font-lock-keyword-face)
     (2 fun-custom-type-face))
    ("\\_<\\([A-Z][A-Za-z0-9_]*\\)\\_>\\s-*\\(?:\\*+\\s-*\\)?[A-Za-z_][A-Za-z0-9_]*\\_>"
     (1 fun-custom-type-face))
    (,(regexp-opt fun-types 'words) . font-lock-type-face)
    (,(regexp-opt fun-support-types 'words) . font-lock-builtin-face)
    ("\\_<[iu][1-9][0-9]*\\_>" . font-lock-type-face)
    (,(regexp-opt fun-constants 'words) . fun-boolean-face)
    ("\\_<[0-9]+\\(?:\\.[0-9]+\\)?\\_>" . font-lock-constant-face)))

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
