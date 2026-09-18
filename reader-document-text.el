;;; reader-document-text.el --- Rendered text document backend -*- lexical-binding: t; -*-

(require 'reader-document)
(require 'english-reading-state)
(require 'thingatpt)

(defun reader-document-text--bounds ()
  "Return prose sentence bounds, treating Markdown ATX headings as speech units."
  (or (and (derived-mode-p 'markdown-mode)
           (save-excursion
             (beginning-of-line)
             (when (looking-at "[ \t]*#+\\(?:[ \t]+\\|$\\)")
               (cons (line-beginning-position) (line-end-position)))))
      (bounds-of-thing-at-point 'sentence)))

(defun english-reading-mode--sentence-bounds-at-point ()
  "Return the document backend's sentence bounds at point."
  (reader-document-call :bounds))

(defun english-reading-mode--sentence-bounds ()
  "Return the sentence at point, or signal a user error."
  (or (english-reading-mode--sentence-bounds-at-point)
      (user-error "Place point in an English sentence")))

(defun reader-document-text--sentence ()
  "Return the trimmed sentence and its exact source bounds."
  (unless (derived-mode-p 'dired-mode)
    (save-excursion
      (let ((sentence-end-double-space nil))
        (when-let* ((bounds (english-reading-mode--sentence-bounds-at-point)))
          (goto-char (car bounds))
          (skip-chars-forward " \t\n\r" (cdr bounds))
          (let ((beg (point)))
            (goto-char (cdr bounds))
            (skip-chars-backward " \t\n\r" beg)
            (when (< beg (point))
              (list (buffer-substring-no-properties beg (point))
                    (current-buffer) beg (point)))))))))

(defun reader-document-text--next ()
  "Move beyond the current text sentence."
  (pcase-let ((`(,_ . ,end) (english-reading-mode--sentence-bounds)))
    (goto-char end)
    (skip-chars-forward " \t\n\r")))

(defun reader-document-text--previous ()
  "Move backward without signaling at the beginning of the document."
  (pcase-let ((`(,beg . ,_) (english-reading-mode--sentence-bounds)))
    (goto-char beg)
    (let ((origin (point)) moved)
      (condition-case nil
          (progn
            (backward-sentence)
            (skip-chars-forward " \t\n\r")
            (setq moved (< (point) origin)))
        (error (goto-char origin)))
      (unless moved
        (goto-char origin)
        (message "Already at the first sentence")))))

(defun reader-document-text--continue ()
  "Advance and speak, or report the end of this text document."
  (english-reading-mode-next-sentence)
  (unless (and (< (point) (point-max))
               (english-reading-mode--sentence-bounds-at-point))
    (user-error "Reached the end of the document"))
  (english-reading-mode-speak-current-sentence))

(defun reader-document-text--title (&optional _frame)
  "Return a file title or a visible buffer name."
  (or (and buffer-file-name (file-name-base buffer-file-name))
      (and (not (string-prefix-p " " (buffer-name))) (buffer-name))
      "Unknown source"))

(defun reader-document-text--source (&optional _frame)
  "Return the current text file, if any."
  buffer-file-name)

(defun reader-document-text--persistent-type ()
  "Return text only for prose files, excluding temporary notes."
  (when (and buffer-file-name (derived-mode-p 'text-mode)) 'text))

(defun reader-document-text--location (&optional window)
  "Capture the text cursor and viewport, preserving active speech position."
  (let* ((visible (and (window-live-p window)
                       (eq (window-buffer window) (current-buffer))))
         (speech english-reading-mode--active-speech)
         (type (reader-document-call :persistent-type))
         (position (if (and (memq type '(text html))
                            (eq (plist-get speech :buffer) (current-buffer))
                            (integerp (plist-get speech :beg)))
                       (plist-get speech :beg)
                     (if visible (window-point window) (point))))
         (record (list :type type :point position)))
    (when visible (setq record (plist-put record :window-start (window-start window))))
    record))

(defun reader-document-text--clamp (position)
  "Clamp POSITION to the accessible document."
  (max (point-min) (min (point-max) position)))

(defun reader-document-text--restore (record window)
  "Restore RECORD's cursor and viewport in WINDOW."
  (with-selected-window window
    (when (integerp (plist-get record :point))
      (goto-char (reader-document-text--clamp (plist-get record :point)))
      (set-window-point window (point))
      (when (derived-mode-p 'org-mode) (org-fold-show-context 'lineage)))
    (when (integerp (plist-get record :window-start))
      (set-window-start window
                        (reader-document-text--clamp (plist-get record :window-start)) t))))

(defun reader-document-text--owns-speech-p (buffer)
  "Return non-nil when BUFFER is this document's speech source."
  (eq buffer (current-buffer)))

(reader-document-register
 'text (lambda () t)
 '(:bounds reader-document-text--bounds
           :speech-spec reader-document-text--speech-spec :resume reader-document-text--resume
           :prepare ignore
           :sentence reader-document-text--sentence
           :next reader-document-text--next :previous reader-document-text--previous
           :speak english-reading-mode--speak-at-point
           :continue reader-document-text--continue
           :title reader-document-text--title :source reader-document-text--source
           :persistent-type reader-document-text--persistent-type
           :location reader-document-text--location :restore reader-document-text--restore
           :owns-speech reader-document-text--owns-speech-p))

(defun reader-document-text--speech-spec ()
  "Return a speech chunk at the rendered text cursor."
  (pcase-let* ((`(,beg . ,end) (english-reading-mode--sentence-bounds))
               (`(,start . ,finish) (english-reading-mode--macos-continuous-bounds beg end)))
    (list :buffer (current-buffer) :beg start :end finish
          :text (kokoro-reader--text start finish))))

(defun reader-document-text--resume (buffer position)
  "Speak from POSITION when BUFFER is the displayed text source."
  (when (eq buffer (current-buffer))
    (goto-char (min position (point-max)))
    (skip-chars-forward " \t\n\r　 ")
    (when (and (< (point) (point-max))
               (english-reading-mode--sentence-bounds-at-point))
      (english-reading-mode-speak-current-sentence)
      t)))

(provide 'reader-document-text)
;;; reader-document-text.el ends here
