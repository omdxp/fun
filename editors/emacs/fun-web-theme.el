;;; fun-web-theme.el --- Fun Web theme -*- lexical-binding: t; -*-

(deftheme fun-web "Fun Web theme matching the Fun reference website palette.")

(let ((bg "#0A1228")
      (fg "#E8EDFF")
      (comment "#7F8DB8")
      (string "#F1C38F")
      (number "#9DE0FF")
      (keyword "#7AA2FF")
    (operator "#8FB3FF")
      (type "#9BDC8A")
      (custom-type "#B6A6FF")
      (support-type "#7FE0C1")
      (boolean "#FFB3C0")
      (func "#A9E4FF")
      (line-bg "#0D1630")
      (region "#355AAD"))
  (custom-theme-set-faces
   'fun-web
   `(default ((t (:foreground ,fg :background ,bg))))
   `(cursor ((t (:background "#E9EEFF"))))
   `(region ((t (:background ,region))))
   `(line-number ((t (:foreground "#5A6EA8" :background ,bg))))
   `(line-number-current-line ((t (:foreground "#9CB1E9" :background ,bg :weight bold))))
   `(hl-line ((t (:background ,line-bg))))
   `(font-lock-comment-face ((t (:foreground ,comment))))
   `(font-lock-string-face ((t (:foreground ,string))))
   `(font-lock-constant-face ((t (:foreground ,number))))
   `(font-lock-keyword-face ((t (:foreground ,keyword :weight bold))))
   `(font-lock-type-face ((t (:foreground ,type))))
   `(font-lock-builtin-face ((t (:foreground ,support-type))))
   `(font-lock-function-name-face ((t (:foreground ,func))))
   `(font-lock-variable-name-face ((t (:foreground ,fg))))
   `(font-lock-warning-face ((t (:foreground ,boolean :weight bold))))
   `(fun-boolean-face ((t (:foreground ,boolean))))
   `(fun-custom-type-face ((t (:foreground ,custom-type))))
   `(fun-operator-face ((t (:foreground ,operator))))))

(provide-theme 'fun-web)

;;; fun-web-theme.el ends here
