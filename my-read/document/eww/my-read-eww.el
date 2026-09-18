;;; my-read-eww.el --- Eww for the reader -*- lexical-binding: t; -*-

(declare-function my/read--prepare-notes-buffer "my-read-ui")
(declare-function my/read--center-window-active-p "my-read-ui")
(declare-function my/read-org-noter-close-source "my-read-org-noter")
(declare-function my/read-lookup-follow-post-command "my-read-lookup")
(declare-function my/read-translate-follow-post-command "my-read-translation")

(declare-function my/read--configure-center-tab-buffer "my-read-ui")
(declare-function my/read--configure-speech-language "my-read-speech-settings")
(declare-function my/read-eww-math-setup "my-read-eww-math")
(require 'my-read-core)
(require 'reader-state-file)
(require 'my-read-position)
(require 'color)
(require 'dom)
(require 'eww)

(defvar my/read-eww-history-page-p)

(defvar-local my/read-position--eww-file nil
  "Local file belonging to the fully rendered EWW document, or nil.")

(defun my/read-position--eww-before-render (&rest _)
  "Save the old EWW document before its rendered contents are replaced."
  (when my/read-position--eww-file
    (my/read-position--save-buffer-now)
    (setq my/read-position--eww-file nil
          my/read-position--restored-p nil)))

(defun my/read-position--eww-after-render ()
  "Restore a local EWW document only after rendering has completed."
  (when (and (derived-mode-p 'eww-mode)
             (frame-live-p my/read-center-tab-frame)
             (not my/read-eww-history-page-p))
    (let* ((url (plist-get eww-data :url))
           (parsed (and (stringp url) (url-generic-parse-url url))))
      (setq my/read-position--eww-file
            (when (and parsed (equal (url-type parsed) "file")
                       (member (url-host parsed) '(nil "" "localhost")))
              (decode-coding-string
               (url-unhex-string (url-filename parsed)) 'utf-8))
            my/read-position--restored-p nil)
      (when my/read-position--eww-file
        (my/read-position-setup-buffer (current-buffer) my/read-center-tab-frame)))))

(with-eval-after-load 'eww
  (advice-add 'eww-setup-buffer :before #'my/read-position--eww-before-render))

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
    (_status buffer start end &optional _flags)
  "Apply the article background after SHR downloads an image into BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when my/read--eww-image-background-installed-p
        ;; The placeholder may already have been marked by the render hook.
        ;; Clear only this fetched image's marker, then process its real data.
        (let ((inhibit-read-only t)
              (begin-position (marker-position start))
              (end-position (marker-position end)))
          (when (and begin-position end-position
                     (< begin-position end-position))
            (remove-text-properties
             begin-position end-position
             '(my/read-eww-image-background nil))))
        (my/read--eww-apply-article-image-background start end)))))

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

(defun my/read--local-html-file ()
  "Return the local HTML file visited by the current source buffer."
  (and buffer-file-name
       (not (file-remote-p buffer-file-name))
       (member (downcase (or (file-name-extension buffer-file-name) ""))
               '("html" "htm" "xhtml"))
       buffer-file-name))

(defun my/read--open-html-in-eww (file frame)
  "Render local HTML FILE in FRAME's EWW reading tab."
  (let ((buffer (frame-parameter frame 'my-reading-eww-buffer)))
    (unless (buffer-live-p buffer)
      (setq buffer (my/read--prepare-eww-buffer frame)))
    (with-selected-window (my/read-center-window frame)
      (switch-to-buffer buffer)
      (my/read--configure-center-tab-buffer buffer frame)
      (add-hook 'eww-after-render-hook
                #'my/read-position--eww-after-render nil t)
      (add-hook 'eww-after-render-hook
                #'my/read--configure-speech-language nil t)
      (eww-open-file file))
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
  "Read validated state without overwriting a corrupted file."
  (reader-state-file-read my/read-eww-history-file #'my/read-eww-history--valid-data-p
                          (my/read-eww-history--empty-data) "EWW履歴"))

(defun my/read-eww-history--write-data (data)
  "Atomically persist DATA with private permissions."
  (reader-state-file-write my/read-eww-history-file data
                           ";;; my-read EWW history -*- mode: emacs-lisp; -*-"))

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

(defun reader-document-eww--source (&optional _frame)
  "Return the rendered local file or EWW URL."
  (or my/read-position--eww-file
      (and (boundp 'eww-data) (plist-get eww-data :url))))

(defun reader-document-eww--title (&optional frame)
  "Return the rendered page title, falling back to its buffer name."
  (or (and (boundp 'eww-data) (plist-get eww-data :title))
      (reader-document-text--title frame)))

(reader-document-register
 'eww (lambda () (derived-mode-p 'eww-mode))
 '(:title reader-document-eww--title :source reader-document-eww--source
          :persistent-type (lambda () (when my/read-position--eww-file 'html))) 'text)

(defun my/read-close-eww ()
  "Close the displayed EWW page while keeping the my-read workspace open."
  (interactive)
  (unless (and (my/read--center-window-active-p) (derived-mode-p 'eww-mode))
    (user-error "my-readのEWWペインで実行してください"))
  (let* ((frame (selected-frame))
         (center (my/read-center-window frame))
         (page (current-buffer))
         (dired (frame-parameter frame 'my-reading-dired-buffer))
         (notes (my/read-note-window frame)))
    (unless (buffer-live-p dired)
      (user-error "my-readのDIREDタブが見つかりません"))
    (my/read-position-save-buffer page center)
    (english-reading-mode-stop-continuous)
    ;; Org-noter must not own either visible window during its teardown.
    (when (window-live-p notes)
      (set-window-buffer notes (my/read--prepare-notes-buffer frame)))
    (set-window-buffer center dired)
    (select-window center)
    (my/read-org-noter-close-source page)
    (when (buffer-live-p page) (kill-buffer page))
    (set-frame-parameter frame 'my-reading-eww-buffer nil)
    (my/read--configure-center-tab-buffer (my/read--prepare-eww-buffer frame) frame)
    (my/read-lookup-follow-post-command)
    (my/read-translate-follow-post-command)
    (message "EWWのページを閉じました")))

(provide 'my-read-eww)
;;; my-read-eww.el ends here
