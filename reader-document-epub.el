;;; reader-document-epub.el --- EPUB document operations -*- lexical-binding: t; -*-

(require 'reader-document-text)

(defun english-reading-mode--continuous-epub-next ()
  "Advance within an EPUB or across empty chapters, then speak once."
  ;; Completion may already have moved point to the chapter's end.  Asking
  ;; for a sentence there either signals or returns the previous sentence.
  (when (and (< (point) (point-max))
             (english-reading-mode--sentence-bounds-at-point))
    (english-reading-mode-next-sentence))
  (skip-chars-forward " \t\n\r　 ")
  ;; Failure to identify a sentence is not evidence that the chapter ended.
  ;; Only an exhausted buffer may advance the EPUB spine.
  (while (and (= (point) (point-max))
              (boundp 'nov-documents-index)
              (boundp 'nov-documents)
              (< nov-documents-index (1- (length nov-documents))))
    (let ((previous-index nov-documents-index))
      (nov-next-document)
      (unless (> nov-documents-index previous-index)
        (user-error "EPUB chapter did not advance")))
    (goto-char (point-min))
    (skip-chars-forward " \t\n\r　 "))
  (when (= (point) (point-max))
    (user-error "Reached the end of the document"))
  (unless (english-reading-mode--sentence-bounds-at-point)
    (user-error "Cannot identify EPUB speech at position %d" (point)))
  (english-reading-mode-speak-current-sentence))

(defun reader-document-epub--location (&optional window)
  "Capture EPUB spine position together with the rendered text cursor."
  (plist-put (reader-document-text--location window) :document
             (and (boundp 'nov-documents-index) nov-documents-index)))

(defun reader-document-epub--source (&optional _frame)
  "Return the EPUB source archive."
  (or (and (boundp 'nov-file-name) nov-file-name) buffer-file-name))
(defun reader-document-epub--restore (record window)
  "Restore EPUB RECORD in WINDOW."
  (let ((document (plist-get record :document))
        (position (plist-get record :point))
        (start (plist-get record :window-start)))
    (with-selected-window window
      (when (and (integerp document)
                 (boundp 'nov-documents)
                 (vectorp nov-documents)
                 (>= document 0)
                 (< document (length nov-documents))
                 (fboundp 'nov-goto-document))
        (nov-goto-document document))
      (when (integerp position)
        (goto-char (reader-document-text--clamp position))
        (set-window-point window (point)))
      (when (integerp start)
        (set-window-start window (reader-document-text--clamp start) t)))))

(defun reader-document-epub--bounds ()
  "Return EPUB sentence bounds, including Japanese dialogue at chapter edges."
  (save-excursion
    ;; Japanese dialogue also uses ideographic spaces between sentences.
    ;; At such a space thing-at-point may return the *previous* sentence.
    (skip-chars-forward " \t\n\r　 ")
    (when (< (point) (point-max))
      (let ((origin (point))
            (bounds (bounds-of-thing-at-point 'sentence)))
        (if (and bounds (> (cdr bounds) origin))
            bounds
          ;; For !? inside Japanese quotes, backward-sentence can stop
          ;; after point and thing-at-point returns nil. Read the rest
          ;; of this rendered line rather than lose the whole chapter.
          ;; Both playback and prefetch must use these same bounds.
          (let ((end (line-end-position)))
            (goto-char end)
            (skip-chars-backward " \t\r　 " origin)
            (when (< origin (point))
              (cons origin (point)))))))))

(reader-document-register
 'epub (lambda () (derived-mode-p 'nov-mode))
 '(:bounds reader-document-epub--bounds
           :continue english-reading-mode--continuous-epub-next
           :persistent-type (lambda () 'epub)
           :location reader-document-epub--location :restore reader-document-epub--restore
           :source reader-document-epub--source) 'text)


(provide 'reader-document-epub)
;;; reader-document-epub.el ends here
