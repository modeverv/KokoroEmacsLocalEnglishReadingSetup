;;; english-reader-tts.el --- macOS English TTS -*- lexical-binding: t; -*-

(defgroup english-reader-tts nil
  "English text-to-speech for reading in Emacs."
  :group 'convenience)

(defcustom english-reader-tts-voice nil
  "macOSの読み上げ音声名。
nilならmacOSのシステム音声を使用する。
利用可能な音声は `say -v ?` で確認できる。"
  :type '(choice
          (const :tag "システム音声" nil)
          (string :tag "音声名")))

(defcustom english-reader-tts-rate 155
  "読み上げ速度。"
  :type 'integer)

(defvar english-reader-tts-process nil
  "現在動作中のsayプロセス。")

(defun english-reader-tts--sentinel (process _event)
  "読み上げ終了時にハイライトを消す。"
  (when (memq (process-status process) '(exit signal))
    (when-let ((overlay (process-get process 'tts-overlay)))
      (delete-overlay overlay))
    (when (eq process english-reader-tts-process)
      (setq english-reader-tts-process nil))))

(defun english-reader-tts-stop ()
  "現在の読み上げを停止する。"
  (interactive)
  (when (process-live-p english-reader-tts-process)
    (delete-process english-reader-tts-process))
  (setq english-reader-tts-process nil))

(defun english-reader-tts--bounds ()
  "読み上げ対象範囲を返す。
リージョンがあればリージョン、なければ現在位置の文を返す。"
  (cond
   ((use-region-p)
    (cons (region-beginning) (region-end)))

   ((bounds-of-thing-at-point 'sentence))

   (t
    (user-error "読み上げる英文を選択するか、英文上にカーソルを置いてください"))))

(defun english-reader-tts--speak-region (beg end)
  "BEGからENDまでをmacOSのsayで読み上げる。"
  (english-reader-tts-stop)

  (let* ((overlay (make-overlay beg end))
         (arguments
          (append
           (when english-reader-tts-voice
             (list "-v" english-reader-tts-voice))
           (list "-r"
                 (number-to-string english-reader-tts-rate))))
         (process
          (make-process
           :name "english-reader-tts"
           :buffer nil
           :command (cons "/usr/bin/say" arguments)
           :connection-type 'pipe
           :noquery t
           :sentinel #'english-reader-tts--sentinel)))

    (overlay-put overlay 'face 'highlight)
    (process-put process 'tts-overlay overlay)

    (setq english-reader-tts-process process)

    ;; コマンドライン引数ではなく標準入力へ送るため、
    ;; 長い文章でも扱いやすい。
    (process-send-region process beg end)
    (process-send-eof process)))

(defun english-reader-tts-speak ()
  "リージョン、またはカーソル位置の文を読み上げる。"
  (interactive)
  (pcase-let ((`(,beg . ,end) (english-reader-tts--bounds)))
    (english-reader-tts--speak-region beg end)))

(defun english-reader-tts-speak-and-forward ()
  "現在の文を読み上げ、カーソルを次の文へ進める。"
  (interactive)
  (pcase-let ((`(,beg . ,end) (english-reader-tts--bounds)))
    (english-reader-tts--speak-region beg end)
    (goto-char end)
    (skip-chars-forward " \t\n")))

(setq english-reader-tts-voice "Samantha")
(setq english-reader-tts-rate 145)

(global-set-key (kbd "C-c s") #'english-reader-tts-speak)
(global-set-key (kbd "C-c n") #'english-reader-tts-speak-and-forward)
(global-set-key (kbd "C-c k") #'english-reader-tts-stop)

;;(provide 'english-reader-tts)
