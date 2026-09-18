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

(ert-deftest reader-layout-close-document-all-formats ()
  ;; Exercise key lookup and ensure session teardown precedes buffer killing.
  (dolist (entry '((pdf . pdf-view-mode) (pdf . doc-view-mode)
                   (epub . nov-mode) (text . text-mode)
                   (text . org-mode) (text . markdown-mode)
                   (eww . eww-mode) (kindle . my-read-k-document-mode)))
    (save-window-excursion
      (let* ((frame (selected-frame))
             (parameters (frame-parameters frame))
             (center (selected-window))
             (notes (split-window-right))
             (source (generate-new-buffer " *close-source*"))
             (dired (generate-new-buffer " *close-dired*"))
             (note (generate-new-buffer " *close-note*"))
             (ready (generate-new-buffer " *close-ready*"))
             (kind (car entry))
             (parameter (intern (format "my-reading-%s-buffer" kind)))
             (my-read-k--buffer nil)
             saved stopped detached closed)
        (unwind-protect
            (cl-letf (((symbol-function 'my/read-position-save-buffer)
                       (lambda (buffer window) (setq saved (list buffer window))))
                      ((symbol-function 'kokoro-reader-stop)
                       (lambda () (setq stopped t)))
                      ((symbol-function 'my-read-k-detach)
                       (lambda () (setq detached t)))
                      ((symbol-function 'my-read-k--prepare-buffer) (lambda () ready))
                      ((symbol-function 'my/read--prepare-eww-buffer) (lambda (_) ready))
                      ((symbol-function 'my/read--prepare-notes-buffer) (lambda (_) ready))
                      ((symbol-function 'my/read--prepare-center-tab-placeholder)
                       (lambda (_ type)
                         (with-current-buffer ready
                           (setq-local my/read-center-tab-placeholder-type type))
                         ready))
                      ((symbol-function 'my/read--configure-center-tab-buffer) #'ignore)
                      ((symbol-function 'my/read-lookup-follow-post-command) #'ignore)
                      ((symbol-function 'my/read-translate-follow-post-command) #'ignore)
                      ((symbol-function 'my/read-org-noter-close-source)
                       (lambda (buffer)
                         (should (eq buffer source))
                         (should (eq (window-buffer center) dired))
                         (should (eq (window-buffer notes) ready))
                         (setq closed t))))
              (set-frame-parameter frame 'my-reading-frame t)
              (set-frame-parameter frame 'my-reading-center-window center)
              (set-frame-parameter frame 'my-reading-center-windows (list center))
              (set-frame-parameter frame 'my-reading-note-window notes)
              (set-frame-parameter frame 'my-reading-dired-buffer dired)
              (set-frame-parameter frame parameter source)
              (set-window-buffer center source)
              (set-window-buffer notes note)
              (with-current-buffer source
                (setq major-mode (cdr entry))
                (setq-local my/read-center-tab-frame frame)
                (my-read-center-tab-mode 1)
                (add-hook 'kill-buffer-hook
                          (lambda () (should closed)) nil t))
              (with-selected-window notes
                (should-not (eq (key-binding (kbd "C-x k"))
                                #'my/read-close-document)))
              (with-selected-window center
                (should (eq (key-binding (kbd "C-x k")) #'my/read-close-document))
                (call-interactively (key-binding (kbd "C-x k"))))
              (should (equal saved (list source center)))
              (should stopped)
              (should (eq detached (eq kind 'kindle)))
              (should-not (buffer-live-p source))
              (should (frame-live-p frame))
              (should (window-live-p notes))
              (should (eq (window-buffer center) dired))
              (should (eq (frame-parameter frame parameter) ready)))
          (dolist (key (delete-dups
                        (list parameter 'my-reading-frame 'my-reading-center-window
                              'my-reading-center-windows 'my-reading-note-window
                              'my-reading-dired-buffer 'my-reading-kindle-book-name)))
            (set-frame-parameter frame key (cdr (assq key parameters))))
          (dolist (buffer (list source dired note ready))
            (when (buffer-live-p buffer)
              (with-current-buffer buffer (setq kill-buffer-hook nil))
              (kill-buffer buffer))))))))

(ert-deftest reader-layout-close-empty-tab-keeps-workspace ()
  (dolist (kind '(dired pdf epub text))
    (save-window-excursion
      (let* ((frame (selected-frame))
             (parameters (frame-parameters frame))
             (window (selected-window))
             (dired (generate-new-buffer " *empty-dired*"))
             (source (if (eq kind 'dired) dired
                       (generate-new-buffer " *empty-tab*")))
             (parameter (intern (format "my-reading-%s-buffer" kind))))
        (unwind-protect
            (progn
              (set-frame-parameter frame 'my-reading-frame t)
              (set-frame-parameter frame 'my-reading-center-window window)
              (set-frame-parameter frame 'my-reading-center-windows (list window))
              (set-frame-parameter frame 'my-reading-dired-buffer dired)
              (set-frame-parameter frame parameter source)
              (switch-to-buffer source)
              (setq-local my/read-center-tab-frame frame)
              (setq-local my/read-center-tab-placeholder-type
                          (unless (eq kind 'dired) kind))
              (my-read-center-tab-mode 1)
              (call-interactively (key-binding (kbd "C-x k")))
              (should (buffer-live-p source))
              (should (frame-live-p frame))
              (should (eq (window-buffer window) dired)))
          (dolist (key (delete-dups (list parameter 'my-reading-frame
                                         'my-reading-center-window
                                         'my-reading-center-windows
                                         'my-reading-dired-buffer)))
            (set-frame-parameter frame key (cdr (assq key parameters))))
          (kill-buffer source)
          (when (buffer-live-p dired) (kill-buffer dired)))))))
