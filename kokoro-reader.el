;;; kokoro-reader.el --- Read English aloud with local Kokoro -*- lexical-binding: t; -*-

;; This client uses macOS /usr/bin/curl asynchronously to fetch a WAV file and
;; /usr/bin/afplay to play it.  It has no third-party Emacs dependencies.

(require 'json)
(require 'subr-x)
(require 'thingatpt)

(defgroup kokoro-reader nil
  "Local Kokoro text-to-speech for reading buffers."
  :group 'multimedia)

(defcustom kokoro-reader-endpoint
  "http://127.0.0.1:8000/v1/audio/speech"
  "Kokoro speech endpoint."
  :type 'string)

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

(defvar kokoro-reader--request-process nil)
(defvar kokoro-reader--player-process nil)
(defvar kokoro-reader--audio-file nil)
(defvar kokoro-reader--overlay nil)

(defun kokoro-reader--delete-overlay ()
  (when (overlayp kokoro-reader--overlay)
    (delete-overlay kokoro-reader--overlay))
  (setq kokoro-reader--overlay nil))

(defun kokoro-reader--delete-audio-file ()
  (when (and kokoro-reader--audio-file
             (file-exists-p kokoro-reader--audio-file))
    (ignore-errors (delete-file kokoro-reader--audio-file)))
  (setq kokoro-reader--audio-file nil))

(defun kokoro-reader-stop ()
  "Cancel synthesis or stop current playback."
  (interactive)
  ;; Clear variables before deleting processes, so their sentinels know that the
  ;; cancellation is intentional and do not start/clean a newer request.
  (let ((request kokoro-reader--request-process)
        (player kokoro-reader--player-process))
    (setq kokoro-reader--request-process nil
          kokoro-reader--player-process nil)
    (when (process-live-p request)
      (delete-process request))
    (when (process-live-p player)
      (delete-process player)))
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

(defun kokoro-reader--play (audio-file overlay)
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
              (message "Kokoro finished"))))))
    (setq kokoro-reader--player-process process)
    (message "Kokoro speaking…")))

(defun kokoro-reader--speak-bounds (beg end)
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
    (message "Kokoro synthesizing…")))

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
