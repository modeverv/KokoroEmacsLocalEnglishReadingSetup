;;; my-read-k2.el --- Kindle.app source for my-read -*- lexical-binding: t; -*-

;; This backend reuses the reader UI, page caches, speech, and translation
;; integration from `my-read-k.el'.  Its bridge reads Kindle.app's native
;; accessibility page text, so English books do not need screenshot OCR.

(require 'my-read-k)

(defgroup my-read-k2 nil
  "Read an English book opened in the macOS Kindle.app."
  :group 'my-read-k)

(defconst my-read-k2--root
  (file-name-directory (or load-file-name buffer-file-name default-directory)))

(defcustom my-read-k2-bridge-program nil
  "Kindle.app bridge executable, or nil to use the package release binary."
  :type '(choice (const :tag "Package release binary" nil) file)
  :group 'my-read-k2)

(defcustom my-read-k2-book-name "Kindle.app"
  "Book name used by my-read notes for the currently open Kindle.app book."
  :type 'string
  :group 'my-read-k2)

(defvar my-read-k2--active-p nil)
(defvar my-read-k2--saved-language :unset)

(defun my-read-k2--bridge-command ()
  "Return the command used to launch the Kindle.app bridge."
  (let* ((package (expand-file-name "my-read-k2/bridge" my-read-k2--root))
         (binary (or my-read-k2-bridge-program
                     (expand-file-name ".build/release/my-read-k2-bridge" package))))
    (if (file-executable-p binary)
        (list binary)
      (list "swift" "run" "--package-path" package
            "--configuration" "release" "my-read-k2-bridge"))))

(defun my-read-k2--activate-backend ()
  "Select the Kindle.app bridge for the shared Kindle reader session."
  (unless my-read-k2--active-p
    (when (process-live-p my-read-k--process)
      (my-read-k-detach))
    (setq my-read-k2--saved-language my-read-k-language
          my-read-k2--active-p t))
  (setq my-read-k-language "en-US"))

(defun my-read-k2--bridge-command-advice (original &rest arguments)
  "Use the native bridge while active; otherwise call ORIGINAL with ARGUMENTS."
  (if my-read-k2--active-p
      (my-read-k2--bridge-command)
    (apply original arguments)))

(defun my-read-k2--reconnect-advice (original &rest arguments)
  "Reconnect the active backend, or call ORIGINAL with ARGUMENTS."
  (if my-read-k2--active-p
      (my-read-k2-reconnect)
    (apply original arguments)))

(defun my-read-k2--after-detach (&rest _arguments)
  "Forget native-backend selection after the shared bridge stops."
  (when my-read-k2--active-p
    (unless (eq my-read-k2--saved-language :unset)
      (setq my-read-k-language my-read-k2--saved-language))
    (setq my-read-k2--saved-language :unset
          my-read-k2--active-p nil)))

(advice-add 'my-read-k--bridge-command :around #'my-read-k2--bridge-command-advice)
(advice-add 'my-read-k-reconnect :around #'my-read-k2--reconnect-advice)
(advice-add 'my-read-k-detach :after #'my-read-k2--after-detach)

;;;###autoload
(defun my-read-k2-attach ()
  "Attach the shared reader UI to the English book open in Kindle.app."
  (interactive)
  (my-read-k2--activate-backend)
  (my-read-k--clear-navigation-caches)
  (setq my-read-k--prefetch-busy-p nil
        my-read-k--sync-busy-p nil
        my-read-k--detected-language nil
        my-read-k--state 'attaching)
  (my-read-k--send
   "attach" `((bookTitle . ,my-read-k2-book-name))
   (lambda (response)
     (if (my-read-k--response-error response)
         (my-read-k--show-connection-status
          "Kindle.appに接続できません。macOSのアクセシビリティ権限を確認してください。" t)
       (my-read-k--remember-target (my-read-k--alist-get 'result response))
       (setq my-read-k--state 'attached)
       (my-read-k-refresh)))))

;;;###autoload
(defun my-read-k2-reconnect ()
  "Restart the bridge and reconnect to Kindle.app."
  (interactive)
  (my-read-k-detach)
  (my-read-k--show-connection-status "Kindle.appへ再接続しています。")
  (my-read-k2-attach))

(defun my-read-k2--prepare-buffer ()
  "Prepare the shared Kindle reader buffer for Kindle.app."
  (let ((buffer (my-read-k--prepare-buffer)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Connecting to Kindle.app…\n\n"
                "Kindle.appで英語の本を開いてから r を押すと再接続します。\n")
        (local-set-key (kbd "r") #'my-read-k2-reconnect)
        (set-buffer-modified-p nil)))
    buffer))

(defun my-read-k2--open-unified-workspace ()
  "Open my-read using the English book currently displayed in Kindle.app."
  (my-read-k2--activate-backend)
  (if (frame-live-p my-read-k--frame)
      (progn
        (select-frame-set-input-focus my-read-k--frame)
        (unless (eq my-read-k--state 'attached)
          (my-read-k2-attach))
        my-read-k--frame)
    (my/read--lookup-enter)
    (let ((buffer (my-read-k2--prepare-buffer))
          frame)
      (condition-case err
          (progn
            (setq frame (make-frame `((name . ,my/read-frame-name))))
            (set-frame-parameter frame 'my-reading-frame t)
            (set-frame-parameter frame 'my-reading-kindle-frame t)
            (set-frame-parameter frame 'my-reading-kindle-buffer buffer)
            (setq my-read-k--frame frame my-read-k--buffer buffer)
            (my/read--setup-frame frame buffer)
            (select-frame-set-input-focus frame)
            (my-read-k--show-connection-status "Kindle.appへ接続しています。")
            (my-read-k2-attach)
            frame)
        (error
         (when (frame-live-p frame) (delete-frame frame t))
         (signal (car err) (cdr err)))))))

;; Remove the former public entry point when this file is reloaded in a live
;; Emacs.  `my-read' is now the sole command that opens this workspace.
(when (fboundp 'my-read-k2)
  (fmakunbound 'my-read-k2))

(provide 'my-read-k2)
;;; my-read-k2.el ends here
