;;; english-reader-tts.el --- Compatibility entry point -*- lexical-binding: t; -*-

;; Implementation: my-read/integrations/english-reader-tts.el
(unless (featurep 'reader-load-path)
  (load (expand-file-name "reader-load-path"
                          (file-name-directory (or load-file-name buffer-file-name)))
        nil t))
(load "my-read/integrations/english-reader-tts" nil t)
;;; english-reader-tts.el ends here
