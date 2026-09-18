;;; reader-translation-tests.el --- Translation regressions -*- lexical-binding: t; -*-

(require 'reader-test-helpers)

(ert-deftest my-read-japanese-source-translates-to-english ()
  (let ((frame (selected-frame))
        (google-translate-default-source-language "en")
        (google-translate-default-target-language "ja")
        captured)
    (set-frame-parameter frame 'my-reading-source-language "ja")
    (unwind-protect
        (cl-letf (((symbol-function 'google-translate--format-request-url)
                   (lambda (params)
                     (setq captured params)
                     "http://translate.test")))
          (should (equal (my/read-google-translate-url "日本語です。" frame)
                         "https://translate.test"))
          (should (equal google-translate-base-url
                         "http://translate.google.com/translate_a/single"))
          (should (equal (cdr (assoc "client" captured)) "dict-chrome-ex"))
          (should (equal (cdr (assoc "sl" captured)) "ja"))
          (should (equal (cdr (assoc "tl" captured)) "en")))
      (set-frame-parameter frame 'my-reading-source-language nil))))

(ert-deftest my-read-google-translation-uses-working-chrome-endpoint ()
  (let (captured-base)
    (cl-letf (((symbol-function 'google-translate--format-request-url)
               (lambda (_params)
                 (setq captured-base google-translate-base-url)
                 google-translate-base-url)))
      (should
       (equal (my/read-google-translate-url "This is a test.")
              "https://clients5.google.com/translate_a/single"))
      (should (equal captured-base
                     "https://clients5.google.com/translate_a/single")))))

(ert-deftest my-read-other-language-source-translates-to-japanese ()
  (let ((frame (selected-frame))
        (google-translate-default-source-language "en")
        (google-translate-default-target-language "ja")
        captured)
    (set-frame-parameter frame 'my-reading-source-language "es")
    (unwind-protect
        (cl-letf (((symbol-function 'google-translate--format-request-url)
                   (lambda (params)
                     (setq captured params)
                     "http://translate.test")))
          (my/read-google-translate-url "Esta es una frase." frame)
          (should (equal (cdr (assoc "sl" captured)) "es"))
          (should (equal (cdr (assoc "tl" captured)) "ja")))
      (set-frame-parameter frame 'my-reading-source-language nil))))

(ert-deftest my-read-translation-defaults-to-google-with-local-available ()
  (should (eq my/read-translation-backend 'google))
  (should (equal my/read-local-translation-model "translategemma:4b"))
  (should my/read-google-translation-fallback))

(ert-deftest my-read-local-translation-request-uses-language-and-model ()
  (let ((frame (selected-frame))
        (my/read-local-translation-model "translategemma:test")
        (google-translate-default-source-language "en")
        (google-translate-default-target-language "ja")
        (json-object-type 'alist)
        (json-array-type 'list)
        (json-false :json-false))
    (let* ((request
            (json-read-from-string
             (my/read--local-translation-request "A quiet morning." frame)))
           (messages (alist-get 'messages request))
           (prompt (alist-get 'content (car messages))))
      (should (equal (alist-get 'model request) "translategemma:test"))
      (should (eq (alist-get 'stream request) :json-false))
      (should (string-match-p "English (en) to Japanese (ja)" prompt))
      (should (string-suffix-p "A quiet morning." prompt)))))

(ert-deftest my-read-local-translation-response-extracts-content ()
  (should
   (equal (my/read--translation-response
           'local
           "{\"message\":{\"role\":\"assistant\",\"content\":\" 静かな朝。 \"}}")
          "静かな朝。")))

(ert-deftest my-read-translation-target-uses-one-sentence-and-exact-bounds ()
  (my-read-k-test--isolated
   (save-window-excursion
     (with-temp-buffer
       (insert "First sentence. Second sentence. Third sentence.")
       (set-window-buffer (selected-window) (current-buffer))
       (goto-char (point-min))
       (search-forward "Second")
       (set-window-point (selected-window) (point))
       (let ((my/read-kokoro-context nil))
         (pcase-let ((`(,mode ,text ,buffer ,beg ,end)
                      (my/read--translation-target
                       (selected-frame) (selected-window))))
           (should (eq mode 'sentence))
           (should (eq buffer (current-buffer)))
           (should (equal text "Second sentence."))
           (should (equal (buffer-substring-no-properties beg end)
                          "Second sentence."))))))))

(ert-deftest my-read-translation-target-reuses-spoken-sentence-bounds ()
  (my-read-k-test--isolated
   (save-window-excursion
     (with-temp-buffer
       (insert "Spoken sentence. Next sentence.")
       (set-window-buffer (selected-window) (current-buffer))
       (let* ((frame (selected-frame))
              (my/read-kokoro-context
               (list :frame frame :window (selected-window)
                     :buffer (current-buffer) :beg 1 :end 17
                     :text "Spoken sentence.")))
         (should
          (equal (my/read--translation-target frame (selected-window))
                 (list 'kokoro "Spoken sentence." (current-buffer) 1 17))))))))

(ert-deftest my-read-non-english-speech-does-not-trigger-translation ()
  (save-window-excursion
    (with-temp-buffer
      (let* ((frame (selected-frame))
             (center (selected-window))
             (context (list :frame frame :window center
                            :buffer (current-buffer) :beg 1 :end 4
                            :text "日本語。"))
             (my/read-kokoro-context nil)
             (my/read-speech-translation-suppressed-context nil)
             (my/read-translate-follow-mode t)
             (my/read-translate-timer nil)
             (my/read-translate-last-target nil)
             requested)
        (insert "日本語。")
        (setq-local my/read-source-language "ja")
        (set-window-buffer center (current-buffer))
        (set-frame-parameter frame 'my-reading-frame t)
        (set-frame-parameter frame 'my-reading-center-window center)
        (set-frame-parameter frame 'my-reading-center-windows (list center))
        (unwind-protect
            (cl-letf (((symbol-function 'my/read--start-translation-request)
                       (lambda (&rest _) (setq requested t))))
              (should-not (my/read--english-speech-context-p context))
              (my/read--english-speech-start context)
              (should-not my/read-kokoro-context)
              (should (eq my/read-speech-translation-suppressed-context
                          context))
              ;; Both ordinary page updates and post-command following must
              ;; remain unable to restart Google while speech is active.
              (my/read-translate-update-for-frame frame center)
              (my/read-translate-follow-post-command)
              (should-not requested)
              (should-not my/read-translate-timer)
              (my/read--english-speech-finish context)
              (should-not my/read-speech-translation-suppressed-context))
          (set-frame-parameter frame 'my-reading-frame nil)
          (set-frame-parameter frame 'my-reading-center-window nil)
          (set-frame-parameter frame 'my-reading-center-windows nil))))))

(ert-deftest my-read-english-speech-still-triggers-translation ()
  (with-temp-buffer
    (setq-local my/read-source-language "en")
    (should
     (my/read--english-speech-context-p
      (list :frame (selected-frame) :buffer (current-buffer)
            :text "English sentence.")))))

(ert-deftest my-read-translation-overlay-targets-center-window ()
  (my-read-k-test--isolated
   (save-window-excursion
     (with-temp-buffer
       (insert "First sentence. Second sentence.")
       (set-window-buffer (selected-window) (current-buffer))
       (let ((frame (selected-frame)))
         (set-frame-parameter frame 'my-reading-center-window
                              (selected-window))
         (unwind-protect
             (progn
               (my/read-translate-show-overlay frame (current-buffer) 1 16)
               (let ((overlay
                      (frame-parameter frame
                                       'my-reading-translate-overlay)))
                 (should (overlayp overlay))
                 (should (= (overlay-start overlay) 1))
                 (should (= (overlay-end overlay) 16))
                 (should (eq (overlay-get overlay 'face)
                             'my/read-translate-overlay-face))
                 (should (eq (overlay-get overlay 'window)
                             (selected-window)))))
           (my/read-translate-delete-overlay frame)
           (set-frame-parameter frame 'my-reading-center-window nil)))))))

(ert-deftest my-read-translation-overlay-blends-blue-with-theme-background ()
  (let ((my/read-translate-overlay-opacity 0.35))
    (cl-letf (((symbol-function 'face-background)
               (lambda (&rest _) "#000000")))
      (let ((blended
             (my/read--translate-overlay-background (selected-frame))))
        (should (string-match-p "\\`#[[:xdigit:]]\\{6\\}\\'" blended))
        (should-not (equal blended "#000000"))
        (should-not (equal (downcase blended) "#87cefa"))))))

(ert-deftest my-read-translation-overlay-preserves-source-font ()
  (let (attributes)
    (cl-letf (((symbol-function 'set-face-attribute)
               (lambda (_face _frame &rest args)
                 (setq attributes args)))
              ((symbol-function 'my/read--translate-overlay-background)
               (lambda (_frame) "#123456")))
      (my/read-refresh-translate-overlay-face (selected-frame)))
    (should (eq (plist-get attributes :inherit) nil))
    (dolist (attribute '(:foreground :family :foundry :width :height
                         :weight :slant))
      (should (eq (plist-get attributes attribute) 'unspecified)))
    (should (equal (plist-get attributes :background) "#123456"))))

(ert-deftest my-read-translation-language-stays-local-to-each-center-buffer ()
  (let ((frame (selected-frame))
        (kindle-buffer (generate-new-buffer " *my-read-language-kindle*"))
        (epub-buffer (generate-new-buffer " *my-read-language-epub*"))
        (google-translate-default-source-language "en")
        (google-translate-default-target-language "ja")
        captured)
    (unwind-protect
        (progn
          (with-current-buffer kindle-buffer
            (setq-local my/read-source-language "ja"))
          (set-frame-parameter frame 'my-reading-kindle-buffer kindle-buffer)
          (set-frame-parameter frame 'my-reading-source-language "ja")
          (cl-letf (((symbol-function 'google-translate--format-request-url)
                     (lambda (params)
                       (setq captured params)
                       "https://translate.test")))
            (my/read-google-translate-url "日本語です。" frame kindle-buffer)
            (should (equal (cdr (assoc "sl" captured)) "ja"))
            (my/read-google-translate-url "English sentence." frame epub-buffer)
            (should (equal (cdr (assoc "sl" captured)) "en"))))
      (set-frame-parameter frame 'my-reading-kindle-buffer nil)
      (set-frame-parameter frame 'my-reading-source-language nil)
      (kill-buffer kindle-buffer)
      (kill-buffer epub-buffer))))

(provide 'reader-translation-tests)
