;;; my-read.el --- My-read for the reader -*- lexical-binding: t; -*-

(declare-function my-read-k2--open-unified-workspace "my-read-k2")
(when load-file-name
  (add-to-list 'load-path (file-name-directory load-file-name)))
(require 'my-read-ui)

;;;###autoload
(defun my-read ()
  "Open the unified Kindle.app, EPUB, and EWW reading workspace."
  (interactive)
  ;; Load lazily to avoid a load-time cycle: my-read-k2 requires my-read via
  ;; the shared my-read-k UI implementation.
  (require 'my-read-k2)
  (my-read-restart-japanese-speech)
  (my-read-k2--open-unified-workspace))

;;;###autoload
(defun my-read-end ()
  "Close the active my-read workspace and stop its background services."
  (interactive)
  (let ((frames (cl-remove-if-not #'my/read-frame-p (frame-list))))
    (unless frames
      (user-error "終了するmy-readワークスペースがありません"))
    ;; The delete-frame hooks stop the Kindle bridge, follower modes, timers,
    ;; translation process, and temporary workspace buffers.
    (dolist (frame frames)
      (my/read-position-save-frame frame)
      (delete-frame frame t))
    (message "my-readを終了しました")))

(defun my/read--frame-deleted (frame)
  "Clean up my-read state when FRAME is deleted."
  (when (my/read-frame-p frame)
    (my/read-position-save-frame frame)
    (when (or (eq frame (plist-get english-reading-mode--continuous-state :frame))
              (eq frame (plist-get english-reading-mode--active-speech :frame)))
      (english-reading-mode-stop-continuous))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (eq my/read-center-tab-frame frame)
          (when (timerp my/read-position--save-timer)
            (cancel-timer my/read-position--save-timer))
          (setq my/read-position--save-timer nil
                my/read-center-tab-frame nil)
          (remove-hook 'post-command-hook #'my/read-position--schedule-save t))))
    (when (and my/read-kokoro-context
               (eq frame (plist-get my/read-kokoro-context :frame)))
      (setq my/read-kokoro-context nil))

    (my/read-translate-delete-overlay frame)

    (dolist (parameter '(my-reading-translate-buffer
                         my-reading-lookup-ready-buffer
                         my-reading-note-ready-buffer
                         my-reading-kindle-placeholder-buffer
                         my-reading-pdf-placeholder-buffer
                         my-reading-epub-placeholder-buffer))
      (when-let* ((buffer (frame-parameter frame parameter)))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))

    (unless (my/read--other-reading-frame-p frame)
      (when (timerp my/read-org-noter--sync-timer)
        (cancel-timer my/read-org-noter--sync-timer))
      (setq my/read-org-noter--sync-timer nil)
      (my/read--lookup-restore-normal)
      (my-read-lookup-follow-mode -1)
      (my-read-translate-follow-mode -1))))

(add-hook 'delete-frame-functions #'my/read--frame-deleted)

(provide 'my-read)
;;; my-read.el ends here
