;;; my-read-eww-math.el --- Asynchronous TeX rendering for EWW -*- lexical-binding: t; -*-

;; Render TeX annotations embedded in arXiv MathML without blocking Emacs.

(require 'cl-lib)
(require 'color)
(require 'dom)
(require 'eww)
(require 'shr)
(require 'subr-x)

(defgroup my-read-eww-math nil
  "Asynchronous math rendering for the my-read EWW tab."
  :group 'my-read)

(defcustom my/read-eww-math-enabled t
  "When non-nil, render trusted EWW MathML TeX annotations as SVG."
  :type 'boolean
  :group 'my-read-eww-math)

(defcustom my/read-eww-math-trusted-url-regexp
  "\\`https://\\(?:www\\.\\)?arxiv\\.org/"
  "Only URLs matching this regexp may send TeX annotations to LaTeX."
  :type 'regexp
  :group 'my-read-eww-math)

(defcustom my/read-eww-math-cache-directory
  (expand-file-name "my-read-eww-math/" user-emacs-directory)
  "Directory containing SVG files cached by formula, color, and layout."
  :type 'directory
  :group 'my-read-eww-math)

(defcustom my/read-eww-math-latex-program "latex"
  "LaTeX executable used to compile one formula at a time."
  :type 'string
  :group 'my-read-eww-math)

(defcustom my/read-eww-math-dvisvgm-program "dvisvgm"
  "Executable used to convert a formula DVI file to SVG."
  :type 'string
  :group 'my-read-eww-math)

(defcustom my/read-eww-math-process-timeout 8
  "Seconds before a formula conversion process is terminated."
  :type 'number
  :group 'my-read-eww-math)

(defcustom my/read-eww-math-max-tex-length 4000
  "Maximum accepted length of one TeX annotation."
  :type 'integer
  :group 'my-read-eww-math)

(defcustom my/read-eww-math-image-ascent 80
  "Image ascent percentage used for inline SVG formulas."
  :type 'integer
  :group 'my-read-eww-math)

(defcustom my/read-eww-math-image-scale nil
  "Scale factor for rendered formulas, or nil to match the default face.

Automatic scaling treats the LaTeX source as 12pt and follows the current
default face height, clamped to a practical range."
  :type '(choice (const :tag "Match default face" nil) number)
  :group 'my-read-eww-math)

(defcustom my/read-eww-math-image-scale-multiplier 1.5
  "Extra multiplier applied when formula scaling is automatic.

The default makes inline and display formulas about 1.5 times as large as the
font-matched size.  Set `my/read-eww-math-image-scale' to a number when an
absolute scale is preferred instead."
  :type 'number
  :group 'my-read-eww-math)

(defcustom my/read-eww-math-inline-scale-multiplier 1.25
  "Additional scale applied only to inline formulas.

This keeps short but semantically important expressions such as subscripts,
superscripts, and dimension declarations legible inside prose."
  :type 'number
  :group 'my-read-eww-math)

(defcustom my/read-eww-math-image-vertical-margin 0
  "Vertical margin in pixels around SVG formulas.

The EWW buffer normally provides its line height through
`my/read-eww-line-spacing'; this option is available for additional
formula-specific padding when needed."
  :type 'integer
  :group 'my-read-eww-math)

(defcustom my/read-eww-math-svg-stroke-width 0.18
  "Outline width added to SVG formula glyphs.

A small same-color stroke makes Computer Modern math slightly bolder without
changing the source formula or replacing its mathematical font."
  :type 'number
  :group 'my-read-eww-math)

(defcustom my/read-eww-math-svg-padding 1.0
  "Padding in TeX points added around the generated SVG view box.

`dvisvgm --exact-bbox' otherwise places the boundary exactly on the outermost
glyph path.  Padding prevents antialiasing and the boldening stroke from being
clipped at any edge."
  :type 'number
  :group 'my-read-eww-math)

(defconst my/read-eww-math--cache-version "v4")

(defconst my/read-eww-math--unsafe-command-regexp
  (concat
   "\\\\\\(?:input\\|include\\|includeonly\\|openin\\|openout\\|read\\|"
   "write\\|special\\|usepackage\\|documentclass\\|catcode\\|csname\\|"
   "newread\\|newwrite\\|immediate\\|everyjob\\|endlinechar\\)"
   "\\(?:[^[:alpha:]@]\\|\\'\\)")
  "TeX commands that are never accepted from webpage annotations.")

(defvar-local my/read-eww-math--queue nil)
(defvar-local my/read-eww-math--active-process nil)
(defvar-local my/read-eww-math--generation 0)
(defvar-local my/read-eww-math--job-counter 0)
(defvar-local my/read-eww-math--installed-p nil)
(defvar my/read-eww-math--missing-program-warning-shown nil)
(defvar my/read-eww-math--render-target-buffer nil)

(defun my/read-eww-math--url (&optional buffer)
  "Return BUFFER's current EWW URL, if any."
  (let ((target (or buffer (current-buffer))))
    (when (buffer-live-p target)
      (with-current-buffer target
        (and (boundp 'eww-data) (plist-get eww-data :url))))))

(defun my/read-eww-math--trusted-page-p (&optional buffer)
  "Return non-nil when BUFFER's EWW page may render TeX."
  (let ((url (my/read-eww-math--url buffer)))
    (and my/read-eww-math-enabled
         (stringp url)
         (string-match-p my/read-eww-math-trusted-url-regexp url))))

(defun my/read-eww-math--tex (dom)
  "Return DOM's embedded TeX annotation, or nil."
  (when-let* ((semantics (dom-child-by-tag dom 'semantics))
              (annotation (dom-child-by-tag semantics 'annotation))
              ((equal (dom-attr annotation 'encoding) "application/x-tex"))
              (text (string-trim (dom-inner-text annotation)))
              ((not (string-empty-p text))))
    text))

(defun my/read-eww-math--display-p (dom)
  "Return non-nil when DOM represents display rather than inline math."
  (or (equal (dom-attr dom 'display) "block")
      (let ((class (dom-attr dom 'class)))
        (and (stringp class)
             (string-match-p "\\bltx_\\(?:display\\|equation\\)\\b" class)))))

(defun my/read-eww-math--safe-tex-p (tex)
  "Return non-nil when TEX is small and excludes file/process primitives."
  (and (stringp tex)
       (<= (length tex) my/read-eww-math-max-tex-length)
       (not (string-match-p "\0" tex))
       (let ((case-fold-search t))
         (not (string-match-p my/read-eww-math--unsafe-command-regexp tex)))))

(defun my/read-eww-math--foreground ()
  "Return the current default foreground as a six-digit RGB string."
  (let* ((name (face-foreground 'default nil t))
         (values (and name (color-values name))))
    (if values
        (mapconcat (lambda (value) (format "%02X" (/ value 257))) values "")
      "000000")))

(defun my/read-eww-math--image-scale (&optional display)
  "Return the SVG scale appropriate for the current default face.

When DISPLAY is nil, apply the extra inline-formula multiplier."
  (or my/read-eww-math-image-scale
      (let ((height (face-attribute 'default :height nil t)))
        (if (integerp height)
            (max 1.0
                 (min 6.0
                      (* my/read-eww-math-image-scale-multiplier
                         (if display
                             1.0
                           my/read-eww-math-inline-scale-multiplier)
                         (/ height 120.0))))
          1.0))))

(defun my/read-eww-math--cache-file (job)
  "Return the SVG cache filename for JOB."
  (let ((key (secure-hash
              'sha256
              (mapconcat #'identity
                         (list my/read-eww-math--cache-version
                               (plist-get job :tex)
                               (if (plist-get job :display) "display" "inline")
                               (plist-get job :foreground)
                               (format "%.4f" my/read-eww-math-svg-stroke-width)
                               (format "%.4f" my/read-eww-math-svg-padding))
                         "\0"))))
    (expand-file-name (concat key ".svg")
                      my/read-eww-math-cache-directory)))

(defun my/read-eww-math--job-region (job)
  "Return the current buffer region occupied by JOB's placeholder.

SHR performs a destructive line-filling pass after visiting the DOM.  Markers
created while visiting MathML can move to unrelated insertion boundaries in
that pass, so placeholders are tracked by a private text property instead."
  (let ((buffer (plist-get job :buffer))
        (id (plist-get job :id)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (= (plist-get job :generation)
                 my/read-eww-math--generation)
          (let ((begin (text-property-any
                        (point-min) (point-max)
                        'my/read-eww-math-job id)))
            (when begin
              (cons begin
                    (next-single-property-change
                     begin 'my/read-eww-math-job nil (point-max))))))))))

(defun my/read-eww-math--job-valid-p (job)
  "Return non-nil when JOB still refers to the current rendered page."
  (and (my/read-eww-math--job-region job) t))

(defun my/read-eww-math--cancel-active-process ()
  "Cancel the current buffer's formula process and remove its temporary files."
  (when (processp my/read-eww-math--active-process)
    (let* ((process my/read-eww-math--active-process)
           (directory (process-get process 'my/read-eww-math-temp-directory)))
      (process-put process 'my/read-eww-math-cancelled t)
      (when (process-live-p process)
        (delete-process process))
      (when (and directory (file-directory-p directory))
        (delete-directory directory t))))
  (setq my/read-eww-math--active-process nil))

(defun my/read-eww-math--begin-render (&rest _)
  "Reset formula work before EWW replaces the current document."
  (cl-incf my/read-eww-math--generation)
  (setq my/read-eww-math--queue nil)
  (my/read-eww-math--cancel-active-process))

(defun my/read-eww-math--around-display-document
    (original document &optional point buffer)
  "Call ORIGINAL to render DOCUMENT while tracking its EWW target BUFFER.

SHR renders table cells in temporary buffers.  The dynamic target lets their
MathML renderers retain the real EWW URL and enqueue jobs against the final
document buffer.  Resetting here also avoids confusing SHR's internal layout
edits with page navigation."
  (let* ((target (or buffer (current-buffer)))
         (installed (and (buffer-live-p target)
                         (buffer-local-value
                          'my/read-eww-math--installed-p target))))
    (when installed
      (with-current-buffer target
        (my/read-eww-math--begin-render)))
    (let ((my/read-eww-math--render-target-buffer
           (and installed target)))
      (prog1 (funcall original document point buffer)
        (when installed
          (my/read-eww-math--finalize-placeholders target))))))

(defun my/read-eww-math--finalize-placeholders (buffer)
  "Replace temporary table-safe tokens with TeX placeholders in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (inhibit-modification-hooks t)
            (case-fold-search nil))
        (dolist (job my/read-eww-math--queue)
          (when-let* ((token (plist-get job :token)))
            (save-excursion
              (goto-char (point-min))
              (when (search-forward token nil t)
                (let ((begin (match-beginning 0))
                      (tex (plist-get job :tex)))
                  (replace-match tex t t)
                  (add-text-properties
                   begin (+ begin (length tex))
                   `(my/read-eww-math-job ,(plist-get job :id))))))))))))

(defun my/read-eww-math--around-render-table-cell (original &rest args)
  "Call ORIGINAL while exposing the math renderer to SHR's temp buffer.

`shr-render-td-1' uses `with-temp-buffer', which does not inherit the EWW
buffer-local value of `shr-external-rendering-functions'.  The default value
is changed only for this synchronous call and is restored even on error."
  (if (not (buffer-live-p my/read-eww-math--render-target-buffer))
      (apply original args)
    (let ((old-default (default-value 'shr-external-rendering-functions)))
      (unwind-protect
          (progn
            (set-default
             'shr-external-rendering-functions
             (cons '(math . my/read-eww-math-render)
                   (assq-delete-all 'math (copy-sequence old-default))))
            (apply original args))
        (set-default 'shr-external-rendering-functions old-default)))))

(defun my/read-eww-math-render (dom)
  "Render MathML DOM asynchronously when it contains trusted TeX."
  (let ((tex (my/read-eww-math--tex dom))
        (target (or (and (buffer-live-p my/read-eww-math--render-target-buffer)
                         my/read-eww-math--render-target-buffer)
                    (current-buffer))))
    (if (not (and tex
                  (my/read-eww-math--trusted-page-p target)
                  (my/read-eww-math--safe-tex-p tex)))
        (shr-tag-math dom)
      (let (id generation)
        (with-current-buffer target
          (setq id (cl-incf my/read-eww-math--job-counter)
                generation my/read-eww-math--generation))
        (let* ((display (my/read-eww-math--display-p dom))
               (deferred (buffer-live-p my/read-eww-math--render-target-buffer))
               (token (and deferred (format "\uE000m%d\uE001" id)))
               start end)
          (when (and display (not (bolp)))
            (insert "\n"))
          (setq start (point))
          (insert (or token tex))
          (setq end (point))
          (unless deferred
            (add-text-properties start end `(my/read-eww-math-job ,id)))
          (when display
            (insert "\n"))
          (with-current-buffer target
            (push (list :tex tex
                        :display display
                        :foreground (my/read-eww-math--foreground)
                        :buffer target
                        :generation generation
                        :id id
                        :token token)
                  my/read-eww-math--queue)))))))

(defun my/read-eww-math--source (job)
  "Return a complete LaTeX document for JOB."
  (format
   (concat "\\documentclass[12pt]{article}\n"
           "\\usepackage[utf8]{inputenc}\n"
           "\\usepackage[T1]{fontenc}\n"
           "\\usepackage{amsmath,amssymb}\n"
           "\\pagestyle{empty}\n"
           "\\begin{document}\n"
           "\\thispagestyle{empty}\n"
           "%s\n"
           "\\end{document}\n")
   (if (plist-get job :display)
       (format "\\[%s\\]" (plist-get job :tex))
     (format "\\(%s\\)" (plist-get job :tex)))))

(defun my/read-eww-math--set-svg-foreground (svg-file foreground)
  "Set SVG-FILE's inherited text color to FOREGROUND.

`dvisvgm --currentcolor' writes glyph paths using CSS `currentColor'.  Adding
the actual EWW foreground and a subtle same-color stroke to the root element
keeps formulas visible and slightly bolder on dark themes without depending
on Ghostscript or PostScript color specials."
  (with-temp-buffer
    (insert-file-contents svg-file)
    (goto-char (point-min))
    (unless (re-search-forward "<svg\\(?:[[:space:]]\\|>\\)" nil t)
      (error "dvisvgm output has no SVG root element"))
    (goto-char (+ (match-beginning 0) 4))
    (insert (format (concat " color='#%s' stroke='currentColor'"
                            " stroke-width='%s' stroke-linejoin='round'"
                            " paint-order='stroke fill'")
                    foreground my/read-eww-math-svg-stroke-width))
    (when (> my/read-eww-math-svg-padding 0)
      (goto-char (point-min))
      (when (re-search-forward
             (concat "width='\\([0-9.]+\\)pt' height='\\([0-9.]+\\)pt'"
                     " viewBox='\\([-0-9.]+\\) \\([-0-9.]+\\)"
                     " \\([0-9.]+\\) \\([0-9.]+\\)'")
             nil t)
        (let* ((padding my/read-eww-math-svg-padding)
               (width (string-to-number (match-string 1)))
               (height (string-to-number (match-string 2)))
               (x (string-to-number (match-string 3)))
               (y (string-to-number (match-string 4)))
               (view-width (string-to-number (match-string 5)))
               (view-height (string-to-number (match-string 6))))
          (replace-match
           (format (concat "width='%.6fpt' height='%.6fpt'"
                           " viewBox='%.6f %.6f %.6f %.6f'")
                   (+ width (* 2 padding))
                   (+ height (* 2 padding))
                   (- x padding)
                   (- y padding)
                   (+ view-width (* 2 padding))
                   (+ view-height (* 2 padding)))
           t t))))
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region (point-min) (point-max) svg-file nil 'silent))))

(defun my/read-eww-math--log-buffer ()
  "Return the conversion log buffer."
  (get-buffer-create " *my-read EWW Math Log*"))

(defun my/read-eww-math--process-timeout (process)
  "Terminate PROCESS if it has exceeded the configured timeout."
  (when (process-live-p process)
    (process-put process 'my/read-eww-math-timed-out t)
    (delete-process process)))

(defun my/read-eww-math--start-process
    (name command sentinel job directory)
  "Start COMMAND for JOB in DIRECTORY and return its process."
  (let ((process
         (make-process
          :name name
          :buffer (my/read-eww-math--log-buffer)
          :command command
          :connection-type 'pipe
          :noquery t
          :sentinel sentinel)))
    (process-put process 'my/read-eww-math-job job)
    (process-put process 'my/read-eww-math-temp-directory directory)
    (process-put process 'my/read-eww-math-timeout-timer
                 (run-at-time my/read-eww-math-process-timeout nil
                              #'my/read-eww-math--process-timeout process))
    process))

(defun my/read-eww-math--cancel-timeout (process)
  "Cancel PROCESS's watchdog timer."
  (when-let* ((timer (process-get process 'my/read-eww-math-timeout-timer)))
    (when (timerp timer)
      (cancel-timer timer))))

(defun my/read-eww-math--schedule-next (buffer)
  "Schedule the next queued formula in BUFFER."
  (when (buffer-live-p buffer)
    (run-at-time 0 nil #'my/read-eww-math--next buffer)))

(defun my/read-eww-math--cleanup-job (process &optional schedule-next)
  "Clean PROCESS temporary state and optionally SCHEDULE-NEXT."
  (my/read-eww-math--cancel-timeout process)
  (let* ((job (process-get process 'my/read-eww-math-job))
         (buffer (plist-get job :buffer))
         (directory (process-get process 'my/read-eww-math-temp-directory)))
    (when (and directory (file-directory-p directory))
      (delete-directory directory t))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (eq process my/read-eww-math--active-process)
          (setq my/read-eww-math--active-process nil))))
    (when schedule-next
      (my/read-eww-math--schedule-next buffer))))

(defun my/read-eww-math--replace-placeholder (job svg-file)
  "Replace JOB's TeX placeholder with SVG-FILE."
  (when-let* ((region (my/read-eww-math--job-region job)))
    (let ((buffer (plist-get job :buffer))
          (tex (plist-get job :tex)))
      (with-current-buffer buffer
        (condition-case err
            (let ((inhibit-read-only t)
                  (inhibit-modification-hooks t)
                  (begin (car region)))
              (delete-region begin (cdr region))
              (goto-char begin)
              (let ((image-begin (point)))
                (insert-image
                 (create-image svg-file 'svg nil
                               :ascent my/read-eww-math-image-ascent
                               :scale (my/read-eww-math--image-scale
                                       (plist-get job :display))
                               :margin
                               (cons 0 my/read-eww-math-image-vertical-margin))
                 tex)
                (put-text-property image-begin (point) 'help-echo tex)))
          (error
           (message "my-read EWW math display failed: %s"
                    (error-message-string err))))))))

(defun my/read-eww-math--dvisvgm-sentinel (process _event)
  "Handle completion of a dvisvgm PROCESS."
  (when (memq (process-status process) '(exit signal))
    (my/read-eww-math--cancel-timeout process)
    (unless (process-get process 'my/read-eww-math-cancelled)
      (let* ((job (process-get process 'my/read-eww-math-job))
             (directory
              (process-get process 'my/read-eww-math-temp-directory))
             (output (expand-file-name "formula.svg" directory))
             (cache (my/read-eww-math--cache-file job)))
        (when (and (= (process-exit-status process) 0)
                   (file-exists-p output)
                   (my/read-eww-math--job-valid-p job))
          (condition-case err
              (progn
                (my/read-eww-math--set-svg-foreground
                 output (plist-get job :foreground))
                (make-directory my/read-eww-math-cache-directory t)
                (rename-file output cache t)
                (my/read-eww-math--replace-placeholder job cache))
            (error
             (message "my-read SVG preparation failed: %s"
                      (error-message-string err)))))))
    (my/read-eww-math--cleanup-job
     process (not (process-get process 'my/read-eww-math-cancelled)))))

(defun my/read-eww-math--start-dvisvgm (job directory)
  "Start SVG conversion for JOB in DIRECTORY."
  (let* ((dvi (expand-file-name "formula.dvi" directory))
         (output (expand-file-name "formula.svg" directory))
         (process
          (my/read-eww-math--start-process
           "my-read-eww-dvisvgm"
           (list my/read-eww-math-dvisvgm-program
                 "--no-fonts"
                 "--currentcolor=#000000"
                 "--exact-bbox"
                 (concat "--output=" output)
                 dvi)
           #'my/read-eww-math--dvisvgm-sentinel
           job directory)))
    (with-current-buffer (plist-get job :buffer)
      (setq my/read-eww-math--active-process process))))

(defun my/read-eww-math--latex-sentinel (process _event)
  "Handle completion of a LaTeX PROCESS."
  (when (memq (process-status process) '(exit signal))
    (my/read-eww-math--cancel-timeout process)
    (let* ((cancelled (process-get process 'my/read-eww-math-cancelled))
           (job (process-get process 'my/read-eww-math-job))
           (buffer (plist-get job :buffer))
           (directory
            (process-get process 'my/read-eww-math-temp-directory)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (eq process my/read-eww-math--active-process)
            (setq my/read-eww-math--active-process nil))))
      (cond
       (cancelled
        (my/read-eww-math--cleanup-job process nil))
       ((and (= (process-exit-status process) 0)
             (file-exists-p (expand-file-name "formula.dvi" directory))
             (my/read-eww-math--job-valid-p job))
        (condition-case err
            (my/read-eww-math--start-dvisvgm job directory)
          (error
           (message "my-read dvisvgm start failed: %s"
                    (error-message-string err))
           (my/read-eww-math--cleanup-job process t))))
       (t
        (my/read-eww-math--cleanup-job process t))))))

(defun my/read-eww-math--compile (job cache)
  "Compile JOB asynchronously for CACHE."
  (make-directory my/read-eww-math-cache-directory t)
  (let* ((directory (make-temp-file "my-read-eww-math-" t))
         (source (expand-file-name "formula.tex" directory))
         (default-directory directory))
    (with-temp-file source
      (set-buffer-file-coding-system 'utf-8-unix)
      (insert (my/read-eww-math--source job)))
    (condition-case err
        (let ((process
               (my/read-eww-math--start-process
                "my-read-eww-latex"
                (list my/read-eww-math-latex-program
                      "-no-shell-escape"
                      "-interaction=nonstopmode"
                      "-halt-on-error"
                      (concat "-output-directory=" directory)
                      source)
                #'my/read-eww-math--latex-sentinel
                job directory)))
          (process-put process 'my/read-eww-math-cache cache)
          (with-current-buffer (plist-get job :buffer)
            (setq my/read-eww-math--active-process process)))
      (error
       (when (file-directory-p directory)
         (delete-directory directory t))
       (message "my-read LaTeX start failed: %s" (error-message-string err))
       (my/read-eww-math--schedule-next (plist-get job :buffer))))))

(defun my/read-eww-math--next (buffer)
  "Render the next queued formula for BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (unless (process-live-p my/read-eww-math--active-process)
        (setq my/read-eww-math--active-process nil)
        (when-let* ((job (pop my/read-eww-math--queue)))
          (if (not (my/read-eww-math--job-valid-p job))
              (my/read-eww-math--schedule-next buffer)
            (let ((cache (my/read-eww-math--cache-file job)))
              (cond
               ((file-exists-p cache)
                (my/read-eww-math--replace-placeholder job cache)
                (my/read-eww-math--schedule-next buffer))
               ((not (and (executable-find my/read-eww-math-latex-program)
                          (executable-find my/read-eww-math-dvisvgm-program)))
                (unless my/read-eww-math--missing-program-warning-shown
                  (setq my/read-eww-math--missing-program-warning-shown t)
                  (message "EWW math needs latex and dvisvgm; showing TeX text"))
                (setq my/read-eww-math--queue nil))
               (t
                (my/read-eww-math--compile job cache))))))))))

(defun my/read-eww-math--after-render ()
  "Start the formula queue after EWW finishes inserting a document."
  (setq my/read-eww-math--queue (nreverse my/read-eww-math--queue))
  (my/read-eww-math--schedule-next (current-buffer)))

(defun my/read-eww-math-setup ()
  "Enable asynchronous SVG formula rendering in the current EWW buffer."
  (setq-local my/read-eww-math--installed-p t)
  ;; Remove the modification-hook implementation used by cache version v1.
  ;; `load-file' does not erase buffer-local hook values from an existing EWW
  ;; buffer, so without this migration an upgraded live session would still
  ;; discard its queue during SHR's layout pass.
  (remove-hook 'before-change-functions 'my/read-eww-math--before-change t)
  (setq-local shr-external-rendering-functions
              (cons '(math . my/read-eww-math-render)
                    (assq-delete-all 'math
                                     shr-external-rendering-functions)))
  (add-hook 'eww-after-render-hook #'my/read-eww-math--after-render nil t)
  (add-hook 'kill-buffer-hook #'my/read-eww-math--cancel-active-process nil t)
  ;; Remove the v2 pre-render advice when upgrading a running Emacs.
  (when (advice-member-p 'my/read-eww-math--before-display-document
                         'eww-display-document)
    (advice-remove 'eww-display-document
                   'my/read-eww-math--before-display-document))
  (unless (advice-member-p #'my/read-eww-math--around-display-document
                           'eww-display-document)
    (advice-add 'eww-display-document :around
                #'my/read-eww-math--around-display-document))
  (unless (advice-member-p #'my/read-eww-math--around-render-table-cell
                           'shr-render-td-1)
    (advice-add 'shr-render-td-1 :around
                #'my/read-eww-math--around-render-table-cell))
  (my/read-eww-math--begin-render))

(provide 'my-read-eww-math)
;;; my-read-eww-math.el ends here
