;;; kokoro-reader.el --- Read English aloud with local Kokoro -*- lexical-binding: t; -*-

;; This client uses macOS /usr/bin/curl asynchronously to fetch a WAV file and
;; /usr/bin/afplay to play it.  It has no third-party Emacs dependencies.

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
`kokoro' uses the local HTTP server.  `macos' uses `/usr/bin/say' and is the
automatic fallback for languages unsupported by Kokoro."
  :type '(choice (const kokoro) (const macos)))

(defcustom kokoro-reader-macos-program "/usr/bin/say"
  "Path to the macOS speech synthesizer used by the fallback backend."
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

(defun kokoro-reader--discard-macos-prefetch-entry (entry)
  "Cancel and delete one queued macOS speech ENTRY."
  (let ((process (plist-get entry :process))
        (file (plist-get entry :file)))
    (when (process-live-p process)
      (delete-process process))
    (when (and file (file-exists-p file))
      (ignore-errors (delete-file file)))))

(defun kokoro-reader--clear-macos-prefetch ()
  "Cancel and delete all queued macOS speech files."
  (let ((entries kokoro-reader--macos-prefetch-queue))
    (setq kokoro-reader--macos-prefetch-queue nil)
    (dolist (entry entries)
      (kokoro-reader--discard-macos-prefetch-entry entry))))

(defun kokoro-reader-stop (&optional preserve-macos-prefetch)
  "Cancel synthesis or stop current playback.
When PRESERVE-MACOS-PREFETCH is non-nil, retain future synthesized audio."
  (interactive)
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
  (unless preserve-macos-prefetch
    (kokoro-reader--clear-macos-prefetch))
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
              (message "%s finished" (or backend-label "Kokoro")))))))
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
  "Return the synthesis cache key for macOS speech TEXT."
  (list text kokoro-reader-macos-program
        kokoro-reader-macos-voice kokoro-reader-macos-rate))

(defun kokoro-reader--macos-command (audio-file)
  "Return a `say' command that synthesizes into AUDIO-FILE."
  (append (list kokoro-reader-macos-program
                "-r" (number-to-string kokoro-reader-macos-rate)
                "-o" audio-file)
          (when (and (stringp kokoro-reader-macos-voice)
                     (not (string-empty-p kokoro-reader-macos-voice)))
            (list "-v" kokoro-reader-macos-voice))))

(defun kokoro-reader--valid-audio-file-p (file)
  "Return non-nil when FILE looks like a non-empty synthesized audio file."
  (and file
       (file-exists-p file)
       (> (file-attribute-size (file-attributes file)) 4096)))

