;;; english-reading-mode.el --- Compatibility entry point -*- lexical-binding: t; -*-

;; Implementation: my-read/core/english-reading-mode.el
(unless (featurep 'reader-load-path)
  (load (expand-file-name "reader-load-path"
                          (file-name-directory (or load-file-name buffer-file-name)))
        nil t))
(load "my-read/core/english-reading-mode" nil t)
;;; english-reading-mode.el ends here
