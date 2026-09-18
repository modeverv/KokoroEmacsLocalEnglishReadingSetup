;;; reader-http-playback.el --- Remote playback bridge -*- lexical-binding: t; -*-

(declare-function reader-http-speech-transport-mode "reader-http-speech-transport")
(require 'reader-http-speech)
(require 'kokoro-reader)

(defvar reader-http-speech-transport-mode)

(defcustom reader-http-speech-playback-endpoint nil
  "Playback server origin, e.g. http://127.0.0.1:8768; nil plays on Emacs's host."
  :type '(choice (const nil) string) :group 'reader-http-speech)
(defcustom reader-http-speech-playback-target "desktop"
  "Target name configured on the generation server."
  :type 'string :group 'reader-http-speech)
(defcustom reader-http-speech-playback-delivery-endpoint nil
  "Playback origin reachable from the generator; nil uses the control endpoint."
  :type '(choice (const nil) string) :group 'reader-http-speech)
(defvar reader-http-playback--session nil)
(defvar reader-http-playback--delivery-token nil)

(defcustom reader-http-playback-auto-start t
  "Automatically start a localhost playback service when connecting on macOS."
  :type 'boolean :group 'reader-http-speech)
(defcustom reader-http-playback-stop-server-on-exit t
  "Stop local playback services used by this Emacs on normal exit."
  :type 'boolean :group 'reader-http-speech)
(defvar reader-http-playback--local-ports nil)

(defun reader-http-playback--local-port (endpoint)
  "Return a strictly local HTTP ENDPOINT's port, otherwise nil."
  (when (and (stringp endpoint)
             (string-match "\\`http://\\(?:127\\.0\\.0\\.1\\|localhost\\)\\(?::\\([0-9]+\\)\\)?/?\\'" endpoint))
    (let ((port (if (match-string 1 endpoint)
                    (string-to-number (match-string 1 endpoint)) 80)))
      (and (<= 1 port 65535) port))))

(defun reader-http-playback--service-command (action port)
  "Run playback service ACTION for local PORT with a bounded wait."
  (let* ((default-directory reader-http-speech--directory)
         (process (make-process
                   :name "reader-playback-service" :noquery t
                   :buffer (get-buffer-create "*HTTP Playback Service*")
                   :connection-type 'pipe :sentinel #'ignore
                   :command (list reader-http-speech-python "-m" "speech_http.playback_service"
                                  action "--port" (number-to-string port)
                                  "--host" "127.0.0.1")))
         (deadline (+ (float-time) 25)))
    (unwind-protect
        (progn
          (while (and (process-live-p process) (< (float-time) deadline))
            (accept-process-output process .05))
          (when (or (process-live-p process) (/= (process-exit-status process) 0))
            (reader-speech-queue-record-error 'playback-service
                                              (format "Playback service %s failed" action))
            (error "Playback service %s failed; see *HTTP Playback Service*" action)))
      (when (process-live-p process) (delete-process process)))))

(defun reader-http-playback--ensure-service (endpoint)
  "Start only a local macOS service; remember it for this Emacs's shutdown."
  (when (eq system-type 'darwin)
    (when-let* ((port (reader-http-playback--local-port endpoint)))
      ;; Remember before starting so even a cancelled/failed startup is cleaned up.
      (cl-pushnew port reader-http-playback--local-ports)
      (when reader-http-playback-auto-start
        (reader-http-playback--service-command "start" port)))))

(defun reader-http-playback--shutdown ()
  "Disconnect playback and stop only local services used by this Emacs."
  (when (and (process-live-p kokoro-reader--macos-bridge-process)
             (process-get kokoro-reader--macos-bridge-process 'playback-endpoint))
    (let ((process kokoro-reader--macos-bridge-process))
      (setq kokoro-reader--macos-bridge-process nil)
      (delete-process process)))
  (when reader-http-playback-stop-server-on-exit
    (dolist (port reader-http-playback--local-ports)
      (condition-case err
          (reader-http-playback--service-command "stop" port)
        (error (message "%s" (error-message-string err)))))))

(defun reader-http-playback--enabled-p ()
  (and (bound-and-true-p reader-http-speech-transport-mode)
       reader-http-speech-playback-endpoint))

(defun reader-http-speech-set-playback-server (endpoint &optional target delivery-endpoint)
  "Stop reading and select playback ENDPOINT.
DELIVERY-ENDPOINT overrides the URL seen by the generator.
TARGET is retained for compatibility with older configurations.
An empty ENDPOINT restores playback on the Emacs host."
  (interactive (list (read-string "再生サーバーURL（空欄でローカル再生）: "
                                  reader-http-speech-playback-endpoint)))
  (when (fboundp 'english-reading-mode-stop-continuous)
    (english-reading-mode-stop-continuous))
  (kokoro-reader-stop)
  (when (process-live-p kokoro-reader--macos-bridge-process)
    (delete-process kokoro-reader--macos-bridge-process))
  (setq kokoro-reader--macos-bridge-process nil
        reader-http-playback--session nil
        reader-http-playback--delivery-token nil
        reader-http-speech-playback-endpoint (unless (string-empty-p (or endpoint "")) endpoint)
        reader-http-speech-playback-target (or target reader-http-speech-playback-target)
        reader-http-speech-playback-delivery-endpoint
        (unless (string-empty-p (or delivery-endpoint "")) delivery-endpoint))
  (when reader-http-speech-playback-endpoint
    (require 'reader-http-speech-transport)
    (unless reader-http-speech-transport-mode (reader-http-speech-transport-mode 1)))
  (message "再生先: %s" (or reader-http-speech-playback-endpoint "Emacs側")))

(defun reader-http-playback--event (event)
  "Consume remote errors and capture capabilities through the queue event API."
  (when (reader-http-playback--enabled-p)
    (pcase (plist-get event :event)
      ("ready"
       (setq reader-http-playback--session (plist-get event :session)
             reader-http-playback--delivery-token (plist-get event :delivery_token))
       nil)
      ("error"
       (reader-speech-queue-record-error 'remote-player
                                        (or (plist-get event :message) "Playback error"))
       (if (fboundp 'english-reading-mode-stop-continuous)
           (english-reading-mode-stop-continuous)
         (kokoro-reader-stop))
       (message "再生サーバー: %s" (plist-get event :message))
       t))))

(defun reader-http-playback--connect ()
  "Use a portable WebSocket helper instead of the native playback process."
  (when (reader-http-playback--enabled-p)
    (unless (and (process-live-p kokoro-reader--macos-bridge-process)
                 (equal (process-get kokoro-reader--macos-bridge-process 'playback-endpoint)
                        reader-http-speech-playback-endpoint))
      (kokoro-reader-stop)
      (when (process-live-p kokoro-reader--macos-bridge-process)
        (delete-process kokoro-reader--macos-bridge-process))
      (setq reader-http-playback--session nil reader-http-playback--delivery-token nil
            kokoro-reader--macos-bridge-fragment "" kokoro-reader--macos-bridge-ready-p nil)
      (let ((generation reader-speech-queue--generation))
        (reader-http-playback--ensure-service reader-http-speech-playback-endpoint)
        (unless (= generation reader-speech-queue--generation)
          (user-error "Playback connection cancelled")))
      (let ((default-directory reader-http-speech--directory))
        (setq kokoro-reader--macos-bridge-process
              (make-process
               :name "reader-remote-playback" :buffer nil :stderr "*HTTP Playback Errors*"
               :command (list reader-http-speech-python "-m" "speech_http.remote_bridge"
                              "--endpoint" reader-http-speech-playback-endpoint)
               :connection-type 'pipe :coding 'utf-8-unix :noquery t
               :filter #'kokoro-reader--macos-bridge-filter
               :sentinel
               (lambda (process event)
                 (when (and (eq process kokoro-reader--macos-bridge-process)
                            (memq (process-status process) '(exit signal)))
                   (setq reader-http-playback--session nil reader-http-playback--delivery-token nil)
                   (when (fboundp 'english-reading-mode-stop-continuous)
                     (english-reading-mode-stop-continuous))
                   (kokoro-reader--macos-bridge-sentinel process event)
                   (message "再生サーバーとの接続終了。*HTTP Playback Errors* を確認してください"))))))
      (process-put kokoro-reader--macos-bridge-process 'playback-endpoint reader-http-speech-playback-endpoint))
    (let ((deadline (+ (float-time) 10)))
      (while (and (not reader-http-playback--session)
                  (process-live-p kokoro-reader--macos-bridge-process)
                  (< (float-time) deadline))
        (accept-process-output kokoro-reader--macos-bridge-process .05)))
    (unless reader-http-playback--session
      (when (process-live-p kokoro-reader--macos-bridge-process)
        (delete-process kokoro-reader--macos-bridge-process))
      (user-error "再生サーバーに接続できません。*HTTP Playback Errors* を確認してください"))
    kokoro-reader--macos-bridge-process))

(defun reader-http-playback--request (entry)
  "Return ENTRY's generation request with a playback delivery capability."
  (let ((deadline (+ (float-time) 10)))
    ;; The reservation acknowledgement precedes generation, even over slow SSH.
    (while (and (not (plist-get entry :queued))
                (process-live-p kokoro-reader--macos-bridge-process)
                (< (float-time) deadline))
      (accept-process-output kokoro-reader--macos-bridge-process .05)))
  (unless (and (plist-get entry :queued) reader-http-playback--session)
    (kokoro-reader-stop)
    (user-error "再生サーバーのキュー予約に失敗しました"))
  (let ((json-object-type 'alist) (json-array-type 'list))
    (json-encode
     (cons `(playback . ((endpoint . ,(or reader-http-speech-playback-delivery-endpoint
                                          reader-http-speech-playback-endpoint))
                         (target . ,reader-http-speech-playback-target)
                         (session . ,reader-http-playback--session)
                         (delivery_token . ,reader-http-playback--delivery-token)
                         (id . ,(plist-get entry :id))))
           (json-read-from-string (plist-get entry :http-payload))))))

(advice-remove 'kokoro-reader--ensure-macos-bridge 'reader-http-playback--ensure)
(advice-remove 'kokoro-reader--handle-macos-bridge-event #'reader-http-playback--event)
(add-hook 'reader-speech-queue-connect-functions #'reader-http-playback--connect)
(add-hook 'reader-speech-queue-event-functions #'reader-http-playback--event)
(add-hook 'kill-emacs-hook #'reader-http-playback--shutdown)
(provide 'reader-http-playback)
;;; reader-http-playback.el ends here
