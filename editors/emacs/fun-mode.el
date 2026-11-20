;;; fun-mode.el --- Major mode for Fun -*- lexical-binding: t; -*-

;;; Commentary:

;; Syntax highlighting and indentation for the Fun programming language
;; (`.fn' files): keywords, types, literals (including backtick raw
;; strings, each line its own piece), `//' and `/* */' comments,
;; function declarations and calls, and the contextual `union',
;; `packed', and `align(N)' declaration modifiers.

;;; Code:

(defvar fun-mode-hook nil)

(defgroup fun nil
  "Major mode for the Fun programming language."
  :group 'languages)

(defcustom fun-indent-offset 2
  "Number of spaces each nested block is indented by."
  :type 'integer
  :group 'fun)

(defvar fun-mode-syntax-table
  (let ((st (make-syntax-table)))
    ;; `//' line comments and `/* */' block comments.
    (modify-syntax-entry ?/ ". 124b" st)
    (modify-syntax-entry ?* ". 23" st)
    (modify-syntax-entry ?\n "> b" st)
    ;; "strings" and 'c' character literals. A backtick raw string is
    ;; marked by `fun-syntax-propertize' instead, since it ends at the
    ;; end of its line when it isn't closed there.
    (modify-syntax-entry ?\" "\"" st)
    (modify-syntax-entry ?' "\"" st)
    (modify-syntax-entry ?` "." st)
    ;; Operators are punctuation, so `Vec<num>' and `a+b' split into
    ;; words; Emacs's default table would read them as one symbol.
    (dolist (c '(?+ ?- ?= ?< ?> ?& ?| ?! ?? ?^ ?~ ?% ?. ?: ?, ?\; ?$ ?#))
      (modify-syntax-entry c "." st))
    (modify-syntax-entry ?_ "_" st)
    st)
  "Syntax table for `fun-mode'.")

(defconst fun-keywords
  '("use" "as" "pub" "fun" "closure" "als" "compound" "shape" "impl" "enum" "asm" "volatile" "arch"
    "defer" "ret" "if" "elif" "else" "for" "fit" "async" "await" "fork" "break" "continue" "assert"
    "panic" "test" "sequential" "fuzz" "allow" "expect" "let" "const")
  "Reserved words of Fun.")

(defconst fun-types
  '("void" "raw" "num" "dec" "f32" "f64" "str" "flag" "chr")
  "Builtin type names of Fun.")

(defconst fun-support-types
  '("size_t" "ptrdiff_t" "ssize_t" "intptr_t" "uintptr_t"
    "int8_t" "uint8_t" "int16_t" "uint16_t"
    "int32_t" "uint32_t" "int64_t" "uint64_t"
    "time_t" "clock_t")
  "C type names Fun code commonly names through its C bindings.")

(defconst fun-constants
  '("true" "false" "nil")
  "Literal constants of Fun.")

(defface fun-boolean-face
  '((t :inherit font-lock-constant-face))
  "Face used for Fun boolean literals and `nil'."
  :group 'fun)

(defface fun-custom-type-face
  '((t :inherit font-lock-type-face))
  "Face used for Fun custom type names."
  :group 'fun)

(defface fun-operator-face
  '((t :inherit font-lock-builtin-face))
  "Face used for Fun operators and separators."
  :group 'fun)

(defconst fun--function-call-face
  (if (facep 'font-lock-function-call-face)
      'font-lock-function-call-face
    'font-lock-function-name-face)
  "The face a call's own callee name is shown in.")

(defvar fun-font-lock-keywords
  `((,(regexp-opt fun-keywords 'symbols) . font-lock-keyword-face)
    ;; Contextual modifiers, keywords only where they're written as such.
    ("\\_<\\(packed\\)\\s-+\\(?:compound\\|union\\)\\_>" (1 font-lock-keyword-face))
    ("\\_<\\(union\\)\\s-+\\([A-Za-z_][A-Za-z0-9_]*\\)\\s-*[{<]"
     (1 font-lock-keyword-face)
     (2 'fun-custom-type-face))
    ("\\_<\\(align\\)([0-9]+)" (1 font-lock-keyword-face))
    ("\\_<\\(compound\\|shape\\|enum\\|impl\\)\\_>\\s-+\\([A-Za-z_][A-Za-z0-9_]*\\)"
     (1 font-lock-keyword-face)
     (2 'fun-custom-type-face))
    ;; A function's own name where it's declared, then any call.
    ("\\_<fun\\_>\\s-+\\([A-Za-z_][A-Za-z0-9_]*\\)" (1 font-lock-function-name-face))
    ("\\_<\\([a-z_][A-Za-z0-9_]*\\)\\(?:<[^<>()]*>\\)?\\s-*("
     (1 fun--function-call-face))
    ("\\_<\\([A-Z][A-Za-z0-9_]*\\)\\_>" (1 'fun-custom-type-face))
    (,(regexp-opt fun-types 'symbols) . font-lock-type-face)
    (,(regexp-opt fun-support-types 'symbols) . font-lock-builtin-face)
    ("\\_<[iu][1-9][0-9]*\\_>" . font-lock-type-face)
    (,(regexp-opt fun-constants 'symbols) . 'fun-boolean-face)
    ("\\_<\\(?:0[xX][0-9a-fA-F_]+\\|0[bB][01_]+\\|[0-9][0-9_]*\\(?:\\.[0-9][0-9_]*\\)?\\)\\_>"
     . font-lock-constant-face)
    ("\\(->\\|::\\|\\+=\\|-=\\|\\*=\\|/=\\|%=\\|==\\|!=\\|<=\\|>=\\|&&\\|[|][|]\\|<<\\|>>\\|\\+\\+\\|--\\|<-\\|[+*/%=<>!?&|^~:;,-]\\)"
     . 'fun-operator-face))
  "Highlighting rules for `fun-mode'.")

(defconst fun--syntax-propertize
  (syntax-propertize-rules
   ;; A backtick raw string: closed by the next lone backtick on its own
   ;; line, or by the end of that line (each line of a multi-line raw
   ;; string starts with its own backtick). A doubled backtick inside is
   ;; a literal one.
   ("\\(`\\)\\(?:[^`\n]\\|``\\)*\\(`\\|\n\\)"
    (1 "|")
    (2 "|")))
  "Marks backtick raw strings as strings.")

(defun fun-indent-line ()
  "Indent the current line by the depth of the braces around it."
  (interactive)
  (let* ((savep (> (current-column) (current-indentation)))
         (depth (save-excursion
                  (beginning-of-line)
                  (car (syntax-ppss))))
         (closes (save-excursion
                   (back-to-indentation)
                   (looking-at-p "[]})]")))
         (target (* fun-indent-offset (max 0 (- depth (if closes 1 0))))))
    (if savep
        (save-excursion (indent-line-to target))
      (indent-line-to target))))

;;;###autoload
(define-derived-mode fun-mode prog-mode "Fun"
  "Major mode for editing Fun language files."
  :syntax-table fun-mode-syntax-table
  (setq-local font-lock-defaults '(fun-font-lock-keywords))
  (setq-local syntax-propertize-function fun--syntax-propertize)
  (setq-local indent-line-function #'fun-indent-line)
  (setq-local comment-start "// ")
  (setq-local comment-end "")
  (setq-local comment-start-skip "\\(?://+\\|/\\*+\\)\\s *")
  (setq-local indent-tabs-mode nil)
  (setq-local tab-width fun-indent-offset))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.fn\\'" . fun-mode))

(provide 'fun-mode)
;;; fun-mode.el ends here
