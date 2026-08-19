;;; my-read.el --- Dedicated English reading frame -*- lexical-binding: t; -*-

;; English reading workspace:
;;   left   : Lookup
;;   center : book
;;   right top    : Google Translate
;;   right bottom : reading notes
;;
;; Translation policy:
;;   - while Kokoro is synthesizing/playing: translate exactly the text
;;     currently handed to Kokoro
;;   - otherwise: translate the paragraph at point in the center window

(require 'cl-lib)
(require 'json)
(require 'thingatpt)
(require 'subr-x)
(require 'google-translate-core)

(add-to-list 'load-path (expand-file-name "~/Sync/emacs.d/reader"))
(require 'kokoro-reader)
(require 'english-reading-mode)

(defgroup my-read nil
  "Dedicated English reading workspace."
  :group 'convenience)

(defcustom my/read-book-path
  "/Users/seijiro/Library/Mobile Documents/iCloud~md~obsidian/Documents/seijiro/000_org/einglish-book"
  "File or directory opened in the center reading window."
  :type 'file
  :group 'my-read)

(defcustom my/read-note-file
  "~/work/002_docs/000_org/article/english.org"
  "Reading note file opened in the lower-right window."
  :type 'file
  :group 'my-read)

(defcustom my/read-frame-name "my-read"
  "Base name of a frame created by `my-read'."
  :type 'string
  :group 'my-read)

(defcustom my/read-translate-idle-delay 0.1
  "Seconds to wait before starting Google Translate after the target changes."
  :type 'number
  :group 'my-read)

(defcustom my/read-lookup-search-agents
  '((nmacos)
    (ndeb "~/Sync/004_dic/chujisnd/")
    (ndspell))
  "Lookup search agents used for the my-read reading frame.

The normal `lookup-search-agents' value is saved when the first my-read
frame is opened and restored when the last my-read frame is closed.
`lookup-pattern' also selects the appropriate profile from the frame it is
called in, so normal Lookup use keeps the normal dictionary set."
  :type '(repeat sexp)
  :group 'my-read)

(defconst my/read-translate-buffer-name "*Reading Translation*")

(defvar my/read-translate-timer nil)
(defvar my/read-translate-process nil)
(defvar my/read-translate-last-target nil)

(defvar my/read-kokoro-text nil
  "Exact text most recently handed to Kokoro from a my-read frame.")

(defvar my/read-kokoro-frame nil
  "my-read frame owning `my/read-kokoro-text'.")

(defvar my/read--lookup-original-search-agents nil)
(defvar my/read--lookup-original-valid-p nil)
(defvar my/read--lookup-current-profile nil)


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

(defun my/read-center-window (&optional frame)
  "Return FRAME's center reading window."
  (my/read-window 'my-reading-center-window frame))

(defun my/read-translate-window (&optional frame)
  "Return FRAME's Google Translate window."
  (my/read-window 'my-reading-translate-window frame))

(defun my/read-note-window (&optional frame)
  "Return FRAME's reading-note window."
  (my/read-window 'my-reading-note-window frame))

(defun my/read--other-reading-frame-p (frame)
  "Return non-nil if a live my-read frame other than FRAME exists."
  (cl-some
   (lambda (candidate)
     (and (not (eq candidate frame))
          (frame-live-p candidate)
          (my/read-frame-p candidate)))
   (frame-list)))


;;; ---------------------------------------------------------------------------
;;; Lookup dictionary profile
;;; ---------------------------------------------------------------------------

(defun my/read--lookup-reset-caches ()
  "Reset Lookup's cached agents/modules after changing dictionaries."
  (dolist (symbol '(lookup-agent-list
                    lookup-module-list
                    lookup-default-module))
    (when (boundp symbol)
      (set symbol nil))))

(defun my/read--lookup-ensure-original ()
  "Remember the normal Lookup dictionary set before entering my-read."
  (when (or (featurep 'lookup)
            (require 'lookup nil t))
    (when (and (boundp 'lookup-search-agents)
               (not my/read--lookup-original-valid-p))
      (setq my/read--lookup-original-search-agents
            (copy-tree lookup-search-agents)
            my/read--lookup-original-valid-p t
            my/read--lookup-current-profile nil))
    my/read--lookup-original-valid-p))

(defun my/read--lookup-apply-profile (profile)
  "Apply Lookup dictionary PROFILE, either `reading' or `normal'."
  (when (and my/read--lookup-original-valid-p
             (boundp 'lookup-search-agents))
    (let ((agents
           (pcase profile
             ('reading my/read-lookup-search-agents)
             ('normal my/read--lookup-original-search-agents)
             (_ (error "Unknown my-read Lookup profile: %S" profile)))))
      (unless (and (eq profile my/read--lookup-current-profile)
                   (equal lookup-search-agents agents))
        (setq lookup-search-agents (copy-tree agents))
        (my/read--lookup-reset-caches)
        (setq my/read--lookup-current-profile profile)))))

(defun my/read--lookup-pattern-around (original-function &rest arguments)
  "Use frame-appropriate dictionaries around Lookup ORIGINAL-FUNCTION."
  (when my/read--lookup-original-valid-p
    (my/read--lookup-apply-profile
     (if (my/read-frame-p) 'reading 'normal)))
  (apply original-function arguments))

(defun my/read--install-lookup-advice ()
  "Install frame-aware dictionary switching around `lookup-pattern'."
  (when (fboundp 'lookup-pattern)
    (advice-remove 'lookup-pattern #'my/read--lookup-pattern-around)
    (advice-add 'lookup-pattern :around #'my/read--lookup-pattern-around)))

(with-eval-after-load 'lookup
  (my/read--install-lookup-advice))

(defun my/read--lookup-enter ()
  "Activate the my-read Lookup dictionary profile."
  (when (my/read--lookup-ensure-original)
    (my/read--install-lookup-advice)
    (my/read--lookup-apply-profile 'reading)))

(defun my/read--lookup-restore-normal ()
  "Restore Lookup dictionaries that were active before my-read started."
  (when (and my/read--lookup-original-valid-p
             (boundp 'lookup-search-agents))
    (setq lookup-search-agents
          (copy-tree my/read--lookup-original-search-agents))
    (my/read--lookup-reset-caches))
  ;; Capture a fresh normal profile next time my-read is opened.
  (setq my/read--lookup-original-search-agents nil
        my/read--lookup-original-valid-p nil
        my/read--lookup-current-profile nil))


;;; ---------------------------------------------------------------------------
;;; Translation target
;;; ---------------------------------------------------------------------------

(defun my/read-current-paragraph-at-window (window)
  "Return the paragraph containing point in WINDOW.

Dired windows and empty paragraphs return nil."
  (when (window-live-p window)
    (with-current-buffer (window-buffer window)
      (unless (derived-mode-p 'dired-mode)
        (save-excursion
          (goto-char (window-point window))
          (when-let ((bounds (bounds-of-thing-at-point 'paragraph)))
            (let ((paragraph
                   (string-trim
                    (buffer-substring-no-properties
                     (car bounds)
                     (cdr bounds)))))
              (unless (string-empty-p paragraph)
                paragraph))))))))

(defun my/read--kokoro-active-p (&optional frame)
  "Return non-nil while Kokoro is active for FRAME."
  (let ((frame (or frame (selected-frame))))
    (and (eq frame my/read-kokoro-frame)
         (stringp my/read-kokoro-text)
         (not (string-empty-p my/read-kokoro-text))
         (or (and (boundp 'kokoro-reader--request-process)
                  (process-live-p kokoro-reader--request-process))
             (and (boundp 'kokoro-reader--player-process)
                  (process-live-p kokoro-reader--player-process))))))

(defun my/read-translate-capture-kokoro-bounds (beg end &rest _)
  "Capture exact Kokoro text between BEG and END in a my-read frame."
  (let* ((frame (selected-frame))
         (center (my/read-center-window frame)))
    (when (and (my/read-frame-p frame)
               (window-live-p center)
               (eq (selected-window) center))
      (let ((text
             (if (fboundp 'kokoro-reader--text)
                 (kokoro-reader--text beg end)
               (string-trim
                (replace-regexp-in-string
                 "[ \t\n\r]+" " "
                 (buffer-substring-no-properties beg end))))))
        (setq my/read-kokoro-text text
              my/read-kokoro-frame frame)))))

(defun my/read--translation-target (frame center)
  "Return (MODE TEXT) to translate for FRAME and CENTER."
  (if (my/read--kokoro-active-p frame)
      (list 'kokoro my/read-kokoro-text)
    (list 'paragraph (my/read-current-paragraph-at-window center))))


;;; ---------------------------------------------------------------------------
;;; Google Translate
;;; ---------------------------------------------------------------------------

(defun my/read-google-translate-url (text)
  "Build a Google Translate URL for TEXT."
  (let ((url
         (google-translate--format-request-url
          `(("client" . "gtx")
            ("ie"     . "UTF-8")
            ("oe"     . "UTF-8")
            ("sl"     . ,(or google-translate-default-source-language
                           "auto"))
            ("tl"     . ,(or google-translate-default-target-language
                           "ja"))
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
      (visual-line-mode 1))
    buffer))

(defun my/read-translate-display (frame source translation mode)
  "Display SOURCE and TRANSLATION in FRAME.
MODE is `kokoro' or `paragraph'."
  (when (and (frame-live-p frame)
             (my/read-frame-p frame))
    (when-let ((window (my/read-translate-window frame)))
      (let ((buffer (my/read-translate-buffer frame)))
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert
             (propertize
              (if (eq mode 'kokoro)
                  "Google Translate  [Kokoro]\n\n"
                "Google Translate  [Paragraph]\n\n")
              'face 'font-lock-keyword-face))
            (insert translation)
            (insert "\n\n")
            (insert (propertize "──────────\n" 'face 'shadow))
            (insert (propertize source 'face 'shadow))
            (goto-char (point-min))))
        (set-window-buffer window buffer)
        (set-window-point window (point-min))))))

(defun my/read-translate-stop-process ()
  "Stop the currently running Google Translate process."
  (when (process-live-p my/read-translate-process)
    (delete-process my/read-translate-process))
  (setq my/read-translate-process nil))

(defun my/read-translate-start (frame center target mode text)
  "Start asynchronous Google translation of TEXT.
FRAME, CENTER and TARGET identify the request; MODE describes its source."
  (setq my/read-translate-timer nil)

  ;; Drop an idle-timer request if the reading target changed meanwhile.
  (when (and my-read-translate-follow-mode
             (frame-live-p frame)
             (window-live-p center)
             (equal target my/read-translate-last-target))
    (my/read-translate-stop-process)

    (let* ((buffer
            (generate-new-buffer " *Reading Google Translate Process*"))
           (url (my/read-google-translate-url text))
           (process
            (make-process
             :name "reading-google-translate"
             :buffer buffer
             :command (list "curl" "-s" "-L" "-A" "Emacs" url)
             :coding 'utf-8-unix
             :noquery t
             :sentinel
             (lambda (proc _event)
               (when (memq (process-status proc) '(exit signal))
                 (unwind-protect
                     (when (and (= (process-exit-status proc) 0)
                                (frame-live-p frame)
                                (equal target my/read-translate-last-target))
                       (with-current-buffer (process-buffer proc)
                         (condition-case err
                             (let* ((json-array-type 'vector)
                                    (json-object-type 'alist)
                                    (json
                                     (json-read-from-string
                                      (google-translate--insert-nulls
                                       (buffer-string))))
                                    (translation
                                     (google-translate-json-translation json)))
                               (when translation
                                 (my/read-translate-display
                                  frame text translation mode)))
                           (error
                            (message "Google Translate error: %s"
                                     (error-message-string err))))))
                   (when-let ((proc-buffer (process-buffer proc)))
                     (when (buffer-live-p proc-buffer)
                       (kill-buffer proc-buffer)))
                   (when (eq proc my/read-translate-process)
                     (setq my/read-translate-process nil))))))))
      (setq my/read-translate-process process))))

(defun my/read-translate-follow-post-command ()
  "Translate the appropriate text for the selected my-read center window.

While Kokoro is active, translate exactly the text currently being read.
Otherwise, translate the paragraph containing point."
  (when my-read-translate-follow-mode
    (let* ((frame (selected-frame))
           (center (my/read-center-window frame)))
      (when (and (my/read-frame-p frame)
                 (window-live-p center)
                 (eq (selected-window) center))
        (pcase-let* ((`(,mode ,text)
                       (my/read--translation-target frame center))
                     (buffer (window-buffer center))
                     (target
                      (and text
                           (list frame buffer mode text))))
          (unless (equal target my/read-translate-last-target)
            (setq my/read-translate-last-target target)

            (when (timerp my/read-translate-timer)
              (cancel-timer my/read-translate-timer)
              (setq my/read-translate-timer nil))

            (my/read-translate-stop-process)

            (when text
              (setq my/read-translate-timer
                    (run-with-idle-timer
                     my/read-translate-idle-delay
                     nil
                     #'my/read-translate-start
                     frame
                     center
                     target
                     mode
                     text)))))))))

(define-minor-mode my-read-translate-follow-mode
  "Automatically update Google Translate from a my-read center window."
  :global t
  :lighter " GTr↔"
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
    (setq my/read-translate-timer nil
          my/read-translate-last-target nil)))


;;; ---------------------------------------------------------------------------
;;; my-read frame setup
;;; ---------------------------------------------------------------------------

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

(defun my/read--setup-frame (frame)
  "Build the my-read layout inside FRAME."
  (with-selected-frame frame
    (delete-other-windows)

    (let* ((lookup-window (selected-window))
           ;; left 1/3, remaining 2/3
           (center-window
            (split-window-right
             (floor (/ (window-total-width lookup-window) 3))))
           right-window
           translate-window
           note-window)

      ;; Split remaining 2/3 into center and right columns.
      (select-window center-window)
      (setq right-window (split-window-right))
      (setq translate-window right-window)

      ;; Right column: top 40% translation, bottom 60% notes.
      (select-window translate-window)
      (setq note-window
            (split-window-below
             (max window-min-height
                  (floor (* (window-total-height translate-window) 0.40)))))

      ;; Store window identity on the frame.
      (set-frame-parameter frame 'my-reading-lookup-window lookup-window)
      (set-frame-parameter frame 'my-reading-center-window center-window)
      (set-frame-parameter frame 'my-reading-translate-window translate-window)
      (set-frame-parameter frame 'my-reading-note-window note-window)

      ;; Lookup must not reuse stale internal windows from another frame.
      (when (boundp 'lookup-main-window)
        (setq lookup-main-window nil
              lookup-sub-window nil))

      ;; Left: Lookup placeholder.
      (set-window-buffer lookup-window (my/read--prepare-ready-buffer frame))

      ;; Right top: Google Translate.
      (let ((buffer (my/read-translate-buffer frame)))
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert
             (propertize "Google Translate\n\n"
                         'face 'font-lock-keyword-face))
            (insert
             "通常はカーソル位置の段落を翻訳します。\nKokoro読み上げ中は読み上げている文章を翻訳します。")))
        (set-window-buffer translate-window buffer)
        (set-window-dedicated-p translate-window t))

      ;; Center: book / book directory.
      (select-window center-window)
      (find-file (expand-file-name my/read-book-path))

      ;; Right bottom: reading notes.
      (select-window note-window)
      (find-file (expand-file-name my/read-note-file))

      ;; Back to the book.
      (select-window center-window)

      ;; English-reading Lookup follower (provided by english-reading-mode.el).
      (when (fboundp 'my-read-lookup-follow-mode)
        (my-read-lookup-follow-mode 1))

      ;; Translation follower from this file.
      (my-read-translate-follow-mode 1)

      ;; Initial refresh.
      (when (fboundp 'my/read-lookup-follow-post-command)
        (my/read-lookup-follow-post-command))
      (my/read-translate-follow-post-command))))

;;;###autoload
(defun my-read ()
  "Create a new dedicated frame and start the English reading workspace."
  (interactive)
  (my/read--lookup-enter)
  (let (frame)
    (condition-case err
        (progn
          (setq frame (make-frame `((name . ,my/read-frame-name))))
          (set-frame-parameter frame 'my-reading-frame t)
          (my/read--setup-frame frame)
          (select-frame-set-input-focus frame)
          frame)
      (error
       ;; Do not leave the reduced dictionary profile behind when frame setup
       ;; fails partway through.  Deleting a marked my-read frame runs the
       ;; normal cleanup hook; if no frame was created, restore explicitly.
       (if (frame-live-p frame)
           (delete-frame frame t)
         (unless (cl-some #'my/read-frame-p (frame-list))
           (my/read--lookup-restore-normal)))
       (signal (car err) (cdr err))))))

(defun my/read--frame-deleted (frame)
  "Clean up my-read state when FRAME is deleted."
  (when (my/read-frame-p frame)
    (when (eq frame my/read-kokoro-frame)
      (setq my/read-kokoro-frame nil
            my/read-kokoro-text nil))

    (dolist (parameter '(my-reading-translate-buffer
                         my-reading-lookup-ready-buffer))
      (when-let ((buffer (frame-parameter frame parameter)))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))

    (unless (my/read--other-reading-frame-p frame)
      (my/read--lookup-restore-normal)
      (when (fboundp 'my-read-lookup-follow-mode)
        (my-read-lookup-follow-mode -1))
      (my-read-translate-follow-mode -1))))

(add-hook 'delete-frame-functions #'my/read--frame-deleted)


;;; ---------------------------------------------------------------------------
;;; Kokoro integration / keys
;;; ---------------------------------------------------------------------------

;; Capture the actual bounds handed to Kokoro.  This covers speak, paragraph,
;; and speak-and-forward with one hook and avoids guessing from point after it
;; has already moved to the next sentence.
(advice-remove 'kokoro-reader--speak-bounds
               #'my/read-translate-capture-kokoro-bounds)
(advice-add 'kokoro-reader--speak-bounds
            :before
            #'my/read-translate-capture-kokoro-bounds)

(add-hook 'nov-mode-hook #'english-reading-mode)

(global-set-key (kbd "C-c p") #'kokoro-reader-speak-paragraph)
(global-set-key (kbd "C-c n") #'kokoro-reader-speak-and-forward)
(global-set-key (kbd "C-c k") #'kokoro-reader-stop)

(provide 'my-read)
;;; my-read.el ends here
