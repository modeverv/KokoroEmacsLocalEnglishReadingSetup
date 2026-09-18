;;; english-reading-pdf.el --- Pdf for sentence reading -*- lexical-binding: t; -*-

(declare-function pdf-view-active-region-text "pdf-view")
(declare-function pdf-view-active-region-p "pdf-view")
(declare-function english-reading-mode-speak-current-sentence "english-reading-mode")
(require 'english-reading-state)
(require 'reader-document-text)
(require 'english-reading-pdf-view)
(require 'kokoro-reader)

(defvar pdf-view-active-region)

(defvar my/read-http-auto-language)
(defvar my/read-speech-language-override nil)

(defun english-reading-mode--pdf-buffer-p (&optional buffer)
  "Return non-nil when BUFFER is a DocView or PDF Tools PDF buffer."
  (with-current-buffer (or buffer (current-buffer))
    (and (memq major-mode '(doc-view-mode pdf-view-mode))
         buffer-file-name
         (string-equal (downcase (or (file-name-extension buffer-file-name) ""))
                       "pdf"))))

(defun english-reading-mode--pdf-page-ranges ()
  "Return page ranges for the current extracted PDF text buffer."
  (let ((start (point-min))
        ranges)
    (save-excursion
      (goto-char (point-min))
      (while (search-forward "\f" nil t)
        (push (cons start (1- (point))) ranges)
        (setq start (point)))
      (when (or (< start (point-max)) (null ranges))
        (push (cons start (point-max)) ranges)))
    (vconcat (nreverse ranges))))

(defun english-reading-mode--pdf-cleanup ()
  "Kill the extracted text buffer owned by the current PDF buffer."
  (when (buffer-live-p english-reading-mode--pdf-text-buffer)
    (kill-buffer english-reading-mode--pdf-text-buffer))
  (setq english-reading-mode--pdf-text-buffer nil
        english-reading-mode--pdf-page-ranges nil
        english-reading-mode--pdf-page nil
        english-reading-mode--pdf-text-point nil
        english-reading-mode--pdf-bbox-cache nil
        english-reading-mode--pdf-image-data-cache nil))

(defun english-reading-mode--normalize-pdf-japanese-spacing ()
  "Join Japanese glyphs separated only by PDF layout whitespace.

Some PDFs position every Japanese glyph independently, causing `pdftotext' to
emit one glyph per line.  Leaving those separators in place makes a speech
engine pronounce isolated character names instead of Japanese words.  Page
breaks are deliberately excluded so page ranges remain intact."
  (let ((regexp
         "\\([ぁ-んァ-ヶ一-龠々〆ヵヶ]\\)[ \t\n\r]+\\([ぁ-んァ-ヶ一-龠々〆ヵヶ]\\)"))
    (goto-char (point-min))
    (while (re-search-forward regexp nil t)
      (replace-match "\\1\\2" nil nil)
      ;; Revisit the second glyph so a chain such as `基  礎  理' is joined.
      (goto-char (max (point-min) (1- (point)))))))

(defun english-reading-mode--pdf-extract-text ()
  "Extract the current PDF's text layer and return its helper buffer."
  (unless (english-reading-mode--pdf-buffer-p)
    (user-error "The current buffer is not a DocView PDF"))
  (unless (executable-find english-reading-mode-pdftotext-program)
    (user-error "%s is required for PDF reading"
                english-reading-mode-pdftotext-program))
  (let* ((pdf-buffer (current-buffer))
         (pdf-file buffer-file-name)
         (helper (generate-new-buffer
                  (format " *English PDF text: %s*" (buffer-name)))))
    (condition-case err
        (with-current-buffer helper
          (let ((status
                 (call-process english-reading-mode-pdftotext-program
                               nil helper nil
                               "-enc" "UTF-8" pdf-file "-")))
            (unless (and (integerp status) (zerop status))
              (error "pdftotext exited with status %s" status)))
          (goto-char (point-min))
          (while (search-forward "\r" nil t)
            (replace-match "" t t))
          (english-reading-mode--normalize-pdf-japanese-spacing)
          (goto-char (point-min))
          (unless (re-search-forward "[[:alpha:]]" nil t)
            (user-error
             "This PDF has no readable text layer; scanned PDFs need OCR"))
          (setq-local sentence-end-double-space nil)
          ;; Kokoro's advice builds speech contexts only while this flag is
          ;; non-nil.  The helper is never displayed, but it is the true text
          ;; source behind the visible PDF window.
          (setq-local english-reading-mode t)
          (setq-local my/read-http-auto-language t)
          (setq-local my/read-speech-language-override
                      (buffer-local-value 'my/read-speech-language-override pdf-buffer))
          (run-hooks 'english-reading-mode-pdf-text-buffer-hook)
          (setq-local buffer-read-only t))
      (error
       (kill-buffer helper)
       (signal (car err) (cdr err))))
    (with-current-buffer pdf-buffer
      (setq english-reading-mode--pdf-text-buffer helper
            english-reading-mode--pdf-page-ranges
            (with-current-buffer helper
              (english-reading-mode--pdf-page-ranges))
            english-reading-mode--pdf-bbox-cache
            (make-hash-table :test #'eql)
            english-reading-mode--pdf-image-data-cache
            (make-hash-table :test #'equal))
      (add-hook 'kill-buffer-hook #'english-reading-mode--pdf-cleanup nil t))
    helper))

(defun english-reading-mode--pdf-current-page ()
  "Return the current one-based page number from the active PDF viewer."
  (max 1
       (cond
        ((and (eq major-mode 'pdf-view-mode)
              (fboundp 'pdf-view-current-page))
         (pdf-view-current-page))
        ((fboundp 'doc-view-current-page) (doc-view-current-page))
        (t 1))))

(defun english-reading-mode--pdf-page-count ()
  "Return the number of extracted pages for the current PDF."
  (length english-reading-mode--pdf-page-ranges))

(defun english-reading-mode--pdf-page-range (page)
  "Return the extracted text range for one-based PAGE."
  (and (<= 1 page)
       (<= page (english-reading-mode--pdf-page-count))
       (aref english-reading-mode--pdf-page-ranges (1- page))))

(defun english-reading-mode--pdf-page-start (page)
  "Return the first non-whitespace position on extracted PAGE."
  (pcase-let ((`(,beg . ,end)
               (or (english-reading-mode--pdf-page-range page)
                   (user-error "PDF page %s has no extracted text" page))))
    (with-current-buffer english-reading-mode--pdf-text-buffer
      (save-restriction
        (widen)
        (narrow-to-region beg end)
        (goto-char (point-min))
        (skip-chars-forward " \t\n\r")
        (point)))))

(defun english-reading-mode--pdf-continuous-source-p ()
  "Return non-nil when continuous narration owns the current PDF buffer."
  (and (bound-and-true-p english-reading-mode--continuous-state)
       (eq (plist-get english-reading-mode--continuous-state :buffer)
           (current-buffer))))

(defun english-reading-mode--pdf-sync ()
  "Ensure PDF text exists and synchronize it with the displayed page."
  (unless (buffer-live-p english-reading-mode--pdf-text-buffer)
    (english-reading-mode--pdf-extract-text))
  (let* ((count (english-reading-mode--pdf-page-count))
         (page (min (english-reading-mode--pdf-current-page) count)))
    (when (zerop count)
      (user-error "This PDF has no extractable text"))
    ;; In PDF roll mode the topmost visible page can remain N while speech has
    ;; already advanced into page N+1.  Treating that visual page as the text
    ;; cursor would reset the virtual position and repeat the boundary chunk.
    ;; Manual PDF movement clears continuous state in `pre-command-hook', so
    ;; the displayed page remains authoritative outside continuous narration.
    (unless (or (and (english-reading-mode--pdf-continuous-source-p)
                     english-reading-mode--pdf-page
                     english-reading-mode--pdf-text-point)
                (and english-reading-mode--pdf-page
                     (= page english-reading-mode--pdf-page)))
      (setq english-reading-mode--pdf-page page
            english-reading-mode--pdf-text-point
            (english-reading-mode--pdf-page-start page)))
    english-reading-mode--pdf-text-buffer))

(defun english-reading-mode--pdf-compact-text-index (beg end)
  "Return compact text and source positions for extracted text BEG to END.

Whitespace is removed so PDF Tools selections can be matched against
`pdftotext' output even when the two backends place line breaks differently."
  (let (characters positions)
    (save-excursion
      (goto-char beg)
      (while (< (point) end)
        (let ((position (point))
              (character (char-after)))
          (unless (string-match-p
                   "\\`[[:space:]\u00a0]\\'"
                   (char-to-string character))
            (push (downcase character) characters)
            (push position positions)))
        (forward-char 1)))
    (list (apply #'string (nreverse characters))
          (vconcat (nreverse positions)))))

(defun english-reading-mode--pdf-selection-ratio (edges)
  "Return the approximate vertical page ratio of PDF selection EDGES."
  (if edges
      (max 0.0
           (min 1.0
                (apply #'min
                       (mapcar (lambda (edge)
                                 (min (float (nth 1 edge))
                                      (float (nth 3 edge))))
                               edges))))
    0.0))

(defun english-reading-mode--pdf-string-match-starts (needle haystack)
  "Return every literal match start of NEEDLE in HAYSTACK."
  (let ((start 0)
        matches)
    (while (and (< start (length haystack))
                (string-match (regexp-quote needle) haystack start))
      (push (match-beginning 0) matches)
      (setq start (1+ (match-beginning 0))))
    (nreverse matches)))

(defun english-reading-mode-use-pdf-selection ()
  "Move the PDF reading cursor to the sentence selected in PDF Tools.

The active PDF selection remains intact so Org-noter can subsequently use it
for selected-text notes and persistent highlights."
  (interactive)
  (unless (and (eq major-mode 'pdf-view-mode)
               (fboundp 'pdf-view-active-region-p)
               (pdf-view-active-region-p))
    (user-error "Select text in a PDF Tools buffer first"))
  (english-reading-mode--pdf-sync)
  (let* ((region pdf-view-active-region)
         (page (car region))
         (edges (cdr region))
         (selected
          (replace-regexp-in-string
           "[[:space:]\u00a0]+" ""
           (downcase
            (string-join (pdf-view-active-region-text) " "))))
         (page-range (english-reading-mode--pdf-page-range page)))
    (unless (and page-range (not (string-empty-p selected)))
      (user-error "The PDF selection has no extractable text"))
    (pcase-let* ((`(,page-text ,positions)
                  (with-current-buffer english-reading-mode--pdf-text-buffer
                    (english-reading-mode--pdf-compact-text-index
                     (car page-range) (cdr page-range))))
                 (matches
                  (english-reading-mode--pdf-string-match-starts
                   selected page-text))
                 (ratio (english-reading-mode--pdf-selection-ratio edges))
                 (span (max 1 (1- (length positions))))
                 (index
                  (if matches
                      (car
                       (sort (copy-sequence matches)
                             (lambda (a b)
                               (< (abs (- (/ (float a) span) ratio))
                                  (abs (- (/ (float b) span) ratio))))))
                    ;; Text extraction can differ around ligatures or unusual
                    ;; punctuation.  Vertical position remains a useful and
                    ;; deterministic fallback in that case.
                    (round (* ratio span)))))
      (unless (> (length positions) 0)
        (user-error "PDF page %s has no readable text" page))
      (setq english-reading-mode--pdf-page page
            english-reading-mode--pdf-text-point
            (aref positions (min index (1- (length positions)))))
      (or (english-reading-mode--pdf-location)
          (user-error "No readable sentence was found at the selection")))))

(defun english-reading-mode--pdf-selection-finished (&rest _)
  "Synchronize the reading cursor after PDF Tools finishes a selection."
  (when (and english-reading-mode
             (english-reading-mode--pdf-buffer-p)
             (pdf-view-active-region-p))
    (english-reading-mode--cancel-continuous-for-pdf-interaction)
    (condition-case error-data
        (let ((location (english-reading-mode-use-pdf-selection)))
          (message "Reading position: %s"
                   (truncate-string-to-width (car location) 60 nil nil "…")))
      (error
       (message "Could not use PDF selection: %s"
                (error-message-string error-data))))))

(defun english-reading-mode--pdf-location ()
  "Return (TEXT BUFFER BEG END) at the PDF text cursor, or nil."
  (english-reading-mode--pdf-sync)
  (let ((text-point english-reading-mode--pdf-text-point)
        location)
    (pcase-let ((`(,page-beg . ,page-end)
                 (english-reading-mode--pdf-page-range
                  english-reading-mode--pdf-page)))
      (with-current-buffer english-reading-mode--pdf-text-buffer
        (save-restriction
          (widen)
          (narrow-to-region page-beg page-end)
          (goto-char (min (max text-point (point-min))
                          (point-max)))
          (skip-chars-forward " \t\n\r")
          (while (and (not location) (< (point) (point-max)))
            (if-let* ((bounds (english-reading-mode--sentence-bounds-at-point)))
                (progn
                  (goto-char (car bounds))
                  (skip-chars-forward " \t\n\r" (cdr bounds))
                  (let ((beg (point)))
                    (goto-char (cdr bounds))
                    (skip-chars-backward " \t\n\r" beg)
                    (let* ((end (point))
                           (text (buffer-substring-no-properties beg end)))
                      ;; Page numbers and isolated mathematical labels are not
                      ;; useful Kokoro utterances.  Require at least two letters
                      ;; in a candidate extracted from a PDF text layer.
                      (if (and (< beg end)
                               (string-match-p
                                "[[:alpha:]].*[[:alpha:]]" text))
                          (setq location
                                (list text (current-buffer) beg end))
                        (goto-char (min (1+ end) (point-max)))
                        (skip-chars-forward " \t\n\r")))))
              (goto-char (point-max))))))
      (when location
        (setq english-reading-mode--pdf-text-point (nth 2 location)))
      location)))

(defun english-reading-mode-current-text-location (&optional buffer)
  "Return (TEXT SOURCE-BUFFER BEG END) for BUFFER's virtual text cursor.

This currently exposes the text layer used behind a DocView PDF."
  (with-current-buffer (or buffer (current-buffer))
    (when (and english-reading-mode
               (english-reading-mode--pdf-buffer-p))
      (english-reading-mode--pdf-location))))

(defun english-reading-mode--pdf-goto-page (page)
  "Display PAGE and reset the extracted PDF text cursor to that page."
  (let ((count (english-reading-mode--pdf-page-count)))
    (unless (<= 1 page count)
      (user-error "No more PDF pages"))
    ;; In a PDF roll, continuous narration advances the visible document by a
    ;; relative pixel distance in the centering step.  An absolute goto here
    ;; would snap back to a page boundary before every cross-page utterance.
    (unless (and (english-reading-mode--pdf-continuous-source-p)
                 (bound-and-true-p pdf-view-roll-minor-mode))
      (cond
       ((and (eq major-mode 'pdf-view-mode)
             (fboundp 'pdf-view-goto-page))
        (pdf-view-goto-page page))
       ((fboundp 'doc-view-goto-page)
        (doc-view-goto-page page))))
    (setq english-reading-mode--pdf-page page
          english-reading-mode--pdf-text-point
          (english-reading-mode--pdf-page-start page))))

(defun english-reading-mode--pdf-next-location ()
  "Return the current PDF location, advancing pages when necessary."
  (english-reading-mode--pdf-sync)
  (or (english-reading-mode--pdf-location)
      (let ((next (1+ english-reading-mode--pdf-page)))
        (english-reading-mode--pdf-goto-page next)
        (or (english-reading-mode--pdf-location)
            (user-error "PDF page %s has no readable text" next)))))

(defun english-reading-mode--pdf-speak-current-sentence ()
  "Read the PDF sentence at the virtual cursor without advancing it."
  (let* ((location (english-reading-mode--pdf-next-location))
         (text-buffer (nth 1 location))
         (beg (nth 2 location))
         (end (nth 3 location))
         (page-end (cdr (english-reading-mode--pdf-page-range
                         english-reading-mode--pdf-page))))
    (with-current-buffer text-buffer
      (pcase-let ((`(,chunk-beg . ,chunk-end)
                   (english-reading-mode--macos-continuous-bounds
                    beg end page-end)))
        (kokoro-reader--speak-bounds chunk-beg chunk-end)))))

(defun english-reading-mode--pdf-next-sentence ()
  "Move the PDF virtual cursor to the next sentence without reading it."
  (let* ((location (english-reading-mode--pdf-next-location))
         (end (nth 3 location)))
    (setq english-reading-mode--pdf-text-point end)
    ;; Resolve the next location now so crossing a page boundary updates the
    ;; displayed page as part of this movement command.
    (english-reading-mode--pdf-next-location)))

(defun english-reading-mode--pdf-previous-location ()
  "Move backward and return the preceding PDF text location."
  (english-reading-mode--pdf-sync)
  (let ((pdf-buffer (current-buffer))
        location)
    (while (not location)
      (let ((text-point english-reading-mode--pdf-text-point))
        (pcase-let ((`(,page-beg . ,page-end)
                     (english-reading-mode--pdf-page-range
                      english-reading-mode--pdf-page)))
          (with-current-buffer english-reading-mode--pdf-text-buffer
            (save-restriction
              (widen)
              (narrow-to-region page-beg page-end)
              (goto-char (min (max text-point (point-min))
                              (point-max)))
              (skip-chars-backward " \t\n\r")
              (let ((origin (point)))
                (condition-case nil
                    (progn
                      (backward-sentence)
                      (skip-chars-forward " \t\n\r")
                      (when (< (point) origin)
                        (let ((text-point (point)))
                          (with-current-buffer pdf-buffer
                            (setq english-reading-mode--pdf-text-point
                                  text-point)))
                        (setq location
                              (with-current-buffer pdf-buffer
                                (english-reading-mode--pdf-location)))))
                  (beginning-of-buffer nil)))))
          (unless location
            (if (> english-reading-mode--pdf-page 1)
                (let ((previous (1- english-reading-mode--pdf-page)))
                  (english-reading-mode--pdf-goto-page previous)
                  (setq english-reading-mode--pdf-text-point
                        (cdr (english-reading-mode--pdf-page-range previous))))
              (user-error "Already at the first PDF sentence"))))))
    location))

(defun english-reading-mode--pdf-previous-sentence ()
  "Move to the preceding PDF sentence without reading it."
  (english-reading-mode--pdf-sync)
  (let* ((origin-page english-reading-mode--pdf-page)
         (origin-point english-reading-mode--pdf-text-point)
         (location (english-reading-mode--pdf-previous-location)))
    ;; A page number before the first real sentence can make the generic
    ;; previous-location scan resolve back to the original sentence.  In that
    ;; case, continue explicitly from the end of the preceding page.
    (when (and (= english-reading-mode--pdf-page origin-page)
               (>= (nth 2 location) origin-point)
               (> origin-page 1))
      (english-reading-mode--pdf-goto-page (1- origin-page))
      (setq english-reading-mode--pdf-text-point
            (cdr (english-reading-mode--pdf-page-range (1- origin-page))))
      (setq location (english-reading-mode--pdf-previous-location)))
    location))

(defun english-reading-mode--pdf-post-command ()
  "Refresh and recenter active PDF speech after an interactive zoom change."
  (when (and (memq this-command english-reading-mode--pdf-zoom-commands)
             english-reading-mode--continuous-state
             english-reading-mode--active-speech)
    ;; pdf-tools has just rendered the page at the new zoom.  Recenter first,
    ;; then rebuild the foreground highlight after redisplay settles.
    (setq english-reading-mode--continuous-state
          (plist-put
           (plist-put english-reading-mode--continuous-state
                      :pdf-roll-page nil)
           :pdf-roll-pixel nil))
    (setq english-reading-mode--continuous-state
          (plist-put english-reading-mode--continuous-state
                     :pdf-roll-source-beg nil))
    (english-reading-mode--pdf-center-continuous-speech
     english-reading-mode--active-speech)
    (english-reading-mode--schedule-pdf-highlight
     english-reading-mode--active-speech)))

(defun english-reading-mode--cancel-continuous-for-pdf-interaction ()
  "Cancel stale continuation when the current PDF is manipulated manually.

The sentence already playing is allowed to finish.  Clearing the continuous
state and timer prevents its completion hook from moving the PDF again."
  (when (and english-reading-mode--continuous-state
             (english-reading-mode--pdf-buffer-p)
             (eq (plist-get english-reading-mode--continuous-state :buffer)
                 (current-buffer)))
    (english-reading-mode-stop-continuous t)
    t))

(defun english-reading-mode--pdf-pre-command ()
  "Cancel continuous reading before a manual PDF navigation command."
  (when (memq this-command
              english-reading-mode--pdf-manual-interaction-commands)
    (english-reading-mode--cancel-continuous-for-pdf-interaction)))

(defun reader-document-pdf--owns-speech-p (buffer)
  "Return non-nil for this PDF or its extracted text BUFFER."
  (or (eq buffer (current-buffer))
      (and (buffer-live-p english-reading-mode--pdf-text-buffer)
           (eq buffer english-reading-mode--pdf-text-buffer))))

(defun reader-document-pdf--continue ()
  "Advance the virtual PDF cursor and speak once."
  (english-reading-mode--pdf-next-sentence)
  (english-reading-mode-speak-current-sentence))

(reader-document-register
 'pdf #'english-reading-mode--pdf-buffer-p
 '(:speech-range reader-document-pdf--speech-range
                 :resume reader-document-pdf--resume :speech-spec reader-document-pdf--speech-spec
                 :prepare english-reading-mode--pdf-sync
                 :sentence english-reading-mode--pdf-location
                 :next english-reading-mode--pdf-next-sentence
                 :previous english-reading-mode--pdf-previous-sentence
                 :speak english-reading-mode--pdf-speak-current-sentence
                 :continue reader-document-pdf--continue
                 :owns-speech reader-document-pdf--owns-speech-p
                 :persistent-type (lambda () (when (derived-mode-p 'pdf-view-mode) 'pdf))
                 :location reader-document-pdf--location
                 :restore reader-document-pdf--restore) 'text)

(defun reader-document-pdf--restore (record window)
  "Restore PDF RECORD in WINDOW."
  (let ((page (plist-get record :page))
        (zoom (plist-get record :zoom))
        (vscroll (plist-get record :vscroll)))
    (with-selected-window window
      (when (and zoom (boundp 'pdf-view-display-size))
        (setq pdf-view-display-size zoom))
      (when (and (integerp page) (> page 0)
                 (fboundp 'pdf-view-goto-page))
        (pdf-view-goto-page page))
      (when (fboundp 'pdf-view-redisplay)
        (pdf-view-redisplay t))
      (when (and (numberp vscroll) (>= vscroll 0))
        (if (fboundp 'image-set-window-vscroll)
            (image-set-window-vscroll vscroll)
          (set-window-vscroll window vscroll t))))))

(defun reader-document-pdf--location (&optional window)
  "Capture PDF page, zoom and pixel scroll in WINDOW."
  (let ((record (list :type 'pdf
                      :page (and (fboundp 'pdf-view-current-page)
                                 (ignore-errors (pdf-view-current-page)))
                      :zoom (and (boundp 'pdf-view-display-size) pdf-view-display-size))))
    (when (and (window-live-p window)
               (eq (window-buffer window) (current-buffer)))
      (setq record (plist-put record :vscroll (window-vscroll window t))))
    record))


(defun reader-document-pdf--speech-range (buffer position)
  "Return the page boundary around POSITION in extracted BUFFER."
  (when (eq buffer english-reading-mode--pdf-text-buffer)
    (cl-loop for range across english-reading-mode--pdf-page-ranges
             when (and (<= (car range) position) (<= position (cdr range)))
             return range)))

(defun reader-document-pdf--resume (buffer position)
  "Resume this PDF from POSITION in extracted speech BUFFER."
  (when (eq buffer english-reading-mode--pdf-text-buffer)
    (setq english-reading-mode--pdf-text-point position)
    (english-reading-mode-speak-current-sentence)
    t))

(defun reader-document-pdf--speech-spec ()
  "Return the page-limited speech chunk at the virtual PDF cursor."
  (let* ((location (english-reading-mode--pdf-next-location))
         (buffer (nth 1 location))
         (beg (nth 2 location)) (end (nth 3 location))
         (limit (cdr (english-reading-mode--pdf-page-range english-reading-mode--pdf-page))))
    (with-current-buffer buffer
      (pcase-let ((`(,start . ,finish)
                   (english-reading-mode--macos-continuous-bounds beg end limit)))
        (list :buffer buffer :beg start :end finish
              :text (kokoro-reader--text start finish))))))

(add-hook 'english-reading-mode-speech-prepare-hook
          #'english-reading-mode--pdf-center-continuous-speech)
(add-hook 'english-reading-mode-speech-highlight-hook
          #'english-reading-mode--schedule-pdf-highlight)

(provide 'english-reading-pdf)
;;; english-reading-pdf.el ends here
