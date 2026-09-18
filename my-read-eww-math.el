;;; my-read-eww-math.el --- Compatibility entry point -*- lexical-binding: t; -*-

;; Implementation: my-read/integrations/my-read-eww-math.el
(unless (featurep 'reader-load-path)
  (load (expand-file-name "reader-load-path"
                          (file-name-directory (or load-file-name buffer-file-name)))
        nil t))
(load "my-read/integrations/my-read-eww-math" nil t)
;;; my-read-eww-math.el ends here
