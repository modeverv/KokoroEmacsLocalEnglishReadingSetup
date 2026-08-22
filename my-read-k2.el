;;; my-read-k2.el --- Kindle.app source for my-read -*- lexical-binding: t; -*-

;; This backend reuses the reader UI, page caches, speech, and translation
;; integration from `my-read-k.el'.  Its bridge reads only Kindle.app's native
;; accessibility page text.

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

(defun my-read-k2--bridge-command ()
  "Return the command used to launch the Kindle.app bridge."
  (let* ((package (expand-file-name "my-read-k2/bridge" my-read-k2--root))
         (binary (or my-read-k2-bridge-program
                     (expand-file-name ".build/release/my-read-k2-bridge" package))))
    (if (file-executable-p binary)
        (list binary)
      (list "swift" "run" "--package-path" package
            "--configuration" "release" "my-read-k2-bridge"))))

(defun my-read-k2--connection-error-message (response)
  "Return an actionable Japanese connection error for bridge RESPONSE."
  (let* ((error (my-read-k--alist-get 'error response))
         (code (my-read-k--alist-get 'code error))
         (detail (my-read-k--alist-get 'message error)))
    (pcase code
      ("NO_KINDLE_APP"
       "Kindle.appが起動していません。本を開いてから r で再接続してください。")
      ("ACCESSIBILITY_PERMISSION_REQUIRED"
       "EmacsにmacOSのアクセシビリティ権限を許可してから r で再接続してください。")
      ("NO_PAGE_TEXT"
       "Kindle.appの本文を取得できません。本を開いて本文ページを表示してから r で再接続してください。")
      (_ (format "Kindle.appに接続できません: %s"
                 (or detail code "不明なエラー"))))))

;;;###autoload
(defun my-read-k2-attach ()
  "Attach the shared reader UI to the English book open in Kindle.app."
  (interactive)
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
          (my-read-k2--connection-error-message response) t)
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

(setq my-read-k--bridge-command-function #'my-read-k2--bridge-command
      my-read-k--reconnect-function #'my-read-k2-reconnect)

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
