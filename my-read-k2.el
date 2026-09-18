;;; my-read-k2.el --- Compatibility entry point -*- lexical-binding: t; -*-

;; Implementation: my-read/document/kindle/my-read-k2.el
(unless (featurep 'reader-load-path)
  (load (expand-file-name "reader-load-path"
                          (file-name-directory (or load-file-name buffer-file-name)))
        nil t))
(load "my-read/document/kindle/my-read-k2" nil t)
;;; my-read-k2.el ends here
