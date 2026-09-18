;;; reader-layout-tests.el --- Relocation and entry point tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'reader-load-path)
(require 'my-read-k2)
(require 'reader-http-speech)

(ert-deftest reader-layout-runtime-assets-use-companion-root ()
  (should (equal my-read-k2--root reader-companion-directory))
  (should (equal reader-http-speech--directory reader-companion-directory))
  (should (equal kokoro-reader-server-directory reader-companion-directory))
  (should (equal reader-http-speech-python
                 (expand-file-name ".venv/bin/python" reader-companion-directory)))
  (should (equal kokoro-reader-macos-speech-bridge-program
                 (expand-file-name "macos-speech-bridge/my-read-speech-bridge"
                                   reader-companion-directory)))
  (dolist (asset '("kokoro_server.py" "speech_http/service.py"
                   "my-read-k2/bridge/Package.swift"))
    (should (file-exists-p (expand-file-name asset reader-companion-directory)))))

(ert-deftest reader-layout-definitions-live-in-concept-directories ()
  (dolist (entry '((my-read . "core/my-read")
                   (reader-document-register . "document/reader-document")
                   (my-read-k2--bridge-command . "document/kindle/my-read-k2")))
    (let ((file (symbol-file (car entry) 'defun)))
      (should (string-suffix-p
               (concat "my-read/" (cdr entry)
                       (if (getenv "READER_TEST_COMPILED") ".elc" ".el"))
               file)))))

(ert-deftest reader-layout-public-entries-load-from-unrelated-directory ()
  ;; Each entry gets a fresh Emacs: a previously loaded bootstrap cannot hide
  ;; a broken standalone path.  Absolute `load' is supported without -L ROOT.
  (dolist (entry '("my-read" "kokoro-reader" "reader-http-speech-transport"))
    (with-temp-buffer
      (let* ((default-directory temporary-file-directory)
             (expression
              `(progn
                 (require 'package)
                 (package-initialize)
                 (setq native-comp-jit-compilation nil)
                 (load ,(expand-file-name "my-read.el" reader-root-directory)
                       nil t t)
                 (require ',(intern entry))
                 (unless (featurep ',(intern entry)) (error "Missing feature"))
                 (unless (equal reader-root-directory ,reader-root-directory)
                   (error "Wrong runtime root"))))
             (status (call-process
                      (expand-file-name invocation-name invocation-directory)
                      nil t nil "-Q" "--batch" "--eval" (prin1-to-string expression))))
        (should (equal (list entry status (and (/= status 0) (buffer-string)))
                       (list entry 0 nil)))))))

;;; reader-layout-tests.el ends here
