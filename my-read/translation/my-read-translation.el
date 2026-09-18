;;; my-read-translation.el --- Translation for the reader -*- lexical-binding: t; -*-

(require 'my-read-core)
(require 'my-read-speech-settings)
(require 'color)
(require 'json)
(require 'google-translate-core)

;; Keep compilation independent of whether a test harness supplied the feature.
(declare-function google-translate--format-request-url "google-translate-core" (query-params))
(declare-function google-translate--insert-nulls "google-translate-core" (string))
(declare-function google-translate-json-translation "google-translate-core" (json))

(declare-function my/read--center-source-window-p "my-read-ui" (window frame))
(defvar my-read-translate-follow-mode)

(defvar google-translate-default-source-language)
(defvar google-translate-default-target-language)

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

(defconst my/read-translate-buffer-name "*Reading Translation*")

(defface my/read-translate-overlay-face
  '((t (:extend t)))
  "Background-only face for the current translation target.

Font and foreground attributes are deliberately left unspecified so EPUB
styling remains unchanged while the target overlay moves through the book."
  :group 'my-read)

(defvar my/read-translate-timer nil)

(defvar my/read-translate-process nil)

(defvar my/read-translate-last-target nil)

(defvar my/read-kokoro-context nil
  "English-reading speech context currently locking translation.

While this is non-nil, point may already be on the next sentence, but
translation remains pinned to CONTEXT's :text until the matching finish event.")

(defvar my/read-speech-translation-suppressed-context nil
  "Non-English speech context currently suppressing automatic translation.")

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
    (if-let* ((sentence (my/read-current-sentence-at-window center)))
        (cons 'sentence sentence)
      (list 'sentence nil nil nil nil))))

(defun my/read--translation-languages (&optional frame source-buffer)
  "Return (SOURCE TARGET) language codes for FRAME and SOURCE-BUFFER."
  (let* ((source-buffer
          (or source-buffer
              (and (frame-live-p frame)
                   (when-let* ((center (my/read-center-window frame)))
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
    (when-let* ((window (my/read-translate-window frame)))
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
  (let ((process my/read-translate-process))
    ;; Invalidate before deletion: its sentinel must not launch a fallback.
    (setq my/read-translate-process nil)
    (when (process-live-p process)
      (delete-process process))))

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
  (let* ((owner (window-buffer center))
         (identity (reader-document-identity owner))
         (local-p (eq backend 'local))
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
                   (when (and (eq proc my/read-translate-process)
                              (frame-live-p frame)
                              (window-live-p center)
                              (buffer-live-p owner)
                              (eq owner (window-buffer center))
                              (equal identity (reader-document-identity owner))
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
                 (when-let* ((proc-buffer (process-buffer proc)))
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
  :group 'my-read
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
        (when-let* ((center
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

(provide 'my-read-translation)
;;; my-read-translation.el ends here
