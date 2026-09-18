;;; english-reading-mode.el --- Mode for sentence reading -*- lexical-binding: t; -*-

(require 'reader-document-epub)
(require 'english-reading-pdf)
(require 'english-reading-speech)

(defun english-reading-mode--filter-key-binding (binding)
  "Return BINDING when reading keys are active in the selected window."
  (when (or (null english-reading-mode-key-active-predicate)
            (funcall english-reading-mode-key-active-predicate))
    binding))

(defun english-reading-mode--enable-single-space-sentences ()
  "Treat normal English punctuation followed by one space as a sentence end."
  (unless english-reading-mode--sentence-setting-saved-p
    (setq english-reading-mode--sentence-setting-was-local-p
          (local-variable-p 'sentence-end-double-space)
          english-reading-mode--saved-sentence-end-double-space
          sentence-end-double-space
          english-reading-mode--sentence-setting-saved-p t))
  (setq-local sentence-end-double-space nil))

(defun english-reading-mode--restore-sentence-setting ()
  "Restore the sentence spacing convention from before this mode was enabled."
  (when english-reading-mode--sentence-setting-saved-p
    (if english-reading-mode--sentence-setting-was-local-p
        (setq-local sentence-end-double-space
                    english-reading-mode--saved-sentence-end-double-space)
      (kill-local-variable 'sentence-end-double-space))
    (setq english-reading-mode--sentence-setting-saved-p nil)))

(defun english-reading-mode--enable-read-only ()
  "Make the current buffer read-only while remembering its prior state."
  (unless english-reading-mode--read-only-setting-saved-p
    (setq english-reading-mode--saved-buffer-read-only buffer-read-only
          english-reading-mode--read-only-setting-saved-p t))
  (read-only-mode 1))

(defun english-reading-mode--restore-read-only ()
  "Restore the read-only state from before this mode was enabled."
  (when english-reading-mode--read-only-setting-saved-p
    (read-only-mode
     (if english-reading-mode--saved-buffer-read-only 1 -1))
    (setq english-reading-mode--read-only-setting-saved-p nil)))

(with-eval-after-load 'pdf-view
  (advice-remove 'pdf-view-mouse-set-region
                 #'english-reading-mode--pdf-selection-finished)
  (advice-add 'pdf-view-mouse-set-region :after
              #'english-reading-mode--pdf-selection-finished))

(defun english-reading-mode--speak-at-point ()
  "Speak the sentence at point with Kokoro."
  (pcase-let ((`(,beg . ,end) (english-reading-mode--sentence-bounds)))
    (pcase-let ((`(,chunk-beg . ,chunk-end)
                 (english-reading-mode--macos-continuous-bounds beg end)))
      (kokoro-reader--speak-bounds chunk-beg chunk-end))))

(defun english-reading-mode-speak-current-sentence ()
  "Read the current sentence without moving the text cursor."
  (interactive)
  (reader-document-call :speak))

(defun english-reading-mode-next-sentence ()
  "Move to the next sentence without reading it."
  (interactive)
  (reader-document-call :next))

(defun english-reading-mode-previous-sentence ()
  "Move to the previous sentence without reading it."
  (interactive)
  (reader-document-call :previous))

(defun english-reading-mode-next-page ()
  "Display the next PDF page and reset the virtual sentence cursor."
  (interactive)
  (unless (english-reading-mode--pdf-buffer-p)
    (user-error "This command is only available in a PDF buffer"))
  (english-reading-mode--pdf-sync)
  (english-reading-mode--pdf-goto-page
   (1+ (english-reading-mode--pdf-current-page))))

(defun english-reading-mode-previous-page ()
  "Display the previous PDF page and reset the virtual sentence cursor."
  (interactive)
  (unless (english-reading-mode--pdf-buffer-p)
    (user-error "This command is only available in a PDF buffer"))
  (english-reading-mode--pdf-sync)
  (english-reading-mode--pdf-goto-page
   (1- (english-reading-mode--pdf-current-page))))

(defun english-reading-mode--filter-pdf-key-binding (binding)
  "Return PDF-only BINDING when reader keys are active."
  (when (and (english-reading-mode--filter-key-binding binding)
             (english-reading-mode--pdf-buffer-p))
    binding))

(defun english-reading-mode-stop ()
  "Stop the current Kokoro reading."
  (interactive)
  (english-reading-mode-stop-continuous))

(defvar-keymap english-reading-mode-map
  :doc "Keymap for `english-reading-mode'."
  "j" '(menu-item "Move to next sentence" english-reading-mode-next-sentence
                  :filter english-reading-mode--filter-key-binding)
  "k" '(menu-item "Move to previous sentence" english-reading-mode-previous-sentence
                  :filter english-reading-mode--filter-key-binding)
  "SPC" '(menu-item "Read current sentence" english-reading-mode-speak-current-sentence
                    :filter english-reading-mode--filter-key-binding)
  "C-v" '(menu-item "Next PDF page" english-reading-mode-next-page
                    :filter english-reading-mode--filter-pdf-key-binding)
  "M-v" '(menu-item "Previous PDF page" english-reading-mode-previous-page
                    :filter english-reading-mode--filter-pdf-key-binding)
  "s" '(menu-item "Continuous sentence reading" english-reading-mode-continuous-read
                  :filter english-reading-mode--filter-key-binding)
  ;;  "" '(menu-item "Read paragraph" kokoro-reader-speak-paragraph
  ;;                   :filter english-reading-mode--filter-key-binding)
  "C-c C-k" '(menu-item "Stop reading" english-reading-mode-stop
                        :filter english-reading-mode--filter-key-binding))

