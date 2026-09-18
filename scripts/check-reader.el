;;; check-reader.el --- Batch syntax and compilation checks -*- lexical-binding: t; -*-

(require 'package)
(package-initialize)
(require 'bytecomp)
(setq load-prefer-newer t
      byte-compile-error-on-warn t
      native-comp-jit-compilation nil
      native-comp-enable-subr-trampolines nil)

(let* ((root (file-name-directory
              (directory-file-name (file-name-directory load-file-name))))
       (output (or (getenv "READER_COMPILE_DIR") (make-temp-file "reader-compile-" t)))
       (files (append (directory-files root t "\\.el\\'")
                      (directory-files-recursively
                       (expand-file-name "my-read" root) "\\.el\\'")))
       (byte-compile-dest-file-function
        (lambda (source)
          (let ((destination
                 (expand-file-name
                  (concat (file-name-sans-extension (file-relative-name source root)) ".elc")
                  output)))
            (make-directory (file-name-directory destination) t)
            destination)))
       failed)
  (add-to-list 'load-path root)
  (load (expand-file-name "test/reader-test-source.el" root) nil t)
  (make-directory output t)
  (dolist (file files)
    (with-temp-buffer
      (insert-file-contents file)
      (emacs-lisp-mode)
      (check-parens))
    (unless (byte-compile-file file) (push file failed)))
  (when failed (error "Compilation failed: %S" failed))
  (message "Checked %d reader modules; bytecode: %s" (length files) output))
