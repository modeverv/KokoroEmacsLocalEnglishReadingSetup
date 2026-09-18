;;; reader-http-speech.el --- Buffered HTTP speech client -*- lexical-binding: t; -*-

(require 'reader-load-path)

(require 'json)
(require 'subr-x)
(require 'thingatpt)
(declare-function reader-http-speech-transport--payload "reader-http-speech-transport" (text))

(defgroup reader-http-speech nil "Independent HTTP speech playback." :group 'multimedia)
(defconst reader-http-speech--directory
  reader-companion-directory)
(defcustom reader-http-speech-python
  (expand-file-name ".venv/bin/python" reader-http-speech--directory)
  "Python executable for the playback helper and server GUI."
  :type 'file)
(defcustom reader-http-speech-endpoint "http://127.0.0.1:8765"
  "Speech server URL; may point to another machine or an SSH tunnel."
  :type 'string)
(defcustom reader-http-speech-listen-host "0.0.0.0"
  "Bind address when automatically starting the local server."
  :type 'string)
(defcustom reader-http-speech-prebuffer 8
  "Seconds of received audio to accumulate before playback."
  :type 'number)
(defcustom reader-http-speech-player "ffplay"
  "FFplay executable; one process plays the entire PCM stream."
  :type 'string)
(defcustom reader-http-speech-english-backend "kokoro"
  "Server backend for English."
  :type '(choice (const "kokoro") (const "macos")))
(defcustom reader-http-speech-japanese-backend "macos"
  "Server backend for Japanese."
  :type '(choice (const "macos") (const "kokoro") (const "irodori")))
(defcustom reader-http-speech-english-speed 1.0
  "English speed multiplier, from 0.5 to 2.0." :type 'number)
(defcustom reader-http-speech-japanese-speed 1.0
  "Japanese speed multiplier, from 0.5 to 2.0." :type 'number)
(defcustom reader-http-speech-language "en"
  "Language used by the buffer's HTTP speech commands."
  :type '(choice (const "en") (const "ja")))
(make-variable-buffer-local 'reader-http-speech-language)
(defvar reader-http-speech--process nil)
(defvar reader-http-speech--gui-process nil)
(defvar reader-http-speech-finished-hook nil
  "Hook run in the source buffer only after successful playback completion.")

(defun reader-http-speech-stop ()
  "Cancel HTTP reception and stop the local audio player."
  (interactive)
  (when (process-live-p reader-http-speech--process)
    ;; SIGTERM lets the helper terminate and reap its child player.
    (signal-process reader-http-speech--process 'SIGTERM))
  (setq reader-http-speech--process nil))

(defun reader-http-speech--request (text language)
  "Build a language-specific request for TEXT and LANGUAGE."
  (unless (member language '("en" "ja")) (user-error "Use en or ja"))
  (unless (<= 1 (length (string-trim text)) 24000)
    (user-error "Select between 1 and 24000 characters"))
  (if (fboundp 'my/read--configure-speech-language)
      (progn
        (require 'reader-http-speech-transport)
        (with-temp-buffer
          (setq-local my/read-speech-language-override (intern language))
          (my/read--configure-speech-language language)
          (let ((json-object-type 'alist) (json-key-type 'symbol))
            (json-read-from-string (reader-http-speech-transport--payload text)))))
    `((text . ,text) (language . ,language)
      (backend . ,(if (equal language "ja") reader-http-speech-japanese-backend
                    reader-http-speech-english-backend))
      (speed . ,(if (equal language "ja") reader-http-speech-japanese-speed
                  reader-http-speech-english-speed)))))

(defun reader-http-speech-speak (text language)
  "Request TEXT in LANGUAGE (en or ja) and play buffered WAV chunks locally."
  (interactive (list (read-string "Text: ")
                     (completing-read "Language: " '("en" "ja") nil t)))
  (let ((payload (json-encode (reader-http-speech--request text language)))
        (source (current-buffer))
        (default-directory reader-http-speech--directory))
    (unless (executable-find reader-http-speech-player)
      (user-error "FFplay is missing: install ffmpeg or set reader-http-speech-player"))
    (reader-http-speech-stop)
    (when (fboundp 'english-reading-mode-stop-continuous)
      (english-reading-mode-stop-continuous))
    (let ((log (get-buffer-create "*HTTP Speech*")))
      (with-current-buffer log (erase-buffer))
      (with-current-buffer (get-buffer-create "*HTTP Speech Errors*") (erase-buffer))
      (setq reader-http-speech--process
            (make-process
             :name "reader-http-speech" :buffer log :stderr "*HTTP Speech Errors*"
             :connection-type 'pipe :coding 'utf-8-unix :noquery t
             :command (list reader-http-speech-python "-m" "speech_http.client"
                            "--endpoint" reader-http-speech-endpoint
                            "--auto-start" "--listen-host" reader-http-speech-listen-host
                            "--prebuffer" (number-to-string reader-http-speech-prebuffer)
                            "--player" reader-http-speech-player)
             :sentinel
             (lambda (process _event)
               (when (and (memq (process-status process) '(exit signal))
                          (eq process reader-http-speech--process))
                 (setq reader-http-speech--process nil)
                 (if (zerop (process-exit-status process))
                     (when (buffer-live-p source)
                       (with-current-buffer source
                         (run-hooks 'reader-http-speech-finished-hook))
                       (message "HTTP speech finished"))
                   (message "HTTP speech failed; see *HTTP Speech Errors*"))))))
      (process-put reader-http-speech--process 'source-buffer source)
      (process-send-string reader-http-speech--process payload)
      (process-send-eof reader-http-speech--process)
      (message "HTTP speech: receiving and buffering %s audio…" language))))

(defun reader-http-speech-read (language)
  "Read the region, or point through buffer end, using LANGUAGE.
In EPUB this reads the current chapter.  For PDF, select extracted text."
  (interactive (list (if current-prefix-arg
                         (completing-read "Language: " '("en" "ja") nil t)
                       reader-http-speech-language)))
  (reader-http-speech-speak
   (buffer-substring-no-properties (if (use-region-p) (region-beginning) (point))
                                   (if (use-region-p) (region-end) (point-max)))
   language))

(defun reader-http-speech-read-english ()
  "Read the region or remainder of this buffer in English."
  (interactive) (reader-http-speech-read "en"))

(defun reader-http-speech-read-japanese ()
  "Read the region or remainder of this buffer in Japanese."
  (interactive) (reader-http-speech-read "ja"))

(defun reader-http-speech-sentence ()
  "Read the current sentence using the buffer's HTTP speech language."
  (interactive)
  (reader-http-speech-speak (or (thing-at-point 'sentence t) "") reader-http-speech-language))

(defun reader-http-speech-open-gui ()
  "Open the native macOS server application."
  (interactive)
  (let ((default-directory reader-http-speech--directory))
    (make-process :name "reader-speech-app-launcher" :noquery t
                  :buffer "*Speech Server GUI*"
                  :command (list reader-http-speech-python "-m" "speech_http.gui"))))

(defvar reader-http-speech-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c h r") #'reader-http-speech-read)
    (define-key map (kbd "C-c h e") #'reader-http-speech-read-english)
    (define-key map (kbd "C-c h j") #'reader-http-speech-read-japanese)
    (define-key map (kbd "C-c h s") #'reader-http-speech-stop)
    (define-key map (kbd "C-c h g") #'reader-http-speech-open-gui)
    map))

;;;###autoload
(define-minor-mode reader-http-speech-mode
  "Additional HTTP speech commands; existing reader keys retain their behavior."
  :lighter " HTTP-TTS" :keymap reader-http-speech-mode-map)

(defun reader-http-speech--source-killed ()
  "Stop playback if its source buffer is being killed."
  (when (and reader-http-speech--process
             (eq (current-buffer)
                 (process-get reader-http-speech--process 'source-buffer)))
    (reader-http-speech-stop)))

(add-hook 'kill-buffer-hook #'reader-http-speech--source-killed)
(add-hook 'kill-emacs-hook #'reader-http-speech-stop)
(provide 'reader-http-speech)
;;; reader-http-speech.el ends here