;; Keep re-evaluation effective in a live Emacs where `defvar-keymap' preserves
;; the already existing map object.
(keymap-set english-reading-mode-map "j"
            '(menu-item "Move to next sentence"
                        english-reading-mode-next-sentence
                        :filter english-reading-mode--filter-key-binding))

(keymap-set english-reading-mode-map "k"
            '(menu-item "Move to previous sentence"
                        english-reading-mode-previous-sentence
                        :filter english-reading-mode--filter-key-binding))

(keymap-set english-reading-mode-map "SPC"
            '(menu-item "Read current sentence"
                        english-reading-mode-speak-current-sentence
                        :filter english-reading-mode--filter-key-binding))

(keymap-set english-reading-mode-map "C-v"
            '(menu-item "Next PDF page" english-reading-mode-next-page
                        :filter english-reading-mode--filter-pdf-key-binding))

(keymap-set english-reading-mode-map "M-v"
            '(menu-item "Previous PDF page" english-reading-mode-previous-page
                        :filter english-reading-mode--filter-pdf-key-binding))

;; `i' belongs exclusively to Org-noter.  Explicit removal also fixes an
;; already loaded map, because `defvar-keymap' preserves its old entries.
(define-key english-reading-mode-map (kbd "i") nil)

(keymap-set english-reading-mode-map "s"
            '(menu-item "Continuous sentence reading"
                        english-reading-mode-continuous-read
                        :filter english-reading-mode--filter-key-binding))

;;(keymap-set english-reading-mode-map "p"
;;            '(menu-item "Read paragraph" kokoro-reader-speak-paragraph
;;                        :filter english-reading-mode--filter-key-binding))
(keymap-set english-reading-mode-map "C-c C-k"
            '(menu-item "Stop reading" english-reading-mode-stop
                        :filter english-reading-mode--filter-key-binding))

;;;###autoload
(define-minor-mode english-reading-mode
  "Read English text or a DocView PDF with Kokoro or macOS speech.

`j' and `k' move to the next and previous sentences, `SPC' reads the sentence
at point, and `s' reads continuously.  The macOS backend groups continuous
speech into short multi-sentence chunks.  `i' is reserved for Org-noter.  The
buffer is read-only while this mode is active.  Speech lifecycle is exposed
through `english-reading-mode-speech-start-hook' and
`english-reading-mode-speech-finish-hook'."
  :lighter " EnglishRead"
  :keymap english-reading-mode-map
  (if english-reading-mode
      (progn
        (english-reading-mode--enable-single-space-sentences)
        (english-reading-mode--enable-read-only)
        (add-hook 'kill-buffer-hook #'english-reading-mode--release-buffer nil t)
        (add-hook 'pre-command-hook
                  #'english-reading-mode--pdf-pre-command nil t)
        (add-hook 'post-command-hook
                  #'english-reading-mode--pdf-post-command nil t)
        (unless (or (derived-mode-p 'nov-mode 'eww-mode 'doc-view-mode
                                    'pdf-view-mode 'text-mode)
                    (bound-and-true-p my-read-k-mode))
          (message "english-reading-mode is designed for reader buffers")))
    (english-reading-mode--restore-sentence-setting)
    (english-reading-mode--restore-read-only)
    (remove-hook 'pre-command-hook
                 #'english-reading-mode--pdf-pre-command t)
    (remove-hook 'post-command-hook
                 #'english-reading-mode--pdf-post-command t)
    (english-reading-mode--release-buffer)
    (remove-hook 'kill-buffer-hook #'english-reading-mode--release-buffer t)
    (english-reading-mode--pdf-cleanup)))

(provide 'english-reading-mode)
;;; english-reading-mode.el ends here
