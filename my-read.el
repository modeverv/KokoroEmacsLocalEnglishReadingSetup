;;; my-read.el --- Reader library entry point -*- lexical-binding: t; -*-

;; Implementation: my-read/core/my-read.el
(unless (featurep 'reader-load-path)
  (load (expand-file-name "my-read/reader-load-path"
                          (file-name-directory (or load-file-name buffer-file-name)))
        nil t))
(load "my-read/core/my-read" nil t)
;;; my-read.el ends here
