;;; my-read.el --- Dedicated English reading frame -*- lexical-binding: t; -*-

;; English reading workspace:
;;   left         : Kindle.app, PDF, EPUB, EWW, and DIRED tabs
;;   right top    : Org-noter notes
;;   right middle : local translation with Google fallback
;;   right bottom : Lookup
;;
;; Translation policy:
;;   - j/k and Kokoro lifecycle are owned by english-reading-mode.el
;;   - while Kokoro is reading: lock translation to the exact spoken text
;;   - point may already move to the next sentence; the lock remains
;;   - when playback finishes/stops/fails: resume sentence-at-point translation

(require 'cl-lib)
(require 'color)
(require 'json)
(require 'org)
(require 'thingatpt)
(require 'subr-x)
(require 'google-translate-core)

(add-to-list 'load-path (expand-file-name "~/Sync/emacs.d/reader"))
(require 'kokoro-reader)
(require 'english-reading-mode)

;; `my-read' treats PDF Tools as the canonical PDF viewer.  Keep this here as
;; well as in init.el so a PDF never falls back to a raw binary buffer when
;; this module is loaded independently.
(autoload 'pdf-view-mode "pdf-view" nil t)
(autoload 'pdf-view-roll-minor-mode "pdf-roll" nil t)
(add-to-list 'auto-mode-alist '("\\.pdf\\'" . pdf-view-mode))

(defgroup my-read nil
  "Dedicated English reading workspace."
  :group 'convenience)

(defcustom my/read-book-path
  "/Users/seijiro/Library/Mobile Documents/iCloud~md~obsidian/Documents/seijiro/000_org/einglish-book"
  "File or directory opened in the center reading window."
  :type 'file
  :group 'my-read)

(defcustom my/read-position-directory
  "/Users/seijiro/Library/Mobile Documents/iCloud~md~obsidian/Documents/seijiro/000_org/read"
  "Directory where PDF and EPUB reading positions are stored."
  :type 'directory
  :group 'my-read)

(defcustom my/read-position-save-delay 1.0
  "Idle seconds before saving the current PDF or EPUB position."
  :type 'number
  :group 'my-read)

(defcustom my/read-pdf-continuous-scroll t
  "When non-nil, show my-read PDFs as a vertically continuous page roll.

This uses PDF Tools' `pdf-view-roll-minor-mode', so pages are rendered lazily
around the visible area instead of loading the entire document at once."
  :type 'boolean
  :group 'my-read)

(defconst my/read-position-file-name "read-positions.el"
  "File name used below `my/read-position-directory'.")

(defvar-local my/read-position--restored-p nil)
(defvar-local my/read-position--restoring-p nil)
(defvar-local my/read-position--save-timer nil)

(defcustom my/read-vocabulary-file
  (expand-file-name "~/my-read/vocabulary.org")
  "Org file used as the canonical my-read vocabulary store."
  :type 'file
  :group 'my-read)

(defcustom my/read-vocab-english-dictionary-title-regexp
  "\\`English\\'\\|英英\\|英語辞典"
  "Regexp matching Lookup dictionary titles used for English definitions."
  :type 'regexp
  :group 'my-read)

(defcustom my/read-vocab-japanese-dictionary-title-regexp
  "Japanese[[:space:]]*-[[:space:]]*English\\|英和\\|和英"
  "Regexp matching Lookup dictionary titles used for Japanese meanings."
  :type 'regexp
  :group 'my-read)

(defcustom my/read-frame-name "my-read"
  "Base name of a frame created by `my-read'."
  :type 'string
  :group 'my-read)

(defcustom my/read-eww-url "https://arxiv.org/"
  "Initial URL offered by the EWW center tab."
  :type 'string
  :group 'my-read)

(defcustom my/read-eww-history-file
  (expand-file-name "eww-history.el" my/read-position-directory)
  "File storing URLs rendered in the my-read EWW tab."
  :type 'file
  :group 'my-read)

(defcustom my/read-eww-history-limit 100
  "Maximum number of recent EWW URLs retained by my-read."
  :type 'integer
  :group 'my-read)

(defcustom my/read-eww-enable-automatic-lookup nil
  "When non-nil, run automatic Lookup in the EWW center tab.

This is disabled by default because EWW briefly exposes status words such as
\"Loading\" while navigating.  Sending those transient words to a synchronous
Lookup dictionary process can block Emacs even though EWW itself is responsive.
Automatic translation remains enabled in EWW."
  :type 'boolean
  :group 'my-read)

(defcustom my/read-eww-line-spacing 0.5
  "Additional line spacing used in the EWW center tab.

A floating-point value is relative to the default frame line height, so 0.5
makes the distance from one baseline to the next approximately 1.5 times the
normal height."
  :type '(choice (const :tag "No extra spacing" nil) number)
  :group 'my-read)

(defcustom my/read-eww-article-image-background "#f5f5f5"
  "Background color used behind arXiv article figures in EWW.

Many paper figures have transparent pixels and otherwise inherit the dark
reader background.  This only affects images served from an arXiv HTML paper;
formula SVGs, site icons, and logos keep their existing appearance."
  :type 'color
  :group 'my-read)

(defcustom my/read-eww-image-convert-program "magick"
  "ImageMagick executable used to flatten transparent raster figures."
  :type 'string
  :group 'my-read)

(defcustom my/read-eww-svg-raster-program "rsvg-convert"
  "Executable used to rasterize complex arXiv SVG figures once."
  :type 'string
  :group 'my-read)

(defcustom my/read-eww-article-svg-max-width 720
  "Maximum raster width in pixels for arXiv article SVG figures.

Figures are fitted to 95 percent of the current EWW window, up to this width.
This avoids expensive native SVG redraws while keeping the entire figure
visible.  Formula SVGs, site icons, raster figures, and logos are not affected."
  :type 'integer
  :group 'my-read)

(defvar-local my/read--eww-image-background-installed-p nil)
(defvar-local my/read-eww-history-page-p nil)
(defconst my/read--eww-image-background-version "v6")

(defun my/read--eww-arxiv-article-image-url-p (url)
  "Return non-nil when URL names an image inside an arXiv HTML paper."
  (and (stringp url)
       (string-match-p
        (concat "\\`https://\\(?:www\\.\\)?arxiv\\.org/html/[^/]+/.+"
                "\\.\\(?:png\\|jpe?g\\|svg\\)\\(?:[?#].*\\)?\\'")
        url)))

(defun my/read--eww-svg-with-background (data color)
  "Return SVG DATA with a COLOR rectangle behind its existing content."
  (if (not (stringp data))
      data
    (let* ((numbers
            (when (string-match
                   "viewBox=['\"]\\([^'\"]+\\)['\"]" data)
              (split-string (match-string 1 data) "[ ,]+" t)))
           (rectangle
            (if (= (length numbers) 4)
                (format
                 (concat "<rect id='my-read-eww-background'"
                         " x='%s' y='%s' width='%s' height='%s' fill='%s'/>")
                 (nth 0 numbers) (nth 1 numbers)
                 (nth 2 numbers) (nth 3 numbers) color)
              (format
               (concat "<rect id='my-read-eww-background' x='0' y='0'"
                       " width='100%%' height='100%%' fill='%s'/>")
               color))))
      (cond
       ((string-match
         "<rect id=['\"]my-read-eww-background['\"][^>]*/>" data)
        (replace-match rectangle t t data))
       ((string-match "<svg\\(?:.\\|\n\\)*?>" data)
        (concat (substring data 0 (match-end 0))
                rectangle
                (substring data (match-end 0))))
       (t data)))))

(defun my/read--eww-flatten-raster-background (data color)
  "Composite transparent raster DATA over COLOR using ImageMagick."
  (when-let* ((program (executable-find my/read-eww-image-convert-program)))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert data)
      (let ((coding-system-for-read 'binary)
            (coding-system-for-write 'binary))
        (when (= (call-process-region
                  (point-min) (point-max) program t (list t nil) nil
                  "-" "-background" color "-alpha" "remove" "-alpha" "off"
                  "png:-")
                 0)
          (buffer-string))))))

(defun my/read--eww-article-svg-target-width ()
  "Return a raster width that fits the current EWW window."
  (let ((window (get-buffer-window (current-buffer) t)))
    (min my/read-eww-article-svg-max-width
         (if (window-live-p window)
             (max 1 (floor (* 0.95 (window-body-width window t))))
           my/read-eww-article-svg-max-width))))

(defun my/read--eww-article-svg-display-scale ()
  "Return the scale that displays rasterized SVGs at logical pixel size."
  (let* ((window (get-buffer-window (current-buffer) t))
         (factor (if (and (window-live-p window)
                          (fboundp 'frame-scale-factor))
                     (frame-scale-factor (window-frame window))
                   1.0)))
    (/ 1.0 (max 1.0 factor))))

(defun my/read--eww-rasterize-svg (data color)
  "Rasterize SVG DATA once over COLOR and return PNG data.

Using librsvg here prevents Emacs from repeatedly rendering large, complex
paper SVGs whenever their display rows enter the window."
  (when-let* ((program (executable-find my/read-eww-svg-raster-program))
              ((stringp data)))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert (encode-coding-string data 'utf-8 t))
      (let ((coding-system-for-read 'binary)
            (coding-system-for-write 'binary))
        (when (= (call-process-region
                  (point-min) (point-max) program t (list t nil) nil
                  "--width"
                  (number-to-string (my/read--eww-article-svg-target-width))
                  "--keep-aspect-ratio"
                  "--background-color" color "--format" "png" "-")
                 0)
          (buffer-string))))))

(defun my/read--eww-image-with-background (display)
  "Return article image DISPLAY composited over the configured background."
  (let* ((properties (copy-sequence (cdr display)))
         (type (plist-get properties :type))
         (data (plist-get properties :data))
         (color my/read-eww-article-image-background)
         output-type
         (output-scale 'default)
         updated-data)
    (cond
     ((eq type 'svg)
      (setq updated-data (my/read--eww-rasterize-svg data color))
      (if updated-data
          (setq output-type 'png
                output-scale (my/read--eww-article-svg-display-scale))
        ;; Keep the fallback cheap: an enlarged native SVG can freeze Emacs
        ;; for seconds each time it is scrolled into view.
        (setq updated-data (my/read--eww-svg-with-background data color)
              output-type 'svg)))
     ((and (memq type '(png imagemagick)) (stringp data))
      (setq updated-data
            (my/read--eww-flatten-raster-background data color)
            output-type 'png)))
    (if updated-data
        (progn
          (setq properties (plist-put properties :data updated-data))
          (setq properties (plist-put properties :type output-type))
          ;; The zoom is baked into PNG data.  Never scale a native fallback.
          (setq properties (plist-put properties :scale output-scale))
          (cons 'image properties))
      ;; This is a best-effort fallback for systems without ImageMagick.
      (cons 'image (plist-put properties :background color)))))

(defun my/read--eww-apply-article-image-background (&optional begin end &rest _)
  "Apply the configured light background to this buffer's paper figures."
  (when (and my/read--eww-image-background-installed-p
             (derived-mode-p 'eww-mode))
    (let ((position (or (and begin (marker-position begin)) (point-min)))
          (limit (or (and end (marker-position end)) (point-max)))
          (changed 0)
          (inhibit-read-only t)
          (inhibit-modification-hooks t))
      (save-excursion
        (setq position (max (point-min) position)
              limit (min (point-max) (max position limit)))
        (while (< position limit)
          (let* ((next (next-single-property-change
                        position 'display nil limit))
                 (display (get-text-property position 'display))
                 (url (get-text-property position 'image-url))
                 (applied (get-text-property
                           position 'my/read-eww-image-background))
                 (application-token
                 (list my/read--eww-image-background-version
                        my/read-eww-article-image-background
                        (my/read--eww-article-svg-target-width)
                        (my/read--eww-article-svg-display-scale)
                        my/read-eww-svg-raster-program)))
            (when (and (consp display)
                       (eq (car display) 'image)
                       (not (equal applied application-token))
                       (my/read--eww-arxiv-article-image-url-p url))
              (let ((updated (my/read--eww-image-with-background display)))
                (unless (equal display updated)
                  (put-text-property position next 'display updated)
                  (put-text-property
                   position next 'my/read-eww-image-background
                   application-token)
                  (cl-incf changed))))
            (setq position next))))
      (when (> changed 0)
        (force-window-update (current-buffer)))
      changed)))

(defun my/read--eww-after-image-fetched
    (_status buffer _start _end &optional _flags)
  "Apply the article background after SHR downloads an image into BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when my/read--eww-image-background-installed-p
        ;; The placeholder may already have been marked by the render hook.
        ;; Clear only this fetched image's marker, then process its real data.
        (let ((inhibit-read-only t)
              (begin-position (marker-position _start))
              (end-position (marker-position _end)))
          (when (and begin-position end-position
                     (< begin-position end-position))
            (remove-text-properties
             begin-position end-position
             '(my/read-eww-image-background nil))))
        (my/read--eww-apply-article-image-background _start _end)))))

(defun my/read--eww-image-background-setup ()
  "Enable light arXiv article-image backgrounds in the current EWW buffer."
  (setq-local my/read--eww-image-background-installed-p t)
  (add-hook 'eww-after-render-hook
            #'my/read--eww-apply-article-image-background nil t)
  (unless (advice-member-p #'my/read--eww-after-image-fetched
                           'shr-image-fetched)
    (advice-add 'shr-image-fetched :after
                #'my/read--eww-after-image-fetched))
  (my/read--eww-apply-article-image-background))

(defcustom my/read-translate-idle-delay 0.1
  "Seconds to wait before translating after the target changes."
  :type 'number
  :group 'my-read)

(defcustom my/read-translation-backend 'google
  "Translation backend used by my-read.
`local' uses the Ollama-compatible endpoint and falls back to Google Translate
when `my/read-google-translation-fallback' is non-nil.  `google' uses Google
Translate directly."
  :type '(choice (const :tag "Local with Google fallback" local)
                 (const :tag "Google Translate" google))
  :group 'my-read)

(defcustom my/read-local-translation-url
  "http://127.0.0.1:11434/api/chat"
  "Ollama-compatible endpoint used for local translation."
  :type 'string
  :group 'my-read)

(defcustom my/read-local-translation-model "translategemma:4b"
  "Ollama model used for local translation."
  :type 'string
  :group 'my-read)

(defcustom my/read-local-translation-timeout 60
  "Maximum seconds to wait for local translation before falling back."
  :type 'integer
  :group 'my-read)

(defcustom my/read-google-translation-fallback t
  "When non-nil, use Google Translate if local translation fails."
  :type 'boolean
  :group 'my-read)

(defcustom my/read-translate-overlay-opacity 0.35
  "Visual opacity of the translation overlay against the theme background.

Emacs faces do not reliably support alpha transparency, so my-read blends its
blue overlay color with each frame's default background.  Values near 0 are
more transparent; 1 is fully opaque."
  :type '(float :tag "Opacity" :value 0.35)
  :group 'my-read)

(defcustom my/read-japanese-translation-target-language "en"
  "Translation target language used for Japanese reading sources."
  :type 'string
  :group 'my-read)

(defcustom my/read-japanese-macos-voice "Kyoko"
  "macOS voice used when a center-pane EPUB or PDF contains Japanese text.

Japanese EPUB/PDF speech deliberately uses macOS while the optional Kokoro
Japanese frontend is unavailable, so opening a Japanese document never leaves
the extracted text configured with an English Kokoro voice."
  :type '(choice (const :tag "System default" nil) string)
  :group 'my-read)

(defcustom my/read-japanese-macos-rate 540
  "Speaking rate used for Japanese EPUBs and PDFs, in words per minute.

This is three times the normal `kokoro-reader-macos-rate' default of 180."
  :type 'integer
  :group 'my-read)

(defcustom my/read-lookup-dictionary-ids
  '("nmacos"
    "ndeb+~/Sync/004_dic/ee/:simpleen"
    "ndeb+~/Sync/004_dic/chujisnd/"
    "ndspell")
  "Lookup dictionary IDs used only by my-read and my-read-k.

Each string may be a complete dictionary ID or an ID prefix.  For example,
`nmacos' selects all macOS Dictionary agents, while a complete NDEB ID selects
one dictionary.  An empty list disables Lookup searches in reading frames;
it never falls back to Lookup's full default module.  Changing this option
rebuilds the private module automatically on the next search."
  :type '(repeat string)
  :group 'my-read)

(defcustom my/read-lookup-idle-delay 0.12
  "Seconds to wait before looking up the word at point in my-read."
  :type 'number
  :group 'my-read)

(defcustom my/read-lookup-entry-window-height 4
  "Height in lines of the Lookup dictionary-entry list in my-read.

This frame-local value takes precedence over the normal
`lookup-window-height'.  Keeping it as a small integer prevents a fractional
global setting from shrinking the dictionary content window."
  :type 'integer
  :group 'my-read)

(defconst my/read-translate-buffer-name "*Reading Translation*")

(defface my/read-translate-overlay-face
  '((t (:extend t)))
  "Background-only face for the current translation target.

Font and foreground attributes are deliberately left unspecified so EPUB
styling remains unchanged while the target overlay moves through the book."
  :group 'my-read)

(defvar my/read-lookup-timer nil)
(defvar my/read-lookup-last-target nil)
(defvar my/read-lookup-running-p nil)
(defvar my/read--lookup-module nil)
(defvar my/read--lookup-module-signature nil)

(defvar my/read-translate-timer nil)
(defvar my/read-translate-process nil)
(defvar my/read-translate-last-target nil)
(defvar my/read-kokoro-context nil
  "English-reading speech context currently locking translation.

While this is non-nil, point may already be on the next sentence, but
translation remains pinned to CONTEXT's :text until the matching finish event.")
(defvar my/read-speech-translation-suppressed-context nil
  "Non-English speech context currently suppressing automatic translation.")

(defvar-local my/read-source-language nil
  "Detected source language for the current reading buffer, or nil.")

(defvar-local my/read-center-tab-frame nil
  "my-read frame owning this center-tab buffer.")

(defvar-local my/read-center-tab-placeholder-type nil
  "Source type represented by this empty fixed-tab placeholder.")



;;; ---------------------------------------------------------------------------
;;; Frame / window helpers
;;; ---------------------------------------------------------------------------

(defun my/read-frame-p (&optional frame)
  "Return non-nil when FRAME is a frame created by `my-read'."
  (frame-parameter (or frame (selected-frame)) 'my-reading-frame))

(defun my/read-window (parameter &optional frame)
  "Return live window stored in FRAME PARAMETER, or nil."
  (let ((window (frame-parameter (or frame (selected-frame)) parameter)))
    (and (window-live-p window) window)))

(defun my/read-lookup-window (&optional frame)
  "Return FRAME's Lookup window."
  (my/read-window 'my-reading-lookup-window frame))

(defun my/read-center-windows (&optional frame)
  "Return all live center reading windows belonging to FRAME."
  (let* ((frame (or frame (selected-frame)))
         (windows (frame-parameter frame 'my-reading-center-windows)))
    (or (delq nil (mapcar (lambda (window)
                            (and (window-live-p window) window))
                          windows))
        (when-let ((window (my/read-window 'my-reading-center-window frame)))
          (list window)))))

(defun my/read-center-window (&optional frame)
  "Return the active center reading window in FRAME.
The Kindle, PDF, EPUB, EWW, and DIRED sources share one window as tabs."
  (let* ((frame (or frame (selected-frame)))
         (windows (my/read-center-windows frame))
         (selected (and (eq frame (selected-frame)) (selected-window))))
    (if (memq selected windows)
        selected
      (car windows))))

(defun my/read-center-window-for-buffer (frame buffer)
  "Return FRAME's center window displaying BUFFER, or its active center."
  (or (cl-find-if (lambda (window)
                    (eq (window-buffer window) buffer))
                  (my/read-center-windows frame))
      (my/read-center-window frame)))

(defun my/read-kindle-window (&optional frame)
  "Return FRAME's center window hosting the Kindle.app tab."
  (my/read-window 'my-reading-kindle-window frame))

(defun my/read-epub-window (&optional frame)
  "Return FRAME's center window hosting the EPUB tab."
  (my/read-window 'my-reading-epub-window frame))

(defun my/read-pdf-window (&optional frame)
  "Return FRAME's center window hosting the PDF tab."
  (my/read-window 'my-reading-pdf-window frame))

(defun my/read-dired-window (&optional frame)
  "Return FRAME's center window hosting the persistent DIRED tab."
  (my/read-window 'my-reading-dired-window frame))

(defun my/read-position-file ()
  "Return the persistent PDF/EPUB position file."
  (expand-file-name my/read-position-file-name my/read-position-directory))

(defun my/read-position--source-type ()
  "Return the persistent source type for the current buffer."
  (cond
   ((derived-mode-p 'pdf-view-mode) 'pdf)
   ((derived-mode-p 'nov-mode) 'epub)))

(defun my/read-position--source-file ()
  "Return a stable absolute source file for the current buffer."
  (when-let ((file (and (my/read-position--source-type)
                        (or (and (boundp 'nov-file-name) nov-file-name)
                            buffer-file-name))))
    (condition-case nil
        (file-truename file)
      (file-error (expand-file-name file)))))

(defun my/read-position--empty-data ()
  "Return an empty position data object."
  '(:version 1 :entries nil))

(defun my/read-position--valid-data-p (data)
  "Return non-nil when DATA is a valid position data object."
  (and (listp data)
       (equal (plist-get data :version) 1)
       (let ((entries (plist-get data :entries)))
         (and (listp entries)
              (cl-every (lambda (entry)
                          (and (consp entry)
                               (stringp (car entry))
                               (listp (cdr entry))))
                        entries)))))

(defun my/read-position--read-data ()
  "Read persistent position data, or return `:invalid' without modifying it."
  (let ((file (my/read-position-file)))
    (if (not (file-exists-p file))
        (my/read-position--empty-data)
      (condition-case err
          (with-temp-buffer
            (insert-file-contents file)
            (let ((read-eval nil)
                  (data (read (current-buffer))))
              (skip-chars-forward " \t\r\n")
              (unless (and (eobp) (my/read-position--valid-data-p data))
                (error "invalid position data"))
              data))
        (error
         (message "my-read: 読書位置ファイルを保護しました（%s）"
                  (error-message-string err))
         :invalid)))))

(defun my/read-position--write-data (data)
  "Atomically write validated position DATA."
  (let* ((directory (file-name-as-directory my/read-position-directory))
         (file (my/read-position-file))
         temp)
    (make-directory directory t)
    (setq temp (make-temp-file (expand-file-name ".read-positions-" directory)))
    (unwind-protect
        (progn
          (with-temp-buffer
            (insert ";;; my-read PDF/EPUB positions -*- mode: emacs-lisp; -*-\n")
            (let ((print-length nil)
                  (print-level nil))
              (prin1 data (current-buffer)))
            (insert "\n")
            (write-region (point-min) (point-max) temp nil 'silent))
          (set-file-modes temp #o600)
          (rename-file temp file t)
          (setq temp nil))
      (when (and temp (file-exists-p temp))
        (delete-file temp)))))

(defun my/read-position--snapshot (&optional window)
  "Return the current PDF or EPUB position, using WINDOW when available."
  (pcase (my/read-position--source-type)
    ('pdf
     (let ((record
            (list :type 'pdf
                  :page (and (fboundp 'pdf-view-current-page)
                             (ignore-errors (pdf-view-current-page)))
                  :zoom (and (boundp 'pdf-view-display-size)
                             pdf-view-display-size))))
       (when (and (window-live-p window)
                  (eq (window-buffer window) (current-buffer)))
         (setq record
               (plist-put record :vscroll (window-vscroll window t))))
       record))
    ('epub
     (let* ((visible (and (window-live-p window)
                          (eq (window-buffer window) (current-buffer))))
            (position (if visible (window-point window) (point)))
            (record
             (list :type 'epub
                   :document (and (boundp 'nov-documents-index)
                                  nov-documents-index)
                   :point position)))
       (when visible
         (setq record (plist-put record :window-start
                                 (window-start window))))
       record))))

(defun my/read-position--merge-record (old new)
  "Merge non-nil values from NEW into position record OLD."
  (let ((record (copy-sequence old)))
    (while new
      (let ((key (pop new))
            (value (pop new)))
        (when value
          (setq record (plist-put record key value)))))
    (plist-put record :updated (float-time))))

(defun my/read-position-save-buffer (buffer &optional window)
  "Persist BUFFER's current PDF or EPUB position, optionally using WINDOW."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when-let* ((key (and (not my/read-position--restoring-p)
                            (my/read-position--source-file)))
                  (snapshot (my/read-position--snapshot window)))
        (let ((data (my/read-position--read-data)))
          (unless (eq data :invalid)
            (let* ((entries (copy-tree (plist-get data :entries)))
                   (old (cdr (assoc-string key entries t)))
                   (record (my/read-position--merge-record old snapshot)))
              (setq entries (cons (cons key record)
                                  (cl-remove key entries
                                             :key #'car :test #'string-equal)))
              (setq entries (sort entries
                                  (lambda (a b) (string-lessp (car a) (car b)))))
              (my/read-position--write-data
               (list :version 1 :entries entries)))))))))

(defun my/read-position--save-buffer-now ()
  "Save the current reading buffer immediately."
  (when (timerp my/read-position--save-timer)
    (cancel-timer my/read-position--save-timer))
  (setq my/read-position--save-timer nil)
  (my/read-position-save-buffer
   (current-buffer) (get-buffer-window (current-buffer) t)))

(defun my/read-position--idle-save (buffer)
  "Save BUFFER after the configured idle delay."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq my/read-position--save-timer nil)
      (my/read-position-save-buffer
       buffer (get-buffer-window buffer t)))))

(defun my/read-position--schedule-save ()
  "Schedule a debounced position save for the current reading buffer."
  (when (and (my/read-position--source-type)
             (not my/read-position--restoring-p))
    (when (timerp my/read-position--save-timer)
      (cancel-timer my/read-position--save-timer))
    (setq my/read-position--save-timer
          (run-with-idle-timer my/read-position-save-delay nil
                               #'my/read-position--idle-save
                               (current-buffer)))))

(defun my/read-position--clamp (position)
  "Clamp POSITION to the accessible part of the current buffer."
  (max (point-min) (min (point-max) position)))

(defun my/read-position--restore-pdf (record window)
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

(defun my/read-position--restore-epub (record window)
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
        (goto-char (my/read-position--clamp position))
        (set-window-point window (point)))
      (when (integerp start)
        (set-window-start window (my/read-position--clamp start) t)))))

(defun my/read-position-restore-buffer (buffer frame)
  "Restore BUFFER's saved position in FRAME once."
  (when (and (buffer-live-p buffer) (frame-live-p frame))
    (with-current-buffer buffer
      (unless my/read-position--restored-p
        (setq my/read-position--restored-p t)
        (when-let* ((key (my/read-position--source-file))
                    (window (my/read-center-window frame)))
          (let ((data (my/read-position--read-data)))
            (unless (eq data :invalid)
              (when-let ((record
                          (cdr (assoc-string
                                key (plist-get data :entries) t))))
                (let ((my/read-position--restoring-p t))
                  (pcase (my/read-position--source-type)
                    ('pdf (my/read-position--restore-pdf record window))
                    ('epub (my/read-position--restore-epub record window))))))))))))

(defun my/read-position-setup-buffer (buffer frame)
  "Enable persistent position tracking for BUFFER in FRAME."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (my/read-position--source-type)
        (add-hook 'post-command-hook #'my/read-position--schedule-save nil t)
        (add-hook 'kill-buffer-hook #'my/read-position--save-buffer-now nil t)
        (my/read-position-restore-buffer buffer frame)))))

(defun my/read-position-save-frame (frame)
  "Persist PDF and EPUB positions belonging to FRAME."
  (when (framep frame)
    (let ((window (and (frame-live-p frame) (my/read-center-window frame))))
      (dolist (buffer
               (delete-dups
                (delq nil
                      (list (frame-parameter frame 'my-reading-epub-buffer)
                            (frame-parameter frame 'my-reading-pdf-buffer)
                            (and (window-live-p window)
                                 (window-buffer window))))))
        (my/read-position-save-buffer
         buffer (and (window-live-p window)
                     (eq (window-buffer window) buffer)
                     window))))))

(defun my/read-eww-window (&optional frame)
  "Return FRAME's center window hosting the EWW tab."
  (my/read-window 'my-reading-eww-window frame))

(defun my/read-translate-window (&optional frame)
  "Return FRAME's Google Translate window."
  (my/read-window 'my-reading-translate-window frame))

(defun my/read-note-window (&optional frame)
  "Return FRAME's Org-noter notes window."
  (my/read-window 'my-reading-note-window frame))

(defun my/read-center-tab-buffers ()
  "Return FRAME's registered center-tab buffers in display order."
  (let ((frame my/read-center-tab-frame))
    (when (frame-live-p frame)
      (delq nil
            (mapcar (lambda (parameter)
                      (let ((buffer (frame-parameter frame parameter)))
                        (and (buffer-live-p buffer) buffer)))
                    '(my-reading-dired-buffer
                      my-reading-kindle-buffer
                      my-reading-pdf-buffer
                      my-reading-epub-buffer
                      my-reading-eww-buffer))))))

(defun my/read-center-tab-name (buffer &optional _buffers)
  "Return a compact tab label for center reading BUFFER."
  (let ((frame (buffer-local-value 'my/read-center-tab-frame buffer)))
    (cond
     ((and (frame-live-p frame)
           (eq buffer (frame-parameter frame 'my-reading-kindle-buffer)))
      " KINDLE ")
     ((and (frame-live-p frame)
           (eq buffer (frame-parameter frame 'my-reading-epub-buffer)))
      " EPUB ")
     ((and (frame-live-p frame)
           (eq buffer (frame-parameter frame 'my-reading-pdf-buffer)))
      " PDF ")
     ((and (frame-live-p frame)
           (eq buffer (frame-parameter frame 'my-reading-dired-buffer)))
      " DIRED ")
     ((and (frame-live-p frame)
           (eq buffer (frame-parameter frame 'my-reading-eww-buffer)))
      " EWW ")
     (t (format " %s " (buffer-name buffer))))))

(defun my/read--center-automatic-lookup-p (window)
  "Return non-nil when automatic Lookup should run for WINDOW."
  (and (window-live-p window)
       (with-current-buffer (window-buffer window)
         (or (not (derived-mode-p 'eww-mode))
             my/read-eww-enable-automatic-lookup))))

(defun my/read--center-source-buffer-p (buffer frame)
  "Return non-nil when BUFFER is a registered reading source in FRAME."
  (and (buffer-live-p buffer)
       (frame-live-p frame)
       (memq buffer
             (delq nil
                   (mapcar
                    (lambda (parameter)
                      (let ((candidate (frame-parameter frame parameter)))
                        (and (buffer-live-p candidate) candidate)))
                    '(my-reading-kindle-buffer
                      my-reading-pdf-buffer
                      my-reading-epub-buffer
                      my-reading-eww-buffer
                      my-reading-dired-buffer))))))

(defun my/read--center-source-window-p (window frame)
  "Return non-nil when WINDOW displays a registered source in FRAME."
  (and (window-live-p window)
       (eq (window-frame window) frame)
       (memq window (my/read-center-windows frame))
       (my/read--center-source-buffer-p (window-buffer window) frame)))

(defun my/read--center-window-active-p ()
  "Return non-nil only in the selected my-read center reading window."
  (let* ((frame (selected-frame))
         (window (selected-window)))
    (and (my/read-frame-p frame)
         (my/read--center-source-window-p window frame)
         (eq (window-buffer window) (current-buffer))
         (eq my/read-center-tab-frame frame))))

(defun my/read--filter-center-key-binding (binding)
  "Return BINDING only while point is in my-read's center reading window."
  (when (my/read--center-window-active-p)
    binding))

(defun my/read--filter-pdf-close-key-binding (binding)
  "Return BINDING only for a PDF in my-read's active reading window."
  (when (and (my/read--center-window-active-p)
             (english-reading-mode--pdf-buffer-p))
    binding))

(defun my/read-close-pdf ()
  "Close the active my-read PDF while keeping the workspace frame open."
  (interactive)
  (let* ((frame (selected-frame))
         (center (my/read-center-window frame))
         (pdf-buffer (current-buffer))
         (dired-buffer (frame-parameter frame 'my-reading-dired-buffer))
         (notes-window (my/read-note-window frame)))
    (unless (and (my/read--center-window-active-p)
                 (english-reading-mode--pdf-buffer-p pdf-buffer))
      (user-error "my-readのPDFペインで実行してください"))
    (unless (buffer-live-p dired-buffer)
      (user-error "my-readのDIREDタブが見つかりません"))

    (my/read-position-save-buffer pdf-buffer center)
    (when (fboundp 'kokoro-reader-stop)
      (kokoro-reader-stop))

    ;; Move both Org-noter-owned windows away before ending the session.  Its
    ;; stock kill hook otherwise deletes the my-read frame with the session.
    (when (window-live-p notes-window)
      (set-window-buffer notes-window (my/read--prepare-notes-buffer frame)))
    (set-window-buffer center dired-buffer)
    (select-window center)

    (when (fboundp 'my/read-org-noter-close-source)
      (my/read-org-noter-close-source pdf-buffer))
    ;; Org-noter normally kills its document itself.  Its cleanup can fail on
    ;; a malformed notes root, so make PDF closure an explicit final step.
    (when (buffer-live-p pdf-buffer)
      (kill-buffer pdf-buffer))

    (let ((placeholder
           (my/read--prepare-center-tab-placeholder frame 'pdf)))
      (set-frame-parameter frame 'my-reading-pdf-buffer placeholder)
      (my/read--configure-center-tab-buffer placeholder frame))
    (my/read-lookup-follow-post-command)
    (my/read-translate-follow-post-command)
    (message "PDFを閉じました")))

(defun my/read-next-word ()
  "Move point to the beginning of the next word in the reading pane."
  (interactive)
  (let* ((origin (point))
         (bounds (bounds-of-thing-at-point 'word))
         (search-start (if bounds (cdr bounds) (point))))
    (goto-char search-start)
    (forward-word 1)
    (if (> (point) search-start)
        (backward-word 1)
      (goto-char origin)
      (message "Already at the last word"))))

(defun my/read-previous-word ()
  "Move point to the beginning of the previous word in the reading pane."
  (interactive)
  (let* ((origin (point))
         (bounds (bounds-of-thing-at-point 'word))
         (search-start (if bounds (car bounds) (point))))
    (goto-char search-start)
    (backward-word 1)
    (when (= (point) search-start)
      (goto-char origin)
      (message "Already at the first word"))))

(defvar my-read-center-tab-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c t")
                '(menu-item "Switch my-read tab" my/read-toggle-center-tab
                            :filter my/read--filter-center-key-binding))
    (define-key map (kbd "C-c p")
                '(menu-item "Read paragraph" kokoro-reader-speak-paragraph
                            :filter my/read--filter-center-key-binding))
    (define-key map (kbd "C-c n")
                '(menu-item "Read and advance" kokoro-reader-speak-and-forward
                            :filter my/read--filter-center-key-binding))
    (define-key map (kbd "C-c k")
                '(menu-item "Stop reading" kokoro-reader-stop
                            :filter my/read--filter-center-key-binding))
    (define-key map (kbd "C-c o")
                '(menu-item "Open Org-noter notes" my/read-org-noter-follow-source
                            :filter my/read--filter-center-key-binding))
    (define-key map (kbd "C-x k")
                '(menu-item "Close my-read PDF" my/read-close-pdf
                            :filter my/read--filter-pdf-close-key-binding))
    (define-key map (kbd "u")
                '(menu-item "Save vocabulary" my/read-vocab-capture
                            :filter my/read--filter-center-key-binding))
    (define-key map (kbd ";")
                '(menu-item "Next word" my/read-next-word
                            :filter my/read--filter-center-key-binding))
    (define-key map (kbd "l")
                '(menu-item "Previous word" my/read-previous-word
                            :filter my/read--filter-center-key-binding))
    map)
  "Keymap active in the my-read center tabs.")

;; Keep re-evaluation effective in a live Emacs where `defvar' preserves the
;; existing map object.
(keymap-set my-read-center-tab-mode-map "C-c t"
            '(menu-item "Switch my-read tab" my/read-toggle-center-tab
                        :filter my/read--filter-center-key-binding))
(keymap-set my-read-center-tab-mode-map "C-c p"
            '(menu-item "Read paragraph" kokoro-reader-speak-paragraph
                        :filter my/read--filter-center-key-binding))
(keymap-set my-read-center-tab-mode-map "C-c n"
            '(menu-item "Read and advance" kokoro-reader-speak-and-forward
                        :filter my/read--filter-center-key-binding))
(keymap-set my-read-center-tab-mode-map "C-c k"
            '(menu-item "Stop reading" kokoro-reader-stop
                        :filter my/read--filter-center-key-binding))
(keymap-set my-read-center-tab-mode-map "C-c o"
            '(menu-item "Open Org-noter notes" my/read-org-noter-follow-source
                        :filter my/read--filter-center-key-binding))
(keymap-set my-read-center-tab-mode-map "C-x k"
            '(menu-item "Close my-read PDF" my/read-close-pdf
                        :filter my/read--filter-pdf-close-key-binding))
(keymap-set my-read-center-tab-mode-map "u"
            '(menu-item "Save vocabulary" my/read-vocab-capture
                        :filter my/read--filter-center-key-binding))
(keymap-set my-read-center-tab-mode-map ";"
            '(menu-item "Next word" my/read-next-word
                        :filter my/read--filter-center-key-binding))
(keymap-set my-read-center-tab-mode-map "l"
            '(menu-item "Previous word" my/read-previous-word
                        :filter my/read--filter-center-key-binding))

(define-minor-mode my-read-center-tab-mode
  "Display the my-read center sources as a dedicated tab line."
  :init-value nil
  :lighter nil
  :keymap my-read-center-tab-mode-map
  (when (fboundp 'tab-line-mode)
    (tab-line-mode (if my-read-center-tab-mode 1 -1))))

(defun my/read--buffer-contains-japanese-p ()
  "Return non-nil when the current buffer contains Japanese script."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (re-search-forward "[ぁ-んァ-ヶ一-龠々]" nil t))))

(defun my/read--configure-speech-language ()
  "Configure speech for the language of the current reading-text buffer."
  (if (my/read--buffer-contains-japanese-p)
      (setq-local my/read-source-language "ja"
                  kokoro-reader-backend 'macos
                  kokoro-reader-macos-voice my/read-japanese-macos-voice
                  kokoro-reader-macos-rate my/read-japanese-macos-rate)
    (setq-local my/read-source-language "en")
    (kill-local-variable 'kokoro-reader-backend)
    (kill-local-variable 'kokoro-reader-macos-voice)
    (kill-local-variable 'kokoro-reader-macos-rate)))

(add-hook 'english-reading-mode-pdf-text-buffer-hook
          #'my/read--configure-speech-language)

(defun my/read--pdf-view-window-overlay-valid-p (window)
  "Return non-nil when WINDOW has a live PDF Tools image overlay."
  (and (window-live-p window)
       (eq (window-buffer window) (current-buffer))
       (or (and (bound-and-true-p pdf-view-roll-minor-mode)
                (fboundp 'pdf-roll-page-overlay)
                (let ((overlay (pdf-roll-page-overlay 1 window)))
                  (and (overlayp overlay)
                       (eq (overlay-buffer overlay) (current-buffer))
                       (eq (overlay-get overlay 'window) window))))
           (and (boundp 'image-mode-winprops-alist)
                (listp image-mode-winprops-alist)
                (let* ((winprops (assq window image-mode-winprops-alist))
                       (overlay (cdr (assq 'overlay (cdr winprops)))))
                  (and (overlayp overlay)
                       (eq (overlay-buffer overlay) (current-buffer))
                       (eq (overlay-get overlay 'window) window)))))))

(defun my/read--enable-pdf-continuous-scroll (buffer frame)
  "Enable Preview-like continuous scrolling for PDF BUFFER in FRAME."
  (when (and my/read-pdf-continuous-scroll
             (buffer-live-p buffer)
             (frame-live-p frame)
             (fboundp 'pdf-view-roll-minor-mode))
    (when-let ((window (my/read-center-window frame)))
      (when (and (eq (window-buffer window) buffer)
                 (with-current-buffer buffer
                   (derived-mode-p 'pdf-view-mode)))
        (with-selected-window window
          (with-current-buffer buffer
            (unless (bound-and-true-p pdf-view-roll-minor-mode)
              (pdf-view-roll-minor-mode 1))
            ;; The mode-line size indicator assumes a single live page
            ;; overlay.  Roll mode can temporarily have no overlay while it
            ;; updates the continuously displayed pages, making redisplay
            ;; signal `wrong-type-argument overlayp nil'.
            (when (and (bound-and-true-p
                        pdf-misc-size-indication-minor-mode)
                       (fboundp 'pdf-misc-size-indication-minor-mode))
              (pdf-misc-size-indication-minor-mode -1))))))))

(defun my/read--repair-pdf-view-window (buffer frame)
  "Repair BUFFER's PDF Tools image state in FRAME's center window.

Moving a PDF buffer between my-read tabs can leave `image-mode' with a dead
window overlay.  In that state the mode line still says PDFView while the raw
%PDF data is visible.  Reinitializing `pdf-view-mode' rebuilds the per-window
overlay; preserve the current page across that repair."
  (when (and (buffer-live-p buffer) (frame-live-p frame))
    (when-let ((window (my/read-center-window frame)))
      (when (and (eq (window-buffer window) buffer)
                 (with-current-buffer buffer
                   (derived-mode-p 'pdf-view-mode))
                 (with-current-buffer buffer
                   (not (my/read--pdf-view-window-overlay-valid-p window))))
        (with-selected-window window
          (with-current-buffer buffer
            (let* ((winprops (and (listp image-mode-winprops-alist)
                                  (or (assq window image-mode-winprops-alist)
                                      (assq t image-mode-winprops-alist))))
                   (page (or (cdr (assq 'page (cdr winprops))) 1)))
              (pdf-view-mode)
              (pdf-view-goto-page page))))))))

(defun my/read--configure-center-tab-buffer (buffer frame)
  "Configure BUFFER as one of FRAME's center reading tabs."
  (when (buffer-live-p buffer)
    (my/read--repair-pdf-view-window buffer frame)
    (with-current-buffer buffer
      (setq-local my/read-center-tab-frame frame)
      (setq-local english-reading-mode-key-active-predicate
                  #'my/read--center-window-active-p)
      (setq-local tab-line-tabs-function #'my/read-center-tab-buffers)
      (setq-local tab-line-tab-name-function #'my/read-center-tab-name)
      (setq-local tab-line-close-button-show nil)
      (setq-local tab-line-new-button-show nil)
      (when (derived-mode-p 'nov-mode)
        (my/read--configure-speech-language))
      (when (derived-mode-p 'nov-mode 'eww-mode 'doc-view-mode 'pdf-view-mode)
        (english-reading-mode 1))
      (my/read--enable-pdf-continuous-scroll buffer frame)
      (my/read-position-setup-buffer buffer frame)
      (my-read-center-tab-mode 1))))

(defun my/read-toggle-center-tab ()
  "Cycle FRAME's center window through its registered tabs."
  (interactive)
  (let* ((frame (or my/read-center-tab-frame (selected-frame)))
         (window (my/read-center-window frame))
         (tabs (and (window-live-p window)
                    (with-current-buffer (window-buffer window)
                      (my/read-center-tab-buffers))))
         (current (and (window-live-p window) (window-buffer window)))
         (target (and (> (length tabs) 1)
                      (or (cadr (memq current tabs)) (car tabs)))))
    (unless (and target (not (eq target current)))
      (user-error "切り替えられる読書タブがありません"))
    (set-window-buffer window target)
    (select-window window)
    (my/read--repair-pdf-view-window target frame)
    (if (my/read--center-automatic-lookup-p window)
        (my/read-lookup-follow-post-command)
      ;; Do not let a Lookup queued by the previous EPUB/Kindle tab run after
      ;; the window has switched to EWW.
      (when (timerp my/read-lookup-timer)
        (cancel-timer my/read-lookup-timer))
      (setq my/read-lookup-timer nil
            my/read-lookup-last-target nil))
    (my/read-translate-follow-post-command)
    (when (fboundp 'my/read-org-noter-follow-source)
      (my/read-org-noter-follow-source frame))))

(defun my/read--track-center-tab-buffer (frame)
  "Remember a newly displayed center buffer in FRAME by source type."
  (when (and (frame-live-p frame) (my/read-frame-p frame))
    (when-let ((window (my/read-center-window frame)))
      (let* ((buffer (window-buffer window))
             (kindle (frame-parameter frame 'my-reading-kindle-buffer))
             (parameter
              (unless (eq buffer kindle)
                (with-current-buffer buffer
                  (cond
                   ((derived-mode-p 'eww-mode)
                    'my-reading-eww-buffer)
                   ((derived-mode-p 'nov-mode)
                    'my-reading-epub-buffer)
                   ((derived-mode-p 'doc-view-mode 'pdf-view-mode)
                    'my-reading-pdf-buffer)
                   ((derived-mode-p 'dired-mode)
                    'my-reading-dired-buffer))))))
        (when parameter
          (set-frame-parameter frame parameter buffer)
          (my/read--configure-center-tab-buffer buffer frame)
          (when (and (eq window (my/read-center-window frame))
                     (fboundp 'my/read-org-noter-follow-source))
            (my/read-org-noter-follow-source frame)))))))

(add-hook 'window-buffer-change-functions #'my/read--track-center-tab-buffer)

(defun my/read--other-reading-frame-p (frame)
  "Return non-nil if a live my-read frame other than FRAME exists."
  (cl-some
   (lambda (candidate)
     (and (not (eq candidate frame))
          (frame-live-p candidate)
          (my/read-frame-p candidate)))
   (frame-list)))


;;; ---------------------------------------------------------------------------
;;; Lookup dictionary scope
;;; ---------------------------------------------------------------------------

(defun my/read--lookup-ensure-runtime ()
  "Ensure the user's normal Lookup runtime is initialized.

Do not assume that a particular Lookup fork exposes
`lookup-dictionary-list'.  A usable default module is enough for
`lookup-pattern', so only initialize when the module runtime is absent."
  (unless (featurep 'lookup)
    (require 'lookup))
  (when (and (fboundp 'lookup-initialize)
             (or (not (boundp 'lookup-module-list))
                 (null (symbol-value 'lookup-module-list))))
    (lookup-initialize))
  t)

(defun my/read-reset-lookup-dictionary-module ()
  "Discard the cached private Lookup module used by reading frames."
  (interactive)
  (setq my/read--lookup-module nil
        my/read--lookup-module-signature nil
        my/read-lookup-last-target nil))

(defun my/read-lookup-list-dictionaries ()
  "Show available Lookup dictionary IDs and the current my-read selection."
  (interactive)
  (my/read--lookup-ensure-runtime)
  (lookup-module-setup (lookup-default-module))
  (let ((buffer (get-buffer-create "*my-read Lookup Dictionaries*"))
        (dictionaries
         (mapcar #'cdr (lookup-dictionary-alist t))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "my-read / my-read-k Lookup dictionaries\n\n")
        (insert "Customize: M-x customize-option RET my/read-lookup-dictionary-ids\n\n")
        (dolist (dictionary dictionaries)
          (let* ((id (lookup-dictionary-id dictionary))
                 (selected
                  (cl-some (lambda (prefix)
                             (string-prefix-p prefix id))
                           my/read-lookup-dictionary-ids)))
            (insert (format "%s %s\n    %s\n"
                            (if selected "[*]" "[ ]")
                            id
                            (lookup-dictionary-title dictionary)))))
        (special-mode)
        (goto-char (point-min))))
    (pop-to-buffer buffer)))

(defun my/read--lookup-reading-module ()
  "Return the private Lookup module configured for my-read and my-read-k."
  (my/read--lookup-ensure-runtime)
  (unless my/read-lookup-dictionary-ids
    (user-error "my/read-lookup-dictionary-ids is empty"))
  (unless (and (fboundp 'lookup-new-module)
               (fboundp 'lookup-module-setup))
    (error "This Lookup version cannot create a private dictionary module"))
  (unless (equal my/read--lookup-module-signature
                 my/read-lookup-dictionary-ids)
    (let ((module
           (lookup-new-module
            (cons "%my-read" my/read-lookup-dictionary-ids))))
      ;; Resolve IDs now so an invalid configuration fails here instead of
      ;; silently searching the full default module.
      (lookup-module-setup module)
      (setq my/read--lookup-module module
            my/read--lookup-module-signature
            (copy-sequence my/read-lookup-dictionary-ids))))
  my/read--lookup-module)

(defun my/read--lookup-reading-dictionaries ()
  "Return dictionaries in the private my-read Lookup module."
  (lookup-module-dictionaries (my/read--lookup-reading-module)))

(defun my/read--lookup-pattern-around
    (function pattern &optional module)
  "Use my-read's private module around Lookup FUNCTION for PATTERN.

An explicitly supplied MODULE is respected.  A normal search outside a reading
frame is passed through unchanged."
  (funcall function
           pattern
           (if (and (my/read-frame-p) (null module))
               (my/read--lookup-reading-module)
             module)))

(defun my/read--install-lookup-advice ()
  "Restrict manual Lookup searches only when they originate in my-read.

Also remove advice left by older my-read revisions so reloading this file in
an existing Emacs session cannot call the destructive profile-switch code."
  ;; Use the user's normal `lookup-pattern' path.  In the user's config this
  ;; already has frame-safety and "open first entry" advice attached, so keeping
  ;; my-read on the same command path preserves that working behavior.
  (when (fboundp 'lookup-pattern)
    (when (fboundp 'my/read--lookup-call-with-reading-scope)
      (advice-remove 'lookup-pattern #'my/read--lookup-call-with-reading-scope))
    (advice-remove 'lookup-pattern #'my/read--lookup-pattern-around)
    (advice-add 'lookup-pattern :around #'my/read--lookup-pattern-around)))

(with-eval-after-load 'lookup
  (my/read--install-lookup-advice))

(defun my/read--lookup-enter ()
  "Prepare Lookup for my-read without mutating the normal Lookup runtime."
  (my/read--lookup-ensure-runtime)
  (my/read--install-lookup-advice))

(defun my/read--lookup-restore-normal ()
  "Compatibility cleanup hook.

There is nothing to restore because my-read no longer mutates the user's
normal Lookup agents, dictionaries or modules."
  nil)


;;; ---------------------------------------------------------------------------
;;; Lookup follower (self-contained in my-read)
;;; ---------------------------------------------------------------------------

(defun my/read-word-at-window (window)
  "Return the word at WINDOW's point, or nil."
  (when (window-live-p window)
    (with-current-buffer (window-buffer window)
      (unless (derived-mode-p 'dired-mode)
        (let ((virtual
               (and (fboundp 'english-reading-mode-current-text-location)
                    (english-reading-mode-current-text-location
                     (current-buffer)))))
          (with-current-buffer (or (nth 1 virtual) (current-buffer))
            (save-excursion
              (goto-char (or (nth 2 virtual) (window-point window)))
              (when-let ((word (thing-at-point 'word t)))
                (setq word (string-trim word))
                (unless (string-empty-p word)
                  word)))))))))

(defun my/read-lookup-open-pane (buffer)
  "Display Lookup BUFFER in the fixed Lookup pane of the current my-read frame.

This intentionally overrides the user's normal `lookup-open-function' only
for automatic searches performed by my-read.  It never creates another pane."
  (let* ((frame (selected-frame))
         (pane (my/read-lookup-window frame)))
    (if (window-live-p pane)
        (progn
          (set-window-dedicated-p pane nil)
          (set-window-buffer pane buffer)
          ;; Lookup open functions normally select the destination window.
          ;; Do that here too so Entry/Content setup can complete normally;
          ;; `save-selected-window' in `my/read-lookup-run' restores CENTER.
          (select-window pane)
          pane)
      ;; Fallback should only be needed outside a valid my-read layout.
      (display-buffer buffer))))

(defun my/read-lookup-run (frame center target)
  "Run Lookup for TARGET in FRAME using CENTER as the source window."
  (setq my/read-lookup-timer nil)
  (when (and my-read-lookup-follow-mode
             (not my/read-lookup-running-p)
             (frame-live-p frame)
             (my/read-frame-p frame)
             (window-live-p center)
             (my/read--center-automatic-lookup-p center)
             (equal target my/read-lookup-last-target))
    (let ((word (caddr target)))
      (when (and word
                 (or (featurep 'lookup)
                     (require 'lookup nil t))
                 (fboundp 'lookup-pattern))
        (setq my/read-lookup-running-p t)
        (unwind-protect
            (with-selected-frame frame
              (save-selected-window
                ;; Run from the book window so Lookup's frame/module state is
                ;; associated with the reading pane.  WORD itself is passed
                ;; explicitly to `lookup-pattern'.
                (with-selected-window center
                  ;; Never reuse a Lookup main/sub window belonging to another
                  ;; frame.  This mirrors the user's normal Lookup protection.
                  (when (and (boundp 'lookup-main-window)
                             (window-live-p lookup-main-window)
                             (not (eq (window-frame lookup-main-window) frame)))
                    (setq lookup-main-window nil
                          lookup-sub-window nil))
                  ;; my-read already owns a Lookup pane, so dynamically route
                  ;; this search there instead of creating another outer pane.
                  ;;
                  ;; IMPORTANT: use `lookup-pattern', not `lookup-word'.  The
                  ;; user's normal Lookup configuration attaches frame handling
                  ;; and "open the first entry" behavior to `lookup-pattern'.
                  ;; Calling it non-interactively with WORD does not open the
                  ;; minibuffer, but does preserve those existing advices.
                  (let ((lookup-open-function #'my/read-lookup-open-pane))
                    (condition-case err
                        (lookup-pattern
                         word
                         (my/read--lookup-reading-module))
                      (error
                       (message "my-read Lookup error for %S: %s"
                                word (error-message-string err))))))))
          (setq my/read-lookup-running-p nil))))))

(defun my/read-lookup-follow-post-command ()
  "Automatically look up the word at point in a my-read center window."
  (when my-read-lookup-follow-mode
    (let* ((frame (selected-frame))
           (center (my/read-center-window frame)))
      (when (and (my/read-frame-p frame)
                 (my/read--center-source-window-p center frame)
                 (eq (selected-window) center)
                 (my/read--center-automatic-lookup-p center)
                 (not my/read-lookup-running-p))
        (let* ((word (my/read-word-at-window center))
               (target (and word
                            (list frame (window-buffer center) word))))
          (unless (equal target my/read-lookup-last-target)
            (setq my/read-lookup-last-target target)
            (when (timerp my/read-lookup-timer)
              (cancel-timer my/read-lookup-timer)
              (setq my/read-lookup-timer nil))
            (when word
              (setq my/read-lookup-timer
                    (run-with-idle-timer
                     my/read-lookup-idle-delay
                     nil
                     #'my/read-lookup-run
                     frame center target)))))))))

(define-minor-mode my-read-lookup-follow-mode
  "Automatically show Lookup results for the word at point in my-read."
  :global t
  :lighter " Lookup↔"
  (if my-read-lookup-follow-mode
      (progn
        (setq my/read-lookup-last-target nil
              my/read-lookup-running-p nil)
        (add-hook 'post-command-hook #'my/read-lookup-follow-post-command))
    (remove-hook 'post-command-hook #'my/read-lookup-follow-post-command)
    (when (timerp my/read-lookup-timer)
      (cancel-timer my/read-lookup-timer))
    (setq my/read-lookup-timer nil
          my/read-lookup-last-target nil
          my/read-lookup-running-p nil)))


(defun my/read-lookup-status ()
  "Show the current my-read Lookup follower state in the echo area."
  (interactive)
  (let* ((frame (selected-frame))
         (center (my/read-center-window frame))
         (word (and (window-live-p center)
                    (my/read-word-at-window center)))
         (dicts (condition-case _err
                    (and (my/read-frame-p frame)
                         (my/read--lookup-reading-dictionaries))
                  (error nil))))
    (message
     "my-read Lookup: mode=%s center=%s word=%S dicts=%S last=%S timer=%s running=%s"
     my-read-lookup-follow-mode
     (window-live-p center)
     word
     (and dicts
          (mapcar (lambda (dict)
                    (if (fboundp 'lookup-dictionary-id)
                        (lookup-dictionary-id dict)
                      dict))
                  dicts))
     my/read-lookup-last-target
     (timerp my/read-lookup-timer)
     my/read-lookup-running-p)))

(defun my/read-lookup-dispatch-key (key)
  "Run the command bound to KEY in the current my-read Lookup pane.

The command is executed with the left Lookup window temporarily selected, then
focus is restored to the center reading window."
  (let* ((frame (selected-frame))
         (center (my/read-center-window frame))
         (lookup (my/read-lookup-window frame)))
    (unless (and (my/read-frame-p frame)
                 (window-live-p center)
                 (eq (selected-window) center))
      (user-error "Use this command from the my-read center window"))
    (unless (window-live-p lookup)
      (user-error "The my-read Lookup window is not available"))
    (let ((command
           (with-selected-window lookup
             (key-binding (kbd key) t))))
      (unless (and (commandp command)
                   (not (memq command '(self-insert-command undefined))))
        (user-error "Lookup has no command bound to %s in the current view"
                    key))
      (with-selected-window lookup
        (call-interactively command)))))

(defun my/read-lookup-next-entry ()
  "Move to the next Lookup entry while focus stays in the reading pane."
  (interactive)
  (my/read-lookup-dispatch-key "n"))

(defun my/read-lookup-previous-entry ()
  "Move to the previous Lookup entry while focus stays in the reading pane."
  (interactive)
  (my/read-lookup-dispatch-key "p"))

;; `english-reading-mode' is active in both my-read center buffers.  Install
;; these explicitly so re-evaluating my-read.el updates a live session too.
(keymap-set
 english-reading-mode-map "p"
 '(menu-item "Next Lookup entry" my/read-lookup-next-entry
             :filter english-reading-mode--filter-key-binding))
(keymap-set
 english-reading-mode-map "o"
 '(menu-item "Previous Lookup entry" my/read-lookup-previous-entry
             :filter english-reading-mode--filter-key-binding))


;;; ---------------------------------------------------------------------------
;;; Translation target
;;; ---------------------------------------------------------------------------

(defun my/read-current-sentence-at-window (window)
  "Return (TEXT BUFFER BEG END) for the sentence at point in WINDOW.

Dired windows and empty sentences return nil.  BEG and END exclude surrounding
whitespace so the returned bounds match the text shown as the translation
source."
  (when (window-live-p window)
    (with-current-buffer (window-buffer window)
      (unless (derived-mode-p 'dired-mode)
        (or (and (fboundp 'english-reading-mode-current-text-location)
                 (english-reading-mode-current-text-location
                  (current-buffer)))
            (save-excursion
              (goto-char (window-point window))
              (let ((sentence-end-double-space nil))
                (when-let ((bounds (bounds-of-thing-at-point 'sentence)))
                  (goto-char (car bounds))
                  (skip-chars-forward " \t\n\r" (cdr bounds))
                  (let ((beg (point)))
                    (goto-char (cdr bounds))
                    (skip-chars-backward " \t\n\r" beg)
                    (let ((end (point)))
                      (when (< beg end)
                        (list (buffer-substring-no-properties beg end)
                              (current-buffer)
                              beg
                              end))))))))))))


;;; ---------------------------------------------------------------------------
;;; Vocabulary capture
;;; ---------------------------------------------------------------------------

(defun my/read-vocab-normalize-text (text)
  "Trim TEXT and collapse each run of whitespace to one space."
  (when (stringp text)
    (string-trim
     (replace-regexp-in-string "[[:space:]\u00a0]+" " " text))))

(defun my/read-vocab--strip-surrounding-punctuation (text)
  "Strip obvious quotation and sentence punctuation around TEXT."
  (let ((punctuation "[[:punct:]“”‘’]"))
    (setq text (replace-regexp-in-string
                (concat "\\`" punctuation "+") "" text))
    (replace-regexp-in-string (concat punctuation "+\\'") "" text)))

(defun my/read-vocab-normalize-key (text)
  "Return the case-folded vocabulary lookup key for TEXT."
  (downcase
   (my/read-vocab--strip-surrounding-punctuation
    (or (my/read-vocab-normalize-text text) ""))))

(defun my/read-vocab--display-text (text)
  "Return normalized display spelling for captured TEXT."
  (my/read-vocab--strip-surrounding-punctuation
   (or (my/read-vocab-normalize-text text) "")))

(defun my/read-vocab-target-at-point (&optional window)
  "Return the selected phrase or word at point in WINDOW.

An active region is preferred and its whitespace is normalized.  WINDOW
defaults to the selected window."
  (let ((window (or window (selected-window))))
    (if (use-region-p)
        (my/read-vocab--display-text
         (buffer-substring-no-properties (region-beginning) (region-end)))
      (when-let ((word (my/read-word-at-window window)))
        (my/read-vocab--display-text word)))))

(defun my/read-vocab-current-book-title (&optional buffer frame)
  "Return the current book or document title for BUFFER in FRAME."
  (let* ((buffer (or buffer (current-buffer)))
         (frame (or frame (selected-frame)))
         (kindle-buffer (and (frame-live-p frame)
                             (frame-parameter frame
                                              'my-reading-kindle-buffer))))
    (or
     (and (eq buffer kindle-buffer)
          (frame-parameter frame 'my-reading-kindle-book-name))
     (and (buffer-live-p buffer)
          (with-current-buffer buffer
            (and (derived-mode-p 'eww-mode)
                 (boundp 'eww-data)
                 (plist-get eww-data :title))))
     (and (buffer-live-p buffer)
          (buffer-local-value 'buffer-file-name buffer)
          (file-name-base (buffer-local-value 'buffer-file-name buffer)))
     (and (buffer-live-p buffer)
          (let ((name (buffer-name buffer)))
            (and name (not (string-prefix-p " " name)) name)))
     "Unknown source")))

(defun my/read-vocab-current-source (&optional buffer frame)
  "Return cheap source metadata for BUFFER in FRAME, or nil."
  (let* ((buffer (or buffer (current-buffer)))
         (frame (or frame (selected-frame)))
         (kindle-buffer (and (frame-live-p frame)
                             (frame-parameter frame
                                              'my-reading-kindle-buffer))))
    (or
     (and (eq buffer kindle-buffer)
          (boundp 'my-read-k--target-url)
          my-read-k--target-url)
     (and (buffer-live-p buffer)
          (with-current-buffer buffer
            (and (derived-mode-p 'eww-mode)
                 (boundp 'eww-data)
                 (plist-get eww-data :url))))
     (and (buffer-live-p buffer)
          (buffer-local-value 'buffer-file-name buffer)))))

(defun my/read-vocab--lookup-buffer-text (buffer)
  "Return useful plain text from Lookup BUFFER, or nil."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((text (string-trim
                   (buffer-substring-no-properties (point-min) (point-max)))))
        (unless (string-empty-p text) text)))))

(defun my/read-vocab--lookup-content-buffer ()
  "Return Lookup's rendered dictionary-content buffer, or nil."
  (let ((name
         (cond
          ((fboundp 'lookup-content-buffer) (lookup-content-buffer))
          ((boundp 'lookup-content-buffer)
           (symbol-value 'lookup-content-buffer)))))
    (and name (get-buffer name))))

(defun my/read-vocab--lookup-entry-content (entry)
  "Return the rendered plain-text content of Lookup ENTRY, or nil."
  (condition-case nil
      (with-temp-buffer
        (lookup-vse-insert-content entry)
        (my/read-vocab--lookup-buffer-text (current-buffer)))
    (error nil)))

(defun my/read-vocab--lookup-results ()
  "Return English and Japanese dictionary results from the current session."
  (let ((entries
         (and (boundp 'lookup-current-session)
              lookup-current-session
              (fboundp 'lookup-session-entries)
              (lookup-session-entries lookup-current-session)))
        english-entry
        japanese-entry)
    (dolist (entry entries)
      (let ((title
             (lookup-dictionary-title (lookup-entry-dictionary entry))))
        (cond
         ((and (null english-entry)
               (string-match-p
                my/read-vocab-english-dictionary-title-regexp title))
          (setq english-entry (cons title entry)))
         ((and (null japanese-entry)
               (string-match-p
                my/read-vocab-japanese-dictionary-title-regexp title))
          (setq japanese-entry (cons title entry))))))
    (let ((english (and english-entry
                        (my/read-vocab--lookup-entry-content
                         (cdr english-entry))))
          (japanese (and japanese-entry
                         (my/read-vocab--lookup-entry-content
                          (cdr japanese-entry)))))
      ;; Older Lookup variants may not expose their session entries.  Preserve
      ;; a useful first English result instead of dropping all dictionary text.
      (unless english
        (setq english
              (my/read-vocab--lookup-buffer-text
               (my/read-vocab--lookup-content-buffer))))
      (list :english-title (car english-entry)
            :english english
            :japanese-title (car japanese-entry)
            :japanese japanese))))

(defun my/read-vocab--format-meaning (lookup-results google-translation)
  "Format LOOKUP-RESULTS and GOOGLE-TRANSLATION for the Meaning section."
  (let ((english-title (plist-get lookup-results :english-title))
        (english (or (plist-get lookup-results :english) ""))
        (japanese-title (plist-get lookup-results :japanese-title))
        (japanese (or (plist-get lookup-results :japanese) ""))
        (google (or google-translation "")))
    (format "English-English%s:\n%s\n\nEnglish-Japanese%s:\n%s\n\nGoogle Translate:\n%s"
            (if english-title (format " [%s]" english-title) "")
            english
            (if japanese-title (format " [%s]" japanese-title) "")
            japanese
            google)))

(defun my/read-vocab-lookup-meaning (text callback &optional frame center)
  "Look up TEXT with my-read's Lookup stack, then call CALLBACK.

CALLBACK receives a plist containing English and Japanese dictionary results,
or nil when Lookup is unavailable or fails."
  (let ((frame (or frame (selected-frame)))
        (center (or center (selected-window)))
        results)
    (condition-case nil
        (when (and (frame-live-p frame)
                   (window-live-p center)
                   (or (featurep 'lookup) (require 'lookup nil t))
                   (fboundp 'lookup-pattern))
          (with-selected-frame frame
            (save-selected-window
              (with-selected-window center
                (let ((lookup-open-function #'my/read-lookup-open-pane))
                  (lookup-pattern text (my/read--lookup-reading-module)))))
            (setq results (my/read-vocab--lookup-results))))
      (error (setq results nil)))
    (funcall callback results)))

(defun my/read-vocab--translation-command
    (backend text frame source-buffer)
  "Return the existing my-read translation command for BACKEND and TEXT."
  (if (eq backend 'local)
      (list "curl" "-sS" "--fail-with-body"
            "--connect-timeout" "1"
            "--max-time" (number-to-string my/read-local-translation-timeout)
            "-H" "Content-Type: application/json"
            "--data-binary"
            (my/read--local-translation-request text frame source-buffer)
            my/read-local-translation-url)
    (list "curl" "-s" "-L" "-A" "Emacs"
          (my/read-google-translate-url text frame source-buffer))))

(defun my/read-vocab--translate-request
    (backend text callback frame source-buffer)
  "Translate TEXT with BACKEND and call CALLBACK with text or nil."
  (let* ((local-p (eq backend 'local))
         (buffer (generate-new-buffer " *my-read vocabulary translation*"))
         (process
          (make-process
           :name "my-read-vocabulary-translation"
           :buffer buffer
           :command (my/read-vocab--translation-command
                     backend text frame source-buffer)
           :coding 'utf-8-unix
           :noquery t
           :sentinel
           (lambda (proc _event)
             (when (memq (process-status proc) '(exit signal))
               (unwind-protect
                   (let ((translation
                          (and (= (process-exit-status proc) 0)
                               (condition-case nil
                                   (with-current-buffer (process-buffer proc)
                                     (my/read--translation-response
                                      backend (buffer-string)))
                                 (error nil)))))
                     (if (and (null translation)
                              local-p
                              my/read-google-translation-fallback)
                         (my/read-vocab--translate-request
                          'google text callback frame source-buffer)
                       (funcall callback translation)))
                 (when-let ((process-buffer (process-buffer proc)))
                   (when (buffer-live-p process-buffer)
                     (kill-buffer process-buffer)))))))))
    process))

(defun my/read-vocab-translate-text
    (text callback &optional backend frame source-buffer)
  "Translate TEXT with BACKEND, then call CALLBACK.
BACKEND defaults to `my/read-translation-backend'."
  (if (string-empty-p (or text ""))
      (funcall callback nil)
    (condition-case nil
        (my/read-vocab--translate-request
         (or backend my/read-translation-backend) text callback
         (or frame (selected-frame)) source-buffer)
      (error (funcall callback nil)))))

(defun my/read-vocab-translate-sentence
    (sentence callback &optional frame source-buffer)
  "Translate SENTENCE with my-read's configured backend, then call CALLBACK."
  (my/read-vocab-translate-text
   sentence callback my/read-translation-backend frame source-buffer))

(defun my/read-vocab--find-entry (key)
  "Return the position of the unique top-level entry matching KEY.

Signal an error if duplicate normalized headings already exist."
  (save-excursion
    (goto-char (point-min))
    (let (matches)
      (while (re-search-forward "^\\* \\(.+?\\)[ \t]*$" nil t)
        (when (equal key (my/read-vocab-normalize-key (match-string 1)))
          (push (line-beginning-position) matches)))
      (when (> (length matches) 1)
        (error "Duplicate vocabulary headings already exist for %s" key))
      (car matches))))

(defun my/read-vocab--safe-body (text)
  "Return TEXT safe for insertion as ordinary Org body text."
  (let ((text (string-trim (or text ""))))
    (replace-regexp-in-string "^\\*" ",*" text)))

(defun my/read-vocab--example-text (data)
  "Return one Org example subtree for vocabulary DATA."
  (let ((timestamp (plist-get data :timestamp))
        (book (my/read-vocab-normalize-text (plist-get data :book)))
        (source (my/read-vocab-normalize-text (plist-get data :source)))
        (english (my/read-vocab--safe-body (plist-get data :sentence)))
        (japanese (my/read-vocab--safe-body (plist-get data :translation))))
    (concat
     (format "*** %s %s\n:PROPERTIES:\n:BOOK: %s\n"
             timestamp book book)
     (if (string-empty-p (or source "")) "" (format ":SOURCE: %s\n" source))
     ":END:\n\nEnglish:\n" english "\n\nJapanese:\n" japanese "\n")))

(defun my/read-vocab--validate-existing-entry (position)
  "Return the positive COUNT at vocabulary entry POSITION.

Signal before editing when the canonical entry structure is unsafe."
  (save-excursion
    (goto-char position)
    (org-back-to-heading t)
    (let* ((count-text (org-entry-get nil "COUNT"))
           (end (save-excursion (org-end-of-subtree t t) (point))))
      (unless (and count-text (string-match-p "\\`[1-9][0-9]*\\'" count-text))
        (error "Vocabulary entry has an invalid COUNT property"))
      (unless (re-search-forward "^\\*\\* Meaning[ \t]*$" end t)
        (error "Vocabulary entry has no safe Meaning section"))
      (unless (re-search-forward "^\\*\\* Examples[ \t]*$" end t)
        (error "Vocabulary entry has no safe Examples section"))
      (string-to-number count-text))))

(defun my/read-vocab--replace-meaning (position meaning)
  "Replace entry POSITION's Meaning body with non-empty MEANING."
  (unless (string-empty-p meaning)
    (save-excursion
      (goto-char position)
      (org-back-to-heading t)
      (let ((end (save-excursion (org-end-of-subtree t t) (point))))
        (unless (re-search-forward "^\\*\\* Meaning[ \t]*$" end t)
          (error "Vocabulary entry has no safe Meaning section"))
        (forward-line 1)
        (let ((body-start (point)))
          (unless (re-search-forward "^\\*\\* Examples[ \t]*$" end t)
            (error "Vocabulary entry has no safe Examples section"))
          (delete-region body-start (line-beginning-position))
          (goto-char body-start)
          (insert meaning "\n\n"))))))

(defun my/read-vocab--write (data)
  "Merge vocabulary DATA into `my/read-vocabulary-file'.

Return (STATUS . COUNT), where STATUS is `added' or `saved'."
  (let* ((file (expand-file-name my/read-vocabulary-file))
         (directory (file-name-directory file))
         (term (my/read-vocab--display-text (plist-get data :term)))
         (key (my/read-vocab-normalize-key term))
         (timestamp (plist-get data :timestamp))
         (type (plist-get data :type))
         (meaning (my/read-vocab--safe-body (plist-get data :meaning))))
    (when (string-empty-p key)
      (error "Vocabulary term is empty"))
    (when directory (make-directory directory t))
    (with-current-buffer (find-file-noselect file)
      (unless (derived-mode-p 'org-mode) (org-mode))
      (let* ((position (my/read-vocab--find-entry key))
             (old-count (and position
                             (my/read-vocab--validate-existing-entry position)))
             (new-count (if old-count (1+ old-count) 1))
             (status (if position 'saved 'added)))
        (atomic-change-group
          (if position
              (progn
                (goto-char position)
                (org-back-to-heading t)
                (org-entry-put nil "UPDATED" timestamp)
                (org-entry-put nil "COUNT" (number-to-string new-count))
                (my/read-vocab--replace-meaning position meaning)
                (goto-char position)
                (org-end-of-subtree t t)
                (unless (bolp) (insert "\n"))
                (insert "\n" (my/read-vocab--example-text data)))
            (goto-char (point-max))
            (unless (or (= (point) (point-min)) (bolp)) (insert "\n"))
            (unless (= (point) (point-min)) (insert "\n"))
            (insert (format "* %s\n:PROPERTIES:\n:TYPE: %s\n"
                            term (symbol-name type)))
            (insert (format ":CREATED: %s\n:UPDATED: %s\n:COUNT: 1\n:END:\n\n"
                            timestamp timestamp))
            (insert "** Meaning\n" meaning "\n\n** Examples\n\n")
            (insert (my/read-vocab--example-text data))))
        (save-buffer)
        (cons status new-count)))))

(defun my/read-vocab--finish-capture (data)
  "Persist completed vocabulary DATA and report success."
  (pcase-let ((`(,status . ,count) (my/read-vocab--write data)))
    (if (eq status 'added)
        (message "Vocabulary added: %s" (plist-get data :term))
      (message "Vocabulary saved: %s (%d examples)"
               (plist-get data :term) count))))

;;;###autoload
(defun my/read-vocab-capture ()
  "Capture the selected phrase or word at point into the vocabulary Org file."
  (interactive)
  (unless (my/read--center-window-active-p)
    (user-error "Use this command from the my-read center window"))
  (let* ((frame (selected-frame))
         (center (selected-window))
         (phrase-p (use-region-p))
         (term (my/read-vocab-target-at-point center)))
    (unless (and term (not (string-empty-p term)))
      (user-error "No word or phrase at point"))
    (when phrase-p
      (deactivate-mark))
    (let* ((sentence-data (my/read-current-sentence-at-window center))
           (sentence (my/read-vocab-normalize-text
                      (or (car sentence-data) term)))
           (source-buffer (or (nth 1 sentence-data) (window-buffer center)))
           (data (list :term term
                       :type (if phrase-p 'phrase 'word)
                       :timestamp (format-time-string "[%Y-%m-%d %a %H:%M]")
                       :book (my/read-vocab-current-book-title
                              source-buffer frame)
                       :source (my/read-vocab-current-source
                                source-buffer frame)
                       :sentence sentence)))
      (message "Capturing vocabulary: %s..." term)
      (my/read-vocab-lookup-meaning
       term
       (lambda (lookup-results)
         ;; The term/phrase meaning is deliberately always Google Translate;
         ;; sentence translation continues to honor the configured backend.
         (my/read-vocab-translate-text
          term
          (lambda (term-translation)
            (setq data
                  (plist-put
                   data :meaning
                   (my/read-vocab--format-meaning
                    lookup-results term-translation)))
            (my/read-vocab-translate-sentence
             sentence
             (lambda (translation)
               (setq data (plist-put data :translation translation))
               (my/read-vocab--finish-capture data))
             frame source-buffer))
          'google frame source-buffer))
       frame center))))

(defun my/read--kokoro-context-for-frame-p (frame)
  "Return non-nil when English-reading speech locks translation for FRAME."
  (and (listp my/read-kokoro-context)
       (eq frame (plist-get my/read-kokoro-context :frame))
       (stringp (plist-get my/read-kokoro-context :text))
       (not (string-empty-p (plist-get my/read-kokoro-context :text)))))

(defun my/read--translation-target (frame center)
  "Return (MODE TEXT BUFFER BEG END) to translate for FRAME and CENTER."
  (if (my/read--kokoro-context-for-frame-p frame)
      (list 'kokoro
            (plist-get my/read-kokoro-context :text)
            (plist-get my/read-kokoro-context :buffer)
            (plist-get my/read-kokoro-context :beg)
            (plist-get my/read-kokoro-context :end))
    (if-let ((sentence (my/read-current-sentence-at-window center)))
        (cons 'sentence sentence)
      (list 'sentence nil nil nil nil))))


;;; ---------------------------------------------------------------------------
;;; Local translation and Google fallback
;;; ---------------------------------------------------------------------------

(defun my/read--translation-languages (&optional frame source-buffer)
  "Return (SOURCE TARGET) language codes for FRAME and SOURCE-BUFFER."
  (let* ((source-buffer
          (or source-buffer
              (and (frame-live-p frame)
                   (when-let ((center (my/read-center-window frame)))
                     (window-buffer center)))))
         (source-language
          (or (and (buffer-live-p source-buffer)
                   (buffer-local-value 'my/read-source-language source-buffer))
              (and (frame-live-p frame)
                   (let ((kindle-buffer
                          (frame-parameter frame 'my-reading-kindle-buffer)))
                     (or (null kindle-buffer)
                         (eq source-buffer kindle-buffer)))
                   (frame-parameter frame 'my-reading-source-language))
              google-translate-default-source-language
              "en"))
         (target-language
          (if (equal source-language "ja")
              my/read-japanese-translation-target-language
            (or google-translate-default-target-language "ja"))))
    (list source-language target-language)))

(defun my/read--translation-language-name (code)
  "Return an English language name for CODE suitable for a model prompt."
  (or (cdr (assoc code '(("en" . "English")
                         ("ja" . "Japanese")
                         ("es" . "Spanish")
                         ("fr" . "French")
                         ("de" . "German")
                         ("it" . "Italian")
                         ("pt" . "Portuguese")
                         ("zh" . "Chinese")
                         ("ko" . "Korean"))))
      code))

(defun my/read--local-translation-prompt (text &optional frame source-buffer)
  "Build TranslateGemma's prompt for TEXT in FRAME from SOURCE-BUFFER."
  (pcase-let* ((`(,source ,target)
                 (my/read--translation-languages frame source-buffer))
               (source-name (my/read--translation-language-name source))
               (target-name (my/read--translation-language-name target)))
    (format
     (concat "You are a professional %s (%s) to %s (%s) translator. "
             "Accurately convey the meaning and nuances of the original text "
             "while using natural %s grammar and vocabulary. "
             "Produce only the %s translation, without explanations or commentary. "
             "Please translate the following text:\n\n%s")
     source-name source target-name target target-name target-name text)))

(defun my/read--local-translation-request (text &optional frame source-buffer)
  "Return an Ollama JSON request translating TEXT locally."
  (json-encode
   `((model . ,my/read-local-translation-model)
     (stream . :json-false)
     (messages . [((role . "user")
                   (content . ,(my/read--local-translation-prompt
                                text frame source-buffer)))])
     (options . ((temperature . 0))))))

(defun my/read-google-translate-url (text &optional frame source-buffer)
  "Build a Google Translate URL for TEXT in FRAME from SOURCE-BUFFER.
Detected Kindle sources use their own source language.  Japanese is translated
to `my/read-japanese-translation-target-language'; all other languages use the
  normal google-translate.el target."
  (pcase-let* ((`(,source-language ,target-language)
                 (my/read--translation-languages frame source-buffer))
               ;; The old translate.google.com + client=gtx combination now
               ;; returns HTTP 429 on otherwise ordinary requests.  Chrome's
               ;; dictionary endpoint still provides the same nested JSON
               ;; shape consumed by `google-translate-json-translation'.
               (google-translate-base-url
                "https://clients5.google.com/translate_a/single")
               (url
                (google-translate--format-request-url
                 `(("client" . "dict-chrome-ex")
                   ("ie"     . "UTF-8")
                   ("oe"     . "UTF-8")
                   ("sl"     . ,source-language)
                   ("tl"     . ,target-language)
                   ("dt"     . "t")
                   ("q"      . ,text)))))
    ;; Support google-translate.el versions whose base URL is still http.
    (replace-regexp-in-string "\\`http:" "https:" url)))

(defun my/read-translate-buffer (&optional frame)
  "Return FRAME's dedicated translation buffer."
  (let* ((frame (or frame (selected-frame)))
         (buffer (frame-parameter frame 'my-reading-translate-buffer)))
    (unless (buffer-live-p buffer)
      (setq buffer (generate-new-buffer my/read-translate-buffer-name))
      (set-frame-parameter frame 'my-reading-translate-buffer buffer))
    (with-current-buffer buffer
      (unless (derived-mode-p 'special-mode)
        (special-mode))
      (visual-line-mode 1)
      ;; `tab-line-mode' is buffer-local.  Keep the compact translation pane
      ;; free of buffer tabs without changing the center or Lookup panes.
      (when (fboundp 'tab-line-mode)
        (tab-line-mode -1)))
    buffer))

(defun my/read-translate-delete-overlay (&optional frame)
  "Delete FRAME's translation-target overlay."
  (let* ((frame (or frame (selected-frame)))
         (overlay (and (frame-live-p frame)
                       (frame-parameter frame
                                        'my-reading-translate-overlay))))
    (when (overlayp overlay)
      (delete-overlay overlay))
    (when (frame-live-p frame)
      (set-frame-parameter frame 'my-reading-translate-overlay nil))))

(defun my/read--translate-overlay-background (frame)
  "Return a theme-aware translucent-blue background color for FRAME."
  (let* ((background (or (face-background 'default frame t) "#000000"))
         (blue (color-name-to-rgb "LightSkyBlue" frame))
         (base (color-name-to-rgb background frame))
         (opacity (max 0.0 (min 1.0 my/read-translate-overlay-opacity))))
    (if (and blue base)
        (apply #'color-rgb-to-hex
               (append
                (cl-mapcar
                 (lambda (blue-component background-component)
                   (+ (* opacity blue-component)
                      (* (- 1.0 opacity) background-component)))
                 blue base)
                '(2)))
      background)))

(defun my/read-refresh-translate-overlay-face (&optional frame)
  "Refresh the translation overlay face for FRAME's current theme."
  (let ((frame (or frame (selected-frame))))
    (when (frame-live-p frame)
      (set-face-attribute
       'my/read-translate-overlay-face frame
       :inherit nil
       :background (my/read--translate-overlay-background frame)
       :foreground 'unspecified
       :family 'unspecified
       :foundry 'unspecified
       :width 'unspecified
       :height 'unspecified
       :weight 'unspecified
       :slant 'unspecified
       :extend t))))

(defun my/read-translate-show-overlay (frame buffer beg end)
  "Highlight BUFFER from BEG to END as FRAME's translation target."
  (my/read-translate-delete-overlay frame)
  (when (and (frame-live-p frame)
             (buffer-live-p buffer)
             (integer-or-marker-p beg)
             (integer-or-marker-p end)
             (< beg end)
             (<= end (with-current-buffer buffer (point-max))))
    (my/read-refresh-translate-overlay-face frame)
    (let ((overlay (make-overlay beg end buffer nil t)))
      (overlay-put overlay 'face 'my/read-translate-overlay-face)
      ;; Let Kokoro's normal `highlight' overlay remain visually dominant when
      ;; speech and translation cover the same sentence.
      (overlay-put overlay 'priority -10)
      (overlay-put overlay 'evaporate t)
      (overlay-put overlay 'window
                   (my/read-center-window-for-buffer frame buffer))
      (set-frame-parameter frame 'my-reading-translate-overlay overlay))))

(defun my/read-translate-display (frame source translation mode &optional backend)
  "Display SOURCE and TRANSLATION in FRAME.
MODE is `kokoro' or `sentence'.  BACKEND is `local' or `google'."
  (when (and (frame-live-p frame)
             (my/read-frame-p frame))
    (when-let ((window (my/read-translate-window frame)))
      (let ((buffer (my/read-translate-buffer frame)))
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert
             (propertize
              (format "%s  [%s]\n\n"
                      (if (eq backend 'google)
                          "Google Translate"
                        "Local Translate")
                      (if (eq mode 'kokoro) "Kokoro" "Sentence"))
              'face 'font-lock-keyword-face))
            (insert translation)
            (insert "\n\n")
            (insert (propertize "──────────\n" 'face 'shadow))
            (insert (propertize source 'face 'shadow))
            (goto-char (point-min))))
        (set-window-buffer window buffer)
        (set-window-point window (point-min))))))

(defun my/read-translate-stop-process ()
  "Stop the currently running translation process."
  (when (process-live-p my/read-translate-process)
    (delete-process my/read-translate-process))
  (setq my/read-translate-process nil))

(defun my/read--translation-response (backend response)
  "Extract translated text from BACKEND's RESPONSE string."
  (let ((translation
         (pcase backend
           ('local
            (let* ((json-object-type 'alist)
                   (json (json-read-from-string response))
                   (reply (alist-get 'message json)))
              (alist-get 'content reply)))
           ('google
            (let ((json-array-type 'vector)
                  (json-object-type 'alist))
              (google-translate-json-translation
               (json-read-from-string
                (google-translate--insert-nulls response))))))))
    (and (stringp translation)
         (not (string-empty-p (string-trim translation)))
         (string-trim translation))))

(defun my/read--start-translation-request
    (backend frame center target mode text source-buffer)
  "Start BACKEND request for TEXT belonging to TARGET in FRAME and CENTER."
  (let* ((local-p (eq backend 'local))
         (buffer
          (generate-new-buffer
           (if local-p
               " *Reading Local Translate Process*"
             " *Reading Google Translate Process*")))
         (command
          (if local-p
              (list "curl" "-sS" "--fail-with-body"
                    "--connect-timeout" "1"
                    "--max-time" (number-to-string
                                   my/read-local-translation-timeout)
                    "-H" "Content-Type: application/json"
                    "--data-binary"
                    (my/read--local-translation-request
                     text frame source-buffer)
                    my/read-local-translation-url)
            (list "curl" "-s" "-L" "-A" "Emacs"
                  (my/read-google-translate-url
                   text frame source-buffer))))
         (process
          (make-process
           :name (if local-p
                     "reading-local-translate"
                   "reading-google-translate")
           :buffer buffer
           :command command
           :coding 'utf-8-unix
           :noquery t
           :sentinel
           (lambda (proc _event)
             (when (memq (process-status proc) '(exit signal))
               (unwind-protect
                   (when (and (frame-live-p frame)
                              (window-live-p center)
                              (equal target my/read-translate-last-target))
                     (let ((translation
                            (and (= (process-exit-status proc) 0)
                                 (condition-case nil
                                     (with-current-buffer (process-buffer proc)
                                       (my/read--translation-response
                                        backend (buffer-string)))
                                   (error nil)))))
                       (cond
                        (translation
                         (my/read-translate-display
                          frame text translation mode backend))
                        ((and local-p my/read-google-translation-fallback)
                         (message
                          "Local translation unavailable; using Google Translate")
                         (my/read--start-translation-request
                          'google frame center target mode text source-buffer))
                        (t
                         (message "%s translation failed"
                                  (if local-p "Local" "Google"))))))
                 (when-let ((proc-buffer (process-buffer proc)))
                   (when (buffer-live-p proc-buffer)
                     (kill-buffer proc-buffer)))
                 (when (eq proc my/read-translate-process)
                   (setq my/read-translate-process nil))))))))
    (setq my/read-translate-process process)))

(defun my/read-translate-start (frame center target mode text)
  "Start asynchronous translation of TEXT.
FRAME, CENTER and TARGET identify the request; MODE describes its source."
  (setq my/read-translate-timer nil)

  ;; Drop an idle-timer request if the reading target changed meanwhile.
  (when (and my-read-translate-follow-mode
             (not (and (listp my/read-speech-translation-suppressed-context)
                       (eq frame
                           (plist-get
                            my/read-speech-translation-suppressed-context
                            :frame))))
             (frame-live-p frame)
             (window-live-p center)
             (equal target my/read-translate-last-target))
    (my/read-translate-stop-process)
    (my/read--start-translation-request
     my/read-translation-backend frame center target mode text (nth 1 target))))

(defun my/read-translate-update-for-frame (frame center)
  "Update translation target for FRAME using CENTER.

While Kokoro is active in FRAME, keep translation locked to the exact spoken
sentence.  Otherwise translate the sentence containing CENTER's point.  This
function is also safe to call asynchronously from the speech-finish hook."
  (when (and my-read-translate-follow-mode
             (not (and (listp my/read-speech-translation-suppressed-context)
                       (eq frame
                           (plist-get
                            my/read-speech-translation-suppressed-context
                            :frame))))
             (frame-live-p frame)
             (my/read-frame-p frame)
             (window-live-p center))
    (pcase-let* ((`(,mode ,text ,buffer ,beg ,end)
                   (my/read--translation-target frame center))
                 (target
                  (and text
                       (list frame buffer mode beg end text))))
      (unless (equal target my/read-translate-last-target)
        (setq my/read-translate-last-target target)

        ;; A newly selected target supersedes both a pending idle timer and an
        ;; in-flight HTTP request for the old target.
        (when (timerp my/read-translate-timer)
          (cancel-timer my/read-translate-timer)
          (setq my/read-translate-timer nil))
        (my/read-translate-stop-process)

        (if text
            (progn
              (my/read-translate-show-overlay frame buffer beg end)
              (setq my/read-translate-timer
                    (run-with-idle-timer
                     my/read-translate-idle-delay
                     nil
                     #'my/read-translate-start
                     frame
                     center
                     target
                     mode
                     text)))
          (my/read-translate-delete-overlay frame))))))

(defun my/read-translate-follow-post-command ()
  "Translate the appropriate text for the selected my-read center window.

While Kokoro is active, translate exactly the text currently being read.
Otherwise, translate the sentence containing point."
  (when my-read-translate-follow-mode
    (let* ((frame (selected-frame))
           (center (my/read-center-window frame)))
      (when (and (my/read-frame-p frame)
                 (my/read--center-source-window-p center frame)
                 (eq (selected-window) center))
        (my/read-translate-update-for-frame frame center)))))

(define-minor-mode my-read-translate-follow-mode
  "Automatically update translation from a my-read center window."
  :global t
  :lighter " Tr↔"
  (if my-read-translate-follow-mode
      (progn
        (setq my/read-translate-last-target nil)
        (add-hook 'post-command-hook
                  #'my/read-translate-follow-post-command))
    (remove-hook 'post-command-hook
                 #'my/read-translate-follow-post-command)
    (when (timerp my/read-translate-timer)
      (cancel-timer my/read-translate-timer))
    (my/read-translate-stop-process)
    (dolist (frame (frame-list))
      (when (my/read-frame-p frame)
        (my/read-translate-delete-overlay frame)))
    (setq my/read-translate-timer nil
          my/read-translate-last-target nil)))



;;; ---------------------------------------------------------------------------
;;; English-reading speech -> translation lock
;;; ---------------------------------------------------------------------------

(defun my/read--english-speech-context-p (context)
  "Return non-nil when spoken CONTEXT has an English source language."
  (let ((frame (plist-get context :frame))
        (source-buffer (plist-get context :buffer)))
    (equal (car (my/read--translation-languages frame source-buffer)) "en")))

(defun my/read--english-speech-start (context)
  "Translate English CONTEXT, or suppress translation for other languages."
  (let* ((frame (plist-get context :frame))
         (window (plist-get context :window))
         (center (and (frame-live-p frame)
                      (memq window (my/read-center-windows frame))
                      window)))
    (when (and (frame-live-p frame)
               (my/read-frame-p frame)
               (window-live-p center)
               (eq window center))
      (if (my/read--english-speech-context-p context)
          (progn
            ;; This runs before point advances.  CONTEXT remains the
            ;; translation source even after point has moved onward.
            (setq my/read-speech-translation-suppressed-context nil
                  my/read-kokoro-context context)
            (my/read-translate-update-for-frame frame center))
        (setq my/read-kokoro-context nil
              my/read-speech-translation-suppressed-context context
              my/read-translate-last-target nil)
        (when (timerp my/read-translate-timer)
          (cancel-timer my/read-translate-timer)
          (setq my/read-translate-timer nil))
        (my/read-translate-stop-process)
        (my/read-translate-delete-overlay frame)))))

(defun my/read--english-speech-finish (context)
  "Unlock translation when the matching English-reading CONTEXT finishes."
  (when (eq context my/read-speech-translation-suppressed-context)
    (setq my/read-speech-translation-suppressed-context nil))
  ;; Ignore stale completion from an utterance replaced by a newer one.
  (when (eq context my/read-kokoro-context)
    (let ((frame (plist-get context :frame)))
      (setq my/read-kokoro-context nil)
      (when (frame-live-p frame)
        (when-let ((center
                    (and (window-live-p (plist-get context :window))
                         (plist-get context :window))))
          ;; Only now follow point again.  With `j', point is normally already
          ;; on the next sentence, so that sentence becomes the new target.
          (my/read-translate-update-for-frame frame center))))))

(add-hook 'english-reading-mode-speech-start-hook
          #'my/read--english-speech-start)
(add-hook 'english-reading-mode-speech-finish-hook
          #'my/read--english-speech-finish)


(defun my/read-translation-lock-status ()
  "Report whether my-read translation is currently locked to Kokoro speech."
  (interactive)
  (if my/read-kokoro-context
      (message "my-read translation LOCKED [Kokoro]: %s"
               (plist-get my/read-kokoro-context :text))
    (message "my-read translation UNLOCKED [Sentence]")))

;;; ---------------------------------------------------------------------------
;;; my-read frame setup
;;; ---------------------------------------------------------------------------

(require 'my-read-org-noter)

(defun my/read--prepare-notes-buffer (frame)
  "Create and return FRAME's Org-noter landing buffer."
  (let ((buffer (frame-parameter frame 'my-reading-note-ready-buffer)))
    (unless (buffer-live-p buffer)
      (setq buffer (generate-new-buffer "*Org-noter Ready*"))
      (set-frame-parameter frame 'my-reading-note-ready-buffer buffer))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (org-mode)
        (insert "* Org-noter\n\nPDF / EPUB / Kindleを開くと、この領域にノートを表示します。\n")))
    buffer))

(defun my/read--prepare-ready-buffer (frame)
  "Create and return FRAME's Lookup placeholder buffer."
  (let ((buffer (frame-parameter frame 'my-reading-lookup-ready-buffer)))
    (unless (buffer-live-p buffer)
      (setq buffer (generate-new-buffer "*Lookup Ready*"))
      (set-frame-parameter frame 'my-reading-lookup-ready-buffer buffer))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Lookup\n\n中央の単語へカーソルを置くと自動検索")
        (special-mode)))
    buffer))

(defun my/read-eww-history--empty-data ()
  "Return an empty EWW history data object."
  '(:version 1 :entries nil))

(defun my/read-eww-history--valid-data-p (data)
  "Return non-nil when DATA is a valid EWW history object."
  (and (listp data)
       (equal (plist-get data :version) 1)
       (let ((entries (plist-get data :entries)))
         (and (listp entries)
              (cl-every
               (lambda (entry)
                 (and (consp entry)
                      (stringp (car entry))
                      (stringp (plist-get (cdr entry) :title))
                      (numberp (plist-get (cdr entry) :visited))))
               entries)))))

(defun my/read-eww-history--read-data ()
  "Read persistent EWW history, preserving an invalid file unchanged."
  (if (not (file-exists-p my/read-eww-history-file))
      (my/read-eww-history--empty-data)
    (condition-case err
        (with-temp-buffer
          (insert-file-contents my/read-eww-history-file)
          (let ((read-eval nil)
                (data (read (current-buffer))))
            (skip-chars-forward " \t\r\n")
            (unless (and (eobp) (my/read-eww-history--valid-data-p data))
              (error "invalid EWW history data"))
            data))
      (error
       (message "my-read: EWW履歴ファイルを保護しました（%s）"
                (error-message-string err))
       :invalid))))

(defun my/read-eww-history--write-data (data)
  "Atomically write validated EWW history DATA."
  (let* ((directory (file-name-directory my/read-eww-history-file))
         temp)
    (make-directory directory t)
    (setq temp (make-temp-file (expand-file-name ".eww-history-" directory)))
    (unwind-protect
        (progn
          (with-temp-buffer
            (insert ";;; my-read EWW history -*- mode: emacs-lisp; -*-\n")
            (let ((print-length nil)
                  (print-level nil))
              (prin1 data (current-buffer)))
            (insert "\n")
            (write-region (point-min) (point-max) temp nil 'silent))
          (set-file-modes temp #o600)
          (rename-file temp my/read-eww-history-file t)
          (setq temp nil))
      (when (and temp (file-exists-p temp))
        (delete-file temp)))))

(defun my/read-eww-history--clean-title (title url)
  "Return a single-line TITLE, falling back to URL."
  (let ((title (string-trim
                (replace-regexp-in-string "[\r\n\t ]+" " " (or title "")))))
    (if (string-empty-p title) url title)))

(defun my/read-eww-history-record-current ()
  "Persist the current rendered page when it belongs to a my-read EWW tab."
  (when (derived-mode-p 'eww-mode)
    (setq my/read-eww-history-page-p nil)
    (let* ((frame (and (boundp 'my/read-center-tab-frame)
                       my/read-center-tab-frame))
           (center (and (frame-live-p frame)
                        (my/read-center-window frame)))
           (url (and (boundp 'eww-data) (plist-get eww-data :url)))
           (title (and (boundp 'eww-data) (plist-get eww-data :title))))
      (when (and (stringp url)
                 (not (string-empty-p url))
                 (frame-live-p frame)
                 (my/read-frame-p frame)
                 (eq (frame-parameter frame 'my-reading-eww-buffer)
                     (current-buffer)))
        (let ((data (my/read-eww-history--read-data)))
          (unless (eq data :invalid)
            (let* ((entry (list url
                                :title (my/read-eww-history--clean-title
                                        title url)
                                :visited (float-time)))
                   (entries
                    (cons entry
                          (cl-remove url (plist-get data :entries)
                                     :key #'car :test #'equal))))
              (setf (plist-get data :entries)
                    (cl-subseq entries 0
                               (min (length entries)
                                    (max 0 my/read-eww-history-limit))))
              (my/read-eww-history--write-data data))))
        (when (and (window-live-p center)
                   (eq (window-buffer center) (current-buffer))
                   (fboundp 'my/read-org-noter-follow-source))
          (my/read-org-noter-follow-source frame))))))

(defun my/read-eww-history-open (button)
  "Open the URL stored on history BUTTON in the current EWW buffer."
  (setq my/read-eww-history-page-p nil)
  (eww (button-get button 'my/read-eww-url)))

(defun my/read-eww-history-render ()
  "Render persistent title-and-URL history in the current EWW buffer."
  (let* ((data (my/read-eww-history--read-data))
         (entries (unless (eq data :invalid) (plist-get data :entries)))
         (inhibit-read-only t))
    (erase-buffer)
    (setq my/read-eww-history-page-p t)
    (setq-local eww-data (list :url my/read-eww-url :title "EWW History"))
    (insert (propertize "EWW History\n\n" 'face 'font-lock-keyword-face))
    (insert "G: URLを入力\n")
    (insert (format "g: %s を開く\n\n" my/read-eww-url))
    (cond
     ((eq data :invalid)
      (insert "履歴ファイルが不正なため、内容を変更せず保護しています。"))
     ((null entries)
      (insert "履歴はまだありません。"))
     (t
      (dolist (entry entries)
        (let ((url (car entry))
              (title (plist-get (cdr entry) :title)))
          (insert-text-button
           title 'follow-link t 'help-echo url
           'my/read-eww-url url 'action #'my/read-eww-history-open)
          (insert "\n  ")
          (insert-text-button
           url 'follow-link t 'help-echo title
           'my/read-eww-url url 'action #'my/read-eww-history-open)
          (insert "\n\n")))))
    (goto-char (point-min))))

(defun my/read--prepare-eww-buffer (frame)
  "Create and return FRAME's EWW center-tab buffer."
  (require 'eww)
  (let ((buffer (frame-parameter frame 'my-reading-eww-buffer)))
    (unless (buffer-live-p buffer)
      (setq buffer (generate-new-buffer "*my-read EWW*"))
      (set-frame-parameter frame 'my-reading-eww-buffer buffer))
    (with-current-buffer buffer
      (unless (derived-mode-p 'eww-mode)
        (eww-mode))
      (require 'my-read-eww-math)
      (my/read-eww-math-setup)
      (my/read--eww-image-background-setup)
      (add-hook 'eww-after-render-hook
                #'my/read-eww-history-record-current nil t)
      (setq-local line-spacing my/read-eww-line-spacing)
      ;; Reuse the EPUB/Kindle reading controls in rendered web papers.
      ;; `eww-setup-buffer' does not re-run `eww-mode' on navigation, so this
      ;; minor mode and its reader bindings remain active after page loads.
      (english-reading-mode 1)
      (my/read-eww-history-render))
    buffer))

(defun my/read--prepare-center-tab-placeholder (frame type)
  "Return FRAME's persistent empty center-tab placeholder for TYPE."
  (let* ((parameter (intern (format "my-reading-%s-placeholder-buffer" type)))
         (buffer (frame-parameter frame parameter)))
    (unless (buffer-live-p buffer)
      (setq buffer
            (generate-new-buffer
             (format "*my-read %s*" (upcase (symbol-name type)))))
      (set-frame-parameter frame parameter buffer))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode))
      (setq-local my/read-center-tab-placeholder-type type))
    buffer))

(defun my/read--setup-frame (frame &optional kindle-buffer)
  "Build the my-read layout inside FRAME.
When KINDLE-BUFFER is live, expose it with the center document tabs."
  (with-selected-frame frame
    (delete-other-windows)

    (let* ((center-window (selected-window))
           ;; Two columns: reading on the left, three utilities on the right.
           (note-window (split-window-right))
           epub-buffer
           pdf-buffer
           dired-buffer
           eww-buffer
           translate-window
           lookup-window)

      ;; Right column: Org-noter, translation, then Lookup.
      (select-window note-window)
      (setq translate-window
            (split-window-below
             (max window-min-height
                  (floor (/ (window-total-height note-window) 3.0)))))
      (select-window translate-window)
      (setq lookup-window (split-window-below))

      ;; Store window identity on the frame.
      (set-frame-parameter frame 'my-reading-lookup-window lookup-window)
      (set-frame-parameter frame 'my-reading-center-window center-window)
      (set-frame-parameter frame 'my-reading-kindle-window center-window)
      (set-frame-parameter frame 'my-reading-epub-window center-window)
      (set-frame-parameter frame 'my-reading-pdf-window center-window)
      (set-frame-parameter frame 'my-reading-dired-window center-window)
      (set-frame-parameter frame 'my-reading-eww-window center-window)
      (set-frame-parameter frame 'my-reading-center-windows (list center-window))
      (set-frame-parameter frame 'my-reading-kindle-buffer kindle-buffer)
      (set-frame-parameter frame 'my-reading-translate-window translate-window)
      (set-frame-parameter frame 'my-reading-note-window note-window)
      ;; Lookup otherwise honors the user's global fractional height (0.7 in
      ;; this setup), which leaves too little room for dictionary content.
      (set-frame-parameter frame 'lookup-window-height
                           my/read-lookup-entry-window-height)

      ;; Lookup must not reuse stale internal windows from another frame.
      (when (boundp 'lookup-main-window)
        (setq lookup-main-window nil
              lookup-sub-window nil))

      ;; Right top: Org-noter notes placeholder (replaced by a live session).
      (set-window-buffer note-window (my/read--prepare-notes-buffer frame))

      ;; Right bottom: Lookup placeholder.
      (set-window-buffer lookup-window (my/read--prepare-ready-buffer frame))

      ;; Right middle: local translation with Google fallback.
      (let ((buffer (my/read-translate-buffer frame)))
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert
             (propertize "Translation\n\n"
                         'face 'font-lock-keyword-face))
            (insert
             "カーソル位置の1文を翻訳します。\nKokoro読み上げ中は読み上げている1文を翻訳します。")))
        (set-window-buffer translate-window buffer)
        (set-window-dedicated-p translate-window t))

      ;; Open the configured path and register it by source type.  Keep its
      ;; containing Dired buffer alive as a permanent tab even after RET opens
      ;; an EPUB or PDF in this same window.
      (select-window center-window)
      (let ((book-path (expand-file-name my/read-book-path)))
        (find-file book-path)
        (cond
         ((derived-mode-p 'dired-mode)
          (setq dired-buffer (current-buffer)))
         ((or (derived-mode-p 'pdf-view-mode 'doc-view-mode)
              (string-match-p "\\.pdf\\'" book-path))
          (setq pdf-buffer (current-buffer)))
         (t
          (setq epub-buffer (current-buffer))))
        (unless (buffer-live-p dired-buffer)
          (require 'dired)
          (setq dired-buffer
                (dired-noselect
                 (if (file-directory-p book-path)
                     book-path
                   (file-name-directory book-path))))))
      (unless (buffer-live-p kindle-buffer)
        (setq kindle-buffer
              (my/read--prepare-center-tab-placeholder frame 'kindle)))
      (unless (buffer-live-p pdf-buffer)
        (setq pdf-buffer
              (my/read--prepare-center-tab-placeholder frame 'pdf)))
      (unless (buffer-live-p epub-buffer)
        (setq epub-buffer
              (my/read--prepare-center-tab-placeholder frame 'epub)))
      (set-frame-parameter frame 'my-reading-kindle-buffer kindle-buffer)
      (set-frame-parameter frame 'my-reading-epub-buffer epub-buffer)
      (set-frame-parameter frame 'my-reading-pdf-buffer pdf-buffer)
      (set-frame-parameter frame 'my-reading-dired-buffer dired-buffer)
      (dolist (buffer (list kindle-buffer pdf-buffer epub-buffer dired-buffer))
        (my/read--configure-center-tab-buffer buffer frame))

      ;; Keep an EWW buffer ready for arXiv without fetching the network until
      ;; the user opens the tab and presses `G'.
      (setq eww-buffer (my/read--prepare-eww-buffer frame))
      (my/read--configure-center-tab-buffer eww-buffer frame)

      ;; DIRED is the leftmost and initially selected center tab.
      (when (buffer-live-p dired-buffer)
        (set-window-buffer center-window dired-buffer))

      ;; Start with the book directory visible.
      (select-window center-window)

      ;; Self-contained Lookup follower from this file.
      (my-read-lookup-follow-mode 1)

      ;; Translation follower from this file.
      (my-read-translate-follow-mode 1)

      ;; Initial refresh.
      (my/read-lookup-follow-post-command)
      (my/read-translate-follow-post-command)
      ;; Kindle attaches asynchronously; EPUB/PDF can start immediately.
      (my/read-org-noter-follow-source frame))))

;;;###autoload
(defun my-read ()
  "Open the unified Kindle.app, EPUB, and EWW reading workspace."
  (interactive)
  ;; Load lazily to avoid a load-time cycle: my-read-k2 requires my-read via
  ;; the shared my-read-k UI implementation.
  (require 'my-read-k2)
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
      (when-let ((buffer (frame-parameter frame parameter)))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))

    (unless (my/read--other-reading-frame-p frame)
      (my/read--lookup-restore-normal)
      (my-read-lookup-follow-mode -1)
      (my-read-translate-follow-mode -1))))

(add-hook 'delete-frame-functions #'my/read--frame-deleted)


;;; ---------------------------------------------------------------------------
;;; Reading mode / convenience keys
;;; ---------------------------------------------------------------------------

;; Reading keys are installed buffer-locally by
;; `my/read--configure-center-tab-buffer' and filtered by the selected window.
;; Remove registrations left by older revisions when this file is reloaded.
(remove-hook 'nov-mode-hook #'english-reading-mode)
(remove-hook 'doc-view-mode-hook #'english-reading-mode)
(dolist (entry '(("C-c p" . kokoro-reader-speak-paragraph)
                 ("C-c n" . kokoro-reader-speak-and-forward)
                 ("C-c k" . kokoro-reader-stop)))
  (when (eq (lookup-key global-map (kbd (car entry))) (cdr entry))
    (define-key global-map (kbd (car entry)) nil)))

(provide 'my-read)
;;; my-read.el ends here
