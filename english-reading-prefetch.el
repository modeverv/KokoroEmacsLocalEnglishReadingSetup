;;; english-reading-prefetch.el --- Prefetch for sentence reading -*- lexical-binding: t; -*-

(require 'english-reading-state)
(require 'reader-document-text)
(require 'reader-document)
(require 'kokoro-reader)
(require 'seq)

(defun english-reading-mode--speech-texts-after-position
    (buffer position count)
  "Return up to COUNT macOS speech chunks in BUFFER after POSITION.

PDF form-feed boundaries are crossed while each individual chunk remains
limited to one page so its cache key matches normal playback."
  (let (texts)
    (when (and (buffer-live-p buffer)
               (integer-or-marker-p position)
               (> count 0))
      (with-current-buffer buffer
        (save-excursion
          (goto-char (min position (point-max)))
          (while (and (< (length texts) count) (< (point) (point-max)))
            (skip-chars-forward " \t\n\r\f")
            (let* ((scan-position (point))
                   (page-range
                    (english-reading-mode--continuous-speech-page-range
                     buffer scan-position))
                   bounds beg finish sentence-text chunk candidate)
              ;; Narrow exactly like normal PDF playback.  Without this, Emacs
              ;; can treat a page number before a form feed as part of the next
              ;; page's first sentence, producing a prefetch cache-key mismatch.
              (save-restriction
                (when page-range
                  (narrow-to-region (car page-range) (cdr page-range)))
                (goto-char (min (max scan-position (point-min)) (point-max)))
                (skip-chars-forward " \t\n\r")
                (setq bounds (and (< (point) (point-max))
                                  (english-reading-mode--sentence-bounds-at-point)))
                (if (not bounds)
                    (goto-char (point-max))
                  (goto-char (car bounds))
                  (skip-chars-forward " \t\n\r" (cdr bounds))
                  (setq beg (point))
                  (goto-char (cdr bounds))
                  (skip-chars-backward " \t\n\r" beg)
                  (setq finish (point)
                        sentence-text
                        (buffer-substring-no-properties beg finish))
                  ;; Match `english-reading-mode--pdf-location': reject an
                  ;; isolated label before extending it into a multi-sentence
                  ;; chunk.  Testing the combined chunk first incorrectly turns
                  ;; table cells such as "○" into "○ 共有ロック" and shifts
                  ;; every prefetched key away from actual playback.
                  ;; Only PDF playback skips isolated labels.  EPUB playback
                  ;; counts a trailing quote as a sentence unit when chunking;
                  ;; dropping it here changes the next chunk and cancels audio
                  ;; already queued in the resident player.
                  (if (and page-range
                           (not (string-match-p
                                 "[[:alpha:]].*[[:alpha:]]" sentence-text)))
                      (goto-char (min (1+ finish) (point-max)))
                    (setq chunk
                          (english-reading-mode--macos-continuous-bounds
                           beg finish (cdr page-range))
                          candidate
                          (kokoro-reader--text (car chunk) (cdr chunk)))
                    ;; `pdftotext' often emits the printed page number directly
                    ;; before the first sentence.  Normal PDF navigation skips
                    ;; that label, so remove it from lookahead as well or the
                    ;; synthesized cache key will differ at the page boundary.
                    (when (and page-range
                               (= beg
                                  (save-excursion
                                    (goto-char (car page-range))
                                    (skip-chars-forward " \t\n\r")
                                    (point))))
                      (setq candidate
                            (replace-regexp-in-string
                             "\\`[[:digit:]０-９]+[.．]?[ \t\n\r]+"
                             "" candidate)))
                    (goto-char (cdr chunk))
                    (push candidate texts)))))))))
    (nreverse texts)))

(defun english-reading-mode--next-speech-texts (context &optional count)
  "Return ordered macOS speech chunks following CONTEXT.

Use the current speech buffer first, crossing PDF pages when present.  A
source-specific provider may then contribute cached future pages, as Kindle
does without changing the displayed page."
  (let ((buffer (plist-get context :buffer))
        (end (plist-get context :end))
        (maximum (or count english-reading-mode-macos-prefetch-chunk-count))
        texts)
    (setq texts
          (english-reading-mode--speech-texts-after-position
           buffer end maximum))
    (let* ((source-buffer
            (plist-get english-reading-mode--continuous-state :buffer))
           (remaining (- maximum (length texts)))
           (more
            (when (and (> remaining 0) (buffer-live-p source-buffer))
              (with-current-buffer source-buffer
                (when (functionp
                       english-reading-mode-continuous-prefetch-text-function)
                  (funcall
                   english-reading-mode-continuous-prefetch-text-function
                   context remaining))))))
      (append texts (seq-take more remaining)))))

(defun english-reading-mode--next-speech-text (context)
  "Return the first macOS speech chunk following CONTEXT."
  (car (english-reading-mode--next-speech-texts context 1)))

(defun english-reading-mode--prefetch-next-macos-sentence (context)
  "Render future resident-player chunks following CONTEXT."
  (let ((speech-buffer (plist-get context :buffer)))
    (when (and english-reading-mode--continuous-state
               (english-reading-mode--continuous-context-owned-p context)
               (buffer-live-p speech-buffer))
      (with-current-buffer speech-buffer
        (let ((texts (english-reading-mode--next-speech-texts context)))
          (pcase kokoro-reader-backend
            ('macos
             (when (fboundp 'kokoro-reader-prefetch-macos-texts)
               (let ((kokoro-reader-macos-prefetch-count
                      english-reading-mode-macos-prefetch-chunk-count))
                 (kokoro-reader-prefetch-macos-texts texts))))
            ((or 'kokoro 'irodori)
             (when (fboundp 'kokoro-reader-prefetch-kokoro-texts)
               (let ((kokoro-reader-kokoro-prefetch-count
                      english-reading-mode-macos-prefetch-chunk-count))
                 (kokoro-reader-prefetch-kokoro-texts texts))))))))))

(defun english-reading-mode--monitor-macos-prefetch ()
  "Replenish future resident audio for the latest active speech context."
  (if (not (and english-reading-mode--continuous-state
                (english-reading-mode--continuous-live-p)))
      (progn
        (when (timerp english-reading-mode--macos-prefetch-monitor-timer)
          (cancel-timer english-reading-mode--macos-prefetch-monitor-timer))
        (setq english-reading-mode--macos-prefetch-monitor-timer nil))
    (when (and english-reading-mode--active-speech
               (english-reading-mode--continuous-context-owned-p
                english-reading-mode--active-speech))
      (english-reading-mode--prefetch-next-macos-sentence
       english-reading-mode--active-speech))))

(defun english-reading-mode--start-macos-prefetch-monitor ()
  "Start periodic replenishment for continuous resident speech audio."
  (when (timerp english-reading-mode--macos-prefetch-monitor-timer)
    (cancel-timer english-reading-mode--macos-prefetch-monitor-timer))
  (setq english-reading-mode--macos-prefetch-monitor-timer nil)
  (let ((speech-buffer
         (plist-get english-reading-mode--active-speech :buffer)))
    (when (and (buffer-live-p speech-buffer)
               (with-current-buffer speech-buffer
                 (memq kokoro-reader-backend '(macos kokoro irodori))))
      (setq english-reading-mode--macos-prefetch-monitor-timer
            (english-reading-mode--session-timer english-reading-mode-macos-prefetch-check-interval
                                                 english-reading-mode-macos-prefetch-check-interval
                                                 #'english-reading-mode--monitor-macos-prefetch)))))

(add-hook 'english-reading-mode-speech-start-hook
          #'english-reading-mode--prefetch-next-macos-sentence)

(provide 'english-reading-prefetch)
;;; english-reading-prefetch.el ends here
