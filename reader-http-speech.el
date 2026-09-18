;;; reader-http-speech.el --- Compatibility entry point -*- lexical-binding: t; -*-

;; Implementation: my-read/speech/http/reader-http-speech.el
(unless (featurep 'reader-load-path)
  (load (expand-file-name "reader-load-path"
                          (file-name-directory (or load-file-name buffer-file-name)))
        nil t))
(load "my-read/speech/http/reader-http-speech" nil t)
;;; reader-http-speech.el ends here
