;;; reader-http-playback.el --- Compatibility entry point -*- lexical-binding: t; -*-

;; Implementation: my-read/speech/playback/reader-http-playback.el
(unless (featurep 'reader-load-path)
  (load (expand-file-name "reader-load-path"
                          (file-name-directory (or load-file-name buffer-file-name)))
        nil t))
(load "my-read/speech/playback/reader-http-playback" nil t)
;;; reader-http-playback.el ends here
