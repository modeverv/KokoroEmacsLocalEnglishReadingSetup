;;; reader-load-path.el --- Reader source layout -*- lexical-binding: t; -*-

(defconst reader-root-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Repository runtime root, independent of the current buffer or directory.")

(defconst reader-module-directories
  '("my-read/core"
    "my-read/ui"
    "my-read/document"
    "my-read/document/pdf"
    "my-read/document/epub"
    "my-read/document/eww"
    "my-read/document/text"
    "my-read/document/kindle"
    "my-read/speech/backend-selection"
    "my-read/speech/synthesis"
    "my-read/speech/http"
    "my-read/speech/prefetch"
    "my-read/speech/playback"
    "my-read/translation"
    "my-read/lookup"
    "my-read/notes"
    "my-read/vocabulary"
    "my-read/position"
    "my-read/integrations")
  "Concept directories containing Reader's Emacs Lisp implementation.")

(defun reader-add-load-path (root)
  "Append Reader module directories under ROOT to `load-path'.
Keep caller-supplied paths (including compiled test modules) ahead of sources."
  (dolist (directory (cons "" reader-module-directories))
    (add-to-list 'load-path (expand-file-name directory root) t)))

(reader-add-load-path reader-root-directory)
(provide 'reader-load-path)
;;; reader-load-path.el ends here
