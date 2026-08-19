;;; my-read.el --- Dedicated English reading frame -*- lexical-binding: t; -*-

;; English reading workspace:
;;   left   : Lookup
;;   center : book
;;   right top    : Google Translate
;;   right bottom : reading notes
;;
;; Translation policy:
;;   - j/k and Kokoro lifecycle are owned by english-reading-mode.el
;;   - while Kokoro is reading: lock translation to the exact spoken text
;;   - point may already move to the next sentence; the lock remains
;;   - when playback finishes/stops/fails: resume paragraph-at-point translation

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

(defcustom my/read-lookup-agent-classes '(nmacos ndspell)
  "Non-NDEB Lookup agent classes enabled while searching from my-read."
  :type '(repeat symbol)
  :group 'my-read)

(defcustom my/read-lookup-ndeb-directories
  '("~/Sync/004_dic/chujisnd/")
  "NDEB dictionary directories enabled while searching from my-read.

Lookup's normal runtime is left untouched.  When the installed Lookup
version exposes dictionary objects, my-read narrows `lookup-search-dictionaries'
for searches originating in a my-read frame.  Older/forked versions fall back
to the normal default module instead of failing."
  :type '(repeat directory)
  :group 'my-read)

(defcustom my/read-lookup-idle-delay 0.12
  "Seconds to wait before looking up the word at point in my-read."
  :type 'number
  :group 'my-read)

(defconst my/read-translate-buffer-name "*Reading Translation*")

(defvar lookup-search-dictionaries nil
  "Lookup dictionary restriction when supported by the installed Lookup version.")

(defvar my/read-lookup-timer nil)
(defvar my/read-lookup-last-target nil)
(defvar my/read-lookup-running-p nil)

(defvar my/read-translate-timer nil)
(defvar my/read-translate-process nil)
(defvar my/read-translate-last-target nil)

(defvar my/read-kokoro-context nil
  "English-reading speech context currently locking translation.

While this is non-nil, point may already be on the next sentence, but
translation remains pinned to CONTEXT's :text until the matching finish event.")



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

(defun my/read--lookup-normalize-directory (directory)
  "Return DIRECTORY as an absolute directory name for comparison."
  (when (stringp directory)
    (file-name-as-directory (expand-file-name directory))))

(defun my/read--lookup-reading-agent-p (agent)
  "Return non-nil when AGENT belongs to the my-read dictionary scope."
  (let ((class (lookup-agent-class agent))
        (location (lookup-agent-location agent)))
    (or (memq class my/read-lookup-agent-classes)
        (and (eq class 'ndeb)
             (stringp location)
             (member (my/read--lookup-normalize-directory location)
                     (mapcar #'my/read--lookup-normalize-directory
                             my/read-lookup-ndeb-directories))))))

(defun my/read--lookup-reading-dictionaries ()
  "Return my-read dictionaries when this Lookup version exposes them.

Some Lookup forks do not define `lookup-dictionary-list'.  In that case
return nil deliberately: `lookup-pattern' will then search the normal
default module instead of failing.  This keeps automatic Lookup working
without rebuilding or mutating the user's Lookup runtime."
  (my/read--lookup-ensure-runtime)
  (when (and (boundp 'lookup-dictionary-list)
             (listp (symbol-value 'lookup-dictionary-list))
             (fboundp 'lookup-dictionary-agent)
             (fboundp 'lookup-agent-class)
             (fboundp 'lookup-agent-location))
    (condition-case nil
        (cl-remove-if-not
         (lambda (dictionary)
           (my/read--lookup-reading-agent-p
            (lookup-dictionary-agent dictionary)))
         (symbol-value 'lookup-dictionary-list))
      (error nil))))

(defun my/read--lookup-call-with-reading-scope (function &rest arguments)
  "Call FUNCTION with my-read's dictionary restriction when appropriate."
  (if (my/read-frame-p)
      (let ((dictionaries (my/read--lookup-reading-dictionaries)))
        ;; A nil restriction intentionally falls back to Lookup's normal module.
        ;; This keeps Lookup usable even if a local/forked agent reports its
        ;; identity differently from the upstream Lookup structures.
        (let ((lookup-search-dictionaries dictionaries))
          (apply function arguments)))
    (apply function arguments)))

(defun my/read--install-lookup-advice ()
  "Restrict manual Lookup searches only when they originate in my-read.

Also remove advice left by older my-read revisions so reloading this file in
an existing Emacs session cannot call the destructive profile-switch code."
  ;; fixed1..fixed3 used this older around-advice on `lookup-pattern'.  The
  ;; function may still be defined in a long-lived Emacs even though it is no
  ;; longer present in this file.
  (when (and (fboundp 'lookup-pattern)
             (fboundp 'my/read--lookup-pattern-around))
    (advice-remove 'lookup-pattern #'my/read--lookup-pattern-around))
  ;; Use the user's normal `lookup-pattern' path.  In the user's config this
  ;; already has frame-safety and "open first entry" advice attached, so keeping
  ;; my-read on the same command path preserves that working behavior.
  (when (fboundp 'lookup-pattern)
    (advice-remove 'lookup-pattern #'my/read--lookup-call-with-reading-scope)
    (advice-add 'lookup-pattern :around #'my/read--lookup-call-with-reading-scope)))

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
        (save-excursion
          (goto-char (window-point window))
          (when-let ((word (thing-at-point 'word t)))
            (setq word (string-trim word))
            (unless (string-empty-p word)
              word)))))))

(defun my/read-lookup-open-left-pane (buffer)
  "Display Lookup BUFFER in the fixed left pane of the current my-read frame.

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
                  ;; Lookup's normal config opens a right pane.  my-read already
                  ;; owns a left pane, so dynamically route this search there.
                  ;;
                  ;; IMPORTANT: use `lookup-pattern', not `lookup-word'.  The
                  ;; user's normal Lookup configuration attaches frame handling
                  ;; and "open the first entry" behavior to `lookup-pattern'.
                  ;; Calling it non-interactively with WORD does not open the
                  ;; minibuffer, but does preserve those existing advices.
                  (let ((lookup-open-function #'my/read-lookup-open-left-pane)
                        ;; Restrict this automatic search without rebuilding
                        ;; Lookup's global agents/modules.
                        (lookup-search-dictionaries
                         (my/read--lookup-reading-dictionaries)))
                    (condition-case err
                        ;; If the reduced dictionary list cannot be identified
                        ;; in a local Lookup fork, nil means "use the normal
                        ;; module".  Working Lookup is preferred to silently
                        ;; disabling the follower.
                        (lookup-pattern word)
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
                 (window-live-p center)
                 (eq (selected-window) center)
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

(defun my/read--kokoro-context-for-frame-p (frame)
  "Return non-nil when English-reading speech locks translation for FRAME."
  (and (listp my/read-kokoro-context)
       (eq frame (plist-get my/read-kokoro-context :frame))
       (stringp (plist-get my/read-kokoro-context :text))
       (not (string-empty-p (plist-get my/read-kokoro-context :text)))))

(defun my/read--translation-target (frame center)
  "Return (MODE TEXT) to translate for FRAME and CENTER."
  (if (my/read--kokoro-context-for-frame-p frame)
      (list 'kokoro (plist-get my/read-kokoro-context :text))
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

(defun my/read-translate-update-for-frame (frame center)
  "Update translation target for FRAME using CENTER.

While Kokoro is active in FRAME, keep translation locked to the exact spoken
text.  Otherwise translate the paragraph containing CENTER's point.  This
function is also safe to call asynchronously from the speech-finish hook."
  (when (and my-read-translate-follow-mode
             (frame-live-p frame)
             (my/read-frame-p frame)
             (window-live-p center))
    (pcase-let* ((`(,mode ,text)
                   (my/read--translation-target frame center))
                 (buffer (window-buffer center))
                 (target
                  (and text
                       (list frame buffer mode text))))
      (unless (equal target my/read-translate-last-target)
        (setq my/read-translate-last-target target)

        ;; A newly selected target supersedes both a pending idle timer and an
        ;; in-flight HTTP request for the old target.
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
                 text)))))))

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
        (my/read-translate-update-for-frame frame center)))))

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
;;; English-reading speech -> translation lock
;;; ---------------------------------------------------------------------------

