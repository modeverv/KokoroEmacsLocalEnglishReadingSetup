;;; my-read-k.el --- Compatibility entry point -*- lexical-binding: t; -*-

;; Implementation: my-read/document/kindle/my-read-k.el
(unless (featurep 'reader-load-path)
  (load (expand-file-name "reader-load-path"
                          (file-name-directory (or load-file-name buffer-file-name)))
        nil t))
(load "my-read/document/kindle/my-read-k" nil t)
;;; my-read-k.el ends here
