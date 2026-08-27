;;; english-reading-mode.el --- Sentence-by-sentence English reading -*- lexical-binding: t; -*-

;; Reader navigation and speech lifecycle belong here.  Consumers such as my-read.el can
;; observe speech without reimplementing cursor movement or advising Kokoro.

(require 'cl-lib)
(require 'dom)
(require 'kokoro-reader)
(require 'seq)
(require 'thingatpt)
(require 'subr-x)

(defgroup english-reading-mode nil
  "Sentence-by-sentence English reading with Kokoro."
  :group 'multimedia)

(defcustom english-reading-mode-pdftotext-program "pdftotext"
  "Program used to extract a text layer from PDF documents."
  :type 'string
  :group 'english-reading-mode)

(defcustom english-reading-mode-pdf-highlight-color "#FFD54F"
  "Fill color used to highlight the spoken sentence on a PDF page."
  :type 'color
  :group 'english-reading-mode)

(defcustom english-reading-mode-pdf-highlight-opacity 0.35
  "Opacity of the spoken-sentence highlight on a PDF page."
  :type 'number
  :group 'english-reading-mode)

(defcustom english-reading-mode-pdf-highlight-delay 0.5
  "Seconds to wait after PDF scrolling before drawing the speech highlight.

The short delay lets PDF Tools or DocView finish redisplaying the new scroll
position.  Speech playback is started independently and is never made to wait
for the PDF image and SVG highlight rendering path."
  :type 'number
  :group 'english-reading-mode)

(defcustom english-reading-mode-pdf-speech-screen-position 0.25
  "Vertical screen position used for continuous PDF speech.

The value is a ratio of the PDF viewport height: 0.0 is the top edge, 0.5 is
the center, and 1.0 is the bottom edge.  The default keeps the beginning of the
spoken text about one quarter of the way down from the top."
  :type 'number
  :group 'english-reading-mode)

(defcustom english-reading-mode-macos-continuous-sentence-count 6
  "Maximum number of sentences in one continuous macOS speech utterance.

Larger chunks make `/usr/bin/say' take longer before the first playback, but
avoid a synthesis/player handoff between every sentence.  One-shot commands
such as `english-reading-mode-speak-current-sentence' still speak one sentence."
  :type '(integer :tag "Sentences" 1)
  :group 'english-reading-mode)

(defcustom english-reading-mode-macos-prefetch-chunk-count 2
  "Number of future macOS speech chunks prepared during continuous reading."
  :type '(integer :tag "Chunks" 1)
  :group 'english-reading-mode)

(defvar english-reading-mode-pdf-text-buffer-hook nil
  "Hook run in a PDF's extracted text buffer after text normalization.

Clients can use this to detect the document language and select a matching
speech backend.  The extracted buffer, rather than the DocView image buffer,
is where PDF speech is actually synthesized.")

(defvar english-reading-mode-speech-start-hook nil
  "Hook run when an English-reading Kokoro utterance starts.

Each function receives one CONTEXT plist with keys :id, :buffer, :frame,
:window, :beg, :end and :text.  :text is the normalized text handed to Kokoro.")

(defvar english-reading-mode-speech-finish-hook nil
  "Hook run when the current English-reading Kokoro utterance finishes.

Each function receives the same CONTEXT object as the matching start hook.
This also runs on synthesis failure or explicit stop.")

(defvar english-reading-mode--speech-sequence 0)
(defvar english-reading-mode--active-speech nil)
(defvar english-reading-mode--pdf-highlight-timer nil)
(defvar english-reading-mode--pdf-highlight-pending-context nil)
(defvar english-reading-mode--pdf-highlight-pending-scroll-state nil)
(defvar english-reading-mode nil)

(defvar-local english-reading-mode--saved-sentence-end-double-space nil)
(defvar-local english-reading-mode--sentence-setting-saved-p nil)
(defvar-local english-reading-mode--sentence-setting-was-local-p nil)
(defvar-local english-reading-mode--saved-buffer-read-only nil)
(defvar-local english-reading-mode--read-only-setting-saved-p nil)
(defvar-local english-reading-mode--pdf-text-buffer nil)
(defvar-local english-reading-mode--pdf-page-ranges nil)
(defvar-local english-reading-mode--pdf-page nil)
(defvar-local english-reading-mode--pdf-text-point nil)
(defvar-local english-reading-mode--pdf-bbox-cache nil)
(defvar-local english-reading-mode--pdf-image-data-cache nil)
(defvar-local english-reading-mode--pdf-highlight-page nil)
(defvar-local english-reading-mode--pdf-highlight-state nil)

(defvar-local english-reading-mode-key-active-predicate nil
  "Optional function deciding whether this mode's keys are active.

When nil, `english-reading-mode' behaves as a normal buffer-local minor mode.
Consumers such as my-read can set this to a window-aware predicate so a
shared reading buffer does not keep its keys in unrelated windows.")

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

(with-eval-after-load 'pdf-view
  (advice-remove 'pdf-view-mouse-set-region
                 #'english-reading-mode--pdf-selection-finished)
  (advice-add 'pdf-view-mouse-set-region :after
              #'english-reading-mode--pdf-selection-finished))

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
            (if-let ((bounds (bounds-of-thing-at-point 'sentence)))
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

(defun english-reading-mode--pdf-bbox-page (page)
  "Return PAGE geometry and positioned words from `pdftotext -bbox-layout'."
  (or (and (hash-table-p english-reading-mode--pdf-bbox-cache)
           (gethash page english-reading-mode--pdf-bbox-cache))
      (let ((pdf-file buffer-file-name)
            parsed)
        (with-temp-buffer
          (let ((status
                 (call-process english-reading-mode-pdftotext-program
                               nil t nil
                               "-f" (number-to-string page)
                               "-l" (number-to-string page)
                               "-bbox-layout" pdf-file "-")))
            (unless (and (integerp status) (zerop status))
              (error "pdftotext bbox extraction failed with status %s"
                     status)))
          (goto-char (point-min))
          (let* ((dom (libxml-parse-html-region (point-min) (point-max)))
                 (page-node (car (dom-by-tag dom 'page))))
            (unless page-node
              (error "pdftotext returned no geometry for PDF page %s" page))
            (setq parsed
                  (list
                   :width (string-to-number (dom-attr page-node 'width))
                   :height (string-to-number (dom-attr page-node 'height))
                   :words
                   (vconcat
                    (mapcar
                     (lambda (word)
                       (list :text (string-trim (dom-text word))
                             :xmin (string-to-number (dom-attr word 'xmin))
                             :ymin (string-to-number (dom-attr word 'ymin))
                             :xmax (string-to-number (dom-attr word 'xmax))
                             :ymax (string-to-number (dom-attr word 'ymax))))
                     (dom-by-tag page-node 'word)))))))
        (unless (hash-table-p english-reading-mode--pdf-bbox-cache)
          (setq english-reading-mode--pdf-bbox-cache
                (make-hash-table :test #'eql)))
        (puthash page parsed english-reading-mode--pdf-bbox-cache)
        parsed)))

(defun english-reading-mode--pdf-normalized-tokens (text)
  "Return normalized whitespace-delimited tokens from TEXT."
  (mapcar #'downcase (split-string text "[[:space:]\u00a0]+" t)))

(defun english-reading-mode--pdf-token-match-starts (needle words)
  "Return all start indices where NEEDLE tokens occur in positioned WORDS."
  (let* ((needle (vconcat needle))
         (needle-count (length needle))
         (word-count (length words))
         starts)
    (when (and (> needle-count 0) (<= needle-count word-count))
      (dotimes (start (1+ (- word-count needle-count)))
        (when (cl-loop for offset below needle-count
                       always
                       (string-equal
                        (aref needle offset)
                        (downcase (plist-get (aref words (+ start offset))
                                             :text))))
          (push start starts))))
    (nreverse starts)))

(defun english-reading-mode--pdf-compact-text (text)
  "Normalize TEXT for matching scripts that do not separate words by spaces."
  (downcase (replace-regexp-in-string "[[:space:]\u00a0]+" "" text)))

(defun english-reading-mode--pdf-compact-match-ranges (text words)
  "Return positioned-word ranges matching compact TEXT in WORDS.

Each result is (START . COUNT).  The match may begin or end inside a bbox word,
which is common when Japanese PDF extraction groups a whole visual line into
one positioned word."
  (let ((needle (english-reading-mode--pdf-compact-text text))
        (page-text "")
        (offsets (make-vector (length words) nil))
        ranges)
    (dotimes (index (length words))
      (let* ((start (length page-text))
             (word
              (english-reading-mode--pdf-compact-text
               (plist-get (aref words index) :text))))
        (setq page-text (concat page-text word))
        (aset offsets index (cons start (length page-text)))))
    (unless (string-empty-p needle)
      (let ((search-start 0))
        (while (string-match (regexp-quote needle) page-text search-start)
          (let* ((match-beg (match-beginning 0))
                 (match-end (match-end 0))
                 (first
                  (cl-position-if
                   (lambda (range)
                     (and (< (car range) match-end)
                          (> (cdr range) match-beg)))
                   offsets))
                 (last
                  (cl-position-if
                   (lambda (range)
                     (and (< (car range) match-end)
                          (> (cdr range) match-beg)))
                   offsets :from-end t)))
            (when (and first last)
              (push (cons first (1+ (- last first))) ranges))
            (setq search-start (max (1+ match-beg) match-end))))))
    (nreverse ranges)))

(defun english-reading-mode--pdf-nearest-match
    (starts word-count source-beg page-range)
  "Choose from STARTS using SOURCE-BEG's relative position in PAGE-RANGE."
  (let* ((text-span (max 1 (- (cdr page-range) (car page-range))))
         (source-ratio (/ (float (- source-beg (car page-range))) text-span))
         (word-span (max 1 (1- word-count))))
    (car
     (sort (copy-sequence starts)
           (lambda (a b)
             (< (abs (- (/ (float a) word-span) source-ratio))
                (abs (- (/ (float b) word-span) source-ratio))))))))

(defun english-reading-mode--pdf-word-rectangles (words start count)
  "Merge COUNT positioned WORDS from START into line rectangles."
  (let (rectangles current)
    (dotimes (offset count)
      (let* ((word (aref words (+ start offset)))
             (xmin (plist-get word :xmin))
             (ymin (plist-get word :ymin))
             (xmax (plist-get word :xmax))
             (ymax (plist-get word :ymax)))
        (if (and current (< (abs (- ymin (nth 1 current))) 2.0))
            (setq current
                  (list (min xmin (nth 0 current))
                        (min ymin (nth 1 current))
                        (max xmax (nth 2 current))
                        (max ymax (nth 3 current))))
          (when current
            (push current rectangles))
          (setq current (list xmin ymin xmax ymax)))))
    (when current
      (push current rectangles))
    (nreverse rectangles)))

(defun english-reading-mode--pdf-compact-anchor-ranges
    (text words &optional from-end)
  "Return bbox ranges matching a compact boundary anchor from TEXT.

Use the beginning of TEXT unless FROM-END is non-nil.  The anchor shrinks when
PDF flow ordering inserts a heading or sidebar next to the boundary; this is
more tolerant than requiring a whole multi-sentence speech chunk to occur as
one contiguous bbox string."
  (let* ((compact (english-reading-mode--pdf-compact-text text))
         (maximum (min 24 (length compact)))
         (minimum (min 6 maximum))
         ranges)
    (cl-loop for length downfrom maximum to minimum
             until ranges
             do (setq ranges
                      (english-reading-mode--pdf-compact-match-ranges
                       (if from-end
                           (substring compact (- length))
                         (substring compact 0 length))
                       words)))
    ranges))

(defun english-reading-mode--pdf-anchored-match-range
    (context words page-range)
  "Return a bbox range spanning speech CONTEXT's boundary anchors.

This is a fallback for PDFs whose plain-text and bbox extractors put an
intermediate heading or sidebar in a different order."
  (let* ((text (plist-get context :text))
         (start-ranges
          (english-reading-mode--pdf-compact-anchor-ranges text words))
         (end-ranges
          (english-reading-mode--pdf-compact-anchor-ranges text words t))
         (start
          (and start-ranges
               (english-reading-mode--pdf-nearest-match
                (mapcar #'car start-ranges) (length words)
                (plist-get context :beg) page-range)))
         (end-start
          (and end-ranges
               (english-reading-mode--pdf-nearest-match
                (mapcar #'car end-ranges) (length words)
                (plist-get context :end) page-range)))
         (end-count (and end-start (cdr (assq end-start end-ranges))))
         (end (and end-start end-count (+ end-start end-count))))
    (when (and start end (> end start))
      (cons start (- end start)))))

(defun english-reading-mode--pdf-context-rectangles (context)
  "Return PDF-space highlight rectangles for speech CONTEXT."
  (let* ((page english-reading-mode--pdf-page)
         (geometry (english-reading-mode--pdf-bbox-page page))
         (words (plist-get geometry :words))
         (tokens (english-reading-mode--pdf-normalized-tokens
                  (plist-get context :text)))
         (starts (english-reading-mode--pdf-token-match-starts tokens words))
         (candidates
          (if starts
              (mapcar (lambda (start) (cons start (length tokens))) starts)
            (english-reading-mode--pdf-compact-match-ranges
             (plist-get context :text) words)))
         (page-range (english-reading-mode--pdf-page-range page))
         (start (and candidates
                     (english-reading-mode--pdf-nearest-match
                      (mapcar #'car candidates) (length words)
                      (plist-get context :beg) page-range)))
         (count (and start (cdr (assq start candidates))))
         (range (or (and start count (cons start count))
                    (english-reading-mode--pdf-anchored-match-range
                     context words page-range))))
    (when range
      (list geometry
            (english-reading-mode--pdf-word-rectangles
             words (car range) (cdr range))))))

(defun english-reading-mode--pdf-image-data-uri (image)
  "Return PDF page IMAGE as a cached data URI.

DocView images normally carry a :file property, while pdf-tools supplies the
rendered PNG directly in :data.  Supporting both keeps the SVG highlight on
the same image that is actually displayed."
  (unless (hash-table-p english-reading-mode--pdf-image-data-cache)
    (setq english-reading-mode--pdf-image-data-cache
          (make-hash-table :test #'equal)))
  (let* ((properties (cdr image))
         (type (or (plist-get properties :type) 'png))
         (image-file (plist-get properties :file))
         (image-data (plist-get properties :data))
         (cache-key
          (or image-file
              (and (stringp image-data)
                   (list type (secure-hash 'sha1 image-data))))))
    (unless cache-key
      (error "PDF page image has neither :file nor :data"))
    (or (gethash cache-key english-reading-mode--pdf-image-data-cache)
        (let* ((bytes
                (or image-data
                    (with-temp-buffer
                      (set-buffer-multibyte nil)
                      (insert-file-contents-literally image-file)
                      (buffer-string))))
               (uri
                (concat (format "data:image/%s;base64," type)
                        (base64-encode-string bytes t))))
          (puthash cache-key uri english-reading-mode--pdf-image-data-cache)
          uri))))

(defun english-reading-mode--pdf-svg-highlight (image geometry rectangles)
  "Return an SVG image spec containing IMAGE with highlighted RECTANGLES."
  (let* ((width (plist-get geometry :width))
         (height (plist-get geometry :height))
         (image-uri (english-reading-mode--pdf-image-data-uri image))
         (display-width (plist-get (cdr image) :width))
         (svg
          (concat
           (format
            (concat "<svg xmlns='http://www.w3.org/2000/svg' "
                    "xmlns:xlink='http://www.w3.org/1999/xlink' "
                    "width='%s' height='%s' viewBox='0 0 %s %s'>"
                    "<image x='0' y='0' width='%s' height='%s' "
                    "preserveAspectRatio='none' xlink:href='%s'/><g>")
            width height width height width height
            image-uri)
           (mapconcat
            (lambda (rect)
              (pcase-let ((`(,xmin ,ymin ,xmax ,ymax) rect))
                (format
                 (concat "<rect x='%.3f' y='%.3f' width='%.3f' height='%.3f' "
                         "rx='1.5' fill='%s' fill-opacity='%.3f'/>")
                 (- xmin 1.5) (- ymin 1.0)
                 (+ (- xmax xmin) 3.0) (+ (- ymax ymin) 2.0)
                 english-reading-mode-pdf-highlight-color
                 english-reading-mode-pdf-highlight-opacity)))
            rectangles "")
           "</g></svg>")))
    (apply #'create-image svg 'svg t
           (append (when display-width (list :width display-width))
                   (list :pointer 'arrow :transform-smoothing t)))))

(defun english-reading-mode--pdf-display-state (&optional window)
  "Return (OVERLAY IMAGE SLICE) for WINDOW's displayed PDF page."
  (when (fboundp 'image-mode-window-get)
    (list (image-mode-window-get 'overlay window)
          (image-mode-window-get 'image window)
          (image-mode-window-get 'slice window))))

(defun english-reading-mode--pdf-roll-page-overlay (page window)
  "Return PAGE's actual pdf-roll overlay for WINDOW.

`pdf-roll-page-overlay' selects the first overlay at the page position whose
`window' property matches.  A PDF selection or other window-local overlay can
span that same position and be returned instead, leaving the visible page
image unchanged.  Match pdf-roll's own category and exact page slot here."
  (when (and (fboundp 'pdf-roll-page-to-pos) (window-live-p window))
    (let ((position (pdf-roll-page-to-pos page)))
      (seq-find
       (lambda (overlay)
         (and (eq (overlay-get overlay 'window) window)
              (eq (overlay-get overlay 'category) 'pdf-roll)
              (= (overlay-start overlay) position)
              (= (overlay-end overlay) (1+ position))))
       (overlays-at position)))))

(defun english-reading-mode--pdf-view-display-image (image page window)
  "Display IMAGE for PAGE in pdf-tools WINDOW without overlay ambiguity."
  (if (bound-and-true-p pdf-view-roll-minor-mode)
      (if-let ((overlay
                (english-reading-mode--pdf-roll-page-overlay page window)))
          (progn
            (overlay-put
             overlay 'display
             (if (fboundp 'pdf-roll-maybe-slice-image)
                 (pdf-roll-maybe-slice-image image window)
               image))
            (force-window-update window))
        (error "No pdf-roll page overlay for page %s" page))
    (pdf-view-display-image image page window)))

(defun english-reading-mode--pdf-view-highlight
    (window geometry rectangles &optional context)
  "Display RECTANGLES as a native raster highlight in pdf-tools WINDOW."
  (let* ((page english-reading-mode--pdf-page)
         (page-image (pdf-view-create-page page window))
         (width (plist-get (cdr page-image) :width))
         (page-width (float (plist-get geometry :width)))
         (page-height (float (plist-get geometry :height)))
         ;; pdf-info takes page-relative edges.  Keep the positioned-text
         ;; matcher in PDF coordinates and convert only at this API boundary.
         (relative-rectangles
          (mapcar
           (lambda (rectangle)
             (pcase-let ((`(,xmin ,ymin ,xmax ,ymax) rectangle))
               (list (/ xmin page-width) (/ ymin page-height)
                     (/ xmax page-width) (/ ymax page-height))))
           rectangles))
         ;; A raster rendered by pdf-tools is materially more reliable than
         ;; embedding the full page PNG in a giant SVG.  The latter can turn a
         ;; live PDF window black on macOS even though Emacs accepts the image.
         (highlight-data
          (pdf-cache-renderpage-highlight
           page width
           (append (list english-reading-mode-pdf-highlight-color
                         english-reading-mode-pdf-highlight-color
                         english-reading-mode-pdf-highlight-opacity)
                   relative-rectangles)))
         (highlight-image
          (create-image highlight-data 'png t
                        :width width :pointer 'arrow)))
    ;; Update the page image itself so normal redisplay does not immediately
    ;; cover the speech highlight.
    (english-reading-mode--pdf-view-display-image
     highlight-image page window)
    (setq english-reading-mode--pdf-highlight-page page
          english-reading-mode--pdf-highlight-state
          (list :context context :mode 'pdf-view-mode
                :page page :window window))))

(defun english-reading-mode--pdf-restore-image
    (pdf-buffer &optional window context)
  "Restore PDF-BUFFER's normal page image in WINDOW.

When CONTEXT is non-nil, restore only the image installed for that exact
speech context.  This prevents a late finish event from removing a newer
sentence's highlight."
  (when (buffer-live-p pdf-buffer)
    (with-current-buffer pdf-buffer
      (let ((state english-reading-mode--pdf-highlight-state))
        (when (and state
                   (or (null context)
                       (eq context (plist-get state :context))))
          (let ((saved-window (plist-get state :window)))
            ;; Clear ownership before redisplay.  If pdf-tools signals while a
            ;; window is disappearing, a later utterance must still be able to
            ;; establish fresh state instead of inheriting a stuck owner.
            (setq english-reading-mode--pdf-highlight-state nil
                  english-reading-mode--pdf-highlight-page nil)
            (pcase (plist-get state :mode)
              ('pdf-view-mode
               (when (and (window-live-p saved-window)
                          (eq (window-buffer saved-window) pdf-buffer))
                 ;; Re-render at the current zoom.  In continuous roll mode
                 ;; this restores the exact page overlay, even if another page
                 ;; has meanwhile become the topmost visible page.
                 (let ((page (plist-get state :page)))
                   (if (bound-and-true-p pdf-view-roll-minor-mode)
                       (english-reading-mode--pdf-view-display-image
                        (pdf-view-create-page page saved-window)
                        page saved-window)
                     (pdf-view-display-page page saved-window)))))
              ('doc-view-mode
               (let ((overlay (plist-get state :overlay))
                     (image (plist-get state :image))
                     (slice (plist-get state :slice)))
                 ;; DocView cannot recreate the original image via pdf-tools.
                 ;; Restore the display value captured before SVG replacement;
                 ;; reading it here would only return the highlight itself.
                 (when (overlayp overlay)
                   (overlay-put overlay 'display
                                (if slice
                                    (list (cons 'slice slice) image)
                                  image))))))))))))

(defun english-reading-mode--pdf-highlight-start (context)
  "Highlight the PDF words belonging to speech CONTEXT."
  (let* ((window (plist-get context :window))
         (pdf-buffer (and (window-live-p window) (window-buffer window))))
    (when (and (buffer-live-p pdf-buffer)
               (with-current-buffer pdf-buffer
                 (and (english-reading-mode--pdf-buffer-p)
                      (eq (plist-get context :buffer)
                          english-reading-mode--pdf-text-buffer))))
      (with-current-buffer pdf-buffer
        ;; A replacement utterance may arrive before the old watcher reports
        ;; completion.  Never leave its old raster/SVG visible while preparing
        ;; the next sentence, including the no-bbox/error paths below.
        (english-reading-mode--pdf-restore-image pdf-buffer window)
        (condition-case err
            (when-let ((match
                        (english-reading-mode--pdf-context-rectangles context)))
              (if (eq major-mode 'pdf-view-mode)
                  (english-reading-mode--pdf-view-highlight
                   window (car match) (cadr match) context)
                (pcase-let* ((`(,overlay ,image ,slice)
                              (english-reading-mode--pdf-display-state window))
                             (highlight
                              (english-reading-mode--pdf-svg-highlight
                               image (car match) (cadr match))))
                  (when (and (overlayp overlay) highlight)
                    (overlay-put overlay 'display
                                 (if slice
                                     (list (cons 'slice slice) highlight)
                                   highlight))
                    (setq english-reading-mode--pdf-highlight-state
                          (list :context context :mode 'doc-view-mode
                                :window window :overlay overlay
                                :image image :slice slice))))))
          (error
           (message "PDF sentence highlight unavailable: %s"
                    (error-message-string err))))))))

(defun english-reading-mode--cancel-pdf-highlight (&optional context)
  "Cancel a pending PDF highlight for CONTEXT.

When CONTEXT is nil, cancel any pending highlight.  A context check prevents a
late finish notification for an older utterance from cancelling the new one."
  (when (or (null context)
            (eq context english-reading-mode--pdf-highlight-pending-context))
    (when (timerp english-reading-mode--pdf-highlight-timer)
      (cancel-timer english-reading-mode--pdf-highlight-timer))
    (setq english-reading-mode--pdf-highlight-timer nil
          english-reading-mode--pdf-highlight-pending-context nil
          english-reading-mode--pdf-highlight-pending-scroll-state nil)))

(defun english-reading-mode--pdf-highlight-scroll-state (context)
  "Return the visible scroll state associated with speech CONTEXT."
  (let ((window (plist-get context :window)))
    (when (window-live-p window)
      (list (window-start window)
            (window-vscroll window t)
            (with-current-buffer (window-buffer window)
              (and (eq major-mode 'pdf-view-mode)
                   (fboundp 'pdf-view-current-page)
                   (pdf-view-current-page window)))))))

(defun english-reading-mode--run-deferred-pdf-highlight (context)
  "Draw CONTEXT's PDF highlight if it is still the active utterance."
  (when (eq context english-reading-mode--pdf-highlight-pending-context)
    (setq english-reading-mode--pdf-highlight-timer nil)
    (if (not (eq context english-reading-mode--active-speech))
        (english-reading-mode--cancel-pdf-highlight context)
      (let ((scroll-state
             (english-reading-mode--pdf-highlight-scroll-state context)))
        (if (equal scroll-state
                   english-reading-mode--pdf-highlight-pending-scroll-state)
            (progn
              (setq english-reading-mode--pdf-highlight-pending-context nil
                    english-reading-mode--pdf-highlight-pending-scroll-state nil)
              (english-reading-mode--pdf-highlight-start context))
          ;; PDF roll redisplay is still changing the page position.  Restart
          ;; the full delay from the latest state instead of drawing midway.
          (setq english-reading-mode--pdf-highlight-pending-scroll-state
                scroll-state
                english-reading-mode--pdf-highlight-timer
                (run-at-time english-reading-mode-pdf-highlight-delay nil
                             #'english-reading-mode--run-deferred-pdf-highlight
                             context)))))))

(defun english-reading-mode--schedule-pdf-highlight (context)
  "Schedule CONTEXT's PDF highlight after PDF redisplay has settled."
  (english-reading-mode--cancel-pdf-highlight)
  (setq english-reading-mode--pdf-highlight-pending-context context
        english-reading-mode--pdf-highlight-pending-scroll-state
        (english-reading-mode--pdf-highlight-scroll-state context)
        english-reading-mode--pdf-highlight-timer
        (run-at-time english-reading-mode-pdf-highlight-delay nil
                     #'english-reading-mode--run-deferred-pdf-highlight
                     context)))

(defun english-reading-mode--pdf-highlight-finish (context)
  "Remove the PDF highlight associated with speech CONTEXT."
  (english-reading-mode--cancel-pdf-highlight context)
  (let ((window (plist-get context :window)))
    (when (window-live-p window)
      (english-reading-mode--pdf-restore-image
       (window-buffer window) window context))))

(defun english-reading-mode--pdf-continuous-vscroll
    (rectangle page-height full-image-height displayed-image-height
               viewport-height &optional image-top-offset)
  "Return pixel vscroll positioning RECTANGLE in a rendered PDF page.

PAGE-HEIGHT is the PDF-space page height.  FULL-IMAGE-HEIGHT is the rendered
height before slicing; DISPLAYED-IMAGE-HEIGHT is the visible slice height;
VIEWPORT-HEIGHT and IMAGE-TOP-OFFSET are pixels.  Position the spoken text at
`english-reading-mode-pdf-speech-screen-position' and clamp at displayed
edges."
  (let* ((spoken-y (/ (+ (nth 1 rectangle) (nth 3 rectangle)) 2.0))
         (spoken-pixel (* (/ spoken-y page-height) full-image-height))
         (displayed-pixel (- spoken-pixel (or image-top-offset 0)))
         (anchor-pixel
          (english-reading-mode--pdf-speech-anchor-pixel viewport-height))
         (maximum (max 0 (- displayed-image-height viewport-height))))
    (round (max 0 (min maximum
                       (- displayed-pixel anchor-pixel))))))

(defun english-reading-mode--pdf-speech-anchor-pixel (viewport-height)
  "Return the desired speech anchor in pixels for VIEWPORT-HEIGHT."
  (* viewport-height
     (max 0.0
          (min 1.0
               (float english-reading-mode-pdf-speech-screen-position)))))

(defun english-reading-mode--pdf-continuous-position (context)
  "Return page geometry and a vertical position for speech CONTEXT.

Prefer exact positioned-word matching.  If PDF text extraction represents
math or punctuation differently, estimate the vertical position from CONTEXT's
relative source-text position so zoom correction never keeps a stale scroll."
  (or (when-let ((match
                  (english-reading-mode--pdf-context-rectangles context)))
        (list (car match) (car (cadr match))))
      (let* ((geometry
              (english-reading-mode--pdf-bbox-page
               english-reading-mode--pdf-page))
             (page-range
              (english-reading-mode--pdf-page-range
               english-reading-mode--pdf-page))
             (span (and page-range
                        (max 1 (- (cdr page-range) (car page-range)))))
             (source-beg (plist-get context :beg)))
        (when (and geometry page-range (numberp source-beg))
          (let* ((ratio
                  (max 0.0
                       (min 1.0
                            (/ (float (- source-beg (car page-range))) span))))
                 (y (* ratio (plist-get geometry :height))))
            (list geometry (list 0.0 y 0.0 y)))))))

(defun english-reading-mode--pdf-roll-spoken-window-pixel
    (page spoken-pixel window)
  "Return PAGE's SPOKEN-PIXEL position inside roll-mode WINDOW.

The result is measured from the top of the visible viewport.  Return nil when
PAGE precedes the topmost visible page, so the caller can re-establish an
absolute page position before measuring again."
  (let ((top-page (and (fboundp 'pdf-view-current-page)
                       (pdf-view-current-page window))))
    (when (and (integerp top-page) (<= top-page page))
      (let ((margin (if (boundp 'pdf-roll-vertical-margin)
                        pdf-roll-vertical-margin
                      0)))
        (- (+ spoken-pixel
              (cl-loop for visible-page from top-page below page
                       sum (+ (pdf-roll-display-page visible-page window)
                              margin)))
           (window-vscroll window t))))))

(defun english-reading-mode--pdf-center-continuous-speech (context)
  "Position PDF speech CONTEXT while preserving continuous-page scrolling."
  (let* ((window (plist-get context :window))
         (pdf-buffer (and (window-live-p window) (window-buffer window))))
    (when (and (buffer-live-p pdf-buffer)
               (eq (plist-get english-reading-mode--continuous-state :buffer)
                   pdf-buffer))
      (with-current-buffer pdf-buffer
        (when (and (eq major-mode 'pdf-view-mode)
                   (english-reading-mode--pdf-buffer-p)
                   (eq (plist-get context :buffer)
                       english-reading-mode--pdf-text-buffer))
          (condition-case err
              (when-let ((position
                          (english-reading-mode--pdf-continuous-position context)))
                (with-selected-window window
                  (let* ((geometry (car position))
                         (rectangle (cadr position))
                         (inside (window-inside-pixel-edges window))
                         (viewport-height (- (nth 3 inside) (nth 1 inside))))
                    (when (and rectangle
                               (> (plist-get geometry :height) 0)
                               (> viewport-height 0))
                      (if (and (bound-and-true-p pdf-view-roll-minor-mode)
                               (fboundp 'pdf-roll-goto-page)
                               (fboundp 'pdf-roll-display-page)
                               (fboundp 'pdf-roll-scroll-forward)
                               (fboundp 'pdf-roll-scroll-backward))
                          ;; Re-measure the spoken line against the live roll
                          ;; viewport for every utterance.  Relative-only motion
                          ;; accumulates page-margin and vscroll errors and lets
                          ;; the anchor drift away from its configured position.
                          (let* ((page english-reading-mode--pdf-page)
                                 (page-height
                                  (pdf-roll-display-page page window))
                                 (spoken-y
                                  (/ (+ (nth 1 rectangle) (nth 3 rectangle))
                                     2.0))
                                 (spoken-pixel
                                  (round (* (/ spoken-y
                                               (plist-get geometry :height))
                                            page-height)))
                                 (actual-pixel
                                  (english-reading-mode--pdf-roll-spoken-window-pixel
                                   page spoken-pixel window)))
                            (unless (numberp actual-pixel)
                              (pdf-roll-goto-page page window)
                              (setq actual-pixel
                                    (english-reading-mode--pdf-roll-spoken-window-pixel
                                     page spoken-pixel window)))
                            (when (numberp actual-pixel)
                              (let ((delta
                                     (round
                                      (- actual-pixel
                                         (english-reading-mode--pdf-speech-anchor-pixel
                                          viewport-height)))))
                                (if (>= delta 0)
                                    (pdf-roll-scroll-forward delta window t)
                                  (pdf-roll-scroll-backward
                                   (- delta) window t))))
                            (setq english-reading-mode--continuous-state
                                  (plist-put
                                   (plist-put
                                    english-reading-mode--continuous-state
                                    :pdf-roll-page page)
                                   :pdf-roll-pixel spoken-pixel)))
                        (let ((full-image-height
                               (cdr (pdf-view-image-size nil window)))
                              (displayed-image-height
                               (cdr (pdf-view-image-size t window)))
                              (image-top-offset
                               (cdr (pdf-view-image-offset window))))
                          (when (and (> full-image-height 0)
                                     (> displayed-image-height 0))
                            (image-set-window-vscroll
                             (english-reading-mode--pdf-continuous-vscroll
                              rectangle (plist-get geometry :height)
                              full-image-height displayed-image-height
                              viewport-height image-top-offset)))))))))
            (error
             (message "PDF speech centering unavailable: %s"
                      (error-message-string err)))))))))

(defconst english-reading-mode--pdf-zoom-commands
  '(pdf-view-enlarge
    pdf-view-shrink
    pdf-view-scale-reset
    pdf-view-fit-page-to-window
    pdf-view-fit-height-to-window
    pdf-view-fit-width-to-window)
  "PDF commands after which continuous speech needs position correction.")

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
    (english-reading-mode--pdf-center-continuous-speech
     english-reading-mode--active-speech)
    (english-reading-mode--schedule-pdf-highlight
     english-reading-mode--active-speech)))

;; PDF visuals are managed by the speech advice.  Remove former start-hook
;; registrations as well so a live `load-file' upgrades an already running
;; reader without doing the work twice.
(remove-hook 'english-reading-mode-speech-start-hook
             #'english-reading-mode--pdf-highlight-start)
(remove-hook 'english-reading-mode-speech-start-hook
             #'english-reading-mode--pdf-center-continuous-speech)
(add-hook 'english-reading-mode-speech-finish-hook
          #'english-reading-mode--pdf-highlight-finish)

(defun english-reading-mode--sentence-bounds ()
  "Return the sentence at point, or signal a user error."
  (or (bounds-of-thing-at-point 'sentence)
      (user-error "Place point in an English sentence")))

(defun english-reading-mode--continuous-speech-buffer-owned-p (speech-buffer)
  "Return non-nil when SPEECH-BUFFER belongs to the continuous source."
  (let ((source-buffer
         (plist-get english-reading-mode--continuous-state :buffer)))
    (and (buffer-live-p source-buffer)
         (or (eq speech-buffer source-buffer)
             (with-current-buffer source-buffer
               (and (english-reading-mode--pdf-buffer-p)
                    (buffer-live-p english-reading-mode--pdf-text-buffer)
                    (eq speech-buffer
                        english-reading-mode--pdf-text-buffer)))))))

(defun english-reading-mode--continuous-speech-page-range
    (speech-buffer position)
  "Return the PDF page range containing POSITION in SPEECH-BUFFER, or nil."
  (let ((source-buffer
         (plist-get english-reading-mode--continuous-state :buffer)))
    (when (and (buffer-live-p source-buffer)
               (with-current-buffer source-buffer
                 (and (english-reading-mode--pdf-buffer-p)
                      (eq speech-buffer english-reading-mode--pdf-text-buffer))))
      (with-current-buffer source-buffer
        (cl-loop for range across english-reading-mode--pdf-page-ranges
                 when (and (<= (car range) position)
                           (<= position (cdr range)))
                 return range)))))

(defun english-reading-mode--continuous-speech-page-end
    (speech-buffer position)
  "Return the PDF page end containing POSITION in SPEECH-BUFFER, or nil."
  (cdr (english-reading-mode--continuous-speech-page-range
        speech-buffer position)))

(defun english-reading-mode--macos-continuous-bounds (beg end &optional limit)
  "Extend BEG..END to a continuous macOS speech chunk.

At most `english-reading-mode-macos-continuous-sentence-count' sentences are
included.  LIMIT, when non-nil, prevents a PDF chunk from crossing its page."
  (if (or (not (english-reading-mode--continuous-speech-buffer-owned-p
                (current-buffer)))
          (not (eq kokoro-reader-backend 'macos))
          (<= english-reading-mode-macos-continuous-sentence-count 1))
      (cons beg end)
    (save-excursion
      (let ((chunk-end end)
            (remaining (1- english-reading-mode-macos-continuous-sentence-count))
            (boundary (or limit (point-max))))
        (goto-char (min end boundary))
        (while (and (> remaining 0) (< (point) boundary))
          (skip-chars-forward " \t\n\r" boundary)
          (if-let ((bounds (and (< (point) boundary)
                               (bounds-of-thing-at-point 'sentence))))
              (let ((next-end (min (cdr bounds) boundary)))
                (if (> next-end chunk-end)
                    (setq chunk-end next-end
                          remaining (1- remaining))
                  (setq remaining 0))
                (goto-char next-end))
            (setq remaining 0)))
        (cons beg chunk-end)))))

(defun english-reading-mode--make-context (beg end)
  "Create a speech context for BEG..END in the current buffer."
  (list :id (cl-incf english-reading-mode--speech-sequence)
        :buffer (current-buffer)
        :frame (selected-frame)
        :window (selected-window)
        :beg beg
        :end end
        :text (if (fboundp 'kokoro-reader--text)
                  (kokoro-reader--text beg end)
                (string-trim
                  (replace-regexp-in-string
                  "[ \t\n\r]+" " "
                  (buffer-substring-no-properties beg end))))))

(defun english-reading-mode--position-spoken-start (context)
  "Keep the beginning of spoken CONTEXT at the configured window position."
  (let ((window (plist-get context :window))
        (buffer (plist-get context :buffer))
        (beg (plist-get context :beg)))
    ;; PDF speech uses a hidden extracted-text buffer while WINDOW displays the
    ;; DocView image, so normal text recentering applies only when they match.
    (when (and (window-live-p window)
               (buffer-live-p buffer)
               (eq (window-buffer window) buffer)
               (integer-or-marker-p beg)
               (<= (with-current-buffer buffer (point-min)) beg)
               (<= beg (with-current-buffer buffer (point-max))))
      (with-selected-window window
        (save-excursion
          (goto-char beg)
          ;; With a nil argument Emacs uses the visual center, accounting for
          ;; enlarged or variable-height reading text.
          (recenter))))))

(add-hook 'english-reading-mode-speech-start-hook
          #'english-reading-mode--position-spoken-start)

(defvar english-reading-mode--speech-watch-timer nil
  "Timer used to watch Kokoro request/playback lifetime.")

(defvar english-reading-mode--speech-start-time nil
  "Time when the active English-reading utterance was handed to Kokoro.")

(defvar english-reading-mode--speech-player-seen-p nil
  "Non-nil after the active utterance has reached actual audio playback.")

(defvar english-reading-mode--continuous-state nil
  "State plist for sentence-by-sentence continuous reading.")

(defvar english-reading-mode--continuous-timer nil
  "Timer that starts the next continuous-reading sentence.")

(defconst english-reading-mode--pdf-manual-interaction-commands
  '(mwheel-scroll
    pixel-scroll-precision
    scroll-up-command
    scroll-down-command
    image-scroll-up
    image-scroll-down
    pdf-view-scroll-up-or-next-page
    pdf-view-scroll-down-or-previous-page
    pdf-view-next-line-or-next-page
    pdf-view-previous-line-or-previous-page
    pdf-view-next-page
    pdf-view-previous-page
    pdf-view-next-page-command
    pdf-view-previous-page-command
    pdf-roll-scroll-forward
    pdf-roll-scroll-backward
    pdf-roll-next-page
    pdf-roll-previous-page
    pdf-roll-goto-page
    pdf-view-first-page
    pdf-view-last-page
    pdf-view-goto-page
    english-reading-mode-next-page
    english-reading-mode-previous-page
    pdf-view-mouse-set-region
    pdf-view-mouse-set-region-rectangle)
  "Commands that make a PDF reader's manual position authoritative.")

(defvar-local english-reading-mode-continuous-next-function nil
  "Optional source-specific function that advances and speaks the next sentence.")

(defvar-local english-reading-mode-continuous-prefetch-text-function nil
  "Optional function returning future page text chunks for speech prefetch.

The function receives the active speech CONTEXT and a maximum COUNT.  It is
used after readable chunks in the current speech buffer have been exhausted.")

(defun english-reading-mode--finish (context)
  "Finish CONTEXT once and notify listeners."
  (when (eq context english-reading-mode--active-speech)
    (setq english-reading-mode--active-speech nil)
    (when (timerp english-reading-mode--speech-watch-timer)
      (cancel-timer english-reading-mode--speech-watch-timer))
    (setq english-reading-mode--speech-watch-timer nil
          english-reading-mode--speech-start-time nil
          english-reading-mode--speech-player-seen-p nil)
    (run-hook-with-args 'english-reading-mode-speech-finish-hook context)))

(defun english-reading-mode--kokoro-busy-p ()
  "Return non-nil while Kokoro is synthesizing or actually playing audio."
  (or (and (boundp 'kokoro-reader--request-process)
           (process-live-p kokoro-reader--request-process))
      (and (boundp 'kokoro-reader--player-process)
           (process-live-p kokoro-reader--player-process))))

(defun english-reading-mode--watch-speech (context)
  "Finish CONTEXT only after Kokoro's actual playback has ended.

There can be a very small event-loop gap between curl finishing and afplay's
process being installed.  Treating that gap as completion unlocks translation
at exactly the wrong moment, just before Kokoro starts speaking.  Therefore
we wait until playback has actually been observed, or until a short grace
period proves that synthesis failed before playback started."
  (cond
   ;; A newer utterance replaced CONTEXT.  Its own watcher owns the lifecycle.
   ((not (eq context english-reading-mode--active-speech))
    nil)

   ;; Actual playback exists: remember that we reached the speaking phase.
   ((and (boundp 'kokoro-reader--player-process)
         (process-live-p kokoro-reader--player-process))
    (setq english-reading-mode--speech-player-seen-p t))

   ;; Curl is still synthesizing/downloading audio.
   ((and (boundp 'kokoro-reader--request-process)
         (process-live-p kokoro-reader--request-process))
    nil)

   ;; Once afplay has been seen, no player now means playback really ended.
   (english-reading-mode--speech-player-seen-p
    (english-reading-mode--finish context))

   ;; Before playback has been seen, tolerate the curl -> afplay transition.
   ;; If nothing appears for 0.75s, regard it as synthesis failure/cancellation.
   ((and english-reading-mode--speech-start-time
         (> (float-time
             (time-subtract (current-time)
                            english-reading-mode--speech-start-time))
            0.75))
    (english-reading-mode--finish context))))

(defun english-reading-mode--start-watch (context)
  "Start watching Kokoro lifetime for CONTEXT."
  (when (timerp english-reading-mode--speech-watch-timer)
    (cancel-timer english-reading-mode--speech-watch-timer))
  (setq english-reading-mode--speech-watch-timer
        (run-with-timer 0.05 0.05
                        #'english-reading-mode--watch-speech
                        context)))

(defun english-reading-mode--around-kokoro-speak-bounds
    (original-function beg end &rest arguments)
  "Track Kokoro ORIGINAL-FUNCTION for BEG..END when this mode is active."
  (if (not english-reading-mode)
      (apply original-function beg end arguments)
    (let ((context (english-reading-mode--make-context beg end)))
      ;; ORIGINAL-FUNCTION creates Kokoro's request process.  Only after that
      ;; succeeds do we publish the new speech context.  `j' moves point after
      ;; this wrapper returns, so listeners lock to the old/current sentence
      ;; before point advances.
      (condition-case err
          (prog1
              (apply original-function beg end arguments)
            ;; Playback, scrolling and highlight rendering are deliberately
            ;; separate.  In particular, SVG generation must not delay audio.
            (english-reading-mode--pdf-center-continuous-speech context)
            (setq english-reading-mode--active-speech context
                  english-reading-mode--speech-start-time (current-time)
                  english-reading-mode--speech-player-seen-p nil)
            (english-reading-mode--schedule-pdf-highlight context)
            (run-hook-with-args 'english-reading-mode-speech-start-hook context)
            ;; Do not infer completion from a request sentinel: Kokoro switches
            ;; from curl -> afplay at that boundary.  Poll the actual request/player
            ;; process variables and finish only when BOTH are no longer alive.
            (english-reading-mode--start-watch context))
        (error
         (signal (car err) (cdr err)))))))

(defun english-reading-mode--after-kokoro-stop (&rest _)
  "Finish the active context after an explicit/internal Kokoro stop."
  (when english-reading-mode--active-speech
    (english-reading-mode--finish english-reading-mode--active-speech)))

(defun english-reading-mode--continuous-live-p ()
  "Return non-nil when continuous reading still owns the displayed source."
  (let ((buffer (plist-get english-reading-mode--continuous-state :buffer))
        (window (plist-get english-reading-mode--continuous-state :window))
        (frame (plist-get english-reading-mode--continuous-state :frame)))
    (and (buffer-live-p buffer)
         (window-live-p window)
         (frame-live-p frame)
         (eq (window-buffer window) buffer))))

(defun english-reading-mode-stop-continuous (&optional quiet)
  "Stop sentence-by-sentence continuous reading.
When QUIET is non-nil, do not stop an already active audio process."
  (interactive)
  (setq english-reading-mode--continuous-state nil)
  (when (timerp english-reading-mode--continuous-timer)
    (cancel-timer english-reading-mode--continuous-timer))
  (setq english-reading-mode--continuous-timer nil)
  (unless quiet (kokoro-reader-stop))
  (unless quiet (message "Continuous reading stopped")))

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

(defun english-reading-mode--continuous-default-next ()
  "Advance a PDF/EPUB/text source and speak its next sentence."
  (cond
   ((english-reading-mode--pdf-buffer-p)
    (english-reading-mode--pdf-next-sentence)
    (english-reading-mode-speak-current-sentence))
   (t
    (english-reading-mode-next-sentence)
    (cond
     ((bounds-of-thing-at-point 'sentence)
      (english-reading-mode-speak-current-sentence))
     ((and (derived-mode-p 'nov-mode)
           (boundp 'nov-documents-index)
           (boundp 'nov-documents)
           (< nov-documents-index (1- (length nov-documents))))
      (nov-next-document)
      (goto-char (point-min))
      (skip-chars-forward " \t\n\r")
      (english-reading-mode-speak-current-sentence))
     (t (user-error "Reached the end of the document"))))))

(defun english-reading-mode--continuous-resume-next-chunk ()
  "Speak the chunk following the last completed continuous utterance.

Return non-nil when speech was started.  Source-specific continuation remains
responsible for page/chapter boundaries when no sentence follows locally."
  (let* ((state english-reading-mode--continuous-state)
         (source-buffer (plist-get state :buffer))
         (speech-buffer (plist-get state :next-speech-buffer))
         (next-position (plist-get state :next-speech-position)))
    (when (and (buffer-live-p source-buffer)
               (buffer-live-p speech-buffer)
               (integer-or-marker-p next-position))
      (setq english-reading-mode--continuous-state
            (plist-put
             (plist-put state :next-speech-buffer nil)
             :next-speech-position nil))
      (cond
       ((eq source-buffer speech-buffer)
        (goto-char (min next-position (point-max)))
        (skip-chars-forward " \t\n\r")
        (when (bounds-of-thing-at-point 'sentence)
          (english-reading-mode-speak-current-sentence)
          t))
       ((and (english-reading-mode--pdf-buffer-p source-buffer)
             (with-current-buffer source-buffer
               (eq speech-buffer english-reading-mode--pdf-text-buffer)))
        (with-current-buffer source-buffer
          (setq english-reading-mode--pdf-text-point next-position)
          (english-reading-mode-speak-current-sentence))
        t)))))

(defun english-reading-mode--continuous-next ()
  "Advance and speak once for the active continuous-reading source."
  (setq english-reading-mode--continuous-timer nil)
  (if (not (english-reading-mode--continuous-live-p))
      (english-reading-mode-stop-continuous t)
    (let ((buffer (plist-get english-reading-mode--continuous-state :buffer))
          (window (plist-get english-reading-mode--continuous-state :window))
          (frame (plist-get english-reading-mode--continuous-state :frame)))
      (condition-case err
          (with-selected-frame frame
            (with-selected-window window
              (with-current-buffer buffer
                (unless (english-reading-mode--continuous-resume-next-chunk)
                  (if (functionp english-reading-mode-continuous-next-function)
                      (funcall english-reading-mode-continuous-next-function)
                    (english-reading-mode--continuous-default-next))))))
        (error
         (english-reading-mode-stop-continuous t)
         (message "Continuous reading finished: %s" (error-message-string err)))))))

(defun english-reading-mode--continuous-context-owned-p (context)
  "Return non-nil when speech CONTEXT belongs to the continuous source.

Normal text speaks directly from the displayed buffer.  A DocView PDF speaks
from its hidden `pdftotext' helper, so that helper must be treated as speech
originating from the displayed PDF buffer."
  (english-reading-mode--continuous-speech-buffer-owned-p
   (plist-get context :buffer)))

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
                   bounds beg finish chunk candidate)
              ;; Narrow exactly like normal PDF playback.  Without this, Emacs
              ;; can treat a page number before a form feed as part of the next
              ;; page's first sentence, producing a prefetch cache-key mismatch.
              (save-restriction
                (when page-range
                  (narrow-to-region (car page-range) (cdr page-range)))
                (goto-char (min (max scan-position (point-min)) (point-max)))
                (skip-chars-forward " \t\n\r")
                (setq bounds (and (< (point) (point-max))
                                  (bounds-of-thing-at-point 'sentence)))
                (if (not bounds)
                    (goto-char (point-max))
                  (goto-char (car bounds))
                  (skip-chars-forward " \t\n\r" (cdr bounds))
                  (setq beg (point))
                  (goto-char (cdr bounds))
                  (skip-chars-backward " \t\n\r" beg)
                  (setq finish (point)
                        chunk
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
                  (if (string-match-p
                       "[[:alpha:]].*[[:alpha:]]" candidate)
                      (push candidate texts)
                    (goto-char (min (1+ finish) (point-max)))))))))))
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
  "Render future speech chunks following CONTEXT while the current one plays."
  (let ((speech-buffer (plist-get context :buffer)))
    (when (and english-reading-mode--continuous-state
               (english-reading-mode--continuous-context-owned-p context)
               (buffer-live-p speech-buffer))
      (with-current-buffer speech-buffer
        (when (and (eq kokoro-reader-backend 'macos)
                   (fboundp 'kokoro-reader-prefetch-macos-texts))
          (kokoro-reader-prefetch-macos-texts
           (english-reading-mode--next-speech-texts context)))))))

(add-hook 'english-reading-mode-speech-start-hook
          #'english-reading-mode--prefetch-next-macos-sentence)

(defun english-reading-mode--continuous-speech-finished (context)
  "Continue immediately after the speech chunk represented by CONTEXT."
  (when (and english-reading-mode--continuous-state
             (english-reading-mode--continuous-context-owned-p context))
    (when (timerp english-reading-mode--continuous-timer)
      (cancel-timer english-reading-mode--continuous-timer))
    (setq english-reading-mode--continuous-state
          (plist-put
           (plist-put english-reading-mode--continuous-state
                      :next-speech-buffer (plist-get context :buffer))
           :next-speech-position (plist-get context :end)))
    ;; A zero-delay timer leaves the process sentinel before starting the next
    ;; chunk, without inserting an intentional silent interval.
    (setq english-reading-mode--continuous-timer
          (run-at-time 0 nil #'english-reading-mode--continuous-next))))

(add-hook 'english-reading-mode-speech-finish-hook
          #'english-reading-mode--continuous-speech-finished)

(defun english-reading-mode-continuous-read ()
  "Read continuously in speech chunks.
Press `s' again to stop."
  (interactive)
  (if english-reading-mode--continuous-state
      (english-reading-mode-stop-continuous)
    ;; Stop any unrelated one-shot utterance while STATE is still nil, so its
    ;; completion cannot schedule a spurious first advance.
    (kokoro-reader-stop)
    ;; Capture the manually displayed PDF page before continuous roll mode can
    ;; leave the previous page at the top during a boundary scroll.
    (when (english-reading-mode--pdf-buffer-p)
      (english-reading-mode--pdf-sync))
    (setq english-reading-mode--continuous-state
          (list :buffer (current-buffer)
                :window (selected-window)
                :frame (selected-frame)))
    (condition-case err
        (progn
          (english-reading-mode-speak-current-sentence)
          (message "Continuous reading started"))
      (error
       (english-reading-mode-stop-continuous t)
       (signal (car err) (cdr err))))))

;; Re-evaluation safe lifecycle integration.
(advice-remove 'kokoro-reader--speak-bounds
               #'english-reading-mode--around-kokoro-speak-bounds)
(advice-add 'kokoro-reader--speak-bounds
            :around
            #'english-reading-mode--around-kokoro-speak-bounds)
(advice-remove 'kokoro-reader-stop
               #'english-reading-mode--after-kokoro-stop)
(advice-add 'kokoro-reader-stop
            :after
            #'english-reading-mode--after-kokoro-stop)

(defun english-reading-mode--speak-at-point ()
  "Speak the sentence at point with Kokoro."
  (pcase-let ((`(,beg . ,end) (english-reading-mode--sentence-bounds)))
    (pcase-let ((`(,chunk-beg . ,chunk-end)
                 (english-reading-mode--macos-continuous-bounds beg end)))
      (kokoro-reader--speak-bounds chunk-beg chunk-end))))

(defun english-reading-mode-speak-current-sentence ()
  "Read the current sentence without moving the text cursor."
  (interactive)
  (if (english-reading-mode--pdf-buffer-p)
      (english-reading-mode--pdf-speak-current-sentence)
    (english-reading-mode--speak-at-point)))

(defun english-reading-mode-next-sentence ()
  "Move to the next sentence without reading it."
  (interactive)
  (if (english-reading-mode--pdf-buffer-p)
      (english-reading-mode--pdf-next-sentence)
    (pcase-let ((`(,_ . ,end) (english-reading-mode--sentence-bounds)))
      (goto-char end)
      (skip-chars-forward " \t\n\r"))))

(defun english-reading-mode-previous-sentence ()
  "Move to the previous sentence without reading it.

At the beginning of the buffer, do not signal `beginning-of-buffer'; just
leave point at the current sentence and report that there is nowhere to go."
  (interactive)
  (if (english-reading-mode--pdf-buffer-p)
      (english-reading-mode--pdf-previous-sentence)
    (pcase-let ((`(,beg . ,_) (english-reading-mode--sentence-bounds)))
      (goto-char beg)
      (let ((origin (point))
            (moved nil))
        (condition-case nil
            (progn
              (backward-sentence)
              (skip-chars-forward " \t\n\r")
              (setq moved (< (point) origin)))
          (beginning-of-buffer
           (goto-char origin))
          (error
           (goto-char origin)))
        (unless moved
          (goto-char origin)
          (message "Already at the first sentence"))))))

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
        (add-hook 'pre-command-hook
                  #'english-reading-mode--pdf-pre-command nil t)
        (add-hook 'post-command-hook
                  #'english-reading-mode--pdf-post-command nil t)
        (unless (or (derived-mode-p 'nov-mode 'eww-mode 'doc-view-mode
                                    'pdf-view-mode)
                    (bound-and-true-p my-read-k-mode))
          (message "english-reading-mode is designed for reader buffers")))
    (english-reading-mode--restore-sentence-setting)
    (english-reading-mode--restore-read-only)
    (remove-hook 'pre-command-hook
                 #'english-reading-mode--pdf-pre-command t)
    (remove-hook 'post-command-hook
                 #'english-reading-mode--pdf-post-command t)
    (english-reading-mode--pdf-cleanup)
    (english-reading-mode-stop)))

(provide 'english-reading-mode)
;;; english-reading-mode.el ends here