(defun my/read--english-speech-start (context)
  "Lock translation to the spoken English-reading CONTEXT."
  (let* ((frame (plist-get context :frame))
         (window (plist-get context :window))
         (center (and (frame-live-p frame)
                      (my/read-center-window frame))))
    (when (and (frame-live-p frame)
               (my/read-frame-p frame)
               (window-live-p center)
               (eq window center))
      ;; This runs before `j' advances point.  CONTEXT remains the translation
      ;; source even after point has moved to the next sentence.
      (setq my/read-kokoro-context context)
      (my/read-translate-update-for-frame frame center))))

(defun my/read--english-speech-finish (context)
  "Unlock translation when the matching English-reading CONTEXT finishes."
  ;; Ignore stale completion from an utterance replaced by a newer one.
  (when (eq context my/read-kokoro-context)
    (let ((frame (plist-get context :frame)))
      (setq my/read-kokoro-context nil)
      (when (frame-live-p frame)
        (when-let ((center (my/read-center-window frame)))
          ;; Only now follow point again.  With `j', point is normally already
          ;; on the next sentence, so its paragraph becomes the new target.
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
    (message "my-read translation UNLOCKED [Paragraph]")))

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

(defun my/read--setup-frame (frame &optional center-buffer)
  "Build the my-read layout inside FRAME.
When CENTER-BUFFER is live, display it instead of opening `my/read-book-path'."
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

      ;; Center: normal book source, or a caller-provided text source.
      (select-window center-window)
      (if (buffer-live-p center-buffer)
          (set-window-buffer center-window center-buffer)
        (find-file (expand-file-name my/read-book-path)))

      ;; Right bottom: reading notes.
      (select-window note-window)
      (find-file (expand-file-name my/read-note-file))

      ;; Back to the book.
      (select-window center-window)

      ;; Self-contained Lookup follower from this file.
      (my-read-lookup-follow-mode 1)

      ;; Translation follower from this file.
      (my-read-translate-follow-mode 1)

      ;; Initial refresh.
      (my/read-lookup-follow-post-command)
      (my/read-translate-follow-post-command))))

;;;###autoload
(defun my-read ()
  "Create a new dedicated frame and start the English reading workspace."
  (interactive)
  ;; Initialize normal Lookup once; my-read only narrows search scope dynamically.
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
       ;; Frame setup may fail after Lookup initialization.  No dictionary
       ;; profile needs restoring because my-read never mutates Lookup runtime.
       (if (frame-live-p frame)
           (delete-frame frame t)
         (unless (cl-some #'my/read-frame-p (frame-list))
           (my/read--lookup-restore-normal)))
       (signal (car err) (cdr err))))))

(defun my/read--frame-deleted (frame)
  "Clean up my-read state when FRAME is deleted."
  (when (my/read-frame-p frame)
    (when (and my/read-kokoro-context
               (eq frame (plist-get my/read-kokoro-context :frame)))
      (setq my/read-kokoro-context nil))

    (dolist (parameter '(my-reading-translate-buffer
                         my-reading-lookup-ready-buffer))
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

;; j/k are defined only by english-reading-mode.el.  my-read.el observes its
;; speech lifecycle hooks above and never overrides j/k or advises Kokoro.
(add-hook 'nov-mode-hook #'english-reading-mode)

(global-set-key (kbd "C-c p") #'kokoro-reader-speak-paragraph)
(global-set-key (kbd "C-c n") #'kokoro-reader-speak-and-forward)
(global-set-key (kbd "C-c k") #'kokoro-reader-stop)

(provide 'my-read)
;;; my-read.el ends here
