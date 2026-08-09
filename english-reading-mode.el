;;; english-reading-mode.el --- Sentence-by-sentence English reading -*- lexical-binding: t; -*-

;; This mode is intended for nov.el/EPUB buffers.  It uses the local Kokoro
;; client for speech and keeps the cursor on the sentence currently being read.

(require 'kokoro-reader)
(require 'thingatpt)

(defgroup english-reading-mode nil
  "Sentence-by-sentence English reading with Kokoro."
  :group 'multimedia)

(defun english-reading-mode--sentence-bounds ()
  "Return the sentence at point, or signal a user error."
  (or (bounds-of-thing-at-point 'sentence)
      (user-error "Place point in an English sentence")))

(defun english-reading-mode--speak-at-point ()
  "Speak the sentence at point with Kokoro."
  (pcase-let ((`(,beg . ,end) (english-reading-mode--sentence-bounds)))
    (kokoro-reader--speak-bounds beg end)))

(defun english-reading-mode-next-sentence ()
  "Read the sentence at point, then move to the next sentence."
  (interactive)
  (pcase-let ((`(_ . ,end) (english-reading-mode--sentence-bounds)))
    (english-reading-mode--speak-at-point)
    (goto-char end)
    (skip-chars-forward " \t\n\r")))

(defun english-reading-mode-previous-sentence ()
  "Move to the previous sentence and read it with Kokoro."
  (interactive)
  (pcase-let ((`(,beg . ,_) (english-reading-mode--sentence-bounds)))
    (goto-char beg)
    (backward-sentence)
    (skip-chars-forward " \t\n\r")
    (when (>= (point) beg)
      (goto-char beg)
      (user-error "Already at the first sentence"))
    (english-reading-mode--speak-at-point)))

(defun english-reading-mode-stop ()
  "Stop the current Kokoro reading."
  (interactive)
  (kokoro-reader-stop))

(defvar-keymap english-reading-mode-map
  :doc "Keymap for `english-reading-mode'."
  "j" #'english-reading-mode-next-sentence
  "k" #'english-reading-mode-previous-sentence
  "C-c C-k" #'english-reading-mode-stop)

;;;###autoload
(define-minor-mode english-reading-mode
  "Read English EPUB text one sentence at a time with local Kokoro.

In a nov.el buffer, use `j` to read the sentence at point and advance to the
next sentence.  Use `k` to move back and read the previous sentence.  The
mode reuses `kokoro-reader-mode`'s server settings."
  :lighter " EnglishRead"
  :keymap english-reading-mode-map
  (when english-reading-mode
    (unless (derived-mode-p 'nov-mode)
      (message "english-reading-mode is designed for nov.el/EPUB buffers")))
  (unless english-reading-mode
    (english-reading-mode-stop)))

(provide 'english-reading-mode)
;;; english-reading-mode.el ends here
