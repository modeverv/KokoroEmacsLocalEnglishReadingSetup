;;; kokoro-reader.el --- Read English aloud with local Kokoro -*- lexical-binding: t; -*-

;; This client uses macOS /usr/bin/curl asynchronously to fetch a WAV file and
;; /usr/bin/afplay to play it.  It has no third-party Emacs dependencies.

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'thingatpt)

(defgroup kokoro-reader nil
  "Local Kokoro text-to-speech for reading buffers."
  :group 'multimedia)

(defcustom kokoro-reader-endpoint
  "http://127.0.0.1:8000/v1/audio/speech"
  "Kokoro speech endpoint."
  :type 'string)

(defcustom kokoro-reader-health-endpoint
  "http://127.0.0.1:8000/health"
  "Kokoro health endpoint used to start the local server on demand."
  :type 'string)

(defcustom kokoro-reader-server-command
  '("uv" "run" "python" "kokoro_server.py"
    "--host" "127.0.0.1" "--port" "8000")
  "Command used to start Kokoro when its health endpoint is unavailable."
  :type '(repeat string))

(defcustom kokoro-reader-server-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Working directory for `kokoro-reader-server-command'."
  :type '(choice (const :tag "Directory containing kokoro-reader.el" nil)
                 directory))

(defcustom kokoro-reader-model
  "mlx-community/Kokoro-82M-bf16"
  "Model identifier sent to the server."
  :type 'string)

(defcustom kokoro-reader-voice
  "bf_emma"
  "Kokoro voice.  For British English, try bf_emma or bm_george."
  :type 'string)

(defcustom kokoro-reader-lang-code
  "b"
  "Kokoro language code.  b means British English; a means American English."
  :type 'string)

(defcustom kokoro-reader-speed
  1.0
  "Synthesis speed, normally between 0.5 and 2.0."
  :type 'number)

(defcustom kokoro-reader-volume
  1.0
  "Playback volume passed to afplay."
  :type 'number)

(defcustom kokoro-reader-curl-program
  "/usr/bin/curl"
  "Path to curl."
  :type 'file)

(defcustom kokoro-reader-player-program
  "/usr/bin/afplay"
  "Path to the macOS audio player."
  :type 'file)

(defcustom kokoro-reader-backend 'kokoro
  "Speech backend used for the current buffer.
`kokoro' uses the local HTTP server.  `macos' uses a resident Apple
`AVSpeechSynthesizer' bridge and is the automatic fallback for languages
unsupported by Kokoro."
  :type '(choice (const kokoro) (const macos)))

(defcustom kokoro-reader-macos-speech-bridge-program
  (expand-file-name
   "macos-speech-bridge/my-read-speech-bridge"
   (file-name-directory (or load-file-name buffer-file-name)))
  "Path to the resident AVSpeechSynthesizer bridge executable."
  :type 'file)

(defcustom kokoro-reader-macos-voice nil
  "macOS voice used by the fallback backend, or nil for the system default."
  :type '(choice (const :tag "System default" nil) string))

(defcustom kokoro-reader-macos-rate 180
  "Speaking rate passed to the macOS fallback backend."
  :type 'integer)

(defcustom kokoro-reader-macos-prefetch-enabled t
  "Whether continuous readers may synthesize future macOS utterances early."
  :type 'boolean)

(defcustom kokoro-reader-macos-prefetch-count 2
  "Maximum number of future macOS utterances synthesized ahead of playback."
  :type '(integer :tag "Utterances" 1))

(defvar kokoro-reader--request-process nil)
(defvar kokoro-reader--player-process nil)
(defvar kokoro-reader--server-process nil)
(defvar kokoro-reader--server-health-process nil)
(defvar kokoro-reader--server-health-timer nil)
(defvar kokoro-reader--audio-file nil)
(defvar kokoro-reader--overlay nil)
(defvar kokoro-reader--macos-prefetch-queue nil)
(defvar kokoro-reader--macos-bridge-process nil)
(defvar kokoro-reader--macos-bridge-fragment "")
(defvar kokoro-reader--macos-bridge-ready-p nil)
(defvar kokoro-reader--macos-next-id 0)
(defvar kokoro-reader--macos-current-entry nil)

(defvar kokoro-reader-macos-queued-start-hook nil
  "Hook run when AVSpeechSynthesizer starts a previously queued utterance.")

(defvar kokoro-reader-player-finish-hook nil
  "Hook run immediately after the current audio player exits normally.

This is separate from `kokoro-reader-stop': cancelling or replacing playback
does not run the hook.  Continuous readers can use it to enqueue the next
already-rendered utterance without polling the player process.")

(defun kokoro-reader--server-ready-p ()
  (and (process-live-p kokoro-reader--server-process)
       (string= (process-name kokoro-reader--server-process) "kokoro-server")))

(defun kokoro-reader--server-failed (message-text on-error)
  (when (timerp kokoro-reader--server-health-timer)
    (cancel-timer kokoro-reader--server-health-timer)
    (setq kokoro-reader--server-health-timer nil))
  (when (functionp on-error)
    (funcall on-error message-text))
  (message "Kokoro server failed: %s" message-text))

(defun kokoro-reader--ensure-server (on-ready on-error)
  "Call ON-READY after the API is reachable, starting it if necessary.
Call ON-ERROR with a diagnostic string when startup cannot be completed."
  (let ((buffer (generate-new-buffer " *kokoro-reader-health*")))
    (setq kokoro-reader--server-health-process
          (make-process
           :name "kokoro-health"
           :buffer buffer
           :noquery t
           :command (list kokoro-reader-curl-program
                          "--silent" "--show-error" "--fail"
                          "--max-time" "1"
                          kokoro-reader-health-endpoint)
           :sentinel
           (lambda (process _event)
             (when (and (eq process kokoro-reader--server-health-process)
                        (memq (process-status process) '(exit signal)))
               (let ((ok (= (process-exit-status process) 0))
                     (error-text
                      (with-current-buffer (process-buffer process)
                        (string-trim (buffer-string)))))
                 (setq kokoro-reader--server-health-process nil)
                 (when (buffer-live-p (process-buffer process))
                   (kill-buffer (process-buffer process)))
                 (cond
                  (ok (funcall on-ready))
                  ((kokoro-reader--server-ready-p)
                   (setq kokoro-reader--server-health-timer
                         (run-at-time 0.2 nil
                                      #'kokoro-reader--ensure-server
                                      on-ready on-error)))
                  ((not (file-directory-p
                         (or kokoro-reader-server-directory default-directory)))
                   (kokoro-reader--server-failed
                    (format "server directory does not exist: %s"
                            (or kokoro-reader-server-directory default-directory))
                    on-error))
                  (t
                   (condition-case err
                       (progn
                         (let ((default-directory
                                (file-name-as-directory
                                 (or kokoro-reader-server-directory
                                     default-directory))))
                           (setq kokoro-reader--server-process
                                 (make-process
                                  :name "kokoro-server"
                                  :buffer "*kokoro-server*"
                                  :command kokoro-reader-server-command
                                  :coding 'utf-8
                                  :noquery t
                                  :sentinel
                                  (lambda (server _server-event)
                                    (when (and (memq (process-status server)
                                                      '(exit signal))
                                               (eq server
                                                   kokoro-reader--server-process))
                                      (setq kokoro-reader--server-process nil)
                                      (kokoro-reader--server-failed
                                       "the server process exited"
                                       on-error))))))
                         (setq kokoro-reader--server-health-timer
                               (run-at-time 0.2 nil
                                            #'kokoro-reader--ensure-server
                                            on-ready on-error)))
                     (error
                      (kokoro-reader--server-failed
                       (error-message-string err) on-error))))))))))
    (set-process-query-on-exit-flag
     kokoro-reader--server-health-process nil)))

(defun kokoro-reader--delete-overlay ()
  (when (overlayp kokoro-reader--overlay)
    (delete-overlay kokoro-reader--overlay))
  (setq kokoro-reader--overlay nil))

(defun kokoro-reader--delete-audio-file ()
  (when (and kokoro-reader--audio-file
             (file-exists-p kokoro-reader--audio-file))
    (ignore-errors (delete-file kokoro-reader--audio-file)))
  (setq kokoro-reader--audio-file nil))

(defun kokoro-reader--clear-macos-prefetch ()
  "Cancel all queued resident macOS speech without killing its bridge."
  (when (process-live-p kokoro-reader--macos-bridge-process)
    (process-send-string kokoro-reader--macos-bridge-process
                         "{\"command\":\"stop\"}\n"))
  (setq kokoro-reader--macos-prefetch-queue nil
        kokoro-reader--macos-current-entry nil)
  (kokoro-reader--delete-overlay))

(defun kokoro-reader-stop (&optional preserve-macos-prefetch)
  "Cancel synthesis or stop current playback.
When PRESERVE-MACOS-PREFETCH is non-nil, retain queued macOS utterances."
  (interactive)
  (unless preserve-macos-prefetch
    (kokoro-reader--clear-macos-prefetch))
  ;; Clear variables before deleting processes, so their sentinels know that the
  ;; cancellation is intentional and do not start/clean a newer request.
  (let ((request kokoro-reader--request-process)
        (player kokoro-reader--player-process)
        (health kokoro-reader--server-health-process))
    (setq kokoro-reader--request-process nil
          kokoro-reader--player-process nil
          kokoro-reader--server-health-process nil)
    (when (process-live-p request)
      (delete-process request))
    (when (process-live-p player)
      (delete-process player))
    (when (process-live-p health)
      (delete-process health)))
  (when (timerp kokoro-reader--server-health-timer)
    (cancel-timer kokoro-reader--server-health-timer)
    (setq kokoro-reader--server-health-timer nil))
  (kokoro-reader--delete-overlay)
  (kokoro-reader--delete-audio-file)
  (message "Kokoro stopped"))

(defun kokoro-reader--sentence-bounds ()
  (or (bounds-of-thing-at-point 'sentence)
      (user-error "Place point in a sentence or select text")))

(defun kokoro-reader--paragraph-bounds ()
  (save-excursion
    (backward-paragraph)
    (skip-chars-forward " \t\n")
    (let ((beg (point)))
      (forward-paragraph)
      (skip-chars-backward " \t\n")
      (cons beg (point)))))

(defun kokoro-reader--default-bounds ()
  (if (use-region-p)
      (cons (region-beginning) (region-end))
    (kokoro-reader--sentence-bounds)))

(defun kokoro-reader--text (beg end)
  (let ((text (buffer-substring-no-properties beg end)))
    ;; EPUB/nov buffers often contain visual line breaks.  Kokoro generally
    ;; produces steadier prose when whitespace is normalized.
    (setq text (replace-regexp-in-string "[ \t\n\r]+" " " text))
    (setq text (string-trim text))
    (when (string-empty-p text)
      (user-error "The selected text is empty"))
    (when (> (length text) 12000)
      (user-error "Selection is too long (%d characters; maximum is 12000)"
                  (length text)))
    text))

(defun kokoro-reader--payload (text)
  (json-serialize
   `((model . ,kokoro-reader-model)
     (input . ,text)
     (voice . ,kokoro-reader-voice)
     (speed . ,(float kokoro-reader-speed))
     (lang_code . ,kokoro-reader-lang-code)
     (response_format . "wav")
     (stream . :false))))

(defun kokoro-reader--play (audio-file overlay &optional backend-label)
  (let ((process
         (make-process
          :name "kokoro-afplay"
          :buffer nil
          :noquery t
          :command
          (list kokoro-reader-player-program
                "-v" (number-to-string kokoro-reader-volume)
                audio-file)
          :sentinel
          (lambda (proc _event)
            (when (and (eq proc kokoro-reader--player-process)
                       (memq (process-status proc) '(exit signal)))
              (setq kokoro-reader--player-process nil)
              (when (overlayp overlay)
                (delete-overlay overlay))
              (when (equal audio-file kokoro-reader--audio-file)
                (kokoro-reader--delete-audio-file))
              (message "%s finished" (or backend-label "Kokoro"))
              (run-hooks 'kokoro-reader-player-finish-hook))))))
    (setq kokoro-reader--player-process process)
    (message "%s speaking…" (or backend-label "Kokoro"))))

(defun kokoro-reader--speak-bounds-kokoro (beg end)
  "Speak BEG through END using the local Kokoro server."
  (kokoro-reader-stop)
  (let* ((text (kokoro-reader--text beg end))
         (payload (kokoro-reader--payload text))
         (audio-file (make-temp-file "kokoro-reader-" nil ".wav"))
         (stderr-buffer (generate-new-buffer " *kokoro-reader-curl*"))
         (overlay (make-overlay beg end (current-buffer) nil t))
         process)
    (overlay-put overlay 'face 'highlight)
    (setq kokoro-reader--audio-file audio-file
          kokoro-reader--overlay overlay)
    (kokoro-reader--ensure-server
     (lambda ()
       (setq process
             (make-process
              :name "kokoro-curl"
              :buffer nil
              :stderr stderr-buffer
              :connection-type 'pipe
              :coding 'binary
              :noquery t
              :command
              (list kokoro-reader-curl-program
                    "--silent"
                    "--show-error"
                    "--fail-with-body"
                    "--request" "POST"
                    "--header" "Content-Type: application/json"
                    "--output" audio-file
                    "--data-binary" "@-"
                    kokoro-reader-endpoint)
              :sentinel
              (lambda (proc _event)
                (when (and (eq proc kokoro-reader--request-process)
                           (memq (process-status proc) '(exit signal)))
                  (setq kokoro-reader--request-process nil)
                  (let ((ok (and (= (process-exit-status proc) 0)
                                 (file-exists-p audio-file)
                                 (> (file-attribute-size
                                     (file-attributes audio-file))
                                    44)))
                        (error-text
                         (when (buffer-live-p stderr-buffer)
                           (with-current-buffer stderr-buffer
                             (string-trim (buffer-string))))))
                    (when (buffer-live-p stderr-buffer)
                      (kill-buffer stderr-buffer))
                    (if ok
                        (kokoro-reader--play audio-file overlay)
                      (when (overlayp overlay)
                        (delete-overlay overlay))
                      (when (equal audio-file kokoro-reader--audio-file)
                        (kokoro-reader--delete-audio-file))
                      (message "Kokoro request failed%s"
                               (if (string-empty-p (or error-text ""))
                                   ""
                                 (concat ": " error-text)))))))))
       (setq kokoro-reader--request-process process)
       (process-send-string process (encode-coding-string payload 'utf-8))
       (process-send-eof process)
       (message "Kokoro synthesizing…"))
     (lambda (error-text)
       (when (buffer-live-p stderr-buffer)
         (kill-buffer stderr-buffer))
       (when (overlayp overlay)
         (delete-overlay overlay))
       (when (equal audio-file kokoro-reader--audio-file)
         (kokoro-reader--delete-audio-file))
       (message "Kokoro request not started: %s" error-text)))))

(defun kokoro-reader--macos-key (text)
  "Return the resident AVSpeechSynthesizer queue key for TEXT."
  (list text kokoro-reader-macos-voice kokoro-reader-macos-rate
        kokoro-reader-volume))

(defun kokoro-reader--macos-entry-for-id (id)
  "Return the resident speech queue entry identified by ID."
  (seq-find (lambda (entry) (= id (plist-get entry :id)))
            kokoro-reader--macos-prefetch-queue))

(defun kokoro-reader--handle-macos-bridge-event (event)
  "Handle one decoded AVSpeechSynthesizer bridge EVENT plist."
  (let* ((name (plist-get event :event))
         (id (plist-get event :id))
         (entry (and (integerp id) (kokoro-reader--macos-entry-for-id id))))
    (pcase name
      ("ready"
       (setq kokoro-reader--macos-bridge-ready-p t))
      ("queued"
       (when entry (setf (plist-get entry :queued) t)))
      ("started"
       (when entry
         (setq kokoro-reader--macos-current-entry entry)
         (setf (plist-get entry :started) t)
         (unless (plist-get entry :announced)
           (run-hooks 'kokoro-reader-macos-queued-start-hook))))
      ("finished"
       (when entry
         (setq kokoro-reader--macos-prefetch-queue
               (delq entry kokoro-reader--macos-prefetch-queue))
         (when (eq entry kokoro-reader--macos-current-entry)
           (setq kokoro-reader--macos-current-entry nil))
         (when (plist-get entry :announced)
           (kokoro-reader--delete-overlay)
           (run-hooks 'kokoro-reader-player-finish-hook))))
      ("cancelled"
       (when entry
         (setq kokoro-reader--macos-prefetch-queue
               (delq entry kokoro-reader--macos-prefetch-queue))
         (when (eq entry kokoro-reader--macos-current-entry)
           (setq kokoro-reader--macos-current-entry nil))))
      ("error"
       (message "macOS speech bridge: %s" (or (plist-get event :message)
                                                "unknown error"))))))

(defun kokoro-reader--macos-bridge-filter (_process output)
  "Decode newline-delimited bridge OUTPUT and dispatch its events."
  ;; Publish the incomplete tail before dispatching any event.  Event hooks can
  ;; enqueue more speech and cause another filter call; retaining byte offsets
  ;; into the shared fragment across that re-entry produced `Args out of range'.
  (let* ((parts (split-string
                 (concat kokoro-reader--macos-bridge-fragment output) "\n"))
         (lines (butlast parts)))
    (setq kokoro-reader--macos-bridge-fragment (car (last parts)))
    (dolist (line lines)
      (unless (string-empty-p line)
        (condition-case err
            (kokoro-reader--handle-macos-bridge-event
             (json-parse-string line :object-type 'plist))
          (error
           (message "macOS speech bridge response error: %s"
                    (error-message-string err))))))))

(defun kokoro-reader--macos-bridge-sentinel (process event)
  "Clear resident bridge state when PROCESS exits with EVENT."
  (when (and (eq process kokoro-reader--macos-bridge-process)
             (memq (process-status process) '(exit signal)))
    (setq kokoro-reader--macos-bridge-process nil
          kokoro-reader--macos-bridge-ready-p nil
          kokoro-reader--macos-bridge-fragment ""
          kokoro-reader--macos-prefetch-queue nil
          kokoro-reader--macos-current-entry nil)
    (kokoro-reader--delete-overlay)
    (message "macOS speech bridge exited: %s" (string-trim event))))

(defun kokoro-reader--ensure-macos-bridge ()
  "Return the live resident AVSpeechSynthesizer bridge process."
  (unless (process-live-p kokoro-reader--macos-bridge-process)
    (unless (file-executable-p kokoro-reader-macos-speech-bridge-program)
      (user-error "Build the speech bridge with `make my-read-speech-build'"))
    (setq kokoro-reader--macos-bridge-fragment ""
          kokoro-reader--macos-bridge-ready-p nil
          kokoro-reader--macos-bridge-process
          (make-process
           :name "my-read-speech-bridge"
           :buffer nil
           :command (list kokoro-reader-macos-speech-bridge-program)
           :connection-type 'pipe
           :coding 'utf-8-unix
           :noquery t
           :filter #'kokoro-reader--macos-bridge-filter
           :sentinel #'kokoro-reader--macos-bridge-sentinel)))
  kokoro-reader--macos-bridge-process)

(defun kokoro-reader--enqueue-macos-text (text &optional announced)
  "Enqueue TEXT in the resident synthesizer and return its entry.
ANNOUNCED means the normal speech wrapper already owns its visual context."
  (let* ((process (kokoro-reader--ensure-macos-bridge))
         (id (cl-incf kokoro-reader--macos-next-id))
         (entry (list :id id :key (kokoro-reader--macos-key text)
                      :announced announced :queued nil :started nil))
         (command `((command . "enqueue")
                    (id . ,id)
                    (text . ,text)
                    (voice . ,kokoro-reader-macos-voice)
                    (rate . ,kokoro-reader-macos-rate)
                    (volume . ,kokoro-reader-volume))))
    (setq kokoro-reader--macos-prefetch-queue
          (append kokoro-reader--macos-prefetch-queue (list entry)))
    (process-send-string process (concat (json-serialize command) "\n"))
    entry))

(defun kokoro-reader-macos-hold ()
  "Hold resident playback while continuous speech fills its initial queue."
  (process-send-string (kokoro-reader--ensure-macos-bridge)
                       "{\"command\":\"hold\"}\n"))

(defun kokoro-reader-macos-play (&optional warmup)
  "Release resident playback after WARMUP utterances have been rendered."
  (process-send-string
   (kokoro-reader--ensure-macos-bridge)
   (concat (json-serialize
            `((command . "play") (warmup . ,(max 1 (or warmup 1)))))
           "\n")))

(defun kokoro-reader-prefetch-macos-texts (texts)
  "Append ordered future TEXTS to the resident AVSpeechSynthesizer queue."
  (when (and kokoro-reader-macos-prefetch-enabled
             (eq kokoro-reader-backend 'macos))
    (let* ((wanted (mapcar #'kokoro-reader--macos-key
                           (seq-take texts kokoro-reader-macos-prefetch-count)))
           (pending (seq-remove
                     (lambda (entry)
                       (or (eq entry kokoro-reader--macos-current-entry)
                           (plist-get entry :announced)))
                     kokoro-reader--macos-prefetch-queue))
           (existing (mapcar (lambda (entry) (plist-get entry :key)) pending)))
      ;; AVSpeechSynthesizer cannot remove one queued utterance without also
      ;; interrupting the current voice.  Normal continuous reading always
      ;; supplies the same retained prefix; only append its missing suffix.
      (when (equal existing (seq-take wanted (length existing)))
        (dolist (key (seq-drop wanted (length existing)))
          (let ((kokoro-reader-macos-voice (nth 1 key))
                (kokoro-reader-macos-rate (nth 2 key))
                (kokoro-reader-volume (nth 3 key)))
            (kokoro-reader--enqueue-macos-text (car key))))))))

(defun kokoro-reader-prefetch-macos-text (text)
  "Asynchronously synthesize macOS speech for one future TEXT."
  (kokoro-reader-prefetch-macos-texts (list text)))

(defun kokoro-reader-macos-prefetch-ready-p (text)
  "Return non-nil when TEXT is already in the resident speech queue."
  (let ((key (kokoro-reader--macos-key text)))
    (seq-some (lambda (entry) (equal key (plist-get entry :key)))
              kokoro-reader--macos-prefetch-queue)))

(defun kokoro-reader-macos-speaking-p ()
  "Return non-nil while resident macOS speech is queued or speaking."
  (and (process-live-p kokoro-reader--macos-bridge-process)
       kokoro-reader--macos-prefetch-queue))

(defun kokoro-reader-macos-has-pending-p ()
  "Return non-nil when an utterance follows the current resident speech."
  (seq-some (lambda (entry)
              (not (eq entry kokoro-reader--macos-current-entry)))
            kokoro-reader--macos-prefetch-queue))

(defun kokoro-reader--speak-bounds-macos (beg end)
  "Speak BEG through END through the resident AVSpeechSynthesizer queue."
  (let* ((text (kokoro-reader--text beg end))
         (key (kokoro-reader--macos-key text))
         (queued-entry
          (and kokoro-reader--macos-current-entry
               (not (plist-get kokoro-reader--macos-current-entry :announced))
               (equal key (plist-get kokoro-reader--macos-current-entry :key))
               kokoro-reader--macos-current-entry)))
    (unless queued-entry
      (kokoro-reader-stop))
    (let ((overlay (make-overlay beg end (current-buffer) nil t)))
      (overlay-put overlay 'face 'highlight)
      (setq kokoro-reader--overlay overlay)
      (if queued-entry
          (setf (plist-get queued-entry :announced) t)
        (kokoro-reader--enqueue-macos-text text t))
      (message "macOS speech queued with %s…"
               (or kokoro-reader-macos-voice "the system voice")))))

(defun kokoro-reader--speak-bounds (beg end)
  "Speak BEG through END with the buffer's configured backend."
  (if (eq kokoro-reader-backend 'macos)
      (kokoro-reader--speak-bounds-macos beg end)
    (kokoro-reader--speak-bounds-kokoro beg end)))

;;;###autoload
(defun kokoro-reader-speak ()
  "Read the active region, or the sentence at point."
  (interactive)
  (pcase-let ((`(,beg . ,end) (kokoro-reader--default-bounds)))
    (kokoro-reader--speak-bounds beg end)))

;;;###autoload
(defun kokoro-reader-speak-paragraph ()
  "Read the paragraph at point."
  (interactive)
  (pcase-let ((`(,beg . ,end) (kokoro-reader--paragraph-bounds)))
    (kokoro-reader--speak-bounds beg end)))

;;;###autoload
(defun kokoro-reader-speak-and-forward ()
  "Read the active region/current sentence, then move to the next sentence."
  (interactive)
  (pcase-let ((`(,beg . ,end) (kokoro-reader--default-bounds)))
    (kokoro-reader--speak-bounds beg end)
    (goto-char end)
    (skip-chars-forward " \t\n")))

(defvar-keymap kokoro-reader-mode-map
  :doc "Keymap for `kokoro-reader-mode'."
;;  "C-c s" #'kokoro-reader-speak
  "C-c p" #'kokoro-reader-speak-paragraph
  "C-c n" #'kokoro-reader-speak-and-forward
  "C-c k" #'kokoro-reader-stop
  )

;;;###autoload
(define-minor-mode kokoro-reader-mode
  "Read English prose through a local Kokoro API."
  :lighter " Kokoro"
  :keymap kokoro-reader-mode-map
  (unless kokoro-reader-mode
    (kokoro-reader-stop)))

(provide 'kokoro-reader)
;;; kokoro-reader.el ends here
