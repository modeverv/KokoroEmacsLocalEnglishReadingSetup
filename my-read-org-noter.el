;;; my-read-org-noter.el --- Compatibility entry point -*- lexical-binding: t; -*-

;; Implementation: my-read/notes/my-read-org-noter.el
(unless (featurep 'reader-load-path)
  (load (expand-file-name "reader-load-path"
                          (file-name-directory (or load-file-name buffer-file-name)))
        nil t))
(load "my-read/notes/my-read-org-noter" nil t)
;;; my-read-org-noter.el ends here
