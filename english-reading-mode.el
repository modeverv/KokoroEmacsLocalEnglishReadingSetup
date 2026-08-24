;;; english-reading-mode.el --- Sentence-by-sentence English reading -*- lexical-binding: t; -*-

;; j/k and Kokoro lifecycle belong here.  Consumers such as my-read.el can
;; observe speech without reimplementing cursor movement or advising Kokoro.

(require 'cl-lib)
(require 'dom)
(require 'kokoro-reader)
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

(defcustom english-reading-mode-pdf-highlight-opacity 0.32
  "Opacity of the spoken-sentence highlight on a PDF page."
  :type 'number
  :group 'english-reading-mode)

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
  "Return non-nil when BUFFER is a DocView PDF buffer."
  (with-current-buffer (or buffer (current-buffer))
    (and (derived-mode-p 'doc-view-mode)
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
          (goto-char (point-min))
          (unless (re-search-forward "[[:alpha:]]" nil t)
            (user-error
             "This PDF has no readable text layer; scanned PDFs need OCR"))
          (setq-local sentence-end-double-space nil)
          ;; Kokoro's advice builds speech contexts only while this flag is
          ;; non-nil.  The helper is never displayed, but it is the true text
          ;; source behind the visible PDF window.
          (setq-local english-reading-mode t)
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
  "Return the current one-based DocView page number."
  (if (fboundp 'doc-view-current-page)
      (max 1 (doc-view-current-page))
    1))

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

(defun english-reading-mode--pdf-sync ()
  "Ensure PDF text exists and synchronize it with the displayed page."
  (unless (buffer-live-p english-reading-mode--pdf-text-buffer)
    (english-reading-mode--pdf-extract-text))
  (let* ((count (english-reading-mode--pdf-page-count))
         (page (min (english-reading-mode--pdf-current-page) count)))
    (when (zerop count)
      (user-error "This PDF has no extractable text"))
    (unless (and english-reading-mode--pdf-page
                 (= page english-reading-mode--pdf-page))
      (setq english-reading-mode--pdf-page page
            english-reading-mode--pdf-text-point
            (english-reading-mode--pdf-page-start page)))
    english-reading-mode--pdf-text-buffer))

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
    (when (fboundp 'doc-view-goto-page)
      (doc-view-goto-page page))
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
         (end (nth 3 location)))
    (with-current-buffer text-buffer
      (kokoro-reader--speak-bounds beg end))))

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
  "Move to and read the preceding PDF sentence."
  (let* ((location (english-reading-mode--pdf-previous-location))
         (text-buffer (nth 1 location))
         (beg (nth 2 location))
         (end (nth 3 location)))
    (with-current-buffer text-buffer
      (kokoro-reader--speak-bounds beg end))))

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

(defun english-reading-mode--pdf-context-rectangles (context)
  "Return PDF-space highlight rectangles for speech CONTEXT."
  (let* ((page english-reading-mode--pdf-page)
         (geometry (english-reading-mode--pdf-bbox-page page))
         (words (plist-get geometry :words))
         (tokens (english-reading-mode--pdf-normalized-tokens
                  (plist-get context :text)))
         (starts (english-reading-mode--pdf-token-match-starts tokens words))
         (page-range (english-reading-mode--pdf-page-range page))
         (start (and starts
                     (english-reading-mode--pdf-nearest-match
                      starts (length words) (plist-get context :beg)
                      page-range))))
    (when start
      (list geometry
            (english-reading-mode--pdf-word-rectangles
             words start (length tokens))))))

(defun english-reading-mode--pdf-image-data-uri (image-file)
  "Return IMAGE-FILE as a cached PNG data URI."
  (unless (hash-table-p english-reading-mode--pdf-image-data-cache)
    (setq english-reading-mode--pdf-image-data-cache
          (make-hash-table :test #'equal)))
  (or (gethash image-file english-reading-mode--pdf-image-data-cache)
      (let ((uri
             (with-temp-buffer
               (set-buffer-multibyte nil)
               (insert-file-contents-literally image-file)
               (concat "data:image/png;base64,"
                       (base64-encode-string (buffer-string) t)))))
        (puthash image-file uri english-reading-mode--pdf-image-data-cache)
        uri)))

(defun english-reading-mode--pdf-svg-highlight (image geometry rectangles)
  "Return an SVG image spec containing IMAGE with highlighted RECTANGLES."
  (let* ((width (plist-get geometry :width))
         (height (plist-get geometry :height))
         (image-file (plist-get (cdr image) :file))
         (image-uri (english-reading-mode--pdf-image-data-uri image-file))
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
                         "rx='1.5' fill='%s' fill-opacity='%.3f' "
                         "stroke='%s' stroke-opacity='0.75' stroke-width='0.8'/>")
                 (- xmin 1.5) (- ymin 1.0)
                 (+ (- xmax xmin) 3.0) (+ (- ymax ymin) 2.0)
                 english-reading-mode-pdf-highlight-color
                 english-reading-mode-pdf-highlight-opacity
                 english-reading-mode-pdf-highlight-color)))
            rectangles "")
           "</g></svg>")))
    (apply #'create-image svg 'svg t
           (append (when display-width (list :width display-width))
                   (list :pointer 'arrow :transform-smoothing t)))))

(defun english-reading-mode--pdf-restore-image (pdf-buffer)
  "Restore PDF-BUFFER's normal DocView page image."
  (when (buffer-live-p pdf-buffer)
    (with-current-buffer pdf-buffer
      (when (and (derived-mode-p 'doc-view-mode)
                 (fboundp 'doc-view-current-overlay))
        (let ((overlay (doc-view-current-overlay))
              (image (doc-view-current-image))
              (slice (doc-view-current-slice)))
          (when (overlayp overlay)
            (overlay-put overlay 'display
                         (if slice (list (cons 'slice slice) image) image))))))))

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
        (condition-case err
            (when-let ((match
                        (english-reading-mode--pdf-context-rectangles context)))
              (let* ((overlay (doc-view-current-overlay))
                     (image (doc-view-current-image))
                     (highlight
                      (english-reading-mode--pdf-svg-highlight
                       image (car match) (cadr match)))
                     (slice (doc-view-current-slice)))
                (when (and (overlayp overlay) highlight)
                  (overlay-put overlay 'display
                               (if slice
                                   (list (cons 'slice slice) highlight)
                                 highlight)))))
          (error
           (message "PDF sentence highlight unavailable: %s"
                    (error-message-string err))))))))

(defun english-reading-mode--pdf-highlight-finish (context)
  "Remove the PDF highlight associated with speech CONTEXT."
  (let ((window (plist-get context :window)))
    (when (window-live-p window)
      (english-reading-mode--pdf-restore-image (window-buffer window)))))

(add-hook 'english-reading-mode-speech-start-hook
          #'english-reading-mode--pdf-highlight-start)
(add-hook 'english-reading-mode-speech-finish-hook
          #'english-reading-mode--pdf-highlight-finish)

(defun english-reading-mode--sentence-bounds ()
  "Return the sentence at point, or signal a user error."
  (or (bounds-of-thing-at-point 'sentence)
      (user-error "Place point in an English sentence")))

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

(defvar english-reading-mode--speech-watch-timer nil
  "Timer used to watch Kokoro request/playback lifetime.")

(defvar english-reading-mode--speech-start-time nil
  "Time when the active English-reading utterance was handed to Kokoro.")

(defvar english-reading-mode--speech-player-seen-p nil
  "Non-nil after the active utterance has reached actual audio playback.")

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
      (prog1
          (apply original-function beg end arguments)
        (setq english-reading-mode--active-speech context
              english-reading-mode--speech-start-time (current-time)
              english-reading-mode--speech-player-seen-p nil)
        (run-hook-with-args 'english-reading-mode-speech-start-hook context)
        ;; Do not infer completion from a request sentinel: Kokoro switches
        ;; from curl -> afplay at that boundary.  Poll the actual request/player
        ;; process variables and finish only when BOTH are no longer alive.
        (english-reading-mode--start-watch context)))))

(defun english-reading-mode--after-kokoro-stop (&rest _)
  "Finish the active context after an explicit/internal Kokoro stop."
  (when english-reading-mode--active-speech
    (english-reading-mode--finish english-reading-mode--active-speech)))

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
    (kokoro-reader--speak-bounds beg end)))

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
  "Move to the previous sentence and read it with Kokoro.

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
        (if moved
            (english-reading-mode--speak-at-point)
          (goto-char origin)
          (message "Already at the first sentence"))))))

(defun english-reading-mode-stop ()
  "Stop the current Kokoro reading."
  (interactive)
  (kokoro-reader-stop))

(defvar-keymap english-reading-mode-map
  :doc "Keymap for `english-reading-mode'."
  "k" '(menu-item "Read current sentence" english-reading-mode-speak-current-sentence
                   :filter english-reading-mode--filter-key-binding)
  "j" '(menu-item "Move to next sentence" english-reading-mode-next-sentence
                   :filter english-reading-mode--filter-key-binding)
  "i" '(menu-item "Read previous sentence" english-reading-mode-previous-sentence
                   :filter english-reading-mode--filter-key-binding)
;;  "" '(menu-item "Read paragraph" kokoro-reader-speak-paragraph
;;                   :filter english-reading-mode--filter-key-binding)
  "C-c C-k" '(menu-item "Stop reading" english-reading-mode-stop
                         :filter english-reading-mode--filter-key-binding))

;; Keep re-evaluation effective in a live Emacs where `defvar-keymap' preserves
;; the already existing map object.
(keymap-set english-reading-mode-map "k"
            '(menu-item "Read current sentence"
                        english-reading-mode-speak-current-sentence
                        :filter english-reading-mode--filter-key-binding))
(keymap-set english-reading-mode-map "j"
            '(menu-item "Move to next sentence"
                        english-reading-mode-next-sentence
                        :filter english-reading-mode--filter-key-binding))
(keymap-set english-reading-mode-map "i"
            '(menu-item "Read previous sentence"
                        english-reading-mode-previous-sentence
                        :filter english-reading-mode--filter-key-binding))
;;(keymap-set english-reading-mode-map "p"
;;            '(menu-item "Read paragraph" kokoro-reader-speak-paragraph
;;                        :filter english-reading-mode--filter-key-binding))
(keymap-set english-reading-mode-map "C-c C-k"
            '(menu-item "Stop reading" english-reading-mode-stop
                        :filter english-reading-mode--filter-key-binding))

;;;###autoload
(define-minor-mode english-reading-mode
  "Read English text or a DocView PDF one sentence at a time with Kokoro.

`j' reads the sentence at point without moving point.  `n' moves to the next
sentence without reading it.  `k' moves back and reads the previous sentence.
`p' reads the current paragraph without moving point.  The buffer is read-only
while this mode is active.  Speech lifecycle
is exposed through `english-reading-mode-speech-start-hook' and
`english-reading-mode-speech-finish-hook'."
  :lighter " EnglishRead"
  :keymap english-reading-mode-map
  (if english-reading-mode
      (progn
        (english-reading-mode--enable-single-space-sentences)
        (english-reading-mode--enable-read-only)
        (unless (or (derived-mode-p 'nov-mode 'eww-mode 'doc-view-mode)
                    (bound-and-true-p my-read-k-mode))
          (message "english-reading-mode is designed for reader buffers")))
    (english-reading-mode--restore-sentence-setting)
    (english-reading-mode--restore-read-only)
    (english-reading-mode--pdf-cleanup)
    (english-reading-mode-stop)))

(provide 'english-reading-mode)
;;; english-reading-mode.el ends here
