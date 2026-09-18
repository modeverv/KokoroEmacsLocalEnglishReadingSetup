;;; reader-test-source.el --- Test checkout sources, not local caches -*- lexical-binding: t; -*-

(defconst reader-test--root
  (file-name-directory (directory-file-name
                        (file-name-directory (or load-file-name buffer-file-name)))))

;; Anchor runtime assets to the checkout even when testing a detached bytecode tree.
(load (expand-file-name "reader-load-path.el" reader-test--root) nil t t)
(when-let* ((compiled (getenv "READER_TEST_COMPILED_DIR"))
            ((not (equal compiled ""))))
  (let ((compiled-paths (let ((load-path nil))
                          (reader-add-load-path compiled)
                          load-path)))
    (setq load-path (append compiled-paths load-path))))

(defun reader-test--load-source (arguments)
  "Resolve checkout libraries in load ARGUMENTS to their source files.
External dependencies keep their normal compiled loading behavior."
  (let* ((name (car arguments))
         (base (if (string-match "\\.elc?\\'" name)
                   (file-name-sans-extension name) name))
         (source (locate-file base load-path '(".el"))))
    (when (and source
               (file-in-directory-p source reader-test--root))
      (setcar arguments source))
    arguments))

(defun reader-test--require-source (original feature &optional filename noerror)
  "Load checkout FEATURE from source before calling ORIGINAL."
  (unless (featurep feature)
    (let* ((name (or filename (symbol-name feature)))
           (resolved (car (reader-test--load-source (list name)))))
      (unless (equal name resolved)
        (load resolved noerror t t))))
  (funcall original feature filename noerror))

(unless (getenv "READER_TEST_COMPILED")
  (advice-add 'load :filter-args #'reader-test--load-source)
  (advice-add 'require :around #'reader-test--require-source))

(provide 'reader-test-source)
;;; reader-test-source.el ends here
