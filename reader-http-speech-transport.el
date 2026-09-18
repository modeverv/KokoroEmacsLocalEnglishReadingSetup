;;; reader-http-speech-transport.el --- Compatibility entry point -*- lexical-binding: t; -*-

;; Implementation: my-read/speech/http/reader-http-speech-transport.el
(unless (featurep 'reader-load-path)
  (load (expand-file-name "reader-load-path"
                          (file-name-directory (or load-file-name buffer-file-name)))
        nil t))
(load "my-read/speech/http/reader-http-speech-transport" nil t)
;;; reader-http-speech-transport.el ends here
