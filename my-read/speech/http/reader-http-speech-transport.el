;;; reader-http-speech-transport.el --- HTTP transport for normal reader keys -*- lexical-binding: t; -*-

(require 'reader-http-speech)
(require 'kokoro-reader)
(require 'cl-lib)
(require 'reader-http-playback)

(defvar reader-http-speech-transport-mode nil)

(defun reader-http-speech-transport--mark-cancelled (&rest _)
  "Mark HTTP requests before killing them so sentinels cannot restart the queue."
  (dolist (entry kokoro-reader--macos-prefetch-queue)
    (when (plist-get entry :http-payload)
      (setf (plist-get entry :http-cancelled) t))))

(defun reader-http-speech-transport--payload (text)
  "Capture the reader's explicit language, voice and exact speed for TEXT."
  (let* ((backend (symbol-name kokoro-reader-backend))
         (language
          (cond ((and (boundp 'my/read-speech-language-override)
                      (memq my/read-speech-language-override '(ja en)))
                 (symbol-name my/read-speech-language-override))
                ((and (boundp 'my/read-source-language)
                      (member my/read-source-language '("ja" "en")))
                 my/read-source-language)
                ((or (eq kokoro-reader-backend 'irodori)
                     (member kokoro-reader-lang-code '("j" "ja"))
                     (and (eq kokoro-reader-backend 'macos)
                          (string-match-p "Kyoko" (or kokoro-reader-macos-voice "")))) "ja")
                (t "en")))
         (voice (if (eq kokoro-reader-backend 'macos)
                    (replace-regexp-in-string " (.*)\\'" "" (or kokoro-reader-macos-voice
                                                                (if (equal language "ja") "Kyoko" "Samantha")))
                  kokoro-reader-voice))
         (payload `((text . ,(kokoro-reader--speech-text text))
                    (language . ,language) (backend . ,backend) (voice . ,voice)
                    (lang_code . ,(if (equal language "ja") "j"
                                    (if (member kokoro-reader-lang-code '("a" "b")) kokoro-reader-lang-code "b")))
                    (speed . ,(if (eq kokoro-reader-backend 'macos) 1.0 kokoro-reader-speed)))))
    (when (eq kokoro-reader-backend 'macos)
      (push `(rate . ,kokoro-reader-macos-rate) payload))
    (json-encode payload)))

(defun reader-http-speech-transport--key (key)
  "Include the HTTP endpoint in KEY without shifting existing key fields."
  (if reader-http-speech-transport-mode
      (append key (list 'http reader-http-speech-endpoint reader-http-speech-playback-endpoint
                        reader-http-speech-playback-delivery-endpoint
                        reader-http-speech-playback-target
                        (and (boundp 'my/read-source-language) my/read-source-language)
                        (and (boundp 'my/read-speech-language-override) my/read-speech-language-override)))
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
                        :http-cancelled nil :process nil
                        :remote-playback (reader-http-playback--enabled-p)
                        :audio-file (unless (reader-http-playback--enabled-p)
                                      (make-temp-file "reader-http-" nil ".wav"))
                        :volume kokoro-reader-volume
                        :http-payload (reader-http-speech-transport--payload text)
                        :endpoint reader-http-speech-endpoint)))
      (setq kokoro-reader--macos-prefetch-queue
            (append kokoro-reader--macos-prefetch-queue (list entry))
            kokoro-reader--kokoro-pending-entries
            (append kokoro-reader--kokoro-pending-entries (list entry))
            kokoro-reader--kokoro-api-ready-p t)
      (process-send-string process
                           (concat (json-encode `((command . "reserve") (id . ,id)
                                                  (volume . ,kokoro-reader-volume))) "\n"))
      (kokoro-reader--launch-pending-requests)
      entry)))

(defun reader-http-speech-transport--start-request (original entry)
  "Download HTTP ENTRY; preserve the existing resident playback lifecycle."
  (if (not (plist-get entry :http-payload))
      (funcall original entry)
    (let* ((default-directory reader-http-speech--directory)
           (remote (plist-get entry :remote-playback))
           (payload (if remote (reader-http-playback--request entry)
                      (plist-get entry :http-payload)))
           (stderr-buffer (generate-new-buffer " *http-speech-request-error*"))
           (process
            (make-process
             :name (format "http-speech-chunk-%s" (plist-get entry :id))
             :buffer nil :stderr stderr-buffer :connection-type 'pipe
             :coding 'utf-8-unix :noquery t
             :command (append (list reader-http-speech-python "-m" "speech_http.client"
                                    "--endpoint" (plist-get entry :endpoint)
                                    "--auto-start" "--listen-host" reader-http-speech-listen-host)
                              (if remote '("--deliver")
                                (list "--output" (plist-get entry :audio-file))))
             :sentinel
             (lambda (proc _event)
               (when (memq (process-status proc) '(exit signal))
                 (when (and (not (zerop (process-exit-status proc)))
                            (not (plist-get entry :http-cancelled))
                            (buffer-live-p stderr-buffer))
                   (with-current-buffer (get-buffer-create "*HTTP Speech Errors*")
                     (insert-buffer-substring stderr-buffer))
                   ;; A failed request must not advance reading or automatically
                   ;; relaunch a server the user just stopped in the app.
                   (when (kokoro-reader--macos-entry-for-id (plist-get entry :id))
                     (if (fboundp 'english-reading-mode-stop-continuous)
                         (english-reading-mode-stop-continuous)
                       (kokoro-reader-stop))
                     (message "HTTP speech stopped; see *HTTP Speech Errors*")))
                 (if (or remote (plist-get entry :http-cancelled))
                     (progn
                       ;; Delivery is not playback completion. Only the player
                       ;; device's finished event advances the reader.
                       (setq kokoro-reader--kokoro-request-processes
                             (delq proc kokoro-reader--kokoro-request-processes))
                       (when (buffer-live-p stderr-buffer) (kill-buffer stderr-buffer))
                       (unless (plist-get entry :http-cancelled)
                         (kokoro-reader--launch-pending-requests)))
                   (kokoro-reader--kokoro-request-finished proc entry stderr-buffer)))))))
      (setf (plist-get entry :process) process)
      (push process kokoro-reader--kokoro-request-processes)
      (process-send-string process payload)
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
  (when (and (not reader-http-speech-transport-mode)
             (process-live-p kokoro-reader--macos-bridge-process)
             (process-get kokoro-reader--macos-bridge-process 'playback-endpoint))
    (delete-process kokoro-reader--macos-bridge-process)
    (setq kokoro-reader--macos-bridge-process nil))
  (setq kokoro-reader--kokoro-api-ready-p nil)
  (if reader-http-speech-transport-mode
      (progn
        (advice-add 'kokoro-reader--clear-macos-prefetch :before #'reader-http-speech-transport--mark-cancelled)
        (advice-add 'kokoro-reader--enqueue-macos-text :around #'reader-http-speech-transport--enqueue)
        (advice-add 'kokoro-reader--enqueue-kokoro-text :around #'reader-http-speech-transport--enqueue)
        (advice-add 'kokoro-reader--start-kokoro-request :around #'reader-http-speech-transport--start-request)
        (advice-add 'kokoro-reader--macos-key :filter-return #'reader-http-speech-transport--key)
        (advice-add 'kokoro-reader--kokoro-key :filter-return #'reader-http-speech-transport--key))
    (advice-remove 'kokoro-reader--clear-macos-prefetch #'reader-http-speech-transport--mark-cancelled)
    (advice-remove 'kokoro-reader--enqueue-macos-text #'reader-http-speech-transport--enqueue)
    (advice-remove 'kokoro-reader--enqueue-kokoro-text #'reader-http-speech-transport--enqueue)
    (advice-remove 'kokoro-reader--start-kokoro-request #'reader-http-speech-transport--start-request)
    (advice-remove 'kokoro-reader--macos-key #'reader-http-speech-transport--key)
    (advice-remove 'kokoro-reader--kokoro-key #'reader-http-speech-transport--key)))

(provide 'reader-http-speech-transport)
;;; reader-http-speech-transport.el ends here