(defun kokoro-reader--start-macos-prefetch (text)
  "Start asynchronous macOS synthesis for TEXT and return its queue entry."
  (let* ((key (kokoro-reader--macos-key text))
         (file (make-temp-file "kokoro-macos-next-" nil ".aiff"))
         (entry (list :key key :file file :process nil :ready nil))
         process)
    (setq process
          (make-process
           :name "kokoro-macos-prefetch"
           :buffer nil
           :connection-type 'pipe
           :coding 'utf-8-unix
           :noquery t
           :command (kokoro-reader--macos-command file)
           :sentinel
           (lambda (proc _event)
             (when (and (eq proc (plist-get entry :process))
                        (memq (process-status proc) '(exit signal)))
               (setf (plist-get entry :process) nil)
               (if (and (= (process-exit-status proc) 0)
                        (kokoro-reader--valid-audio-file-p file))
                   (setf (plist-get entry :ready) t)
                 (setq kokoro-reader--macos-prefetch-queue
                       (delq entry kokoro-reader--macos-prefetch-queue))
                 (kokoro-reader--discard-macos-prefetch-entry entry))))))
    (setf (plist-get entry :process) process)
    (process-send-string process text)
    (process-send-eof process)
    entry))

(defun kokoro-reader-prefetch-macos-texts (texts)
  "Asynchronously synthesize ordered future macOS utterance TEXTS.

Matching queued work is retained, obsolete work is cancelled, and no more
than `kokoro-reader-macos-prefetch-count' entries are kept."
  (when (and kokoro-reader-macos-prefetch-enabled
             (eq kokoro-reader-backend 'macos))
    (let ((wanted (mapcar #'kokoro-reader--macos-key
                          (seq-take texts kokoro-reader-macos-prefetch-count)))
          (available kokoro-reader--macos-prefetch-queue)
          retained)
      (dolist (key wanted)
        (let ((entry (seq-find
                      (lambda (candidate)
                        (and (equal key (plist-get candidate :key))
                             (or (and (plist-get candidate :ready)
                                      (kokoro-reader--valid-audio-file-p
                                       (plist-get candidate :file)))
                                 (process-live-p
                                  (plist-get candidate :process)))))
                      available)))
          (if entry
              (progn
                (setq available (delq entry available))
                (push entry retained))
            (push (kokoro-reader--start-macos-prefetch (car key)) retained))))
      (dolist (entry available)
        (kokoro-reader--discard-macos-prefetch-entry entry))
      (setq kokoro-reader--macos-prefetch-queue (nreverse retained)))))

(defun kokoro-reader-prefetch-macos-text (text)
  "Asynchronously synthesize macOS speech for one future TEXT."
  (kokoro-reader-prefetch-macos-texts (list text)))

(defun kokoro-reader--take-macos-prefetch (key)
  "Return and detach the ready prefetched file matching KEY."
  (when-let ((entry
              (seq-find
               (lambda (candidate)
                 (and (plist-get candidate :ready)
                      (equal key (plist-get candidate :key))
                      (kokoro-reader--valid-audio-file-p
                       (plist-get candidate :file))))
               kokoro-reader--macos-prefetch-queue)))
    (setq kokoro-reader--macos-prefetch-queue
          (delq entry kokoro-reader--macos-prefetch-queue))
    (plist-get entry :file)))

(defun kokoro-reader--take-running-macos-prefetch (key)
  "Return and detach an in-progress prefetch matching KEY.

The return value is (PROCESS . FILE).  Detaching prevents
`kokoro-reader-stop' from cancelling synthesis when the continuous reader
promotes this work to the current utterance."
  (when-let ((entry
              (seq-find
               (lambda (candidate)
                 (and (not (plist-get candidate :ready))
                      (equal key (plist-get candidate :key))
                      (process-live-p (plist-get candidate :process))))
               kokoro-reader--macos-prefetch-queue)))
    (setq kokoro-reader--macos-prefetch-queue
          (delq entry kokoro-reader--macos-prefetch-queue))
    (cons (plist-get entry :process) (plist-get entry :file))))

(defun kokoro-reader--speak-bounds-macos (beg end)
  "Synthesize BEG through END to AIFF, then play it with `afplay'."
  (let* ((text (kokoro-reader--text beg end))
         (key (kokoro-reader--macos-key text))
         (prefetched-file (kokoro-reader--take-macos-prefetch key))
         (running-prefetch
          (unless prefetched-file
            (kokoro-reader--take-running-macos-prefetch key))))
    ;; Detaching matching prefetch work first prevents normal stop cleanup from
    ;; deleting ready audio or cancelling synthesis that is nearly complete.
    (kokoro-reader-stop t)
    (let* ((audio-file (or prefetched-file (cdr running-prefetch)
                           (make-temp-file "kokoro-macos-" nil ".aiff")))
           (overlay (make-overlay beg end (current-buffer) nil t))
           process)
      (overlay-put overlay 'face 'highlight)
      (setq kokoro-reader--audio-file audio-file
            kokoro-reader--overlay overlay)
      (if prefetched-file
          (kokoro-reader--play audio-file overlay "macOS speech")
        (setq process
              (or (car running-prefetch)
                  (make-process
                   :name "kokoro-macos-synthesize"
                   :buffer nil
                   :connection-type 'pipe
                   :coding 'utf-8-unix
                   :noquery t
                   :command (kokoro-reader--macos-command audio-file))))
        (set-process-sentinel
         process
         (lambda (proc _event)
           (when (and (eq proc kokoro-reader--request-process)
                      (memq (process-status proc) '(exit signal)))
             (setq kokoro-reader--request-process nil)
             (if (and (= (process-exit-status proc) 0)
                      (kokoro-reader--valid-audio-file-p audio-file))
                 (kokoro-reader--play
                  audio-file overlay "macOS speech")
               (when (overlayp overlay)
                 (delete-overlay overlay))
               (when (equal audio-file kokoro-reader--audio-file)
                 (kokoro-reader--delete-audio-file))
               (message "macOS speech synthesis failed")))))
        (setq kokoro-reader--request-process process)
        (if running-prefetch
            (message "macOS speech finishing prefetched audio…")
          (process-send-string process text)
          (process-send-eof process)
          (message "macOS speech synthesizing with %s…"
                   (or kokoro-reader-macos-voice "the system voice")))))))

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
