;;; reader-diagnose.el --- Read-only speech diagnostics -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'button)
(require 'kokoro-reader)
(require 'reader-http-speech)

(declare-function reader-http-speech-transport--auto-language-p "reader-http-speech-transport" ())
(defvar english-reading-mode--continuous-state)
(defvar english-reading-mode--active-speech)
(defvar reader-http-speech-transport-mode)
(defvar reader-http-speech-playback-endpoint)
(defvar reader-http-speech-playback-delivery-endpoint)
(declare-function my/read-center-window "my-read-core" (&optional frame))
(defvar-local reader-diagnose--source nil)
(defvar-local reader-diagnose--generation 0)
(defvar-local reader-diagnose--probes nil)
(defvar-local reader-diagnose--health nil)
(defvar-local reader-diagnose--snapshot nil)

(defun reader-diagnose--source-buffer ()
  "Choose the playing document rather than notes or diagnostics."
  (or (let ((source (plist-get (bound-and-true-p english-reading-mode--continuous-state) :buffer)))
        (and (buffer-live-p source) source))
      (let ((source (plist-get (bound-and-true-p english-reading-mode--active-speech) :buffer)))
        (and (buffer-live-p source) source))
      (and (buffer-live-p reader-diagnose--source) reader-diagnose--source)
      (when (fboundp 'my/read-center-window)
        (let ((window (my/read-center-window)))
          (and (window-live-p window) (window-buffer window))))
      (current-buffer)))

(defun reader-diagnose--safe-url (url)
  "Hide credentials and query parameters in displayed URL."
  (when (stringp url)
    (replace-regexp-in-string "://[^/@]+@" "://[redacted]@"
                              (car (split-string url "[?#]")))))

(defun reader-diagnose--collect (source)
  "Collect metadata for SOURCE without requests or playback side effects."
  (with-current-buffer source
    (let ((http (bound-and-true-p reader-http-speech-transport-mode)))
      (list :source (buffer-name source) :backend kokoro-reader-backend
            :voice (if (eq kokoro-reader-backend 'macos) kokoro-reader-macos-voice kokoro-reader-voice)
            :speed (if (eq kokoro-reader-backend 'macos)
                       (format "%s 語/分" kokoro-reader-macos-rate)
                     (format "%s 倍" kokoro-reader-speed))
            :language-policy (if (and http (fboundp 'reader-http-speech-transport--auto-language-p)
                                      (reader-http-speech-transport--auto-language-p))
                                 "auto（生成サーバーが判定。下記の声・速度はEmacs側の推定設定）"
                               "Emacs側で指定")
            :transport (if http "HTTP" "ローカル")
            :endpoint (cond (http reader-http-speech-endpoint)
                            ((not (eq kokoro-reader-backend 'macos)) kokoro-reader-endpoint))
            :health-url (cond (http (concat (string-remove-suffix "/" reader-http-speech-endpoint) "/health"))
                              ((not (eq kokoro-reader-backend 'macos)) kokoro-reader-health-endpoint))
            :playback (and http (bound-and-true-p reader-http-speech-playback-endpoint))
            :delivery (and http (bound-and-true-p reader-http-speech-playback-delivery-endpoint))
            :player-pid (when (process-live-p kokoro-reader--macos-bridge-process)
                          (process-id kokoro-reader--macos-bridge-process))
            :queue (reader-speech-queue-snapshot)))))

(defun reader-diagnose--cancel-probes ()
  "Cancel only this diagnostic buffer's health checks."
  (let ((probes reader-diagnose--probes))
    (setq reader-diagnose--probes nil)
    (dolist (process probes)
      (when (process-live-p process) (delete-process process)))))

(defun reader-diagnose--probe (key url)
  "Check URL asynchronously; never start or stop a service."
  (let* ((view (current-buffer)) (generation reader-diagnose--generation)
         (output (generate-new-buffer " *reader-diagnose-health*")))
    (condition-case nil
        (push
         (make-process
          :name "reader-diagnose-health" :buffer output :noquery t
          :connection-type 'pipe :coding 'utf-8-unix
          :command (list kokoro-reader-curl-program "--silent" "--fail" "--max-time" "1.5"
                         "--max-filesize" "65536" "--" url)
          :sentinel
          (lambda (process _event)
            (when (memq (process-status process) '(exit signal))
              (unwind-protect
                  (when (and (buffer-live-p view)
                             (= generation (buffer-local-value 'reader-diagnose--generation view)))
                    (let ((data (when (and (zerop (process-exit-status process)) (buffer-live-p output))
                                  (with-current-buffer output
                                    (ignore-errors (json-parse-string (buffer-string) :object-type 'plist))))))
                      (with-current-buffer view
                        (setq reader-diagnose--probes (delq process reader-diagnose--probes))
                        (setf (alist-get key reader-diagnose--health)
                              (if (and data (eq (plist-get data :ok) t))
                                  (list :status "応答あり" :pid (plist-get data :pid))
                                (list :status "応答なし／不正な応答")))
                        (reader-diagnose--render))))
                (when (buffer-live-p output) (kill-buffer output))))))
         reader-diagnose--probes)
      (error
       (kill-buffer output)
       (setf (alist-get key reader-diagnose--health) '(:status "確認できません"))))))

(defun reader-diagnose--render ()
  "Render captured state and health without changing the source selection."
  (let* ((inhibit-read-only t) (saved-point (point))
         (data reader-diagnose--snapshot) (queue (plist-get data :queue))
         (health (alist-get 'speech reader-diagnose--health))
         (stage (alist-get (plist-get queue :stage)
                          '((idle . "停止中") (playing . "再生中")
                            (connecting . "生成サーバーの接続待ち")
                            (generating . "先頭区間の生成・受信待ち")
                            (buffering . "再生開始待ち（先読み準備／プレイヤー）")))))
    (erase-buffer)
    (insert (format "Reader 診断  %s\n\ng: 更新   q: 閉じる\n\n" (format-time-string "%H:%M:%S")))
    (insert (format "対象          %s\n状態          %s\n方式          %s / %s\n声・速度      %s / %s\n"
                    (plist-get data :source) stage (plist-get data :transport)
                    (plist-get data :backend) (plist-get data :voice) (plist-get data :speed)))
    (insert (format "言語指定      %s\n" (plist-get data :language-policy)))
    (insert (format "生成先        %s\nサーバー      %s   PID: %s\n"
                    (or (reader-diagnose--safe-url (plist-get data :endpoint)) "ネイティブ音声合成")
                    (or (plist-get health :status) "対象外") (or (plist-get health :pid) "不明／対象外")))
    (insert (format "再生先        %s\n再生プロセス  PID: %s\n"
                    (or (reader-diagnose--safe-url (plist-get data :playback)) "Emacs側の音声出力")
                    (or (plist-get data :player-pid) "未起動")))
    (when (plist-get data :playback)
      (insert (format "再生サーバー  %s\n配送先        %s\n"
                      (or (plist-get (alist-get 'playback reader-diagnose--health) :status) "確認中")
                      (reader-diagnose--safe-url (or (plist-get data :delivery) (plist-get data :playback))))))
    (insert (format "\n生成・受信中  %s件（送信待ち %s件）\n準備済み      %s区間（先頭から連続 %s区間）\n先読み音声    %s\n"
                    (plist-get queue :inflight) (plist-get queue :pending)
                    (plist-get queue :ready) (plist-get queue :contiguous-ready)
                    (if (numberp (plist-get queue :seconds))
                        (format "%.2f秒（現在の再生区間を除く）" (plist-get queue :seconds))
                      "不明（プレイヤーから長さの通知なし）")))
    (when (and (eq (plist-get queue :stage) 'playing) (equal (plist-get queue :seconds) 0))
      (insert "注意          次の連続区間の音声がまだ準備できていません。\n"))
    (let ((error (plist-get queue :last-error)))
      (insert (format "\n直近のエラー  %s\n"
                      (if error
                          (format "%s [%s] %s" (format-time-string "%H:%M:%S" (plist-get error :time))
                                  (plist-get error :stage) (plist-get error :message))
                        "記録なし"))))
    (dolist (name '("*HTTP Speech Errors*" "*HTTP Playback Errors*" "*HTTP Speech Service*" "*HTTP Playback Service*"))
      (when (get-buffer name)
        (insert-text-button name 'follow-link t 'action (lambda (_) (display-buffer name)))
        (insert "  ")))
    (insert "\n\n生成・受信中はEmacs側の要求数です。サーバー内部の実行数とは異なります。\n")
    (goto-char (min saved-point (point-max)))))

(defun reader-diagnose-refresh ()
  "Refresh metadata and bounded health checks without interrupting reading."
  (interactive)
  (cl-incf reader-diagnose--generation)
  (reader-diagnose--cancel-probes)
  (if (not (buffer-live-p reader-diagnose--source))
      (message "診断対象のバッファは閉じられています")
    (setq reader-diagnose--snapshot (reader-diagnose--collect reader-diagnose--source)
          reader-diagnose--health nil)
    (when-let* ((url (plist-get reader-diagnose--snapshot :health-url)))
      (push '(speech . (:status "確認中")) reader-diagnose--health)
      (reader-diagnose--probe 'speech url))
    (when-let* ((endpoint (plist-get reader-diagnose--snapshot :playback)))
      (push '(playback . (:status "確認中")) reader-diagnose--health)
      (reader-diagnose--probe 'playback (concat (string-remove-suffix "/" endpoint) "/health")))
    (reader-diagnose--render)))

(define-derived-mode reader-diagnose-mode special-mode "Reader診断"
  "Read-only diagnostic snapshot; g refreshes and q closes the window."
  (local-set-key (kbd "g") #'reader-diagnose-refresh)
  (add-hook 'kill-buffer-hook #'reader-diagnose--cancel-probes nil t))

;;;###autoload
(defun reader-diagnose ()
  "Show live reading state without starting services or changing playback."
  (interactive)
  (let ((source (reader-diagnose--source-buffer))
        (buffer (get-buffer-create "*Reader Diagnose*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'reader-diagnose-mode) (reader-diagnose-mode))
      (setq reader-diagnose--source source)
      (reader-diagnose-refresh))
    (display-buffer buffer '((display-buffer-in-side-window)
                             (side . bottom) (window-height . 0.35)))))

(provide 'reader-diagnose)
;;; reader-diagnose.el ends here
