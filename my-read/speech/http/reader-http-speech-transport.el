;;; reader-http-speech-transport.el --- HTTP transport for normal reader keys -*- lexical-binding: t; -*-

(require 'reader-http-speech)
(require 'kokoro-reader)
(require 'cl-lib)
(require 'reader-http-playback)

(defvar reader-http-speech-transport-mode nil)

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

(defun reader-http-speech-transport--prepare (text)
  "Describe HTTP synthesis of TEXT without modifying the queue."
  (let ((remote (reader-http-playback--enabled-p)))
    (list :backend 'kokoro :start #'reader-http-speech-transport--start-request
          :failure-policy 'stop :error-buffer "*HTTP Speech Errors*"
          :remote-playback remote
          :audio-file (unless remote (make-temp-file "reader-http-" nil ".wav"))
          :volume kokoro-reader-volume
          :http-payload (reader-http-speech-transport--payload text)
          :endpoint reader-http-speech-endpoint)))

(defun reader-http-speech-transport--start-request (entry)
  "Send ENTRY and report its result through the shared queue API."
  (reader-http-speech--remember-endpoint (plist-get entry :endpoint))
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
               (reader-speech-queue-request-finished proc entry stderr-buffer))))))
    (reader-speech-queue-attach-process entry process)
    (process-send-string process payload)
    (process-send-eof process)))

(defun reader-http-speech-transport--descriptor ()
  "Return the explicit HTTP transport operations."
  (list :prepare #'reader-http-speech-transport--prepare
        :key #'reader-http-speech-transport--key))

;; Remove old runtime advice when updating an already-running Emacs.
(dolist (pair '((kokoro-reader--clear-macos-prefetch . reader-http-speech-transport--mark-cancelled)
                (kokoro-reader--enqueue-macos-text . reader-http-speech-transport--enqueue)
                (kokoro-reader--enqueue-kokoro-text . reader-http-speech-transport--enqueue)
                (kokoro-reader--start-kokoro-request . reader-http-speech-transport--start-request)
                (kokoro-reader--macos-key . reader-http-speech-transport--key)
                (kokoro-reader--kokoro-key . reader-http-speech-transport--key)))
  (advice-remove (car pair) (cdr pair)))

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
  (reader-speech-queue-select-transport
   (when reader-http-speech-transport-mode
     (reader-http-speech-transport--descriptor))))

(provide 'reader-http-speech-transport)
;;; reader-http-speech-transport.el ends here
