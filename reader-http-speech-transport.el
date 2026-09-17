;;; reader-http-speech-transport.el --- HTTP transport for normal reader keys -*- lexical-binding: t; -*-

(require 'reader-http-speech)
(require 'kokoro-reader)
(require 'cl-lib)

(defvar reader-http-speech-transport-mode nil)

(defun reader-http-speech-transport--payload (text)
  "Capture the current reader's language, voice and speed for TEXT."
  (let* ((backend (symbol-name kokoro-reader-backend))
         (japanese (or (eq kokoro-reader-backend 'irodori)
                       (member kokoro-reader-lang-code '("j" "ja"))
                       (and (eq kokoro-reader-backend 'macos)
                            (string-match-p "Kyoko" kokoro-reader-macos-voice))))
         (voice (if (eq kokoro-reader-backend 'macos)
                    (replace-regexp-in-string " (.*)\\'" "" kokoro-reader-macos-voice)
                  kokoro-reader-voice))
         (speed (if (eq kokoro-reader-backend 'macos)
                    (/ kokoro-reader-macos-rate 250.0)
                  kokoro-reader-speed)))
    (json-encode `((text . ,(kokoro-reader--speech-text text))
                   (language . ,(if japanese "ja" "en"))
                   (backend . ,backend) (voice . ,voice) (speed . ,speed)))))

(defun reader-http-speech-transport--key (key)
  "Include the HTTP endpoint in KEY without shifting existing key fields."
  (if reader-http-speech-transport-mode
      (append key (list 'http reader-http-speech-endpoint))
    key))

(defun reader-http-speech-transport--enqueue (original text &optional announced)
  "Reserve a native playback slot and receive TEXT over HTTP."
  (if (not reader-http-speech-transport-mode)
      (funcall original text announced)
    (let* ((process (kokoro-reader--ensure-macos-bridge))
           (id (cl-incf kokoro-reader--macos-next-id))
           (entry (list :id id :backend 'kokoro
                        :key (if (eq kokoro-reader-backend 'macos)
                                 (kokoro-reader--macos-key text)
                               (kokoro-reader--kokoro-key text))
                        :announced announced :queued nil :loaded nil :started nil
                        :audio-file (make-temp-file "reader-http-" nil ".wav")
                        :volume kokoro-reader-volume
                        :http-payload (reader-http-speech-transport--payload text)
                        :endpoint reader-http-speech-endpoint)))
      (setq kokoro-reader--macos-prefetch-queue
            (append kokoro-reader--macos-prefetch-queue (list entry))
            kokoro-reader--kokoro-pending-entries
            (append kokoro-reader--kokoro-pending-entries (list entry))
            kokoro-reader--kokoro-api-ready-p t)
      (process-send-string process
                           (concat (json-encode `((command . "reserve") (id . ,id))) "\n"))
      (kokoro-reader--launch-pending-requests)
      entry)))

(defun reader-http-speech-transport--start-request (original entry)
  "Download HTTP ENTRY; preserve the existing resident playback lifecycle."
  (if (not (plist-get entry :http-payload))
      (funcall original entry)
    (let* ((default-directory reader-http-speech--directory)
           (stderr-buffer (generate-new-buffer " *http-speech-request-error*"))
           (process
            (make-process
             :name (format "http-speech-chunk-%s" (plist-get entry :id))
             :buffer nil :stderr stderr-buffer :connection-type 'pipe
             :coding 'utf-8-unix :noquery t
             :command (list reader-http-speech-python "-m" "speech_http.client"
                            "--endpoint" (plist-get entry :endpoint)
                            "--output" (plist-get entry :audio-file))
             :sentinel
             (lambda (proc _event)
               (when (memq (process-status proc) '(exit signal))
                 (when (and (not (zerop (process-exit-status proc)))
                            (buffer-live-p stderr-buffer))
                   (with-current-buffer (get-buffer-create "*HTTP Speech Errors*")
                     (insert-buffer-substring stderr-buffer)))
                 (kokoro-reader--kokoro-request-finished proc entry stderr-buffer))))))
      (setf (plist-get entry :process) process)
      (push process kokoro-reader--kokoro-request-processes)
      (process-send-string process (plist-get entry :http-payload))
      (process-send-eof process))))

;;;###autoload
(define-minor-mode reader-http-speech-transport-mode
  "Route normal reader speech and lookahead through the HTTP speech server.
The resident native process only plays downloaded WAVs, preserving the normal
sentence completion, highlighting, page turning and continuous audio queue."
  :global t :group 'reader-http-speech
  (when (fboundp 'english-reading-mode-stop-continuous)
    (english-reading-mode-stop-continuous))
  (kokoro-reader-stop)
  (setq kokoro-reader--kokoro-api-ready-p nil)
  (if reader-http-speech-transport-mode
      (progn
        (advice-add 'kokoro-reader--enqueue-macos-text :around #'reader-http-speech-transport--enqueue)
        (advice-add 'kokoro-reader--enqueue-kokoro-text :around #'reader-http-speech-transport--enqueue)
        (advice-add 'kokoro-reader--start-kokoro-request :around #'reader-http-speech-transport--start-request)
        (advice-add 'kokoro-reader--macos-key :filter-return #'reader-http-speech-transport--key)
        (advice-add 'kokoro-reader--kokoro-key :filter-return #'reader-http-speech-transport--key))
    (advice-remove 'kokoro-reader--enqueue-macos-text #'reader-http-speech-transport--enqueue)
    (advice-remove 'kokoro-reader--enqueue-kokoro-text #'reader-http-speech-transport--enqueue)
    (advice-remove 'kokoro-reader--start-kokoro-request #'reader-http-speech-transport--start-request)
    (advice-remove 'kokoro-reader--macos-key #'reader-http-speech-transport--key)
    (advice-remove 'kokoro-reader--kokoro-key #'reader-http-speech-transport--key)))

(provide 'reader-http-speech-transport)
;;; reader-http-speech-transport.el ends here
