;;; fun-web-light-theme.el --- Fun Web Light theme -*- lexical-binding: t; -*-

(deftheme fun-web-light "Fun Web Light theme matching the Fun reference website palette.")

(let ((bg "#F6F8FF")
      (fg "#1B2340")
      (comment "#6A78A0")
      (string "#9A5B12")
      (number "#1F6F9E")
      (keyword "#2F5BD0")
    (operator "#3F63C0")
      (type "#2E7D32")
      (custom-type "#6A4FD0")
      (support-type "#0E8A6E")
      (boolean "#C0325A")
      (func "#1E7FA8")
      (line-bg "#EEF2FF")
      (region "#B9CCF5"))
  (custom-theme-set-faces
   'fun-web-light
   `(default ((t (:foreground ,fg :background ,bg))))
   `(cursor ((t (:background "#1B2340"))))
   `(region ((t (:background ,region))))
   `(line-number ((t (:foreground "#9AA6D0" :background ,bg))))
   `(line-number-current-line ((t (:foreground "#4A5A90" :background ,bg :weight bold))))
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

(provide-theme 'fun-web-light)

;;; fun-web-light-theme.el ends here
