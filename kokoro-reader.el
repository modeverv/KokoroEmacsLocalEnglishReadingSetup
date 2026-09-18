;;; kokoro-reader.el --- Compatibility entry point -*- lexical-binding: t; -*-

;; Implementation: my-read/speech/synthesis/kokoro-reader.el
(unless (featurep 'reader-load-path)
  (load (expand-file-name "reader-load-path"
                          (file-name-directory (or load-file-name buffer-file-name)))
        nil t))
(load "my-read/speech/synthesis/kokoro-reader" nil t)
;;; kokoro-reader.el ends here
