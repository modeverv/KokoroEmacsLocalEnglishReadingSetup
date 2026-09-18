;;; english-reading-pdf-view.el --- Pdf-view for sentence reading -*- lexical-binding: t; -*-

(declare-function pdf-view-display-image "pdf-view")
(declare-function pdf-view-create-page "pdf-view")
(declare-function pdf-cache-renderpage-highlight "pdf-cache")
(declare-function pdf-view-display-page "pdf-view")
(declare-function image-mode-window-put "image-mode")
(declare-function pdf-roll-set-vscroll "pdf-roll")
(declare-function pdf-roll-display-pages "pdf-roll")
(declare-function pdf-roll-page-to-pos "pdf-roll")
(declare-function pdf-roll-display-page "pdf-roll")
(declare-function pdf-view-image-size "pdf-view")
(declare-function pdf-view-image-offset "pdf-view")
(declare-function image-set-window-vscroll "image-mode")
(require 'english-reading-state)
(require 'dom)
(require 'seq)

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
                       (list :text (string-trim (dom-inner-text word))
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

(defun english-reading-mode--pdf-image-bytes (image)
  "Return the raw bytes represented by image spec IMAGE."
  (let* ((properties (cdr image))
         (data (plist-get properties :data))
         (file (plist-get properties :file)))
    (cond
     ((stringp data) data)
     ((stringp file)
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally file)
        (buffer-string)))
     (t nil))))

(defun english-reading-mode--png-width (data)
  "Return the pixel width encoded in PNG DATA, or nil if DATA is not PNG."
  (let ((bytes (and (stringp data) (encode-coding-string data 'raw-text))))
    (when (and bytes
               (>= (length bytes) 24)
               (= (aref bytes 0) #x89)
               (string-equal (substring bytes 1 8) "PNG\r\n\x1a\n"))
      (+ (ash (aref bytes 16) 24)
         (ash (aref bytes 17) 16)
         (ash (aref bytes 18) 8)
         (aref bytes 19)))))

(defun english-reading-mode--pdf-borderless-raster-highlight
    (image geometry rectangles)
  "Return IMAGE's PNG bytes with fill-only highlight RECTANGLES.

Return nil when ImageMagick or the source image bytes are unavailable.  This
keeps the stable native-raster PDF path while avoiding PDF Tools' mandatory
opaque stroke around every highlighted region."
  (when-let* ((program
               (executable-find english-reading-mode-pdf-highlight-program))
              (image-data (english-reading-mode--pdf-image-bytes image))
              (display-width (plist-get (cdr image) :width))
              (page-width (float (plist-get geometry :width)))
              ((> page-width 0)))
    (let* (;; pdf-tools commonly stores a Retina PNG whose raster is twice
           ;; DISPLAY-WIDTH.  ImageMagick draws in those native pixels, so
           ;; using the display width shifts and shrinks every rectangle.
           (raster-width
            (or (english-reading-mode--png-width image-data) display-width))
           (scale (/ raster-width page-width))
           (color-values
            (or (color-values english-reading-mode-pdf-highlight-color)
                '(65535 54613 20303)))
           (fill
            (format "rgba(%d,%d,%d,%.3f)"
                    (/ (nth 0 color-values) 257)
                    (/ (nth 1 color-values) 257)
                    (/ (nth 2 color-values) 257)
                    english-reading-mode-pdf-highlight-opacity))
           (draw
            (mapconcat
             (lambda (rectangle)
               (pcase-let ((`(,xmin ,ymin ,xmax ,ymax) rectangle))
                 (format "roundrectangle %.3f,%.3f %.3f,%.3f %.3f,%.3f"
                         (* scale (- xmin 1.5))
                         (* scale (- ymin 1.0))
                         (* scale (+ xmax 1.5))
                         (* scale (+ ymax 1.0))
                         (* scale 1.5) (* scale 1.5))))
             rectangles " "))
           (output (generate-new-buffer " *PDF borderless highlight*")))
      (unwind-protect
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert image-data)
            (when (zerop
                   (call-process-region
                    (point-min) (point-max) program nil output nil
                    "png:-" "-fill" fill "-stroke" "none"
                    "-draw" draw "png:-"))
              (with-current-buffer output
                (set-buffer-multibyte nil)
                (buffer-string))))
        (kill-buffer output)))))

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
      (if-let* ((overlay
                 (english-reading-mode--pdf-roll-page-overlay page window)))
          (let ((display-image
                 (if (fboundp 'pdf-roll-maybe-slice-image)
                     (pdf-roll-maybe-slice-image image window)
                   image)))
            (overlay-put overlay 'display display-image)
            (force-window-update window)
            display-image)
        (error "No pdf-roll page overlay for page %s" page))
    (pdf-view-display-image image page window)
    image))

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
          (or (english-reading-mode--pdf-borderless-raster-highlight
               page-image geometry rectangles)
              ;; Retain PDF Tools as a compatibility fallback on systems
              ;; without ImageMagick.  Its renderer always adds a stroke.
              (pdf-cache-renderpage-highlight
               page width
               (append (list english-reading-mode-pdf-highlight-color
                             english-reading-mode-pdf-highlight-color
                             english-reading-mode-pdf-highlight-opacity)
                       relative-rectangles))))
         (highlight-image
          (create-image highlight-data 'png t
                        :width width :pointer 'arrow)))
    ;; Update the page image itself so normal redisplay does not immediately
    ;; cover the speech highlight.
    (let ((display-image
           (english-reading-mode--pdf-view-display-image
            highlight-image page window)))
      (setq english-reading-mode--pdf-highlight-page page
            english-reading-mode--pdf-highlight-state
            (list :context context :mode 'pdf-view-mode
                  :page page :window window
                  :highlight-image highlight-image
                  :display-image display-image)))))

(defun english-reading-mode--pdf-highlight-current-display (state)
  "Return the image currently displayed for PDF highlight STATE."
  (let ((window (plist-get state :window))
        (page (plist-get state :page)))
    (when (window-live-p window)
      (if (bound-and-true-p pdf-view-roll-minor-mode)
          (when-let* ((overlay
                       (english-reading-mode--pdf-roll-page-overlay page window)))
            (overlay-get overlay 'display))
        (cadr (english-reading-mode--pdf-display-state window))))))

(defun english-reading-mode--run-pdf-highlight-watch (context)
  "Reapply CONTEXT's highlight if delayed PDF redisplay replaced it."
  (setq english-reading-mode--pdf-highlight-watch-timer nil)
  (let* ((window (plist-get context :window))
         (pdf-buffer (and (window-live-p window) (window-buffer window)))
         (state
          (and (buffer-live-p pdf-buffer)
               (with-current-buffer pdf-buffer
                 english-reading-mode--pdf-highlight-state))))
    (if (not (and (eq context english-reading-mode--active-speech)
                  (eq context english-reading-mode--pdf-highlight-watch-context)
                  (eq context (plist-get state :context))))
        (english-reading-mode--cancel-pdf-highlight context)
      (with-current-buffer pdf-buffer
        (unless (equal (english-reading-mode--pdf-highlight-current-display state)
                       (plist-get state :display-image))
          (let ((display-image
                 (english-reading-mode--pdf-view-display-image
                  (plist-get state :highlight-image)
                  (plist-get state :page) window)))
            (setq english-reading-mode--pdf-highlight-state
                  (plist-put state :display-image display-image)))))
      (cl-decf english-reading-mode--pdf-highlight-watch-remaining)
      (if (> english-reading-mode--pdf-highlight-watch-remaining 0)
          (setq english-reading-mode--pdf-highlight-watch-timer
                (run-at-time english-reading-mode-pdf-highlight-delay nil
                             #'english-reading-mode--run-pdf-highlight-watch
                             context))
        (setq english-reading-mode--pdf-highlight-watch-context nil)))))

(defun english-reading-mode--start-pdf-highlight-watch (context)
  "Briefly protect CONTEXT's highlight from delayed PDF redisplay."
  (let* ((window (plist-get context :window))
         (pdf-buffer (and (window-live-p window) (window-buffer window)))
         (state
          (and (buffer-live-p pdf-buffer)
               (with-current-buffer pdf-buffer
                 english-reading-mode--pdf-highlight-state))))
    (when (eq context (plist-get state :context))
      (when (timerp english-reading-mode--pdf-highlight-watch-timer)
        (cancel-timer english-reading-mode--pdf-highlight-watch-timer))
      (setq english-reading-mode--pdf-highlight-watch-context context
            english-reading-mode--pdf-highlight-watch-remaining
            (max 1 (ceiling english-reading-mode-pdf-highlight-watch-duration
                            (max english-reading-mode-pdf-highlight-delay
                                 0.001)))
            english-reading-mode--pdf-highlight-watch-timer
            (run-at-time english-reading-mode-pdf-highlight-delay nil
                         #'english-reading-mode--run-pdf-highlight-watch
                         context)))))

(defun english-reading-mode--pdf-restore-image
    (pdf-buffer &optional _window context)
  "Restore PDF-BUFFER's normal page image in its saved window.

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
            (when-let* ((match
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
            (eq context english-reading-mode--pdf-highlight-pending-context)
            (eq context english-reading-mode--pdf-highlight-watch-context))
    (when (timerp english-reading-mode--pdf-highlight-timer)
      (cancel-timer english-reading-mode--pdf-highlight-timer))
    (when (timerp english-reading-mode--pdf-highlight-watch-timer)
      (cancel-timer english-reading-mode--pdf-highlight-watch-timer))
    (setq english-reading-mode--pdf-highlight-timer nil
          english-reading-mode--pdf-highlight-pending-context nil
          english-reading-mode--pdf-highlight-pending-scroll-state nil
          english-reading-mode--pdf-highlight-watch-timer nil
          english-reading-mode--pdf-highlight-watch-context nil
          english-reading-mode--pdf-highlight-watch-remaining 0)))

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
              (english-reading-mode--pdf-highlight-start context)
              (english-reading-mode--start-pdf-highlight-watch context))
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

Prefer the exact rectangle used by the speech highlight, so scrolling places
that visible rectangle at the configured screen position.  Fall back to
CONTEXT's relative source-text position only when PDF word matching fails."
  (let* ((page-range
          (and (integerp english-reading-mode--pdf-page)
               (english-reading-mode--pdf-page-range
                english-reading-mode--pdf-page)))
         (span (and page-range
                    (max 1 (- (cdr page-range) (car page-range)))))
         (source-beg (plist-get context :beg))
         (geometry
          (and page-range
               (numberp source-beg)
               (english-reading-mode--pdf-bbox-page
                english-reading-mode--pdf-page))))
    (or (when-let* ((match
                     (english-reading-mode--pdf-context-rectangles context)))
          (list (car match) (car (cadr match))))
        (when (and geometry page-range (numberp source-beg))
          (let* ((ratio
                  (max 0.0
                       (min 1.0
                            (/ (float (- source-beg (car page-range))) span))))
                 (y (* ratio (plist-get geometry :height))))
            (list geometry (list 0.0 y 0.0 y)))))))

(defun english-reading-mode--pdf-roll-set-position (page vscroll window)
  "Atomically show PAGE at VSCROLL in roll-mode WINDOW."
  ;; `pdf-view-current-page' is a macro whose SETF expansion is unavailable
  ;; when this file is reloaded before pdf-macs.  Write the underlying
  ;; image-mode window property directly, as pdf-roll does for vscroll.
  (image-mode-window-put 'page page window)
  ;; Determine visible pages using the destination offset.  At a boundary,
  ;; the old offset can leave the next visible page as a placeholder until
  ;; another redisplay pass (or the next speech chunk) repairs it.
  (pdf-roll-set-vscroll vscroll window)
  (pdf-roll-display-pages page window)
  (set-window-start window (pdf-roll-page-to-pos page) t)
  (force-window-update window))

(defun english-reading-mode--pdf-roll-target-position
    (page spoken-pixel anchor-pixel window)
  "Return roll page and vscroll placing speech at ANCHOR-PIXEL.

PAGE and SPOKEN-PIXEL identify the highlighted speech rectangle.  Normalize
the result across page boundaries so the bottom of the preceding page remains
visible while speech near the next page's head reaches the configured anchor."
  (let* ((target-page page)
         (offset (- spoken-pixel anchor-pixel))
         (page-count (english-reading-mode--pdf-page-count))
         (margin (if (boundp 'pdf-roll-vertical-margin)
                     pdf-roll-vertical-margin
                   0)))
    (while (and (< offset 0) (> target-page 1))
      (setq target-page (1- target-page)
            offset (+ offset
                      (pdf-roll-display-page target-page window)
                      margin)))
    (let ((page-height (pdf-roll-display-page target-page window)))
      (while (and (< target-page page-count)
                  (>= offset (+ page-height margin)))
        (setq offset (- offset page-height margin)
              target-page (1+ target-page)
              page-height (pdf-roll-display-page target-page window)))
      (list target-page
            (min (max 0 (round offset)) (max 0 (1- page-height)))))))

(defun english-reading-mode--pdf-roll-position-spoken
    (page spoken-pixel anchor-pixel source-beg window)
  "Move forward so PAGE's SPOKEN-PIXEL appears at ANCHOR-PIXEL in WINDOW.

SOURCE-BEG identifies the ordered speech context.  Compare against the last
canonical roll position stored in the continuous-reading state rather than
`pdf-view-current-page', whose meaning changes while roll mode normalizes a
page boundary.  Return the applied canonical position, or nil when the PDF
rectangle or callback moves backward."
  (pcase-let* ((`(,target-page ,target-vscroll)
                (english-reading-mode--pdf-roll-target-position
                 page spoken-pixel anchor-pixel window))
               (last-page
                (plist-get english-reading-mode--continuous-state
                           :pdf-roll-page))
               (last-vscroll
                (plist-get english-reading-mode--continuous-state
                           :pdf-roll-pixel))
               (last-source-beg
                (plist-get english-reading-mode--continuous-state
                           :pdf-roll-source-beg)))
    (when (and (or (not (numberp last-source-beg))
                   (>= source-beg last-source-beg))
               (or (not (integerp last-page))
                   (> target-page last-page)
                   (and (= target-page last-page)
                        (or (not (numberp last-vscroll))
                            (> target-vscroll last-vscroll)))))
      ;; Always restore the canonical window start together with its vscroll.
      ;; Updating only vscroll lets pdf-roll reinterpret the same viewport as
      ;; the next page and produces an apparent jump on the following chunk.
      (english-reading-mode--pdf-roll-set-position
       target-page target-vscroll window)
      (list target-page target-vscroll))))

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
              (when-let* ((position
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
                               (fboundp 'pdf-roll-display-page)
                               (fboundp 'pdf-roll-display-pages)
                               (fboundp 'pdf-roll-page-to-pos)
                               (fboundp 'pdf-roll-set-vscroll))
                          ;; Recompute an absolute roll position from the exact
                          ;; highlight rectangle for every utterance.  This
                          ;; prevents estimated relative deltas from drifting
                          ;; away from the configured screen anchor.
                          (let* ((page english-reading-mode--pdf-page)
                                 (page-height
                                  (pdf-roll-display-page page window))
                                 (spoken-y
                                  (/ (+ (nth 1 rectangle) (nth 3 rectangle))
                                     2.0))
                                 (spoken-pixel
                                  (round (* (/ spoken-y
                                               (plist-get geometry :height))
                                            page-height))))
                            (when-let* ((applied
                                         (english-reading-mode--pdf-roll-position-spoken
                                          page spoken-pixel
                                          (english-reading-mode--pdf-speech-anchor-pixel
                                           viewport-height)
                                          (plist-get context :beg)
                                          window)))
                              (setq english-reading-mode--continuous-state
                                    (plist-put
                                     (plist-put
                                      (plist-put
                                       english-reading-mode--continuous-state
                                       :pdf-roll-page (car applied))
                                      :pdf-roll-pixel (cadr applied))
                                     :pdf-roll-source-beg
                                     (plist-get context :beg)))))
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

;; PDF visuals are managed by the speech advice.  Remove former start-hook
;; registrations as well so a live `load-file' upgrades an already running
;; reader without doing the work twice.
(remove-hook 'english-reading-mode-speech-start-hook
             #'english-reading-mode--pdf-highlight-start)

(remove-hook 'english-reading-mode-speech-start-hook
             #'english-reading-mode--pdf-center-continuous-speech)

(add-hook 'english-reading-mode-speech-finish-hook
          #'english-reading-mode--pdf-highlight-finish)

(provide 'english-reading-pdf-view)
;;; english-reading-pdf-view.el ends here
