;;; my-read-speech-settings.el --- Speech-settings for the reader -*- lexical-binding: t; -*-

(require 'my-read-core)

(defcustom my/read-japanese-speech-backend 'macos
  "Japanese speech backend: macos, kokoro, or irodori.
Use `my-read-set-japanese-speech-backend' to also update open buffers."
  :type '(choice (const macos) (const kokoro) (const irodori))
  :group 'my-read)

(defcustom my/read-japanese-kokoro-voice "jf_alpha"
  "Japanese Kokoro voice, independent of the English voice."
  :type 'string
  :group 'my-read)

(defcustom my/read-japanese-kokoro-speed 1.0
  "Japanese Kokoro speed multiplier, from 0.5 to 2.0.
Use `my-read-change-japanese-speed' to update open buffers."
  :type 'number
  :group 'my-read)

(defcustom my/read-japanese-irodori-speed 1.0
  "Japanese Irodori speed multiplier, from 0.5 to 2.0.
The local asuka voice uses assets/asuka.wav as reference audio."
  :type 'number
  :group 'my-read)

(defcustom my/read-japanese-macos-voice "Kyoko"
  "macOS voice used when a center-pane EPUB or PDF contains Japanese text.

Used when `my/read-japanese-speech-backend' is macos."
  :type '(choice (const :tag "System default" nil) string)
  :group 'my-read)

(defcustom my/read-japanese-macos-rate 540
  "Japanese reading rate in words per minute.
Use `my-read-change-japanese-speed' to also update open reading buffers."
  :type 'integer
  :group 'my-read)

(defcustom my/read-english-macos-rate 180
  "English reading rate in words per minute.
Use `my-read-change-english-speed' to also update open reading buffers."
  :type 'integer
  :group 'my-read)

(defvar-local my/read-http-auto-language nil
  "Non-nil in hidden PDF speech buffers: use server language detection by default.")

(defvar-local my/read-source-language nil
  "Detected source language for the current reading buffer, or nil.")

(defun my/read--buffer-contains-japanese-p ()
  "Return non-nil when the current buffer contains Japanese script."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (re-search-forward "[ぁ-んァ-ヶ一-龠々]" nil t))))

(defvar-local my/read-speech-language-override nil
  "Manual speech language for this buffer: nil (automatic), ja, or en.
The override lasts until changed or the buffer is closed, including EWW
navigation and redisplay in the same buffer.")

(defun my/read--configure-speech-language (&optional detected-language)
  "Configure speech, preferring the buffer's explicit language selection.
Use DETECTED-LANGUAGE when supplied, otherwise inspect the buffer text."
  (if (or (eq my/read-speech-language-override 'ja)
          (and (null my/read-speech-language-override)
               (if detected-language
                   (equal detected-language "ja")
                 (my/read--buffer-contains-japanese-p))))
      (progn
        (setq-local my/read-source-language "ja"
                    kokoro-reader-backend my/read-japanese-speech-backend
                    kokoro-reader-macos-voice my/read-japanese-macos-voice
                    kokoro-reader-macos-rate my/read-japanese-macos-rate)
        (kill-local-variable 'kokoro-reader-model)
        (pcase my/read-japanese-speech-backend
          ('irodori
           (setq-local kokoro-reader-model "irodori-tts"
                       kokoro-reader-voice "asuka"
                       kokoro-reader-lang-code "j"
                       kokoro-reader-speed my/read-japanese-irodori-speed))
          ('kokoro
           (setq-local kokoro-reader-voice my/read-japanese-kokoro-voice
                       kokoro-reader-lang-code "j"
                       kokoro-reader-speed my/read-japanese-kokoro-speed))
          (_
           (dolist (variable '(kokoro-reader-voice kokoro-reader-lang-code
                                                   kokoro-reader-speed))
             (kill-local-variable variable)))))
    (setq-local my/read-source-language
                (if (eq my/read-speech-language-override 'en)
                    "en"
                  (or detected-language "en")))
    (kill-local-variable 'kokoro-reader-backend)
    (dolist (variable '(kokoro-reader-model kokoro-reader-voice kokoro-reader-lang-code
                                            kokoro-reader-speed))
      (kill-local-variable variable))
    (kill-local-variable 'kokoro-reader-macos-voice)
    (if (equal my/read-source-language "en")
        (setq-local kokoro-reader-macos-rate my/read-english-macos-rate)
      (kill-local-variable 'kokoro-reader-macos-rate))))

(defun my-read-set-speech-language (language)
  "Set the current KINDLE/EWW/TEXT/EPUB reading buffer's speech LANGUAGE.
LANGUAGE is ja, en, or nil for automatic detection.  Stop current playback
and discard prefetched audio; press SPC or s to resume at the current point.
The selection survives Kindle page turns and EWW navigation
until reset or closed."
  (interactive
   (list (pcase (completing-read "読み上げ言語: " '("ja" "en" "auto") nil t)
           ("ja" 'ja) ("en" 'en) (_ nil))))
  (unless (memq language '(nil ja en))
    (user-error "言語は ja、en、または nil を指定してください"))
  (unless (and (my/read--center-window-active-p)
               (or (derived-mode-p 'eww-mode 'nov-mode 'my-read-k-document-mode 'pdf-view-mode 'doc-view-mode)
                   (my/read--text-file-buffer-p)))
    (user-error "my-readのKINDLE・PDF・EWW・TEXT・EPUB本文で実行してください"))
  (english-reading-mode-stop-continuous)
  (setq-local my/read-speech-language-override language)
  (if (derived-mode-p 'my-read-k-document-mode)
      (my-read-k--configure-buffer-language my-read-k--current-result)
    (my/read--configure-speech-language))
  (when (and (derived-mode-p 'pdf-view-mode 'doc-view-mode)
             (buffer-live-p english-reading-mode--pdf-text-buffer))
    (with-current-buffer english-reading-mode--pdf-text-buffer
      (setq-local my/read-speech-language-override language)
      (my/read--configure-speech-language)))
  (when (derived-mode-p 'eww-mode)
    (add-hook 'eww-after-render-hook #'my/read--configure-speech-language nil t))
  (message "読み上げ言語: %s（SPC または s で再開）"
           (pcase language ('ja "日本語") ('en "英語") (_ "自動判定"))))

(defun my-read-use-japanese-speech ()
  "Read this my-read KINDLE/EWW/TEXT/EPUB buffer using Japanese macOS speech."
  (interactive)
  (my-read-set-speech-language 'ja))

(defun my-read-use-auto-speech ()
  "Restore automatic language detection for this reading buffer."
  (interactive)
  (my-read-set-speech-language nil))

(add-hook 'english-reading-mode-pdf-text-buffer-hook
          #'my/read--configure-speech-language)

(defun my/read--stop-language-speech (language)
  "Stop active or warming speech only when it belongs to LANGUAGE."
  (let ((active-buffers
         (list (plist-get english-reading-mode--continuous-state :buffer)
               (and (overlayp kokoro-reader--overlay)
                    (overlay-buffer kokoro-reader--overlay)))))
    (when (cl-some (lambda (buffer)
                     (and (buffer-live-p buffer)
                          (equal (buffer-local-value 'my/read-source-language buffer)
                                 language)))
                   active-buffers)
      (english-reading-mode-stop-continuous))))

(defun my-read-set-japanese-speech-backend (backend)
  "Select Japanese BACKEND (kokoro, irodori or macos) for this session.
Stop Japanese speech and update existing Japanese reading buffers.
Resume with SPC or s.  English speech settings remain unchanged."
  (interactive
   (list (intern (completing-read "日本語の音声エンジン: "
                                  '("kokoro" "irodori" "macos") nil t nil nil
                                  (symbol-name my/read-japanese-speech-backend)))))
  (unless (memq backend '(kokoro irodori macos))
    (user-error "音声エンジンは kokoro、irodori または macos を指定してください"))
  (my/read--stop-language-speech "ja")
  (setq my/read-japanese-speech-backend backend)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (equal my/read-source-language "ja")
        (my/read--configure-speech-language "ja"))))
  (message "日本語の音声エンジン: %s（SPC または s で再開）" backend))

(defun my-read-set-english-speech-backend (backend)
  "Select English BACKEND (kokoro or macos) for this session.
Stop English speech and update existing English reading buffers.
Resume with SPC or s.  Japanese speech settings remain unchanged."
  (interactive
   (list (intern (completing-read "英語の音声エンジン: "
                                  '("kokoro" "macos") nil t nil nil
                                  (symbol-name (default-value 'kokoro-reader-backend))))))
  (unless (memq backend '(kokoro macos))
    (user-error "音声エンジンは kokoro または macos を指定してください"))
  (my/read--stop-language-speech "en")
  (set-default 'kokoro-reader-backend backend)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (equal my/read-source-language "en")
        (my/read--configure-speech-language "en"))))
  (message "英語の音声エンジン: %s（SPC または s で再開）" backend))

(defun my/read--change-language-speed (language rate &optional kokoro)
  "Set LANGUAGE reading speed to positive integer RATE for this session.
Update open buffers and stop matching speech, including pending warmup.
With KOKORO non-nil, RATE is a multiplier between 0.5 and 2.0.
KOKORO may be the symbol irodori to select its independent setting."
  (if kokoro
      (unless (and (numberp rate) (<= 0.5 rate 2.0))
        (user-error "音声合成の速度は0.5〜2.0で入力してください"))
    (unless (and (integerp rate) (> rate 0))
      (user-error "速度は正の整数で入力してください")))
  (my/read--stop-language-speech language)
  (set-default (cond ((eq kokoro 'irodori) 'my/read-japanese-irodori-speed)
                     ((and kokoro (equal language "ja"))
                      'my/read-japanese-kokoro-speed)
                     (kokoro 'kokoro-reader-speed)
                     ((equal language "ja") 'my/read-japanese-macos-rate)
                     (t 'my/read-english-macos-rate))
               rate)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (equal my/read-source-language language)
        (if kokoro
            (setq-local kokoro-reader-speed rate)
          (setq-local kokoro-reader-macos-rate rate)))))
  (message "%sの読み上げ速度を %s%s に変更しました（次の再生から適用）"
           (if (equal language "ja") "日本語" "英語") rate
           (if kokoro "倍" "語/分")))

(defun my-read-change-japanese-speed (rate)
  "Set Japanese speed independently of English.
Kokoro and Irodori accept multipliers from 0.5 to 2.0; macOS accepts
positive integer words per minute. Stop Japanese playback; resume with s."
  ;; Use my-read-change-speed from M-x; retain Lisp-call compatibility.
;;   (interactive
;;    (list (pcase my/read-japanese-speech-backend
;;            ('irodori (read-number "日本語のIrodori速度（0.5〜2.0倍）: "
;;                                   my/read-japanese-irodori-speed))
;;            ('kokoro (read-number "日本語のKokoro速度（0.5〜2.0倍）: "
;;                                  my/read-japanese-kokoro-speed))
;;            (_ (read-number "日本語の読み上げ速度（毎分語数）: "
;;                            my/read-japanese-macos-rate)))))
  (my/read--change-language-speed
   "ja" rate (pcase my/read-japanese-speech-backend
               ('irodori 'irodori) ('kokoro t) (_ nil))))

(defun my-read-change-english-speed (rate)
  "Set English reading speed for the current session.
With the default Kokoro backend, RATE is a 0.5 to 2.0 multiplier and
updates `kokoro-reader-speed'.  With macOS, RATE is words per minute
and updates `my/read-english-macos-rate'.  Stop active English speech;
resume with SPC or s.  Japanese speed remains unchanged."
  ;; Use my-read-change-speed from M-x; retain Lisp-call compatibility.
;;   (interactive
;;    (list (if (eq (default-value 'kokoro-reader-backend) 'kokoro)
;;              (read-number "英語のKokoro速度（0.5〜2.0倍）: "
;;                           (default-value 'kokoro-reader-speed))
;;            (read-number "英語の読み上げ速度（毎分語数）: "
;;                         my/read-english-macos-rate))))
  (my/read--change-language-speed
   "en" rate (eq (default-value 'kokoro-reader-backend) 'kokoro)))

(defun my/read--speed-language ()
  "Return the current reading language for speed adjustment."
  (let ((language (or (and my/read-speech-language-override
                           (symbol-name my/read-speech-language-override))
                      my/read-source-language
                      (progn (my/read--configure-speech-language)
                             my/read-source-language))))
    (unless (member language '("en" "ja"))
      (user-error "読み上げ言語を英語または日本語に設定してください"))
    language))

(defun my-read-change-speed (rate)
  "Change the current reading language's speed to RATE.
Use words per minute for macOS, or a multiplier for Kokoro/Irodori."
  (interactive
   (list
    (read-number
     (let* ((language (my/read--speed-language))
            (backend (if (equal language "ja") my/read-japanese-speech-backend
                       (default-value 'kokoro-reader-backend))))
       (format "%sの読み上げ速度（%s）: "
               (if (equal language "ja") "日本語" "英語")
               (if (eq backend 'macos) "毎分語数" "0.5〜2.0倍")))
     (if (equal (my/read--speed-language) "ja")
         (pcase my/read-japanese-speech-backend
           ('irodori my/read-japanese-irodori-speed)
           ('kokoro my/read-japanese-kokoro-speed)
           (_ my/read-japanese-macos-rate))
       (if (eq (default-value 'kokoro-reader-backend) 'kokoro)
           (default-value 'kokoro-reader-speed)
         my/read-english-macos-rate)))))
  (if (equal (my/read--speed-language) "ja")
      (my-read-change-japanese-speed rate)
    (my-read-change-english-speed rate)))

(defun my-read-restart-japanese-speech ()
  "Restart the resident speech engine and discard stale continuous playback."
  (interactive)
  ;; Kill first: a wedged bridge may not consume even its stop command.
  ;; Detach its sentinel before creating the replacement process.
  (let ((process kokoro-reader--macos-bridge-process))
    (setq kokoro-reader--macos-bridge-process nil
          kokoro-reader--macos-bridge-ready-p nil
          kokoro-reader--macos-bridge-fragment "")
    (when (process-live-p process)
      (delete-process process)))
  (english-reading-mode-stop-continuous)
  (kokoro-reader--ensure-macos-bridge))

(provide 'my-read-speech-settings)
;;; my-read-speech-settings.el ends here
