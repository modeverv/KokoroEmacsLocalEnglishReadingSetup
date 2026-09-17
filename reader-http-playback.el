;;; reader-http-playback.el --- Remote playback bridge -*- lexical-binding: t; -*-

(require 'reader-http-speech)
(require 'kokoro-reader)

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

(defun reader-http-playback--event (original event)
  "Capture the capability and fail closed on playback errors."
  (if (not (reader-http-playback--enabled-p))
      (funcall original event)
    (pcase (plist-get event :event)
      ("ready"
       (setq reader-http-playback--session (plist-get event :session)
             reader-http-playback--delivery-token (plist-get event :delivery_token))
       (funcall original event))
      ("error"
       (if (fboundp 'english-reading-mode-stop-continuous)
           (english-reading-mode-stop-continuous)
         (kokoro-reader-stop))
       (message "再生サーバー: %s" (plist-get event :message)))
      (_ (funcall original event)))))

(defun reader-http-playback--ensure (original)
  "Use a portable WebSocket helper instead of the native playback process."
  (if (not (reader-http-playback--enabled-p))
      (funcall original)
    (unless (and (process-live-p kokoro-reader--macos-bridge-process)
                 (equal (process-get kokoro-reader--macos-bridge-process 'playback-endpoint)
                        reader-http-speech-playback-endpoint))
      (kokoro-reader-stop)
      (when (process-live-p kokoro-reader--macos-bridge-process)
        (delete-process kokoro-reader--macos-bridge-process))
      (setq reader-http-playback--session nil reader-http-playback--delivery-token nil
            kokoro-reader--macos-bridge-fragment "" kokoro-reader--macos-bridge-ready-p nil)
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

(advice-add 'kokoro-reader--ensure-macos-bridge :around #'reader-http-playback--ensure)
(advice-add 'kokoro-reader--handle-macos-bridge-event :around #'reader-http-playback--event)
(provide 'reader-http-playback)
;;; reader-http-playback.el ends here
