;;; my-read-k-tests.el --- Tests for my-read-k -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

;; `my-read.el' references this optional package at runtime.  The tests stub
;; network-facing functions and need only the feature to load the local code.
(unless (featurep 'google-translate-core)
  (provide 'google-translate-core))

;; The real optional package declares these special variables.  Batch tests
;; provide only its feature, so declare the setting used by local URL logic.
(defvar google-translate-default-target-language "ja")
(defvar google-translate-default-source-language "en")
(defvar google-translate-base-url
  "http://translate.google.com/translate_a/single")
(defvar lookup-current-session nil)

(require 'my-read-k)
(require 'my-read-eww-math)

(defmacro my-read-k-test--isolated (&rest body)
  `(let ((my-read-k--process nil)
         (my-read-k--stopping-p nil)
         (my-read-k--process-output "")
         (my-read-k--callbacks (make-hash-table :test #'eql))
         (my-read-k--request-id 0)
         (my-read-k--generation 0)
         (my-read-k--busy-p nil)
         (my-read-k--prefetch-busy-p nil)
         (my-read-k--sync-busy-p nil)
         (my-read-k--pending-intent nil)
         (my-read-k--state 'detached)
         (my-read-k--detected-language nil)
         (my-read-k--frame nil)
         (my-read-k--buffer nil)
         (my-read-k--last-fingerprint nil)
         (my-read-k--page-number 1)
         (my-read-k--current-result nil)
         (my-read-k--prefetch-queue nil)
         (my-read-k--prefetch-source-fingerprint nil)
         (my-read-k--prefetch-attempted-fingerprint nil)
         (my-read-k--back-queue nil)
         (my-read-k--back-source-fingerprint nil))
     ,@body))

(ert-deftest my-read-org-noter-uses-obsidian-read-directory ()
  (should
   (equal my/read-org-noter-directory
          "/Users/seijiro/Library/Mobile Documents/iCloud~md~obsidian/Documents/seijiro/000_org/read")))

(ert-deftest my-read-positions-use-obsidian-read-directory ()
  (should
   (equal my/read-position-directory
          "/Users/seijiro/Library/Mobile Documents/iCloud~md~obsidian/Documents/seijiro/000_org/read"))
  (should (equal (file-name-nondirectory (my/read-position-file))
                 "read-positions.el")))

(ert-deftest my-read-position-persists-a-pdf-snapshot ()
  (let* ((directory (make-temp-file "my-read-position-" t))
         (my/read-position-directory directory)
         (source (make-temp-file "my-read-book-" nil ".pdf"))
         (buffer (generate-new-buffer " *my-read-position-pdf*")))
    (unwind-protect
        (with-current-buffer buffer
          (setq-local major-mode 'pdf-view-mode)
          (setq-local buffer-file-name source)
          (setq-local pdf-view-display-size 2.5)
          (cl-letf (((symbol-function 'pdf-view-current-page)
                     (lambda () 12)))
            (my/read-position-save-buffer buffer))
          (let* ((data (my/read-position--read-data))
                 (record (cdr (assoc-string
                               (file-truename source)
                               (plist-get data :entries) t))))
            (should (eq (plist-get record :type) 'pdf))
            (should (= (plist-get record :page) 12))
            (should (= (plist-get record :zoom) 2.5))
            (should (numberp (plist-get record :updated)))
            (should (= (logand (file-modes (my/read-position-file)) #o777)
                       #o600))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (when (file-exists-p source) (delete-file source))
      (delete-directory directory t))))

(ert-deftest my-read-position-restores-pdf-page-zoom-and-scroll ()
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (setq-local major-mode 'pdf-view-mode)
      (setq-local pdf-view-display-size 'fit-width)
      (let (page redisplayed vscroll)
        (cl-letf (((symbol-function 'pdf-view-goto-page)
                   (lambda (value) (setq page value)))
                  ((symbol-function 'pdf-view-redisplay)
                   (lambda (&optional force) (setq redisplayed force)))
                  ((symbol-function 'image-set-window-vscroll)
                   (lambda (value) (setq vscroll value))))
          (my/read-position--restore-pdf
           '(:type pdf :page 9 :zoom 3.0 :vscroll 420)
           (selected-window)))
        (should (= page 9))
        (should (= pdf-view-display-size 3.0))
        (should redisplayed)
        (should (= vscroll 420))))))

(ert-deftest my-read-position-restores-epub-document-and-point ()
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (setq-local major-mode 'nov-mode)
      (setq-local nov-documents [first second third])
      (setq-local nov-documents-index 0)
      (let (document)
        (cl-letf (((symbol-function 'nov-goto-document)
                   (lambda (index)
                     (setq document index
                           nov-documents-index index)
                     (erase-buffer)
                     (insert "0123456789abcdefghij"))))
          (my/read-position--restore-epub
           '(:type epub :document 2 :point 8 :window-start 3)
           (selected-window)))
        (should (= document 2))
        (should (= nov-documents-index 2))
        (should (= (window-point (selected-window)) 8))
        (should (= (window-start (selected-window)) 3))))))

(ert-deftest my-read-enables-continuous-pdf-scroll-in-center-window ()
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *my-read-pdf-roll*"))
          (frame (selected-frame))
          enabled-in
          size-indication-disabled-in)
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (setq-local major-mode 'pdf-view-mode)
            (setq-local pdf-misc-size-indication-minor-mode t)
            (let ((my/read-pdf-continuous-scroll t))
              (cl-letf (((symbol-function 'my/read-center-window)
                         (lambda (_frame) (selected-window)))
                        ((symbol-function 'pdf-view-roll-minor-mode)
                         (lambda (&optional _arg)
                           (setq enabled-in
                                 (list (current-buffer)
                                       (selected-window)))))
                        ((symbol-function
                          'pdf-misc-size-indication-minor-mode)
                         (lambda (&optional arg)
                           (setq size-indication-disabled-in
                                 (list (current-buffer)
                                       (selected-window)
                                       arg))
                           (setq pdf-misc-size-indication-minor-mode nil))))
                (my/read--enable-pdf-continuous-scroll buffer frame)))
            (should (equal enabled-in
                           (list buffer (selected-window))))
            (should (equal size-indication-disabled-in
                           (list buffer (selected-window) -1)))
            (should-not pdf-misc-size-indication-minor-mode))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest my-read-recognizes-pdf-roll-page-overlay ()
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (let* ((window (selected-window))
             (overlay (make-overlay (point-min) (point-max))))
        (overlay-put overlay 'window window)
        (setq-local pdf-view-roll-minor-mode t)
        (cl-letf (((symbol-function 'pdf-roll-page-overlay)
                   (lambda (&optional _page _window) overlay)))
          (should (my/read--pdf-view-window-overlay-valid-p window)))))))

(ert-deftest english-reading-mode-pdf-roll-scroll-cancels-continuation ()
  (should (memq 'pdf-roll-scroll-forward
                english-reading-mode--pdf-manual-interaction-commands))
  (should (memq 'pdf-roll-scroll-backward
                english-reading-mode--pdf-manual-interaction-commands)))

(ert-deftest my-read-position-does-not-overwrite-malformed-data ()
  (let* ((directory (make-temp-file "my-read-position-bad-" t))
         (my/read-position-directory directory)
         (file (my/read-position-file))
         (source (make-temp-file "my-read-book-" nil ".pdf"))
         (buffer (generate-new-buffer " *my-read-position-bad*")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "not valid position data"))
          (with-current-buffer buffer
            (setq-local major-mode 'pdf-view-mode)
            (setq-local buffer-file-name source)
            (cl-letf (((symbol-function 'pdf-view-current-page)
                       (lambda () 4)))
              (my/read-position-save-buffer buffer)))
          (with-temp-buffer
            (insert-file-contents file)
            (should (equal (buffer-string) "not valid position data"))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (when (file-exists-p source) (delete-file source))
      (delete-directory directory t))))

(ert-deftest my-read-japanese-epub-uses-macos-japanese-speech ()
  (with-temp-buffer
    (insert "あの日、わたしとあいつとの関係が壊れた。")
    (my/read--configure-speech-language)
    (should (equal my/read-source-language "ja"))
    (should (eq kokoro-reader-backend 'macos))
    (should (equal kokoro-reader-macos-voice
                   my/read-japanese-macos-voice))
    (should (= kokoro-reader-macos-rate 540))
    (should (= kokoro-reader-macos-rate
               (* 3 (default-value 'kokoro-reader-macos-rate))))))

(ert-deftest my-read-japanese-pdf-helper-auto-selects-japanese-speech ()
  (with-temp-buffer
    (insert "応 用 情 報 技 術 者。")
    (english-reading-mode--normalize-pdf-japanese-spacing)
    (run-hooks 'english-reading-mode-pdf-text-buffer-hook)
    (should (equal (buffer-string) "応用情報技術者。"))
    (should (equal my/read-source-language "ja"))
    (should (eq kokoro-reader-backend 'macos))
    (should (equal kokoro-reader-macos-voice "Kyoko"))))

(ert-deftest my-read-english-epub-clears-japanese-speech-overrides ()
  (with-temp-buffer
    (setq-local kokoro-reader-backend 'macos)
    (setq-local kokoro-reader-macos-voice "Kyoko (Enhanced)")
    (setq-local kokoro-reader-macos-rate 540)
    (insert "This is an English sentence.")
    (my/read--configure-speech-language)
    (should (equal my/read-source-language "en"))
    (should-not (local-variable-p 'kokoro-reader-backend))
    (should-not (local-variable-p 'kokoro-reader-macos-voice))
    (should-not (local-variable-p 'kokoro-reader-macos-rate))))

(ert-deftest my-read-k-uses-reported-language-and-defaults-to-english ()
  (should (equal (my-read-k--language-from-result '((language . "en-US")))
                 "en"))
  (should (equal (my-read-k--language-from-result '((text . "English.")))
                 "en")))

(ert-deftest my-read-k-japanese-sentence-boundaries-work-one-at-a-time ()
  (with-temp-buffer
    (insert "これは最初の文です。これは二番目の文です！最後です？")
    (goto-char (point-min))
    (setq-local sentence-end-double-space nil)
    (should (equal (buffer-substring-no-properties
                    (car (bounds-of-thing-at-point 'sentence))
                    (cdr (bounds-of-thing-at-point 'sentence)))
                   "これは最初の文です。"))))

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

(ert-deftest my-read-k-process-filter-assembles-partial-and-multiple-lines ()
  (my-read-k-test--isolated
   (let ((seen nil))
     (puthash 1 (lambda (response)
                  ;; Deliberately clobber match data inside the callback.
                  (string-match "x" "x")
                  (push (my-read-k--alist-get 'id response) seen))
              my-read-k--callbacks)
     (puthash 2 (lambda (response) (push (my-read-k--alist-get 'id response) seen))
              my-read-k--callbacks)
     (my-read-k--process-filter nil "{\"id\":1,\"ok\":true")
     (should-not seen)
     (my-read-k--process-filter nil "}\n{\"id\":2,\"ok\":true}\n")
     (should (equal seen '(2 1)))
     (should (string-empty-p my-read-k--process-output)))))

(ert-deftest my-read-k-stale-generation-does-not-replace-buffer ()
  (my-read-k-test--isolated
   (with-temp-buffer
     (insert "newer page")
     (setq my-read-k--buffer (current-buffer)
           my-read-k--generation 5
           my-read-k--busy-p t)
     (my-read-k--finish-page-request
      '((ok . t) (result . ((text . "old page")))) 4 'next nil)
     (should (equal (buffer-string) "newer page"))
     (should my-read-k--busy-p))))

(ert-deftest my-read-k-current-error-clears-busy-and-enters-error-state ()
  (my-read-k-test--isolated
   (setq my-read-k--generation 2 my-read-k--busy-p t my-read-k--state 'busy)
   (my-read-k--finish-page-request
    '((ok . nil) (error . ((code . "NO_TEXT") (message . "No text"))))
    2 'refresh nil)
   (should-not my-read-k--busy-p)
   (should (eq my-read-k--state 'error))
   (should (equal (plist-get my-read-k--last-error :code) "NO_TEXT"))))

(ert-deftest my-read-k-continuous-page-error-disarms-continuation ()
  (my-read-k-test--isolated
   (let ((stopped nil))
     (setq my-read-k--generation 2 my-read-k--busy-p t my-read-k--state 'busy)
     (cl-letf (((symbol-function 'english-reading-mode-stop-continuous)
                (lambda (&optional quiet) (setq stopped quiet))))
       (my-read-k--finish-page-request
        '((ok . nil) (error . ((code . "NO_TEXT") (message . "No text"))))
        2 'next 'continuous))
     (should stopped)
     (should-not my-read-k--busy-p)
     (should (eq my-read-k--state 'error)))))

(ert-deftest my-read-k-page-replacement-keeps-normal-read-only-text ()
  (my-read-k-test--isolated
   (with-temp-buffer
     (setq my-read-k--buffer (current-buffer))
     (my-read-k--apply-page
      '((text . "First sentence.\n\nSecond sentence.")
        (fingerprint . "abc") (ocrMs . 12) (lines . nil))
      'next nil)
     (should buffer-read-only)
     (should (equal (buffer-string) "First sentence.\nSecond sentence.\n"))
     (should (equal (thing-at-point 'word t) "First"))
     (should (equal my-read-k--last-fingerprint "abc"))
     (should (equal (my-read-k--alist-get 'text my-read-k--current-result)
                    "First sentence.\n\nSecond sentence.")))))

(ert-deftest my-read-k-formats-accessibility-text-one-sentence-per-line ()
  (should
   (equal
    (my-read-k--one-sentence-per-line
     "Prologue \u201cReady, Sousuke? We need paper.\u201d Chidori spoke to Mr. Sayama. He nodded.")
    (string-join '("Prologue"
                   "\u201cReady, Sousuke?"
                   "We need paper.\u201d"
                   "Chidori spoke to Mr. Sayama."
                   "He nodded.")
                 "\n"))))

(ert-deftest my-read-k-mode-keeps-kindle-buffer-read-only ()
  (my-read-k-test--isolated
   (with-temp-buffer
     (my-read-k-mode 1)
     (should buffer-read-only)
     (my-read-k-mode -1)
     (should-not buffer-read-only))))

(ert-deftest english-reading-mode-j-speaks-current-and-n-moves-without-speaking ()
  (my-read-k-test--isolated
   (with-temp-buffer
     (insert "First sentence. Second sentence. Third sentence.")
     (let ((my-read-k-mode t)
           spoken)
       (cl-letf (((symbol-function 'kokoro-reader--speak-bounds)
                  (lambda (beg end)
                    (push (buffer-substring-no-properties beg end) spoken))))
         (english-reading-mode 1)
         (goto-char (point-min))
         (english-reading-mode-speak-current-sentence)
         (should (equal (car spoken) "First sentence."))
         (should (= (point) (point-min)))
         (english-reading-mode-next-sentence)
         (should (= (length spoken) 1))
         (should (looking-at-p "Second sentence\\."))
         (english-reading-mode-previous-sentence)
         (should (= (length spoken) 1))
         (should (equal (car spoken) "First sentence."))
         (should (= (point) (point-min)))
         (english-reading-mode -1))))))

(ert-deftest english-reading-mode-k-moves-to-previous-sentence-without-speaking ()
  (my-read-k-test--isolated
   (with-temp-buffer
     (insert "First sentence. Second sentence.")
     (let ((my-read-k-mode t)
           (spoken 0))
       (cl-letf (((symbol-function 'kokoro-reader--speak-bounds)
                  (lambda (&rest _) (cl-incf spoken))))
         (english-reading-mode 1)
         (goto-char (point-min))
         (search-forward "Second")
         (should (eq (lookup-key english-reading-mode-map (kbd "k"))
                     #'english-reading-mode-previous-sentence))
         (should (eq (key-binding (kbd "k")) #'my-read-k-backward))
         (call-interactively (key-binding (kbd "k")))
         (should (looking-at-p "First sentence\\."))
         (should (= spoken 0))
         (english-reading-mode -1))))))

(ert-deftest english-reading-mode-restores-buffer-sentence-spacing-setting ()
  (my-read-k-test--isolated
   (with-temp-buffer
     (setq-local sentence-end-double-space t)
     (let ((my-read-k-mode t))
       (english-reading-mode 1)
       (should-not sentence-end-double-space)
       (english-reading-mode -1)
       (should sentence-end-double-space)
       (should (local-variable-p 'sentence-end-double-space))))))

(ert-deftest english-reading-mode-s-binds-continuous-sentence-reading ()
  (should (eq (lookup-key english-reading-mode-map (kbd "s"))
              #'english-reading-mode-continuous-read)))

(ert-deftest english-reading-mode-continuous-default-speaks-next-sentence ()
  (with-temp-buffer
    (insert "First sentence. Second sentence.")
    (goto-char (point-min))
    (setq-local sentence-end-double-space nil)
    (let (spoken)
      (cl-letf (((symbol-function 'english-reading-mode-speak-current-sentence)
                 (lambda () (setq spoken (thing-at-point 'sentence t)))))
        (english-reading-mode--continuous-default-next)
        (should (string-prefix-p "Second sentence." spoken))))))

(ert-deftest english-reading-mode-pdf-finish-schedules-continuous-next ()
  (let ((pdf-buffer (generate-new-buffer " *continuous-pdf*"))
        (text-buffer (generate-new-buffer " *continuous-pdf-text*"))
        scheduled
        scheduled-delay)
    (unwind-protect
        (let ((english-reading-mode--continuous-state
               (list :buffer pdf-buffer
                     :window (selected-window)
                     :frame (selected-frame)))
              (english-reading-mode--continuous-timer nil))
          (with-current-buffer pdf-buffer
            (setq-local major-mode 'doc-view-mode)
            (setq-local buffer-file-name "/tmp/continuous.pdf")
            (setq-local english-reading-mode--pdf-text-buffer text-buffer))
          (with-current-buffer text-buffer
            (setq-local kokoro-reader-backend 'macos))
          (cl-letf (((symbol-function 'run-at-time)
                     (lambda (seconds _repeat function &rest _args)
                       (setq scheduled function
                             scheduled-delay seconds)
                       'fake-timer)))
            (english-reading-mode--continuous-speech-finished
             (list :buffer text-buffer)))
          (should (eq scheduled #'english-reading-mode--continuous-next))
          (should (zerop scheduled-delay)))
      (kill-buffer pdf-buffer)
      (kill-buffer text-buffer))))

(ert-deftest english-reading-mode-kokoro-continuous-speech-keeps-zero-gap ()
  (with-temp-buffer
    (let ((source-buffer (current-buffer))
          (english-reading-mode--continuous-state nil)
          (english-reading-mode--continuous-timer nil)
          scheduled-delay)
      (setq-local kokoro-reader-backend 'kokoro)
      (setq english-reading-mode--continuous-state
            (list :buffer source-buffer
                  :window (selected-window)
                  :frame (selected-frame)))
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (seconds _repeat _function &rest _args)
                   (setq scheduled-delay seconds)
                   'fake-timer)))
        (english-reading-mode--continuous-speech-finished
         (list :buffer source-buffer)))
      (should (zerop scheduled-delay)))))

(ert-deftest english-reading-mode-prefetches-two-macos-chunks ()
  (with-temp-buffer
    (insert "一番です。二番です。三番です。四番です。五番です。六番です。")
    (setq-local sentence-end-double-space nil)
    (setq-local kokoro-reader-backend 'macos)
    (let ((source-buffer (current-buffer))
          (english-reading-mode--continuous-state nil)
          (english-reading-mode-macos-continuous-sentence-count 2)
          (english-reading-mode-macos-prefetch-chunk-count 3)
          queue-limit
          prefetched)
      (setq english-reading-mode--continuous-state
            (list :buffer source-buffer
                  :window (selected-window)
                  :frame (selected-frame)))
      (cl-letf (((symbol-function 'kokoro-reader-prefetch-macos-texts)
                 (lambda (texts)
                   (setq prefetched texts
                         queue-limit kokoro-reader-macos-prefetch-count))))
        (english-reading-mode--prefetch-next-macos-sentence
         (list :buffer source-buffer
               :beg (point-min)
               :end (save-excursion
                      (goto-char (point-min))
                      (forward-sentence 2)
                      (point))))
        (should (equal prefetched
                       '("三番です。四番です。"
                         "五番です。六番です。")))
        (should (= queue-limit 3))))))

(ert-deftest english-reading-mode-macos-prefetch-monitor-refills-periodically ()
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (setq-local kokoro-reader-backend 'macos)
      (let* ((source-buffer (current-buffer))
             (context (list :buffer source-buffer :beg 1 :end 1))
             (english-reading-mode--continuous-state
              (list :buffer source-buffer
                    :window (selected-window)
                    :frame (selected-frame)))
             (english-reading-mode--active-speech context)
             (english-reading-mode--macos-prefetch-monitor-timer nil)
             scheduled-delay scheduled-repeat scheduled-function refreshed)
        (cl-letf (((symbol-function 'run-with-timer)
                   (lambda (delay repeat function &rest _args)
                     (setq scheduled-delay delay
                           scheduled-repeat repeat
                           scheduled-function function)
                     'prefetch-monitor))
                  ((symbol-function
                    'english-reading-mode--prefetch-next-macos-sentence)
                   (lambda (active-context)
                     (setq refreshed active-context))))
          (english-reading-mode--start-macos-prefetch-monitor)
          (should (= scheduled-delay 0.5))
          (should (= scheduled-repeat 0.5))
          (funcall scheduled-function)
          (should (eq refreshed context)))))))

(ert-deftest english-reading-mode-continuous-waits-for-full-macos-warmup ()
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (insert "一番です。二番です。三番です。")
      (setq-local sentence-end-double-space nil)
      (setq-local kokoro-reader-backend 'macos)
      (let* ((source-buffer (current-buffer))
             (window (selected-window))
             (frame (selected-frame))
             (spec (list :buffer source-buffer :beg 1 :end 6
                         :text "一番です。"))
             (english-reading-mode--continuous-state
              (list :buffer source-buffer :window window :frame frame
                    :warmup-spec spec
                    :warmup-texts '("一番です。" "二番です。")))
             (english-reading-mode--continuous-warmup-timer nil)
             (ready nil)
             scheduled spoken monitor-started)
        (cl-letf (((symbol-function 'kokoro-reader-prefetch-macos-texts)
                   #'ignore)
                  ((symbol-function 'kokoro-reader-macos-prefetch-ready-p)
                   (lambda (_text) ready))
                  ((symbol-function 'run-at-time)
                   (lambda (delay _repeat function &rest _args)
                     (setq scheduled (list delay function))
                     'warmup-timer))
                  ((symbol-function 'kokoro-reader--speak-bounds)
                   (lambda (beg end) (setq spoken (cons beg end))))
                  ((symbol-function
                    'english-reading-mode--start-macos-prefetch-monitor)
                   (lambda () (setq monitor-started t))))
          (english-reading-mode--continuous-warmup-check)
          (should-not spoken)
          (should (= (car scheduled) 0.05))
          (setq ready t)
          (funcall (cadr scheduled))
          (should (equal spoken '(1 . 6)))
          (should monitor-started)
          (should-not (plist-get english-reading-mode--continuous-state
                                 :warmup-texts)))))))

(ert-deftest english-reading-mode-quiet-stop-clears-prefetch-monitor-and-queue ()
  (let ((english-reading-mode--continuous-state '(active))
        (english-reading-mode--continuous-timer nil)
        (english-reading-mode--macos-prefetch-monitor-timer 'monitor)
        cancelled cleared)
    (cl-letf (((symbol-function 'timerp)
               (lambda (object) (eq object 'monitor)))
              ((symbol-function 'cancel-timer)
               (lambda (timer) (setq cancelled timer)))
              ((symbol-function 'kokoro-reader--clear-macos-prefetch)
               (lambda () (setq cleared t))))
      (english-reading-mode-stop-continuous t))
    (should (eq cancelled 'monitor))
    (should cleared)
    (should-not english-reading-mode--macos-prefetch-monitor-timer)))

(ert-deftest kokoro-reader-prefetch-replaces-invalid-ready-entry ()
  (let* ((bad-file (make-temp-file "kokoro-prefetch-invalid-"))
         (kokoro-reader-backend 'macos)
         (kokoro-reader-macos-prefetch-enabled t)
         (old-entry
          (list :key (kokoro-reader--macos-key "次です。")
                :process nil :file bad-file :ready t))
         (kokoro-reader--macos-prefetch-queue (list old-entry))
         started discarded)
    (unwind-protect
        (cl-letf (((symbol-function 'kokoro-reader--start-macos-prefetch)
                   (lambda (text)
                     (setq started text)
                     (list :key (kokoro-reader--macos-key text)
                           :process 'new :file "/tmp/new.aiff" :ready nil)))
                  ((symbol-function 'kokoro-reader--discard-macos-prefetch-entry)
                   (lambda (entry) (setq discarded entry))))
          (kokoro-reader-prefetch-macos-texts '("次です。"))
          (should (equal started "次です。"))
          (should (eq discarded old-entry))
          (should (eq (plist-get (car kokoro-reader--macos-prefetch-queue)
                                 :process)
                      'new)))
      (when (file-exists-p bad-file) (delete-file bad-file)))))

(ert-deftest kokoro-reader-staggers-macos-prefetch-launches ()
  (let ((kokoro-reader-backend 'macos)
        (kokoro-reader-macos-prefetch-enabled t)
        (kokoro-reader-macos-prefetch-count 2)
        (kokoro-reader-macos-prefetch-launch-interval 0.2)
        (kokoro-reader--macos-prefetch-queue nil)
        (kokoro-reader--macos-prefetch-launch-timer nil)
        scheduled launched (timer-sequence 0))
    (cl-letf (((symbol-function 'timerp)
               (lambda (object) (and (consp object)
                                     (eq (car object) 'fake-timer))))
              ((symbol-function 'run-at-time)
               (lambda (delay _repeat function &rest _args)
                 (let ((timer (list 'fake-timer (cl-incf timer-sequence))))
                   (setq scheduled
                         (append scheduled (list (list delay function timer))))
                   timer)))
              ((symbol-function 'cancel-timer) #'ignore)
              ((symbol-function 'kokoro-reader--launch-macos-prefetch)
               (lambda (entry)
                 (setq launched
                       (append launched
                               (list (car (plist-get entry :key)))))
                 entry)))
      (unwind-protect
          (progn
            (kokoro-reader-prefetch-macos-texts '("一番。" "二番。"))
            (should-not launched)
            (should (plist-member (car kokoro-reader--macos-prefetch-queue)
                                  :launched-at))
            (should (= (caar scheduled) 0.2))
            (funcall (cadar scheduled))
            (should (equal launched '("一番。")))
            (should (= (car (nth 1 scheduled)) 0.2))
            (funcall (cadr (nth 1 scheduled)))
            (should (equal launched '("一番。" "二番。")))
            (should (= (length scheduled) 2)))
        (kokoro-reader--clear-macos-prefetch)))))

(ert-deftest kokoro-reader-staggered-launch-preserves-buffer-local-rate ()
  (let (entry command)
    (with-temp-buffer
      (setq-local kokoro-reader-macos-program "/usr/bin/say")
      (setq-local kokoro-reader-macos-voice "Kyoko")
      (setq-local kokoro-reader-macos-rate 600)
      (setq entry (kokoro-reader--start-macos-prefetch "速度確認。")))
    (unwind-protect
        (let ((kokoro-reader-macos-rate 180)
              (kokoro-reader-macos-voice nil))
          (cl-letf (((symbol-function 'make-process)
                     (lambda (&rest arguments)
                       (setq command (plist-get arguments :command))
                       'fake-process))
                    ((symbol-function 'process-send-string) #'ignore)
                    ((symbol-function 'process-send-eof) #'ignore))
            (kokoro-reader--launch-macos-prefetch entry))
          (should (equal (seq-take command 4)
                         '("/usr/bin/say" "-r" "600" "-o")))
          (should (equal (seq-drop command 5) '("-v" "Kyoko")))
          ;; The temporary output path between -o and -v is variable.
          (should (stringp (nth 4 command))))
      (kokoro-reader--discard-macos-prefetch-entry entry))))

(ert-deftest english-reading-mode-macos-continuous-speaks-two-sentence-chunks ()
  (with-temp-buffer
    (insert "一番目です。二番目です。三番目です。四番目です。五番目です。六番目です。七番目です。")
    (goto-char (point-min))
    (setq-local sentence-end-double-space nil)
    (setq-local kokoro-reader-backend 'macos)
    (let ((english-reading-mode--continuous-state
           (list :buffer (current-buffer)))
          spoken-bounds)
      (cl-letf (((symbol-function 'kokoro-reader--speak-bounds)
                 (lambda (beg end) (setq spoken-bounds (cons beg end)))))
        (english-reading-mode-speak-current-sentence))
      (should (equal (buffer-substring-no-properties
                      (car spoken-bounds) (cdr spoken-bounds))
                     "一番目です。二番目です。")))))

(ert-deftest kokoro-reader-promotes-running-macos-prefetch ()
  (let ((kokoro-reader--macos-prefetch-queue
         '((:key matching-key :process prefetch-process
            :file "/tmp/prefetch.aiff" :ready nil))))
    (cl-letf (((symbol-function 'process-live-p) (lambda (_process) t)))
      (should (equal (kokoro-reader--take-running-macos-prefetch 'matching-key)
                     '(prefetch-process . "/tmp/prefetch.aiff"))))
    (should-not kokoro-reader--macos-prefetch-queue)))

(ert-deftest english-reading-mode-continuous-resumes-after-completed-chunk ()
  (with-temp-buffer
    (insert "一番目です。二番目です。三番目です。四番目です。")
    (goto-char (point-min))
    (setq-local sentence-end-double-space nil)
    (let ((source-buffer (current-buffer))
          (english-reading-mode--continuous-state nil)
          spoken)
      (setq english-reading-mode--continuous-state
            (list :buffer source-buffer
                  :next-speech-buffer source-buffer
                  :next-speech-position
                  (save-excursion
                    (forward-sentence 3)
                    (point))))
      (cl-letf (((symbol-function 'english-reading-mode-speak-current-sentence)
                 (lambda () (setq spoken (thing-at-point 'sentence t)))))
        (should (english-reading-mode--continuous-resume-next-chunk)))
      (should (string-prefix-p "四番目です。" spoken)))))

(ert-deftest kokoro-reader-takes-only-matching-ready-macos-prefetch ()
  (let* ((file (make-temp-file "kokoro-prefetch-test-"))
         (key '("次の文です。" "/usr/bin/say" "Kyoko" 540))
         (kokoro-reader--macos-prefetch-queue
          (list (list :key key :process nil :file file :ready t))))
    (unwind-protect
        (progn
          (with-temp-file file (insert (make-string 5000 ?a)))
          (should-not (kokoro-reader--take-macos-prefetch '(different)))
          (should (equal (kokoro-reader--take-macos-prefetch key) file))
          (should-not kokoro-reader--macos-prefetch-queue))
      (when (file-exists-p file) (delete-file file)))))

(ert-deftest english-reading-mode-prefetch-crosses-pdf-page-boundary ()
  (let ((pdf-buffer (generate-new-buffer " *prefetch-pdf*"))
        (text-buffer (generate-new-buffer " *prefetch-pdf-text*")))
    (unwind-protect
        (progn
          (with-current-buffer text-buffer
            (insert "Page one final.\f2 Page two first. Page two second.")
            (setq-local sentence-end-double-space nil)
            (setq-local kokoro-reader-backend 'macos))
          (with-current-buffer pdf-buffer
            (setq-local major-mode 'doc-view-mode)
            (setq-local buffer-file-name "/tmp/prefetch.pdf")
            (setq-local english-reading-mode--pdf-text-buffer text-buffer)
            (setq-local english-reading-mode--pdf-page-ranges
                        (with-current-buffer text-buffer
                          (english-reading-mode--pdf-page-ranges))))
          (let ((english-reading-mode--continuous-state
                 (list :buffer pdf-buffer))
                (english-reading-mode-macos-continuous-sentence-count 1))
            (should
             (equal
              (english-reading-mode--next-speech-texts
               (list :buffer text-buffer
                     :end (with-current-buffer text-buffer
                            (cdr (aref
                                  (with-current-buffer pdf-buffer
                                    english-reading-mode--pdf-page-ranges)
                                  0))))
               2)
              '("Page two first." "Page two second.")))))
      (kill-buffer pdf-buffer)
      (kill-buffer text-buffer))))

(ert-deftest english-reading-mode-pdf-prefetch-skips-label-before-chunking ()
  (let ((pdf-buffer (generate-new-buffer " *prefetch-pdf-table*"))
        (text-buffer (generate-new-buffer " *prefetch-pdf-table-text*")))
    (unwind-protect
        (progn
          (with-current-buffer text-buffer
            (insert "前文です。\n\n○\n\n共有ロック\n\n×\n\n○\n\nロックなし。")
            (setq-local sentence-end-double-space nil)
            (setq-local kokoro-reader-backend 'macos))
          (with-current-buffer pdf-buffer
            (setq-local major-mode 'doc-view-mode)
            (setq-local buffer-file-name "/tmp/prefetch-table.pdf")
            (setq-local english-reading-mode--pdf-text-buffer text-buffer)
            (setq-local english-reading-mode--pdf-page-ranges
                        (with-current-buffer text-buffer
                          (english-reading-mode--pdf-page-ranges))))
          (let ((english-reading-mode--continuous-state
                 (list :buffer pdf-buffer))
                (english-reading-mode-macos-continuous-sentence-count 2))
            (should
             (equal
              (english-reading-mode--speech-texts-after-position
               text-buffer
               (with-current-buffer text-buffer
                 (goto-char (point-min))
                 (forward-sentence 1)
                 (point))
               2)
              '("共有ロック ×" "ロックなし。")))))
      (kill-buffer pdf-buffer)
      (kill-buffer text-buffer))))

(ert-deftest my-read-k-speech-prefetch-uses-cached-future-pages ()
  (my-read-k-test--isolated
   (let ((my-read-k--last-fingerprint "current")
         (my-read-k--prefetch-source-fingerprint "current")
         (my-read-k--prefetch-queue
          '(((fingerprint . "next")
             (text . "Next page one. Next page two."))
            ((fingerprint . "later")
             (text . "Later page one. Later page two."))))
         (english-reading-mode-macos-continuous-sentence-count 2))
     (should
      (equal (my-read-k--continuous-prefetch-page-texts nil 2)
             '("Next page one. Next page two."
               "Later page one. Later page two."))))))

(ert-deftest my-read-k-continuous-reading-turns-page-with-continuation-intent ()
  (my-read-k-test--isolated
   (with-temp-buffer
     (insert "Last sentence.")
     (goto-char (point-min))
     (setq-local sentence-end-double-space nil)
     (let (requested)
       (cl-letf (((symbol-function 'my-read-k--request-page)
                  (lambda (direction &optional speak)
                    (setq requested (cons direction speak)))))
         (my-read-k-continuous-next)
         (should (equal requested '(next . continuous))))))))

(ert-deftest my-read-org-noter-kindle-location-prefers-accessibility-position ()
  (let ((my-read-k--current-result
         '((start . 8783) (end . 9885) (fingerprint . "kindle-position")))
        (my-read-k--page-number 7))
    (with-temp-buffer
      (insert "Sentence at a known location.")
      (goto-char 10)
      (should (equal (my/read-org-noter--kindle-approx-location
                      'my-read-k-document-mode)
                     '(8783 . 10))))))

(ert-deftest my-read-org-noter-stale-kindle-sync-does-not-restore-hidden-tab ()
  (save-window-excursion
    (let* ((frame (selected-frame))
           (kindle (generate-new-buffer " *my-read-noter-kindle*"))
           (eww (generate-new-buffer " *my-read-noter-eww*"))
           (window (selected-window))
           (sync-called nil))
      (unwind-protect
          (progn
            (set-frame-parameter frame 'my-reading-frame t)
            (set-frame-parameter frame 'my-reading-center-window window)
            (set-frame-parameter frame 'my-reading-center-windows (list window))
            (with-current-buffer kindle
              (setq-local my/read-center-tab-frame frame)
              (setq-local org-noter--session t))
            (set-window-buffer window eww)
            (cl-letf (((symbol-function 'org-noter--doc-location-change-handler)
                       (lambda () (setq sync-called t))))
              (my/read-org-noter--sync-now kindle))
            (should-not sync-called)
            (should (eq (window-buffer window) eww)))
        (set-frame-parameter frame 'my-reading-frame nil)
        (set-frame-parameter frame 'my-reading-center-window nil)
        (set-frame-parameter frame 'my-reading-center-windows nil)
        (kill-buffer kindle)
        (kill-buffer eww)))))

(ert-deftest my-read-org-noter-eww-url-is-document-identity ()
  (with-temp-buffer
    (eww-mode)
    (setq-local eww-data
                '(:url "https://example.test/paper?id=7#results"
                  :title "Example Paper"))
    (should (my/read-org-noter--supported-buffer-p (current-buffer)))
    (should (equal (my/read-org-noter--eww-url)
                   "https://example.test/paper?id=7"))
    (let ((property (my/read-org-noter--eww-property)))
      (should (equal property "[[eww:https://example.test/paper?id=7]]"))
      (should (equal (my/read-org-noter--eww-url-from-property property)
                     "https://example.test/paper?id=7")))))

(ert-deftest my-read-org-noter-eww-location-uses-heading-and-body-offset ()
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (eww-mode)
      (let ((inhibit-read-only t)
            first second alpha beta)
        (insert "Introduction\n")
        (setq first (point))
        (insert "First section\n")
        (setq alpha (point))
        (insert "Alpha body text.\n")
        (setq second (point))
        (insert "Second section\n")
        (setq beta (point))
        (insert "Beta body text.\n")
        (put-text-property first (1- alpha) 'outline-level 1)
        (put-text-property second (1- beta) 'outline-level 2)
        (should (equal (my/read-org-noter--eww-heading-positions)
                       (list first second)))
        (should (equal (my/read-org-noter--eww-location-at (+ alpha 6))
                       (cons 1 (- (+ alpha 6) first))))
        (should (equal (my/read-org-noter--eww-location-at (+ beta 5))
                       (cons 2 (- (+ beta 5) second))))
        (should (equal (my/read-org-noter--eww-heading-at-location '(2 . 3))
                       "Second section"))
        (my/read-org-noter--eww-goto 'eww-mode
                                     (cons 1 (- alpha first)))
        (should (= (point) alpha))
        (should (looking-at-p "Alpha body"))))))

(ert-deftest my-read-org-noter-eww-opener-reuses-matching-live-buffer ()
  (let ((buffer (generate-new-buffer " *my-read-noter-eww-open*")))
    (unwind-protect
        (with-current-buffer buffer
          (eww-mode)
          (setq-local eww-data
                      '(:url "https://example.test/article#details"))
          (should (eq (my/read-org-noter--eww-open-document
                       "[[eww:https://example.test/article]]")
                      buffer)))
      (kill-buffer buffer))))

(ert-deftest my-read-org-noter-eww-url-change-rejects-old-session ()
  (let ((document (generate-new-buffer " *my-read-noter-eww-document*"))
        (notes (generate-new-buffer " *my-read-noter-eww-notes*")))
    (unwind-protect
        (let ((session
               (make-org-noter--session
                :property-text "[[eww:https://example.test/old]]"
                :doc-mode "[[eww:https://example.test/old]]"
                :doc-buffer document :notes-buffer notes)))
          (with-current-buffer document
            (eww-mode)
            (setq-local eww-data '(:url "https://example.test/new"))
            (setq-local org-noter--session session))
          (with-current-buffer notes
            (org-mode)
            (setq-local org-noter--session session))
          (setq org-noter--sessions (cons session org-noter--sessions))
          (should-not
           (my/read-org-noter--session-matches-source-p
            session document (selected-frame)))
          (my/read-org-noter--detach-reused-eww-session session)
          (should (buffer-live-p document))
          (should-not (memq session org-noter--sessions))
          (should-not (buffer-local-value 'org-noter--session document))
          (should-not (buffer-local-value 'org-noter--session notes)))
      (setq org-noter--sessions
            (cl-remove-if
             (lambda (session)
               (or (eq (org-noter--session-doc-buffer session) document)
                   (eq (org-noter--session-notes-buffer session) notes)))
             org-noter--sessions))
      (kill-buffer document)
      (kill-buffer notes))))

(ert-deftest my-read-eww-history-records-title-and-deduplicates-url ()
  (save-window-excursion
    (let* ((frame (selected-frame))
           (window (selected-window))
           (buffer (generate-new-buffer " *my-read-eww-history-record*"))
           (file (make-temp-file "my-read-eww-history-"))
           (my/read-eww-history-file file)
           (my/read-eww-history-limit 10))
      (unwind-protect
          (progn
            (delete-file file)
            (set-frame-parameter frame 'my-reading-frame t)
            (set-frame-parameter frame 'my-reading-center-window window)
            (set-frame-parameter frame 'my-reading-eww-buffer buffer)
            (set-window-buffer window buffer)
            (with-current-buffer buffer
              (eww-mode)
              (setq-local my/read-center-tab-frame frame)
              (setq-local eww-data
                          '(:url "https://example.test/paper"
                            :title "  First\n title  "))
              (cl-letf (((symbol-function 'my/read-org-noter-follow-source)
                         #'ignore))
                (my/read-eww-history-record-current))
              (plist-put eww-data :title "Updated title")
              (cl-letf (((symbol-function 'my/read-org-noter-follow-source)
                         #'ignore))
                (my/read-eww-history-record-current)))
            (let* ((data (my/read-eww-history--read-data))
                   (entries (plist-get data :entries)))
              (should (= (length entries) 1))
              (should (equal (caar entries)
                             "https://example.test/paper"))
              (should (equal (plist-get (cdar entries) :title)
                             "Updated title"))))
        (set-frame-parameter frame 'my-reading-frame nil)
        (set-frame-parameter frame 'my-reading-center-window nil)
        (set-frame-parameter frame 'my-reading-eww-buffer nil)
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (when (file-exists-p file) (delete-file file))))))

(ert-deftest my-read-eww-history-landing-page-lists-title-and-url ()
  (let* ((file (make-temp-file "my-read-eww-history-"))
         (my/read-eww-history-file file))
    (unwind-protect
        (progn
          (delete-file file)
          (my/read-eww-history--write-data
           '(:version 1
             :entries
             (("https://example.test/article"
               :title "Example Article" :visited 1.0))))
          (with-temp-buffer
            (eww-mode)
            (my/read-eww-history-render)
            (should my/read-eww-history-page-p)
            (should (string-match-p "Example Article" (buffer-string)))
            (should (string-match-p "https://example.test/article"
                                    (buffer-string)))
            (goto-char (point-min))
            (search-forward "Example Article")
            (let ((button (button-at (1- (point)))))
              (should button)
              (should (equal (button-get button 'my/read-eww-url)
                             "https://example.test/article")))))
      (when (file-exists-p file) (delete-file file)))))

(ert-deftest my-read-eww-history-landing-is-not-an-org-noter-document ()
  (with-temp-buffer
    (eww-mode)
    (setq-local eww-data '(:url "https://arxiv.org/" :title "EWW History"))
    (setq-local my/read-eww-history-page-p t)
    (should-not (my/read-org-noter--supported-buffer-p (current-buffer)))
    (setq my/read-eww-history-page-p nil)
    (should (my/read-org-noter--supported-buffer-p (current-buffer)))))

(ert-deftest my-read-org-noter-appends-kindle-location-properties ()
  (let ((doc (generate-new-buffer " *my-read-noter-kindle-doc*"))
        (notes (generate-new-buffer " *my-read-noter-kindle-notes*"))
        (my-read-k--current-result
         '((start . 8783) (end . 9885) (fingerprint . "kindle-position:8783-9885"))))
    (unwind-protect
        (let ((session (make-org-noter--session
                        :doc-mode 'my-read-k-document-mode
                        :doc-buffer doc :notes-buffer notes)))
          (with-current-buffer doc
            (my-read-k-document-mode)
            (insert "A Kindle sentence.")
            (goto-char 5))
          (with-current-buffer notes
            (org-mode)
            (insert "* Note\n")
            (goto-char (point-min))
            (setq-local org-noter--session session)
            (my/read-org-noter--record-kindle-metadata)
            (should (equal (org-entry-get nil "KINDLE_LOCATION")
                           "8783-9885, offset 5"))
            (should (equal (org-entry-get nil "KINDLE_FINGERPRINT")
                           "kindle-position:8783-9885"))))
      (kill-buffer doc)
      (kill-buffer notes))))

(ert-deftest english-reading-mode-makes-buffer-read-only-and-restores-writable-state ()
  (my-read-k-test--isolated
   (with-temp-buffer
     (should-not buffer-read-only)
     (english-reading-mode 1)
     (should buffer-read-only)
     (english-reading-mode -1)
     (should-not buffer-read-only))))

(ert-deftest english-reading-mode-preserves-an-existing-read-only-state ()
  (my-read-k-test--isolated
   (with-temp-buffer
     (read-only-mode 1)
     (english-reading-mode 1)
     (should buffer-read-only)
     (english-reading-mode -1)
     (should buffer-read-only))))

(ert-deftest english-reading-mode-centers-spoken-sentence-start ()
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *english-reading-center-test*"))
          recentered-at
          recentered-line)
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (dotimes (number 80)
              (insert (format "Sentence %d.\n" number)))
            (goto-char (point-min))
            (forward-line 60)
            (let ((beg (point))
                  (original-point (1+ (point))))
              (goto-char original-point)
              (cl-letf (((symbol-function 'recenter)
                         (lambda (&optional line)
                           (setq recentered-at (point)
                                 recentered-line line))))
                (english-reading-mode--position-spoken-start
                 (list :window (selected-window)
                       :buffer buffer
                       :beg beg)))
              (should (= recentered-at beg))
              (should-not recentered-line)
              (should (= (point) original-point))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest english-reading-mode-splits-pdftotext-output-into-pages ()
  (with-temp-buffer
    (insert "Page one.\fPage two.\fPage three.")
    (should (equal (append (english-reading-mode--pdf-page-ranges) nil)
                   '((1 . 10) (11 . 20) (21 . 32))))))

(ert-deftest english-reading-mode-pdf-sync-keeps-roll-speech-page ()
  (let ((pdf-buffer (generate-new-buffer " *pdf-roll-sync*"))
        (text-buffer (generate-new-buffer " *pdf-roll-sync-text*")))
    (unwind-protect
        (with-current-buffer pdf-buffer
          (setq-local major-mode 'pdf-view-mode)
          (setq-local buffer-file-name "/tmp/pdf-roll-sync.pdf")
          (setq-local english-reading-mode--pdf-text-buffer text-buffer)
          (setq-local english-reading-mode--pdf-page-ranges
                      [(1 . 100) (101 . 200)])
          ;; Speech is on page 2 while the top of the continuous roll remains
          ;; on page 1.  Synchronization must not rewind the speech cursor.
          (setq-local english-reading-mode--pdf-page 2)
          (setq-local english-reading-mode--pdf-text-point 150)
          (let ((english-reading-mode--continuous-state
                 (list :buffer pdf-buffer)))
            (cl-letf (((symbol-function
                        'english-reading-mode--pdf-current-page)
                       (lambda () 1)))
              (english-reading-mode--pdf-sync)))
          (should (= english-reading-mode--pdf-page 2))
          (should (= english-reading-mode--pdf-text-point 150)))
      (when (buffer-live-p pdf-buffer)
        (kill-buffer pdf-buffer))
      (when (buffer-live-p text-buffer)
        (kill-buffer text-buffer)))))

(ert-deftest english-reading-mode-pdf-roll-page-crossing-does-not-snap ()
  (let ((pdf-buffer (generate-new-buffer " *pdf-roll-crossing*"))
        (text-buffer (generate-new-buffer " *pdf-roll-crossing-text*"))
        displayed-page)
    (unwind-protect
        (progn
          (with-current-buffer text-buffer
            (insert (make-string 200 ?x)))
          (with-current-buffer pdf-buffer
            (setq-local major-mode 'pdf-view-mode)
            (setq-local buffer-file-name "/tmp/pdf-roll-crossing.pdf")
            (setq-local pdf-view-roll-minor-mode t)
            (setq-local english-reading-mode--pdf-text-buffer text-buffer)
            (setq-local english-reading-mode--pdf-page-ranges
                        [(1 . 100) (101 . 200)])
            (setq-local english-reading-mode--pdf-page 1)
            (setq-local english-reading-mode--pdf-text-point 90)
            (let ((english-reading-mode--continuous-state
                   (list :buffer pdf-buffer)))
              (cl-letf (((symbol-function 'pdf-view-goto-page)
                         (lambda (page) (setq displayed-page page))))
                (english-reading-mode--pdf-goto-page 2)))
            (should-not displayed-page)
            (should (= english-reading-mode--pdf-page 2))
            (should (= english-reading-mode--pdf-text-point 101))))
      (when (buffer-live-p pdf-buffer)
        (kill-buffer pdf-buffer))
      (when (buffer-live-p text-buffer)
        (kill-buffer text-buffer)))))

(ert-deftest english-reading-mode-pdf-selection-moves-reading-position ()
  (let ((pdf-buffer (generate-new-buffer " *english-reading-pdf-selection*"))
        (text-buffer (generate-new-buffer " *english-reading-pdf-selection-text*")))
    (unwind-protect
        (progn
          (with-current-buffer text-buffer
            (insert "Target sentence. Middle sentence. Target sentence.")
            (setq-local sentence-end-double-space nil))
          (with-current-buffer pdf-buffer
            (setq-local major-mode 'pdf-view-mode)
            (setq-local buffer-file-name "/tmp/english-reading-selection.pdf")
            (setq-local english-reading-mode t)
            (setq-local english-reading-mode--pdf-text-buffer text-buffer)
            (setq-local english-reading-mode--pdf-page-ranges
                        (with-current-buffer text-buffer
                          (english-reading-mode--pdf-page-ranges)))
            (setq-local english-reading-mode--pdf-page 1)
            (setq-local english-reading-mode--pdf-text-point 1)
            (setq-local pdf-view-active-region
                        '(1 (0.1 0.85 0.5 0.9)))
            (cl-letf (((symbol-function 'pdf-view-current-page)
                       (lambda () 1))
                      ((symbol-function 'pdf-view-active-region-p)
                       (lambda () t))
                      ((symbol-function 'pdf-view-active-region-text)
                       (lambda () '("Target\nsentence."))))
              (let ((location (english-reading-mode-use-pdf-selection)))
                (should (equal (car location) "Target sentence."))
                ;; The selection is near the page bottom, so the duplicate
                ;; sentence nearest that position must be selected.
                (should (> (nth 2 location) 30))))))
      (when (buffer-live-p pdf-buffer)
        (kill-buffer pdf-buffer))
      (when (buffer-live-p text-buffer)
        (kill-buffer text-buffer)))))

(ert-deftest english-reading-mode-pdf-manual-scroll-cancels-continuation ()
  (let ((pdf-buffer (generate-new-buffer " *continuous-pdf-scroll*"))
        (timer (run-at-time 60 nil #'ignore))
        stopped-audio)
    (unwind-protect
        (with-current-buffer pdf-buffer
          (setq-local major-mode 'pdf-view-mode)
          (setq-local buffer-file-name "/tmp/continuous-scroll.pdf")
          (setq-local english-reading-mode t)
          (let ((english-reading-mode--continuous-state
                 (list :buffer pdf-buffer))
                (english-reading-mode--continuous-timer timer)
                (this-command 'mwheel-scroll))
            (cl-letf (((symbol-function 'kokoro-reader-stop)
                       (lambda () (setq stopped-audio t))))
              (english-reading-mode--pdf-pre-command))
            (should-not english-reading-mode--continuous-state)
            (should-not english-reading-mode--continuous-timer)
            (should-not stopped-audio)))
      (when (timerp timer)
        (cancel-timer timer))
      (when (buffer-live-p pdf-buffer)
        (kill-buffer pdf-buffer)))))

(ert-deftest english-reading-mode-pdf-selection-cancels-continuation ()
  (let ((pdf-buffer (generate-new-buffer " *continuous-pdf-selection*"))
        (timer (run-at-time 60 nil #'ignore))
        synchronized)
    (unwind-protect
        (with-current-buffer pdf-buffer
          (setq-local major-mode 'pdf-view-mode)
          (setq-local buffer-file-name "/tmp/continuous-selection.pdf")
          (setq-local english-reading-mode t)
          (let ((english-reading-mode--continuous-state
                 (list :buffer pdf-buffer))
                (english-reading-mode--continuous-timer timer))
            (cl-letf (((symbol-function 'pdf-view-active-region-p)
                       (lambda () t))
                      ((symbol-function 'english-reading-mode-use-pdf-selection)
                       (lambda ()
                         (setq synchronized t)
                         '("Selected sentence." nil 1 19))))
              (english-reading-mode--pdf-selection-finished))
            (should synchronized)
            (should-not english-reading-mode--continuous-state)
            (should-not english-reading-mode--continuous-timer)))
      (when (timerp timer)
        (cancel-timer timer))
      (when (buffer-live-p pdf-buffer)
        (kill-buffer pdf-buffer)))))

(ert-deftest english-reading-mode-pdf-j-speaks-and-n-moves-across-pages ()
  (let ((pdf-buffer (generate-new-buffer " *english-reading-pdf-test*"))
        (text-buffer (generate-new-buffer " *english-reading-pdf-text-test*"))
        (shown-page 1)
        spoken)
    (unwind-protect
        (progn
          (with-current-buffer text-buffer
            (insert "First sentence. Second sentence.\f2\n\nThird sentence.")
            (setq-local sentence-end-double-space nil)
            (setq-local english-reading-mode t))
          (with-current-buffer pdf-buffer
            (setq-local major-mode 'doc-view-mode)
            (setq-local buffer-file-name "/tmp/english-reading-test.pdf")
            (setq-local english-reading-mode t)
            (setq-local english-reading-mode--pdf-text-buffer text-buffer)
            (setq-local english-reading-mode--pdf-page-ranges
                        (with-current-buffer text-buffer
                          (english-reading-mode--pdf-page-ranges)))
            (setq-local english-reading-mode--pdf-page 1)
            (setq-local english-reading-mode--pdf-text-point 1)
            (cl-letf (((symbol-function 'doc-view-current-page)
                       (lambda () shown-page))
                      ((symbol-function 'doc-view-goto-page)
                       (lambda (page) (setq shown-page page)))
                      ((symbol-function 'kokoro-reader--speak-bounds)
                       (lambda (beg end)
                         (push (buffer-substring-no-properties beg end)
                               spoken))))
              (english-reading-mode-speak-current-sentence)
              (should (equal (car spoken) "First sentence."))
              (should (equal (car (english-reading-mode-current-text-location))
                             "First sentence."))
              (english-reading-mode-next-sentence)
              (should (= (length spoken) 1))
              (should (equal (car (english-reading-mode-current-text-location))
                             "Second sentence."))
              (english-reading-mode-speak-current-sentence)
              (should (equal (car spoken) "Second sentence."))
              (english-reading-mode-next-sentence)
              (should (= shown-page 2))
              (should (= (length spoken) 2))
              (should (equal (car (english-reading-mode-current-text-location))
                             "Third sentence."))
              (let ((location (english-reading-mode-previous-sentence)))
                (should (equal (car location) "Second sentence.")))
              (should (= (length spoken) 2))
              (should (equal (car (english-reading-mode-current-text-location))
                             "Second sentence.")))))
      (when (buffer-live-p pdf-buffer)
        (kill-buffer pdf-buffer))
      (when (buffer-live-p text-buffer)
        (kill-buffer text-buffer)))))

(ert-deftest english-reading-mode-pdf-tools-page-navigation ()
  (let ((pdf-buffer (generate-new-buffer " *english-reading-pdf-tools-test*"))
        (text-buffer (generate-new-buffer " *english-reading-pdf-tools-text*"))
        (shown-page 1))
    (unwind-protect
        (progn
          (with-current-buffer text-buffer
            (insert "Page one.\fPage two.\fPage three."))
          (with-current-buffer pdf-buffer
            (setq-local major-mode 'pdf-view-mode)
            (setq-local buffer-file-name "/tmp/english-reading-pdf-tools-test.pdf")
            (setq-local english-reading-mode--pdf-text-buffer text-buffer)
            (setq-local english-reading-mode--pdf-page-ranges
                        (with-current-buffer text-buffer
                          (english-reading-mode--pdf-page-ranges)))
            (setq-local english-reading-mode--pdf-page 1)
            (setq-local english-reading-mode--pdf-text-point 1)
            (cl-letf (((symbol-function 'pdf-view-current-page)
                       (lambda () shown-page))
                      ((symbol-function 'pdf-view-goto-page)
                       (lambda (page) (setq shown-page page))))
              (english-reading-mode-next-page)
              (should (= shown-page 2))
              (should (= english-reading-mode--pdf-page 2))
              (english-reading-mode-previous-page)
              (should (= shown-page 1))
              (should (= english-reading-mode--pdf-page 1)))))
      (when (buffer-live-p pdf-buffer)
        (kill-buffer pdf-buffer))
      (when (buffer-live-p text-buffer)
        (kill-buffer text-buffer)))))

(ert-deftest english-reading-mode-pdf-matches-words-and-merges-line-rectangles ()
  (let* ((words
          (vector
           '(:text "First" :xmin 10.0 :ymin 20.0 :xmax 30.0 :ymax 30.0)
           '(:text "sentence." :xmin 32.0 :ymin 20.0 :xmax 70.0 :ymax 30.0)
           '(:text "Second" :xmin 10.0 :ymin 35.0 :xmax 40.0 :ymax 45.0)))
         (starts
          (english-reading-mode--pdf-token-match-starts
           '("first" "sentence.") words)))
    (should (equal starts '(0)))
    (should
     (equal (english-reading-mode--pdf-word-rectangles words 0 2)
            '((10.0 20.0 70.0 30.0))))))

(ert-deftest english-reading-mode-pdf-matches-japanese-across-bbox-lines ()
  (let ((words
         (vector
          '(:text "前の文です。また，デッドロックの検出や解消のための機能は，排他制御機能を提供している"
            :xmin 10.0 :ymin 20.0 :xmax 500.0 :ymax 30.0)
          '(:text "ミドルウェアによって提供される。次の文です。"
            :xmin 10.0 :ymin 35.0 :xmax 300.0 :ymax 45.0))))
    (should
     (equal
      (english-reading-mode--pdf-compact-match-ranges
       "また，デッドロックの検出や解消のための機能は，排他制御機能を提供しているミドルウェアによって提供される。"
       words)
      '((0 . 2))))))

(ert-deftest english-reading-mode-pdf-anchors-multi-sentence-bbox-order-mismatch ()
  (let* ((words
          (vector
           '(:text "これは先頭の文章です。" :xmin 10.0 :ymin 20.0
             :xmax 200.0 :ymax 30.0)
           '(:text "図表の注記が途中にあります。" :xmin 10.0 :ymin 35.0
             :xmax 240.0 :ymax 45.0)
           '(:text "抽出順だけが本文と異なります。" :xmin 10.0 :ymin 50.0
             :xmax 260.0 :ymax 60.0)
           '(:text "これは最後の文章です。" :xmin 10.0 :ymin 65.0
             :xmax 210.0 :ymax 75.0)))
         (context
          '(:text "これは先頭の文章です。抽出順だけが本文と異なります。図表の注記が途中にあります。これは最後の文章です。"
            :beg 1 :end 100)))
    (should-not
     (english-reading-mode--pdf-compact-match-ranges
      (plist-get context :text) words))
    (should
     (equal
      (english-reading-mode--pdf-anchored-match-range
       context words '(1 . 100))
      '(0 . 4)))))

(ert-deftest english-reading-mode-pdf-builds-highlight-svg-at-docview-width ()
  (let (captured)
    (cl-letf (((symbol-function 'english-reading-mode--pdf-image-data-uri)
               (lambda (_image) "data:image/png;base64,AAAA"))
              ((symbol-function 'create-image)
               (lambda (data type data-p &rest properties)
                 (setq captured (list data type data-p properties))
                 'highlight-image)))
      (should
       (eq (english-reading-mode--pdf-svg-highlight
            '(image :type png :file "/tmp/page.png" :width 850)
            '(:width 612.0 :height 792.0)
            '((10.0 20.0 70.0 30.0)))
           'highlight-image))
      (should (eq (nth 1 captured) 'svg))
      (should (nth 2 captured))
      (should (equal (plist-get (nth 3 captured) :width) 850))
      (should (string-match-p "data:image/png;base64,AAAA" (car captured)))
      (should (string-match-p "<rect x='8\\.500'" (car captured)))
      (should-not (string-match-p "stroke=" (car captured))))))

(ert-deftest english-reading-mode-pdf-image-data-uri-supports-pdf-tools-data ()
  (let ((english-reading-mode--pdf-image-data-cache
         (make-hash-table :test #'equal)))
    (should
     (equal (english-reading-mode--pdf-image-data-uri
             '(image :type png :data "PNG bytes"))
            (concat "data:image/png;base64,"
                    (base64-encode-string "PNG bytes" t))))))

(ert-deftest english-reading-mode-doc-view-highlights-and-restores-sentence ()
  (save-window-excursion
    (let ((pdf-buffer (generate-new-buffer " *pdf-view-highlight*"))
          (text-buffer (generate-new-buffer " *pdf-view-highlight-text*")))
      (unwind-protect
          (progn
            (switch-to-buffer pdf-buffer)
            (insert " ")
            (setq-local major-mode 'doc-view-mode)
            (setq-local buffer-file-name "/tmp/highlight.pdf")
            (setq-local english-reading-mode--pdf-text-buffer text-buffer)
            (let ((page-overlay (make-overlay (point-min) (point-max)))
                  (page-image '(image :type png :data "PNG bytes" :width 500)))
              (overlay-put page-overlay 'display page-image)
              (cl-letf (((symbol-function
                          'english-reading-mode--pdf-context-rectangles)
                         (lambda (_context)
                           '((:width 612.0 :height 792.0)
                             ((10.0 20.0 70.0 30.0)))))
                        ((symbol-function
                          'english-reading-mode--pdf-display-state)
                         (lambda (&optional _window)
                           (list page-overlay page-image nil)))
                        ((symbol-function
                          'english-reading-mode--pdf-svg-highlight)
                         (lambda (&rest _arguments) 'highlight-image)))
                (let ((context (list :window (selected-window)
                                     :buffer text-buffer
                                     :text "Spoken sentence."
                                     :beg 1 :end 17)))
                  (english-reading-mode--pdf-highlight-start context)
                  (should (eq (overlay-get page-overlay 'display)
                              'highlight-image))
                  ;; A real DocView state read now returns the installed SVG,
                  ;; not PAGE-IMAGE.  Restoration must use the captured value.
                  (cl-letf (((symbol-function
                              'english-reading-mode--pdf-display-state)
                             (lambda (&optional _window)
                               (list page-overlay 'highlight-image nil))))
                    (english-reading-mode--pdf-highlight-finish context))
                  (should (equal (overlay-get page-overlay 'display)
                                 page-image))))))
        (when (buffer-live-p pdf-buffer) (kill-buffer pdf-buffer))
        (when (buffer-live-p text-buffer) (kill-buffer text-buffer))))))

(ert-deftest english-reading-mode-pdf-view-renders-highlight-above-page ()
  (with-temp-buffer
    (setq-local major-mode 'pdf-view-mode)
    (setq-local english-reading-mode--pdf-page 3)
    (let (created raster-arguments image-arguments displayed restored)
      (cl-letf (((symbol-function 'pdf-view-create-page)
                 (lambda (page &optional window)
                   (setq created (list page window))
                   '(image :type png :width 500)))
                ((symbol-function
                  'english-reading-mode--pdf-borderless-raster-highlight)
                 (lambda (image geometry rectangles)
                   (setq raster-arguments
                         (list image geometry rectangles))
                   "highlight-png-data"))
                ((symbol-function 'create-image)
                 (lambda (data type data-p &rest properties)
                   (setq image-arguments
                         (list data type data-p properties))
                   'native-highlight-image))
                ((symbol-function 'pdf-view-display-image)
                 (lambda (image page &optional window _inhibit-slice)
                   (setq displayed (list image page window))))
                ((symbol-function 'pdf-view-display-page)
                 (lambda (page &optional window)
                   (setq restored (list page window)))))
        (cl-letf (((symbol-function 'window-live-p) (lambda (_window) t))
                  ((symbol-function 'window-buffer)
                   (lambda (_window) (current-buffer))))
          (english-reading-mode--pdf-view-highlight
           'test-window
           '(:width 500.0 :height 1000.0)
           '((50.0 200.0 250.0 240.0))
           'speech-context))
        (should (equal created '(3 test-window)))
        (should (equal raster-arguments
                       '((image :type png :width 500)
                         (:width 500.0 :height 1000.0)
                         ((50.0 200.0 250.0 240.0)))))
        (should (equal image-arguments
                       '("highlight-png-data" png t
                         (:width 500 :pointer arrow))))
        (should (equal displayed
                       '(native-highlight-image 3 test-window)))
        (should (= english-reading-mode--pdf-highlight-page 3))
        (should (eq (plist-get english-reading-mode--pdf-highlight-state
                               :context)
                    'speech-context))
        (cl-letf (((symbol-function 'window-live-p) (lambda (_window) t))
                  ((symbol-function 'window-buffer)
                   (lambda (_window) (current-buffer))))
          (english-reading-mode--pdf-restore-image
           (current-buffer) 'test-window 'speech-context))
        (should (equal restored '(3 test-window)))
        (should-not english-reading-mode--pdf-highlight-page)
        (should-not english-reading-mode--pdf-highlight-state)))))

(ert-deftest english-reading-mode-pdf-raster-highlight-has-no-stroke ()
  (let ((png-data (make-string 24 0))
        process-arguments)
    ;; A 1000-pixel Retina PNG displayed at width 500 must still receive
    ;; coordinates in its native 1000-pixel raster space.
    (aset png-data 0 #x89)
    (cl-loop for byte across "PNG\r\n\x1a\n"
             for index from 1
             do (aset png-data index byte))
    (aset png-data 16 0)
    (aset png-data 17 0)
    (aset png-data 18 3)
    (aset png-data 19 232)
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_program) "/opt/homebrew/bin/magick"))
              ((symbol-function 'call-process-region)
               (lambda (_beg _end program _delete destination _display
                        &rest arguments)
                 (setq process-arguments (cons program arguments))
                 (with-current-buffer destination
                   (set-buffer-multibyte nil)
                   (insert "borderless-png"))
                 0)))
      (should
       (equal
        (english-reading-mode--pdf-borderless-raster-highlight
         `(image :type png :width 500 :data ,png-data)
         '(:width 500.0 :height 1000.0)
         '((50.0 200.0 250.0 240.0)))
        "borderless-png")))
    (should (member "-stroke" process-arguments))
    (should (equal (cadr (member "-stroke" process-arguments)) "none"))
    (should
     (equal (cadr (member "-draw" process-arguments))
            "roundrectangle 97.000,398.000 503.000,482.000 3.000,3.000"))))

(ert-deftest english-reading-mode-pdf-highlight-delay-is-one-millisecond ()
  (should (= english-reading-mode-pdf-highlight-delay 0.001)))

(ert-deftest english-reading-mode-pdf-highlight-watch-reapplies-overwritten-image ()
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (let* ((window (selected-window))
             (context (list :window window :buffer 'speech-buffer))
             (english-reading-mode--active-speech context)
             (english-reading-mode--pdf-highlight-watch-context context)
             (english-reading-mode--pdf-highlight-watch-remaining 1)
             reapplied)
        (setq-local
         english-reading-mode--pdf-highlight-state
         (list :context context :mode 'pdf-view-mode :page 3 :window window
               :highlight-image 'highlight-image
               :display-image 'installed-highlight))
        (cl-letf (((symbol-function
                    'english-reading-mode--pdf-highlight-current-display)
                   (lambda (_state) 'normal-page-image))
                  ((symbol-function
                    'english-reading-mode--pdf-view-display-image)
                   (lambda (image page target-window)
                     (setq reapplied (list image page target-window))
                     'reinstalled-highlight)))
          (english-reading-mode--run-pdf-highlight-watch context))
        (should (equal reapplied (list 'highlight-image 3 window)))
        (should
         (eq (plist-get english-reading-mode--pdf-highlight-state
                        :display-image)
             'reinstalled-highlight))))))

(ert-deftest english-reading-mode-pdf-roll-highlight-targets-page-overlay ()
  (save-window-excursion
    (with-temp-buffer
      (insert (make-string 80 ?\s))
      (let* ((window (selected-window))
             (page 16)
             (position (- (* 4 page) 3))
             (selection-overlay (make-overlay 47 63))
             (page-overlay (make-overlay position (1+ position)))
             (pdf-view-roll-minor-mode t))
        (set-window-buffer window (current-buffer))
        ;; This overlapping selection is returned first by pdf-tools'
        ;; `pdf-roll-page-overlay' on the affected live layout.
        (overlay-put selection-overlay 'window window)
        (overlay-put selection-overlay 'face 'region)
        (overlay-put selection-overlay 'display 'selection-image)
        (overlay-put page-overlay 'window window)
        (overlay-put page-overlay 'category 'pdf-roll)
        (overlay-put page-overlay 'display 'normal-page-image)
        (cl-letf (((symbol-function 'pdf-roll-page-to-pos)
                   (lambda (_page) position))
                  ((symbol-function 'pdf-roll-maybe-slice-image)
                   (lambda (image _window &optional _inhibit) image))
                  ((symbol-function 'force-window-update) #'ignore))
          (english-reading-mode--pdf-view-display-image
           'highlight-image page window))
        (should (eq (overlay-get page-overlay 'display) 'highlight-image))
        (should (eq (overlay-get selection-overlay 'display)
                    'selection-image))))))

(ert-deftest english-reading-mode-pdf-highlight-finish-does-not-restore-newer-context ()
  (save-window-excursion
    (with-temp-buffer
      (setq-local major-mode 'pdf-view-mode)
      (setq-local buffer-file-name "/tmp/highlight-owner.pdf")
      (set-window-buffer (selected-window) (current-buffer))
      (let* ((old-context (list :id 1 :window (selected-window)))
             (new-context (list :id 2 :window (selected-window)))
             (english-reading-mode--pdf-highlight-page 4)
             (english-reading-mode--pdf-highlight-state
              (list :context new-context :mode 'pdf-view-mode
                    :page 4 :window (selected-window)))
             restored)
        (cl-letf (((symbol-function 'pdf-view-display-page)
                   (lambda (&rest arguments) (setq restored arguments))))
          (english-reading-mode--pdf-highlight-finish old-context))
        (should-not restored)
        (should english-reading-mode--pdf-highlight-state)
        (should (= english-reading-mode--pdf-highlight-page 4))))))

(ert-deftest english-reading-mode-pdf-new-highlight-restores-stale-image-first ()
  (save-window-excursion
    (let ((pdf-buffer (generate-new-buffer " *stale-pdf-highlight*"))
          (text-buffer (generate-new-buffer " *stale-pdf-highlight-text*"))
          events)
      (unwind-protect
          (progn
            (switch-to-buffer pdf-buffer)
            (setq-local major-mode 'pdf-view-mode)
            (setq-local buffer-file-name "/tmp/stale-highlight.pdf")
            (setq-local english-reading-mode--pdf-text-buffer text-buffer)
            (setq-local english-reading-mode--pdf-highlight-page 2)
            (setq-local english-reading-mode--pdf-highlight-state
                        (list :context 'old :mode 'pdf-view-mode
                              :page 2 :window (selected-window)))
            (cl-letf (((symbol-function 'pdf-view-display-page)
                       (lambda (&rest _) (push 'restore events)))
                      ((symbol-function
                        'english-reading-mode--pdf-context-rectangles)
                       (lambda (_context) nil)))
              (english-reading-mode--pdf-highlight-start
               (list :window (selected-window) :buffer text-buffer)))
            (should (equal events '(restore)))
            (should-not english-reading-mode--pdf-highlight-state)
            (should-not english-reading-mode--pdf-highlight-page))
        (when (buffer-live-p pdf-buffer) (kill-buffer pdf-buffer))
        (when (buffer-live-p text-buffer) (kill-buffer text-buffer))))))

(ert-deftest english-reading-mode-pdf-highlight-is-deferred-after-scroll ()
  (with-temp-buffer
    (setq-local english-reading-mode t)
    (let ((english-reading-mode--active-speech nil)
          (english-reading-mode--pdf-highlight-timer nil)
          (english-reading-mode--pdf-highlight-pending-context nil)
          scheduled-function
          scheduled-context
          events)
      (cl-letf (((symbol-function 'english-reading-mode--make-context)
                 (lambda (_beg _end) '(:id 1 :text "Short sentence.")))
                ((symbol-function
                  'english-reading-mode--pdf-center-continuous-speech)
                 (lambda (_context) (push 'center events)))
                ((symbol-function 'english-reading-mode--pdf-highlight-start)
                 (lambda (_context) (push 'highlight events)))
                ((symbol-function 'run-at-time)
                 (lambda (_delay _repeat function context)
                   (setq scheduled-function function
                         scheduled-context context)
                   'fake-highlight-timer))
                ((symbol-function 'english-reading-mode--start-watch)
                 (lambda (_context) (push 'watch events))))
        (english-reading-mode--around-kokoro-speak-bounds
         (lambda (_beg _end)
           (push 'play events)
           'playing)
         1 2)
        (should (equal (reverse events)
                       '(play center watch)))
        (should (eq scheduled-function
                    #'english-reading-mode--run-deferred-pdf-highlight))
        (funcall scheduled-function scheduled-context)
        (should (equal (reverse events)
                       '(play center watch highlight)))))))

(ert-deftest english-reading-mode-pdf-highlight-waits-for-stable-scroll ()
  (let* ((context '(:id 1 :text "Moving sentence."))
         (english-reading-mode--active-speech context)
         (english-reading-mode--pdf-highlight-pending-context context)
         (english-reading-mode--pdf-highlight-pending-scroll-state '(10 20 1))
         (english-reading-mode--pdf-highlight-timer nil)
         (current-scroll-state '(11 25 1))
         scheduled-function
         scheduled-context
         highlighted)
    (cl-letf (((symbol-function
                'english-reading-mode--pdf-highlight-scroll-state)
               (lambda (_context) current-scroll-state))
              ((symbol-function 'run-at-time)
               (lambda (_delay _repeat function callback-context)
                 (setq scheduled-function function
                       scheduled-context callback-context)
                 'fake-highlight-timer))
              ((symbol-function 'english-reading-mode--pdf-highlight-start)
               (lambda (_context) (setq highlighted t))))
      (english-reading-mode--run-deferred-pdf-highlight context)
      (should-not highlighted)
      (should (equal english-reading-mode--pdf-highlight-pending-scroll-state
                     current-scroll-state))
      (should (eq scheduled-function
                  #'english-reading-mode--run-deferred-pdf-highlight))
      ;; With no further scroll change, the second delay may draw the layer.
      (funcall scheduled-function scheduled-context)
      (should highlighted)
      (should-not english-reading-mode--pdf-highlight-pending-context)
      (should-not english-reading-mode--pdf-highlight-pending-scroll-state))))

(ert-deftest english-reading-mode-pdf-highlight-is-not-scheduled-on-speech-error ()
  (with-temp-buffer
    (setq-local english-reading-mode t)
    (let ((english-reading-mode--active-speech nil)
          (english-reading-mode--pdf-highlight-timer nil)
          (english-reading-mode--pdf-highlight-pending-context nil)
          events)
      (cl-letf (((symbol-function 'english-reading-mode--make-context)
                 (lambda (_beg _end) '(:id 1 :text "Short sentence.")))
                ((symbol-function
                  'english-reading-mode--pdf-center-continuous-speech)
                 #'ignore)
                ((symbol-function 'english-reading-mode--pdf-highlight-start)
                 (lambda (_context) (push 'highlight events)))
                ((symbol-function 'english-reading-mode--pdf-highlight-finish)
                 (lambda (_context) (push 'restore events))))
        (should-error
         (english-reading-mode--around-kokoro-speak-bounds
          (lambda (&rest _) (error "speech failed"))
          1 2))
        (should-not events)
        (should-not english-reading-mode--pdf-highlight-pending-context)))))

(ert-deftest english-reading-mode-pdf-continuous-centers-spoken-line ()
  (save-window-excursion
    (let ((pdf-buffer (generate-new-buffer " *continuous-pdf-center*"))
          (text-buffer (generate-new-buffer " *continuous-pdf-center-text*"))
          centered-at)
      (unwind-protect
          (progn
            (switch-to-buffer pdf-buffer)
            (setq-local major-mode 'pdf-view-mode)
            (setq-local buffer-file-name "/tmp/continuous-center.pdf")
            (setq-local english-reading-mode--pdf-text-buffer text-buffer)
            (let ((english-reading-mode--continuous-state
                   (list :buffer pdf-buffer)))
              (cl-letf (((symbol-function
                          'english-reading-mode--pdf-context-rectangles)
                         (lambda (_context)
                           '((:height 1000.0)
                             ((10.0 500.0 100.0 520.0)))))
                        ((symbol-function 'pdf-view-image-size)
                         (lambda (&optional _displayed _window)
                           '(1000 . 2000)))
                        ((symbol-function 'pdf-view-image-offset)
                         (lambda (&optional _window) '(0 . 0)))
                        ((symbol-function 'window-inside-pixel-edges)
                         (lambda (&optional _window) '(0 0 500 800)))
                        ((symbol-function 'image-set-window-vscroll)
                         (lambda (value) (setq centered-at value))))
                (english-reading-mode--pdf-center-continuous-speech
                 (list :window (selected-window)
                       :buffer text-buffer
                       :text "Spoken sentence."
                       :beg 1 :end 17))))
            (should (= centered-at 860)))
        (when (buffer-live-p pdf-buffer)
          (kill-buffer pdf-buffer))
        (when (buffer-live-p text-buffer)
          (kill-buffer text-buffer))))))

(ert-deftest english-reading-mode-pdf-continuous-rolls-across-page-boundaries ()
  (save-window-excursion
    (let ((pdf-buffer (generate-new-buffer " *continuous-pdf-roll*"))
          (text-buffer (generate-new-buffer " *continuous-pdf-roll-text*"))
          goto-page
          (goto-count 0)
          (simulated-vscroll 0)
          positioned-vscrolls
          forward-scrolls
          single-page-scroll)
      (unwind-protect
          (progn
            (switch-to-buffer pdf-buffer)
            (setq-local major-mode 'pdf-view-mode)
            (setq-local buffer-file-name "/tmp/continuous-roll.pdf")
            (setq-local pdf-view-roll-minor-mode t)
            (setq-local english-reading-mode--pdf-page 3)
            (setq-local english-reading-mode--pdf-text-buffer text-buffer)
            (let ((english-reading-mode--continuous-state
                   (list :buffer pdf-buffer)))
              (cl-letf (((symbol-function
                          'english-reading-mode--pdf-context-rectangles)
                         (lambda (context)
                           (if (= (plist-get context :beg) 1)
                               '((:height 1000.0)
                                 ((10.0 500.0 100.0 520.0)))
                             '((:height 1000.0)
                               ((10.0 600.0 100.0 620.0))))))
                        ((symbol-function 'pdf-roll-goto-page)
                         (lambda (page window)
                           (cl-incf goto-count)
                           (setq goto-page (list page window)
                                 simulated-vscroll 0)))
                        ((symbol-function 'pdf-view-current-page)
                         (lambda (&optional _window) 3))
                        ((symbol-function 'pdf-roll-display-page)
                         (lambda (&rest _) 2000))
                        ((symbol-function 'pdf-roll-display-pages)
                         (lambda (&rest _)))
                        ((symbol-function 'pdf-roll-page-to-pos)
                         (lambda (page) page))
                        ((symbol-function 'pdf-roll-set-vscroll)
                         (lambda (vscroll &optional _window)
                           (setq simulated-vscroll vscroll)))
                        ((symbol-function
                          'english-reading-mode--pdf-roll-set-position)
                         (lambda (_page vscroll _window)
                           (setq simulated-vscroll vscroll)
                           (push vscroll positioned-vscrolls)))
                        ((symbol-function 'pdf-roll-scroll-forward)
                         (lambda (pixels window pixelwise)
                           (cl-incf simulated-vscroll pixels)
                           (push (list pixels window pixelwise)
                                 forward-scrolls)))
                        ((symbol-function 'pdf-roll-scroll-backward)
                         (lambda (pixels _window _pixelwise)
                           (cl-decf simulated-vscroll pixels)))
                        ((symbol-function 'window-vscroll)
                         (lambda (&optional _window _pixels)
                           simulated-vscroll))
                        ((symbol-function 'pdf-view-image-size)
                         (lambda (&optional _displayed _window)
                           '(1000 . 2000)))
                        ((symbol-function 'pdf-view-image-offset)
                         (lambda (&optional _window) '(0 . 0)))
                        ((symbol-function 'window-inside-pixel-edges)
                         (lambda (&optional _window) '(0 0 500 800)))
                        ((symbol-function 'image-set-window-vscroll)
                         (lambda (value) (setq single-page-scroll value))))
                (english-reading-mode--pdf-center-continuous-speech
                 (list :window (selected-window)
                       :buffer text-buffer
                       :text "Spoken sentence."
                       :beg 1 :end 17))
                (english-reading-mode--pdf-center-continuous-speech
                 (list :window (selected-window)
                       :buffer text-buffer
                       :text "Following sentence."
                       :beg 18 :end 37))))
            ;; Each exact highlight position is placed at the configured
            ;; 20-percent anchor without forcing a page-head jump.
            (should-not goto-page)
            (should (= goto-count 0))
            (should (equal (reverse positioned-vscrolls) '(860 1060)))
            (should-not forward-scrolls)
            (should-not single-page-scroll))
        (when (buffer-live-p pdf-buffer)
          (kill-buffer pdf-buffer))
        (when (buffer-live-p text-buffer)
          (kill-buffer text-buffer))))))

(ert-deftest english-reading-mode-pdf-continuous-does-not-rewind-to-page-head ()
  (save-window-excursion
    (let ((pdf-buffer (generate-new-buffer " *continuous-pdf-no-rewind*"))
          (text-buffer (generate-new-buffer
                        " *continuous-pdf-no-rewind-text*"))
          goto-page
          scroll)
      (unwind-protect
          (progn
            (switch-to-buffer pdf-buffer)
            (setq-local major-mode 'pdf-view-mode)
            (setq-local buffer-file-name "/tmp/continuous-no-rewind.pdf")
            (setq-local pdf-view-roll-minor-mode t)
            (setq-local english-reading-mode--pdf-page 3)
            (setq-local english-reading-mode--pdf-text-buffer text-buffer)
            (let ((english-reading-mode--continuous-state
                   (list :buffer pdf-buffer)))
              (cl-letf (((symbol-function
                          'english-reading-mode--pdf-context-rectangles)
                         (lambda (_context)
                           '((:height 1000.0)
                             ((10.0 600.0 100.0 620.0)))))
                        ;; Roll mode has already advanced its topmost page.
                        ((symbol-function 'pdf-view-current-page)
                         (lambda (&optional _window) 4))
                        ((symbol-function 'pdf-roll-display-page)
                         (lambda (&rest _) 2000))
                        ((symbol-function 'pdf-roll-goto-page)
                         (lambda (&rest arguments)
                           (setq goto-page arguments)))
                        ((symbol-function 'pdf-roll-scroll-forward)
                         (lambda (&rest arguments) (setq scroll arguments)))
                        ((symbol-function 'pdf-roll-scroll-backward)
                         (lambda (&rest arguments) (setq scroll arguments)))
                        ((symbol-function 'window-vscroll)
                         (lambda (&optional _window _pixels) 375))
                        ((symbol-function 'window-inside-pixel-edges)
                         (lambda (&optional _window) '(0 0 500 800))))
                (english-reading-mode--pdf-center-continuous-speech
                 (list :window (selected-window)
                       :buffer text-buffer
                       :text "Delayed sentence."
                       :beg 1 :end 17))))
            (should-not goto-page)
            (should-not scroll))
        (when (buffer-live-p pdf-buffer)
          (kill-buffer pdf-buffer))
        (when (buffer-live-p text-buffer)
          (kill-buffer text-buffer))))))

(ert-deftest english-reading-mode-pdf-continuous-position-follows-highlight ()
  (let ((english-reading-mode--pdf-page 2)
        (english-reading-mode--pdf-page-ranges
         [(1 . 100) (101 . 201)]))
    (cl-letf (((symbol-function 'english-reading-mode--pdf-bbox-page)
               (lambda (_page) '(:height 1000.0)))
              ;; Exact bbox order is deliberately unrelated to source order.
              ((symbol-function
                'english-reading-mode--pdf-context-rectangles)
               (lambda (_context)
                 '((:height 1000.0) ((10.0 100.0 100.0 120.0))))))
      (should
       (equal (english-reading-mode--pdf-continuous-position '(:beg 151))
              '((:height 1000.0) (10.0 100.0 100.0 120.0)))))))

(ert-deftest english-reading-mode-pdf-roll-target-keeps-boundary-continuous ()
  (let ((pdf-roll-vertical-margin 2))
    (cl-letf (((symbol-function 'english-reading-mode--pdf-page-count)
               (lambda () 5))
              ((symbol-function 'pdf-roll-display-page)
               (lambda (_page _window) 1000)))
      ;; The first line on page 4 is shown at 20% while page 3's bottom remains
      ;; above it; a later line naturally advances the top page to page 4.
      (should (equal (english-reading-mode--pdf-roll-target-position
                      4 100 200 'test-window)
                     '(3 900)))
      (should (equal (english-reading-mode--pdf-roll-target-position
                      4 300 200 'test-window)
                     '(4 100))))))

(ert-deftest english-reading-mode-pdf-roll-set-position-uses-window-property ()
  (let (calls)
    (cl-letf (((symbol-function 'image-mode-window-put)
               (lambda (property value window)
                 (push (list 'put property value window) calls)))
              ((symbol-function 'pdf-roll-display-pages)
               (lambda (page window &rest _)
                 (push (list 'display page window) calls)))
              ((symbol-function 'pdf-roll-page-to-pos)
               (lambda (page) (+ 100 page)))
              ((symbol-function 'set-window-start)
               (lambda (window position &optional noforce)
                 (push (list 'start window position noforce) calls)))
              ((symbol-function 'pdf-roll-set-vscroll)
               (lambda (vscroll window)
                 (push (list 'vscroll vscroll window) calls)))
              ((symbol-function 'force-window-update)
               (lambda (window) (push (list 'force window) calls))))
      (english-reading-mode--pdf-roll-set-position 4 275 'test-window))
    (should
     (equal (reverse calls)
            '((put page 4 test-window)
              (display 4 test-window)
              (start test-window 104 t)
              (vscroll 275 test-window)
              (force test-window))))))

(ert-deftest english-reading-mode-pdf-roll-rejects-regression-and-stale-context ()
  (let ((english-reading-mode--continuous-state
         '(:pdf-roll-page 3 :pdf-roll-pixel 700 :pdf-roll-source-beg 200))
        applied)
    (cl-letf (((symbol-function
                'english-reading-mode--pdf-roll-target-position)
               (lambda (_page spoken-pixel _anchor _window)
                 (list 3 spoken-pixel)))
              ((symbol-function
                'english-reading-mode--pdf-roll-set-position)
               (lambda (&rest arguments) (push arguments applied))))
      ;; A later text chunk whose PDF rectangle is above the last rectangle
      ;; must not pull the viewport backward.
      (should-not
       (english-reading-mode--pdf-roll-position-spoken
        3 650 0 220 'test-window))
      ;; Nor may a delayed callback move forward after its text position has
      ;; already been superseded.
      (should-not
       (english-reading-mode--pdf-roll-position-spoken
        3 800 0 180 'test-window))
      (should-not applied)
      ;; A genuinely later canonical position is applied exactly once.
      (should
       (equal (english-reading-mode--pdf-roll-position-spoken
               3 800 0 220 'test-window)
              '(3 800)))
      (should (equal applied '((3 800 test-window)))))))

(ert-deftest english-reading-mode-pdf-continuous-never-scrolls-backward ()
  (save-window-excursion
    (let ((pdf-buffer (generate-new-buffer " *continuous-pdf-forward-only*"))
          (text-buffer (generate-new-buffer
                        " *continuous-pdf-forward-only-text*"))
          backward-scroll)
      (unwind-protect
          (progn
            (switch-to-buffer pdf-buffer)
            (setq-local major-mode 'pdf-view-mode)
            (setq-local buffer-file-name "/tmp/continuous-forward-only.pdf")
            (setq-local pdf-view-roll-minor-mode t)
            (setq-local english-reading-mode--pdf-page 3)
            (setq-local english-reading-mode--pdf-text-buffer text-buffer)
            (let ((english-reading-mode--continuous-state
                   (list :buffer pdf-buffer)))
              (cl-letf (((symbol-function
                          'english-reading-mode--pdf-continuous-position)
                         (lambda (_context)
                           '((:height 1000.0)
                             (0.0 50.0 0.0 50.0))))
                        ((symbol-function 'pdf-view-current-page)
                         (lambda (&optional _window) 3))
                        ((symbol-function 'pdf-roll-display-page)
                         (lambda (&rest _) 1000))
                        ((symbol-function 'pdf-roll-scroll-forward)
                         (lambda (&rest _) (error "unexpected forward scroll")))
                        ((symbol-function 'pdf-roll-scroll-backward)
                         (lambda (&rest arguments)
                           (setq backward-scroll arguments)))
                        ((symbol-function 'window-vscroll)
                         (lambda (&optional _window _pixels) 0))
                        ((symbol-function 'window-inside-pixel-edges)
                         (lambda (&optional _window) '(0 0 500 800))))
                (english-reading-mode--pdf-center-continuous-speech
                 (list :window (selected-window)
                       :buffer text-buffer
                       :text "Already above the anchor."
                       :beg 1 :end 26))))
            (should-not backward-scroll))
        (when (buffer-live-p pdf-buffer)
          (kill-buffer pdf-buffer))
        (when (buffer-live-p text-buffer)
          (kill-buffer text-buffer))))))

(ert-deftest english-reading-mode-pdf-centering-corrects-for-slice-offset ()
  (should
   (= (english-reading-mode--pdf-continuous-vscroll
       '(10.0 600.0 100.0 620.0)
       1000.0 2000 1000 800 500)
      200)))

(ert-deftest english-reading-mode-pdf-positions-speech-at-top-quarter ()
  (let ((english-reading-mode-pdf-speech-screen-position 0.25))
    (should
     (= (english-reading-mode--pdf-continuous-vscroll
         '(10.0 500.0 100.0 520.0)
         1000.0 2000 2000 800)
        820))))

(ert-deftest english-reading-mode-pdf-centering-falls-back-to-text-position ()
  (let ((english-reading-mode--pdf-page 2)
        (english-reading-mode--pdf-page-ranges
         [(1 . 100) (101 . 201)]))
    (cl-letf (((symbol-function
                'english-reading-mode--pdf-context-rectangles)
               (lambda (_context) nil))
              ((symbol-function 'english-reading-mode--pdf-bbox-page)
               (lambda (_page) '(:height 1000.0))))
      (should
       (equal (english-reading-mode--pdf-continuous-position '(:beg 151))
              '((:height 1000.0) (0.0 500.0 0.0 500.0)))))))

(ert-deftest english-reading-mode-pdf-zoom-recenters-before-highlight ()
  (let ((english-reading-mode--continuous-state '(:buffer active-pdf))
        (english-reading-mode--active-speech '(:text "Current sentence."))
        (this-command 'pdf-view-enlarge)
        events)
    (cl-letf (((symbol-function 'english-reading-mode--schedule-pdf-highlight)
               (lambda (context) (push (list 'highlight context) events)))
              ((symbol-function
                'english-reading-mode--pdf-center-continuous-speech)
               (lambda (context) (push (list 'center context) events))))
      (english-reading-mode--pdf-post-command))
    (should
     (equal (reverse events)
            (list (list 'center english-reading-mode--active-speech)
                  (list 'highlight english-reading-mode--active-speech))))))

(ert-deftest english-reading-mode-pdf-one-shot-does-not-auto-scroll ()
  (save-window-excursion
    (let ((pdf-buffer (generate-new-buffer " *one-shot-pdf-center*"))
          (text-buffer (generate-new-buffer " *one-shot-pdf-center-text*"))
          scrolled)
      (unwind-protect
          (progn
            (switch-to-buffer pdf-buffer)
            (setq-local major-mode 'pdf-view-mode)
            (setq-local buffer-file-name "/tmp/one-shot-center.pdf")
            (setq-local english-reading-mode--pdf-text-buffer text-buffer)
            (let ((english-reading-mode--continuous-state nil))
              (cl-letf (((symbol-function 'image-set-window-vscroll)
                         (lambda (_value) (setq scrolled t))))
                (english-reading-mode--pdf-center-continuous-speech
                 (list :window (selected-window)
                       :buffer text-buffer
                       :text "Spoken sentence."
                       :beg 1 :end 17))))
            (should-not scrolled))
        (when (buffer-live-p pdf-buffer)
          (kill-buffer pdf-buffer))
        (when (buffer-live-p text-buffer)
          (kill-buffer text-buffer))))))

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

(ert-deftest my-read-k-uses-title-or-asin-for-target-identifier ()
  (should (equal (my-read-k--target-book-name
                  "A Real Book Title"
                  "https://read.amazon.co.jp/?asin=B012345678")
                 "A Real Book Title"))
  (should (equal (my-read-k--target-book-name
                  "Kindle Cloud Reader"
                  "https://read.amazon.co.jp/?asin=B012345678&foo=1")
                 "Kindle-B012345678")))

(ert-deftest my-read-k-next-request-increments-generation-once ()
  (my-read-k-test--isolated
   (let (sent)
     (cl-letf (((symbol-function 'my-read-k--send)
                (lambda (command _params _callback generation)
                  (setq sent (list command generation)))))
       (my-read-k--request-page 'next)
       (should (equal sent '("next" 1)))
       (should my-read-k--busy-p)
       (should (= my-read-k--generation 1))))))

(ert-deftest my-read-k-prefetch-starts-immediately-and-only-once-per-source ()
  (my-read-k-test--isolated
   (with-temp-buffer
     (insert (make-string 100 ?x))
     (setq my-read-k--buffer (current-buffer)
           my-read-k--state 'attached
           my-read-k--last-fingerprint "source")
     (goto-char 40)
     (let (sent)
       (cl-letf (((symbol-function 'my-read-k--send)
                  (lambda (command params _callback generation)
                    (setq sent (list command
                                     (my-read-k--alist-get 'prefetchCount params)
                                     generation)))))
         (my-read-k--maybe-prefetch-next)
         (should (equal sent '("prefetchNext" 2 0)))
         (should my-read-k--prefetch-busy-p)
         (my-read-k--maybe-prefetch-next)
         (should (equal sent '("prefetchNext" 2 0))))))))

(ert-deftest my-read-k-prefetch-response-caches-matching-source ()
  (my-read-k-test--isolated
   (with-temp-buffer
     (setq my-read-k--buffer (current-buffer)
           my-read-k--last-fingerprint "source"
           my-read-k--prefetch-busy-p t
           header-line-format " Kindle: attached")
     (my-read-k--finish-prefetch
      '((ok . t)
        (result . ((prefetchSourceFingerprint . "source")
                   (pages . (((fingerprint . "next-1") (text . "Next page 1"))
                             ((fingerprint . "next-2") (text . "Next page 2")))))))
      "source")
     (should (my-read-k--prefetch-valid-p))
     (should (= (length my-read-k--prefetch-queue) 2))
     (should-not my-read-k--prefetch-busy-p)
     (should (string-suffix-p "next ready: 2 | prev ready: 0"
                             header-line-format)))))

(ert-deftest my-read-k-prefetch-response-rejects-stale-source ()
  (my-read-k-test--isolated
   (with-temp-buffer
     (setq my-read-k--buffer (current-buffer)
           my-read-k--last-fingerprint "newer"
           my-read-k--prefetch-busy-p t)
     (my-read-k--finish-prefetch
      '((ok . t)
        (result . ((prefetchSourceFingerprint . "old")
                   (fingerprint . "next") (text . "Old next"))))
      "old")
     (should-not my-read-k--prefetch-queue)
     (should-not my-read-k--prefetch-busy-p))))

(ert-deftest my-read-k-next-consumes-cache-and-advances-app ()
  (my-read-k-test--isolated
   (with-temp-buffer
     (setq my-read-k--buffer (current-buffer)
           my-read-k--state 'attached
           my-read-k--last-fingerprint "source"
           my-read-k--current-result
           '((fingerprint . "source") (text . "Current"))
           my-read-k--prefetch-source-fingerprint "source"
           my-read-k--prefetch-queue
           '(((fingerprint . "next") (text . "Cached next") (ocrMs . 7))
             ((fingerprint . "after-next") (text . "Cached after next") (ocrMs . 8))))
     (let (applied sent)
       (cl-letf (((symbol-function 'my-read-k--apply-page)
                  (lambda (result direction speak)
                    (setq applied (list result direction speak))))
                 ((symbol-function 'my-read-k--send)
                  (lambda (command _params _callback generation)
                    (setq sent (list command generation)))))
         (my-read-k--request-page 'next nil)
         (should (equal (cdr applied) '(next nil)))
         (should (equal sent '("advanceNext" 1)))
         (should my-read-k--sync-busy-p)
         (should (= (length my-read-k--prefetch-queue) 1))
         (should (equal (my-read-k--alist-get
                         'fingerprint (car my-read-k--prefetch-queue))
                        "after-next"))
         (should (equal my-read-k--prefetch-source-fingerprint "next")))))))

(ert-deftest my-read-k-next-cache-remembers-current-page-for-instant-back ()
  (my-read-k-test--isolated
   (with-temp-buffer
     (setq my-read-k--buffer (current-buffer)
           my-read-k--state 'attached
           my-read-k--last-fingerprint "current"
           my-read-k--current-result
           '((fingerprint . "current") (text . "Current page"))
           my-read-k--prefetch-source-fingerprint "current"
           my-read-k--prefetch-queue
           '(((fingerprint . "next") (text . "Next page"))))
     (cl-letf (((symbol-function 'my-read-k--send)
                (lambda (&rest _) nil)))
       (my-read-k--request-page 'next)
       (should (equal (buffer-string) "Next page\n"))
       (should (my-read-k--history-valid-p))
       (should (equal (my-read-k--alist-get
                       'fingerprint (car my-read-k--back-queue))
                      "current"))))))

(ert-deftest my-read-k-prev-consumes-history-and-restores-forward-cache ()
  (my-read-k-test--isolated
   (with-temp-buffer
     (setq my-read-k--buffer (current-buffer)
           my-read-k--state 'attached
           my-read-k--last-fingerprint "current"
           my-read-k--current-result
           '((fingerprint . "current") (text . "Current page"))
           my-read-k--back-source-fingerprint "current"
           my-read-k--back-queue
           '(((fingerprint . "previous") (text . "Previous page"))))
     (let (sent)
       (cl-letf (((symbol-function 'my-read-k--send)
                  (lambda (command _params _callback generation)
                    (setq sent (list command generation)))))
         (my-read-k--request-page 'prev)
         (should (equal (buffer-string) "Previous page\n"))
         (should (equal sent '("advancePrev" 1)))
         (should my-read-k--sync-busy-p)
         (should (my-read-k--prefetch-valid-p))
         (should (equal (my-read-k--alist-get
                         'fingerprint (car my-read-k--prefetch-queue))
                        "current")))))))

(ert-deftest my-read-k-prev-cache-displays-while-forward-prefetch-is-running ()
  (my-read-k-test--isolated
   (with-temp-buffer
     (setq my-read-k--buffer (current-buffer)
           my-read-k--state 'attached
           my-read-k--prefetch-busy-p t
           my-read-k--last-fingerprint "current"
           my-read-k--current-result
           '((fingerprint . "current") (text . "Current page"))
           my-read-k--back-source-fingerprint "current"
           my-read-k--back-queue
           '(((fingerprint . "previous") (text . "Previous page"))))
     (let (sent)
       (cl-letf (((symbol-function 'my-read-k--send)
                  (lambda (command _params _callback _generation)
                    (setq sent command))))
         (my-read-k--request-page 'prev)
         (should (equal (buffer-string) "Previous page\n"))
         (should (equal sent "advancePrev"))
         (should-not my-read-k--pending-intent))))))

(ert-deftest my-read-k-history-keeps-only-two-nearest-pages ()
  (my-read-k-test--isolated
   (let ((my-read-k-history-count 2)
         (my-read-k--last-fingerprint "page-4"))
     (setq my-read-k--back-queue
           '(((fingerprint . "page-2")) ((fingerprint . "page-1"))))
     (my-read-k--remember-transition '((fingerprint . "page-3")) 'next)
     (should (equal (mapcar (lambda (page)
                              (my-read-k--alist-get 'fingerprint page))
                            my-read-k--back-queue)
                    '("page-3" "page-2")))
     (should (equal my-read-k--back-source-fingerprint "page-4")))))

(ert-deftest my-read-k-successful-advance-refills-two-page-queue ()
  (my-read-k-test--isolated
   (with-temp-buffer
     (setq my-read-k--buffer (current-buffer)
           my-read-k--state 'syncing
           my-read-k--sync-busy-p t
           my-read-k--generation 4
           my-read-k--last-fingerprint "current"
           my-read-k--prefetch-queue
           '(((fingerprint . "next") (text . "Next")))
           my-read-k--prefetch-source-fingerprint "current")
     (let (sent)
       (cl-letf (((symbol-function 'my-read-k--send)
                  (lambda (command params _callback generation)
                    (setq sent (list command
                                     (my-read-k--alist-get 'prefetchCount params)
                                     generation)))))
         (my-read-k--finish-advance
          '((ok . t) (result . ((fingerprint . "current"))))
          4 "current" 'next)
         (should (equal sent '("prefetchNext" 2 4)))
         (should my-read-k--prefetch-busy-p)
         (should-not my-read-k--sync-busy-p))))))

(ert-deftest my-read-k-boundary-waits-for-running-prefetch ()
  (my-read-k-test--isolated
   (setq my-read-k--prefetch-busy-p t)
   (my-read-k--request-page 'next t)
   (should (equal my-read-k--pending-intent '(next . t)))
   (should-not my-read-k--busy-p)))

(ert-deftest my-read-k-forward-within-buffer-reuses-next-sentence-movement ()
  (my-read-k-test--isolated
   (with-temp-buffer
     (insert "One sentence. Another sentence.")
     (goto-char (point-min))
     (let ((calls 0))
       (cl-letf (((symbol-function 'english-reading-mode-next-sentence)
                  (lambda () (interactive) (cl-incf calls)))
                 ((symbol-function 'my-read-k--request-page)
                  (lambda (&rest _) (ert-fail "unexpected page request"))))
         (my-read-k-forward)
         (should (= calls 1)))))))

(ert-deftest my-read-k-forward-at-end-requests-one-next-page ()
  (my-read-k-test--isolated
   (with-temp-buffer
     (insert "One sentence.")
     (goto-char (point-max))
     (let (request)
       (cl-letf (((symbol-function 'my-read-k--request-page)
                  (lambda (direction &optional speak)
                    (setq request (list direction speak)))))
         (my-read-k-forward)
         (should (equal request '(next nil))))))))

(ert-deftest my-read-k-backward-at-first-sentence-requests-prev-page ()
  (my-read-k-test--isolated
   (with-temp-buffer
     (insert "First sentence. Second sentence.")
     (goto-char (point-min))
     (let (request)
       (should (eq (lookup-key my-read-k-mode-map (kbd "k"))
                   #'my-read-k-backward))
       (cl-letf (((symbol-function 'my-read-k--request-page)
                  (lambda (direction &optional speak)
                    (setq request (list direction speak)))))
         (my-read-k-backward)
         (should (equal request '(prev nil))))))))

(ert-deftest my-read-k-busy-input-is-serialized-as-last-intent ()
  (my-read-k-test--isolated
   (setq my-read-k--busy-p t)
   (my-read-k-forward)
   (should (equal my-read-k--pending-intent '(next)))
   (my-read-k-backward)
   (should (equal my-read-k--pending-intent '(prev)))))

(ert-deftest my-read-k-down-within-buffer-keeps-normal-line-movement ()
  (my-read-k-test--isolated
   (with-temp-buffer
     (insert "first line\nsecond line\n")
     (goto-char (point-min))
     (cl-letf (((symbol-function 'my-read-k--request-page)
                (lambda (&rest _) (ert-fail "unexpected page request"))))
       (my-read-k-down)
       (should (= (line-number-at-pos) 2))))))

(ert-deftest my-read-k-down-at-buffer-bottom-requests-next-page ()
  (my-read-k-test--isolated
   (with-temp-buffer
     (insert "last line")
     (goto-char (point-max))
     (let (request)
       (cl-letf (((symbol-function 'my-read-k--request-page)
                  (lambda (direction &optional speak)
                    (setq request (list direction speak)))))
         (my-read-k-down)
         (should (equal request '(next nil)))
         (should (= (point) (point-max))))))))

(ert-deftest my-read-k-down-at-long-page-start-never-turns-page ()
  (my-read-k-test--isolated
   (with-temp-buffer
     (insert (make-string 300 ?x))
     (goto-char (point-min))
     (cl-letf (((symbol-function 'next-line) (lambda (&rest _) nil))
               ((symbol-function 'my-read-k--request-page)
                (lambda (&rest _) (ert-fail "unexpected page request"))))
       (my-read-k-down)))))

(ert-deftest my-read-k-down-while-busy-queues-one-next-page ()
  (my-read-k-test--isolated
   (setq my-read-k--busy-p t)
   (my-read-k-down)
   (should (equal my-read-k--pending-intent '(next)))))

(ert-deftest my-read-k-up-within-buffer-keeps-normal-line-movement ()
  (my-read-k-test--isolated
   (with-temp-buffer
     (insert "first line\nsecond line\n")
     (goto-char (point-min))
     (forward-line 1)
     (cl-letf (((symbol-function 'my-read-k--request-page)
                (lambda (&rest _) (ert-fail "unexpected page request"))))
       (my-read-k-up)
       (should (= (line-number-at-pos) 1))))))

(ert-deftest my-read-k-up-at-buffer-top-requests-prev-page ()
  (my-read-k-test--isolated
   (with-temp-buffer
     (insert "first line")
     (goto-char (point-min))
     (let (request)
       (cl-letf (((symbol-function 'my-read-k--request-page)
                  (lambda (direction &optional speak)
                    (setq request (list direction speak)))))
         (my-read-k-up)
         (should (equal request '(prev nil)))
         (should (= (point) (point-min))))))))

(ert-deftest my-read-k-up-at-long-page-end-never-turns-page ()
  (my-read-k-test--isolated
   (with-temp-buffer
     (insert (make-string 300 ?x))
     (goto-char (point-max))
     (cl-letf (((symbol-function 'previous-line) (lambda (&rest _) nil))
               ((symbol-function 'my-read-k--request-page)
                (lambda (&rest _) (ert-fail "unexpected page request"))))
       (my-read-k-up)))))

(ert-deftest my-read-k-up-while-busy-queues-one-prev-page ()
  (my-read-k-test--isolated
   (setq my-read-k--busy-p t)
   (my-read-k-up)
   (should (equal my-read-k--pending-intent '(prev)))))

(ert-deftest my-read-k-malformed-response-does-not-throw ()
  (my-read-k-test--isolated
   (let ((my-read-k--last-error nil))
     (my-read-k--process-filter nil "not-json\n")
     (should (equal (plist-get my-read-k--last-error :code)
                    "MALFORMED_RESPONSE")))))

(ert-deftest my-read-k-page-success-runs-update-and-followers-once ()
  (my-read-k-test--isolated
   (with-temp-buffer
     (setq my-read-k--buffer (current-buffer)
           my-read-k--generation 3
           my-read-k--busy-p t)
     (let ((apply-count 0) (follow-count 0))
       (cl-letf (((symbol-function 'my-read-k--apply-page)
                  (lambda (&rest _) (cl-incf apply-count)))
                 ((symbol-function 'my-read-k--refresh-followers)
                  (lambda () (cl-incf follow-count))))
         ;; Count the common follower call through the real apply function is
         ;; covered separately; here the response must invoke apply only once.
         (my-read-k--finish-page-request
          '((ok . t) (result . ((text . "Page")))) 3 'next nil)
         (should (= apply-count 1))
         (should (= follow-count 0))
         (should-not my-read-k--busy-p))))))

(ert-deftest my-read-k-apply-page-calls-common-followers-once ()
  (my-read-k-test--isolated
   (with-temp-buffer
     (setq my-read-k--buffer (current-buffer))
     (let ((follow-count 0))
       (cl-letf (((symbol-function 'my-read-k--refresh-followers)
                  (lambda () (cl-incf follow-count))))
         (my-read-k--apply-page '((text . "Page sentence.") (ocrMs . 1))
                                'next nil)
         (should (= follow-count 1)))))))

(ert-deftest my-read-k-background-page-update-does-not-steal-epub-tab ()
  (my-read-k-test--isolated
   (save-window-excursion
     (let* ((frame (selected-frame))
            (window (selected-window))
            (kindle-buffer (generate-new-buffer " *my-read-k-hidden-tab*"))
            (epub-buffer (generate-new-buffer " *my-read-epub-visible-tab*"))
            (speech-count 0))
       (unwind-protect
           (progn
             (setq my-read-k--frame frame my-read-k--buffer kindle-buffer)
             (set-frame-parameter frame 'my-reading-kindle-window window)
             (set-window-buffer window epub-buffer)
             (cl-letf (((symbol-function 'my-read-k--refresh-followers) #'ignore)
                       ((symbol-function 'english-reading-mode-next-sentence)
                        (lambda () (cl-incf speech-count)))
                       ((symbol-function 'english-reading-mode--speak-at-point)
                        (lambda () (cl-incf speech-count))))
               (my-read-k--apply-page
                '((text . "Updated Kindle sentence.") (ocrMs . 1)) 'next t))
             (should (eq (window-buffer window) epub-buffer))
             (should (= speech-count 0))
             (with-current-buffer kindle-buffer
               (should (equal (buffer-string) "Updated Kindle sentence.\n"))))
         (set-frame-parameter frame 'my-reading-kindle-window nil)
         (kill-buffer kindle-buffer)
         (kill-buffer epub-buffer))))))

(ert-deftest my-read-k-process-death-clears-busy-state ()
  (my-read-k-test--isolated
   (let ((process (make-process :name "my-read-k-test-exit"
                                :command '("sh" "-c" "exit 1")
                                :noquery t
                                :sentinel #'ignore)))
     (setq my-read-k--process process my-read-k--busy-p t my-read-k--state 'busy)
     (while (process-live-p process) (accept-process-output process 0.05))
     (my-read-k--process-sentinel process "exited abnormally with code 1\n")
     (should-not my-read-k--process)
     (should-not my-read-k--busy-p)
     (should (eq my-read-k--state 'detached))
     (should (equal (plist-get my-read-k--last-error :code) "BRIDGE_EXIT")))))

(ert-deftest my-read-registers-pdf-tools-as-the-pdf-viewer ()
  (should (eq (cdr (assoc "\\.pdf\\'" auto-mode-alist))
              #'pdf-view-mode)))

(ert-deftest my-read-repairs-a-dead-pdf-view-window-overlay ()
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *my-read-pdf-overlay-test*"))
          (frame (selected-frame))
          repaired-page)
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (with-current-buffer buffer
              (setq-local major-mode 'pdf-view-mode)
              (setq-local image-mode-winprops-alist
                          `((,(selected-window) (page . 7) (overlay . nil)))))
            (cl-letf (((symbol-function 'my/read-center-window)
                       (lambda (&optional _frame) (selected-window)))
                      ((symbol-function 'pdf-view-mode)
                       (lambda () (setq major-mode 'pdf-view-mode)))
                      ((symbol-function 'pdf-view-goto-page)
                       (lambda (page) (setq repaired-page page))))
              (my/read--repair-pdf-view-window buffer frame))
            (should (= repaired-page 7)))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest my-read-k-keeps-current-reader-bindings ()
  (should (commandp 'my-read))
  (should (equal (help-function-arglist #'my/read--setup-frame t)
                 '(frame &optional kindle-buffer)))
  (should (eq (lookup-key english-reading-mode-map (kbd "j"))
              #'english-reading-mode-next-sentence))
  (should (eq (lookup-key english-reading-mode-map (kbd "k"))
              #'english-reading-mode-previous-sentence))
  (should (eq (lookup-key english-reading-mode-map (kbd "SPC"))
              #'english-reading-mode-speak-current-sentence))
  (with-temp-buffer
    (setq-local major-mode 'pdf-view-mode)
    (setq-local buffer-file-name "/tmp/reader-key-test.pdf")
    (should (eq (lookup-key english-reading-mode-map (kbd "C-v"))
                #'english-reading-mode-next-page))
    (should (eq (lookup-key english-reading-mode-map (kbd "M-v"))
                #'english-reading-mode-previous-page)))
  (should-not (lookup-key english-reading-mode-map (kbd "i")))
  (should (eq (lookup-key my-read-k-mode-map (kbd "k"))
              #'my-read-k-backward))
  (should (eq (lookup-key my-read-k-mode-map (kbd "SPC"))
              #'english-reading-mode-speak-current-sentence))
  (should-not (lookup-key my-read-k-mode-map (kbd "i")))
  (should (eq (lookup-key org-noter-doc-mode-map (kbd "i"))
              #'org-noter-insert-note))
  (should (eq (lookup-key my-read-k-mode-map (kbd "<down>"))
              #'my-read-k-down))
  (should (eq (lookup-key my-read-k-mode-map (kbd "<up>"))
              #'my-read-k-up))
  (should (eq (lookup-key my-read-k-mode-map (kbd "C-n"))
              #'my-read-k-down))
  (should (eq (lookup-key my-read-k-mode-map (kbd "C-p"))
              #'my-read-k-up))
  (should (eq (lookup-key my-read-k-mode-map (kbd "C-v"))
              #'my-read-k-next-page))
  (should (eq (lookup-key my-read-k-mode-map (kbd "M-v"))
              #'my-read-k-prev-page))
  (should (eq (lookup-key my-read-k-mode-map (kbd "r"))
              #'my-read-k-reconnect))
  (with-temp-buffer
    (my-read-k-mode 1)
    (english-reading-mode 1)
    (should (eq (key-binding (kbd "r")) #'my-read-k-reconnect))
    (english-reading-mode -1)
    (my-read-k-mode -1)))

(ert-deftest my-read-keys-only-apply-in-selected-center-window ()
  (save-window-excursion
    (let* ((frame (selected-frame))
           (center (selected-window))
           (other (split-window-right))
           (buffer (generate-new-buffer " *my-read-key-scope*")))
      (unwind-protect
          (progn
            (set-frame-parameter frame 'my-reading-frame t)
            (set-frame-parameter frame 'my-reading-center-window center)
            (set-frame-parameter frame 'my-reading-center-windows (list center))
            (set-frame-parameter frame 'my-reading-epub-buffer buffer)
            (set-window-buffer center buffer)
            (with-current-buffer buffer
              (setq-local my/read-center-tab-frame frame)
              (setq-local english-reading-mode-key-active-predicate
                          #'my/read--center-window-active-p)
              (my-read-center-tab-mode 1)
              (english-reading-mode 1))
            (select-window center)
            (should (eq (key-binding (kbd "j"))
                        #'english-reading-mode-next-sentence))
            (should (eq (key-binding (kbd "k"))
                        #'english-reading-mode-previous-sentence))
            (should (eq (key-binding (kbd "SPC"))
                        #'english-reading-mode-speak-current-sentence))
            (should (eq (key-binding (kbd ";"))
                        #'my/read-next-word))
            (should (eq (key-binding (kbd "l"))
                        #'my/read-previous-word))
            (should (eq (key-binding (kbd "C-c p"))
                        #'kokoro-reader-speak-paragraph))
            ;; Even the same buffer must not carry my-read keys into a window
            ;; that is not the registered center reading pane.
            (set-window-buffer other buffer)
            (select-window other)
            (should-not (eq (key-binding (kbd "j"))
                            #'english-reading-mode-next-sentence))
            (should-not (eq (key-binding (kbd "k"))
                            #'english-reading-mode-previous-sentence))
            (should-not (eq (key-binding (kbd "SPC"))
                            #'english-reading-mode-speak-current-sentence))
            (should-not (eq (key-binding (kbd ";"))
                            #'my/read-next-word))
            (should-not (eq (key-binding (kbd "l"))
                            #'my/read-previous-word))
            (should-not (eq (key-binding (kbd "C-c p"))
                            #'kokoro-reader-speak-paragraph)))
        (set-frame-parameter frame 'my-reading-frame nil)
        (set-frame-parameter frame 'my-reading-center-window nil)
        (set-frame-parameter frame 'my-reading-center-windows nil)
        (set-frame-parameter frame 'my-reading-epub-buffer nil)
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest my-read-word-keys-move-between-word-beginnings ()
  (with-temp-buffer
    (insert "First, second third.")
    (goto-char (point-min))
    (my/read-next-word)
    (should (looking-at-p "second"))
    (my/read-next-word)
    (should (looking-at-p "third"))
    (my/read-previous-word)
    (should (looking-at-p "second"))
    (my/read-previous-word)
    (should (= (point) (point-min)))))

(ert-deftest my-read-org-buffer-is-not-registered-as-a-reading-tab ()
  (save-window-excursion
    (let* ((frame (selected-frame))
           (center (selected-window))
           (epub-buffer (generate-new-buffer " *my-read-real-epub*"))
           (org-buffer (generate-new-buffer " *my-read-org-input*")))
      (unwind-protect
          (progn
            (with-current-buffer org-buffer (org-mode))
            (set-frame-parameter frame 'my-reading-frame t)
            (set-frame-parameter frame 'my-reading-center-window center)
            (set-frame-parameter frame 'my-reading-center-windows (list center))
            (set-frame-parameter frame 'my-reading-epub-buffer epub-buffer)
            (set-window-buffer center org-buffer)
            (my/read--track-center-tab-buffer frame)
            (should (eq (frame-parameter frame 'my-reading-epub-buffer)
                        epub-buffer))
            (with-current-buffer org-buffer
              (should-not my-read-center-tab-mode)
              (should-not my/read-center-tab-frame)))
        (dolist (parameter '(my-reading-frame my-reading-center-window
                             my-reading-center-windows
                             my-reading-epub-buffer))
          (set-frame-parameter frame parameter nil))
        (kill-buffer epub-buffer)
        (kill-buffer org-buffer)))))

(ert-deftest my-read-registers-opened-files-in-source-specific-tabs ()
  (save-window-excursion
    (let* ((frame (selected-frame))
           (center (selected-window))
           (epub-buffer (generate-new-buffer " *my-read-opened-epub*"))
           (pdf-buffer (generate-new-buffer " *my-read-opened-pdf*"))
           (dired-buffer (generate-new-buffer " *my-read-opened-dired*")))
      (unwind-protect
          (progn
            (set-frame-parameter frame 'my-reading-frame t)
            (set-frame-parameter frame 'my-reading-center-window center)
            (set-frame-parameter frame 'my-reading-center-windows (list center))
            (cl-letf (((symbol-function 'my/read--configure-center-tab-buffer)
                       #'ignore)
                      ((symbol-function 'my/read-org-noter-follow-source)
                       #'ignore))
              (dolist (entry `((,dired-buffer dired-mode
                                my-reading-dired-buffer)
                               (,epub-buffer nov-mode
                                my-reading-epub-buffer)
                               (,pdf-buffer pdf-view-mode
                                my-reading-pdf-buffer)))
                (with-current-buffer (nth 0 entry)
                  (setq major-mode (nth 1 entry)))
                (set-window-buffer center (nth 0 entry))
                (my/read--track-center-tab-buffer frame)
                (should (eq (frame-parameter frame (nth 2 entry))
                            (nth 0 entry)))))
            (should (eq (frame-parameter frame 'my-reading-dired-buffer)
                        dired-buffer))
            (should (eq (frame-parameter frame 'my-reading-epub-buffer)
                        epub-buffer))
            (should (eq (frame-parameter frame 'my-reading-pdf-buffer)
                        pdf-buffer)))
        (dolist (parameter '(my-reading-frame my-reading-center-window
                             my-reading-center-windows my-reading-epub-buffer
                             my-reading-pdf-buffer my-reading-dired-buffer))
          (set-frame-parameter frame parameter nil))
        (dolist (buffer (list epub-buffer pdf-buffer dired-buffer))
          (kill-buffer buffer))))))

(ert-deftest my-read-c-x-k-closes-only-the-active-pdf ()
  (save-window-excursion
    (let* ((frame (selected-frame))
           (center (selected-window))
           (notes (split-window-right))
           (pdf-buffer (generate-new-buffer " *my-read-close-pdf*"))
           (dired-buffer (generate-new-buffer " *my-read-close-dired*"))
           (notes-buffer (generate-new-buffer " *my-read-close-notes*"))
           saved stopped session-closed)
      (unwind-protect
          (progn
            (with-current-buffer pdf-buffer
              (setq major-mode 'pdf-view-mode
                    buffer-file-name "/tmp/my-read-close.pdf"))
            (with-current-buffer dired-buffer
              (setq major-mode 'dired-mode))
            (set-window-buffer center pdf-buffer)
            (set-window-buffer notes notes-buffer)
            (set-frame-parameter frame 'my-reading-frame t)
            (set-frame-parameter frame 'my-reading-center-window center)
            (set-frame-parameter frame 'my-reading-center-windows (list center))
            (set-frame-parameter frame 'my-reading-note-window notes)
            (set-frame-parameter frame 'my-reading-pdf-buffer pdf-buffer)
            (set-frame-parameter frame 'my-reading-dired-buffer dired-buffer)
            (with-current-buffer pdf-buffer
              (setq-local my/read-center-tab-frame frame)
              (my-read-center-tab-mode 1))
            (cl-letf (((symbol-function 'my/read-position-save-buffer)
                       (lambda (buffer window)
                         (setq saved (list buffer window))))
                      ((symbol-function 'kokoro-reader-stop)
                       (lambda () (setq stopped t)))
                      ((symbol-function 'my/read-org-noter-close-source)
                       (lambda (buffer)
                         (setq session-closed buffer)
                         t))
                      ((symbol-function 'my/read-lookup-follow-post-command)
                       #'ignore)
                      ((symbol-function 'my/read-translate-follow-post-command)
                       #'ignore))
              (with-selected-window center
                (should (eq (key-binding (kbd "C-x k"))
                            #'my/read-close-pdf))
                (my/read-close-pdf)))
            (should (frame-live-p frame))
            (should-not (buffer-live-p pdf-buffer))
            (should (eq (window-buffer center) dired-buffer))
            (should (eq session-closed pdf-buffer))
            (should (equal saved (list pdf-buffer center)))
            (should stopped)
            (let ((placeholder
                   (frame-parameter frame 'my-reading-pdf-buffer)))
              (should (buffer-live-p placeholder))
              (with-current-buffer placeholder
                (should (eq my/read-center-tab-placeholder-type 'pdf)))))
        (dolist (buffer (list pdf-buffer dired-buffer notes-buffer
                              (frame-parameter frame
                                               'my-reading-pdf-buffer)
                              (frame-parameter frame
                                               'my-reading-note-ready-buffer)))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))
        (dolist (parameter '(my-reading-frame my-reading-center-window
                             my-reading-center-windows my-reading-note-window
                             my-reading-pdf-buffer my-reading-dired-buffer
                             my-reading-pdf-placeholder-buffer
                             my-reading-note-ready-buffer))
          (set-frame-parameter frame parameter nil))))))

(ert-deftest my-read-followers-ignore-org-buffer-in-center-window ()
  (save-window-excursion
    (let* ((frame (selected-frame))
           (center (selected-window))
           (epub-buffer (generate-new-buffer " *my-read-follower-epub*"))
           (org-buffer (generate-new-buffer " *my-read-follower-org*"))
           (my-read-lookup-follow-mode t)
           (my-read-translate-follow-mode t)
           lookup-called
           translate-called)
      (unwind-protect
          (progn
            (set-frame-parameter frame 'my-reading-frame t)
            (set-frame-parameter frame 'my-reading-center-window center)
            (set-frame-parameter frame 'my-reading-center-windows (list center))
            (set-frame-parameter frame 'my-reading-epub-buffer epub-buffer)
            (with-current-buffer org-buffer (org-mode))
            (set-window-buffer center org-buffer)
            (select-window center)
            (cl-letf (((symbol-function 'my/read-word-at-window)
                       (lambda (_window) (setq lookup-called t) "word"))
                      ((symbol-function 'my/read-translate-update-for-frame)
                       (lambda (_frame _window)
                         (setq translate-called t))))
              (my/read-lookup-follow-post-command)
              (my/read-translate-follow-post-command))
            (should-not lookup-called)
            (should-not translate-called))
        (dolist (parameter '(my-reading-frame my-reading-center-window
                             my-reading-center-windows
                             my-reading-epub-buffer))
          (set-frame-parameter frame parameter nil))
        (kill-buffer epub-buffer)
        (kill-buffer org-buffer)))))

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

(ert-deftest my-read-eww-math-extracts-arxiv-tex-annotation ()
  (let ((dom
         '(math ((display . "block"))
                (semantics nil
                           (mrow nil (mi nil "x"))
                           (annotation ((encoding . "application/x-tex"))
                                       " \\frac{x}{2} ")))))
    (should (equal (my/read-eww-math--tex dom) "\\frac{x}{2}"))
    (should (my/read-eww-math--display-p dom))))

(ert-deftest my-read-eww-math-rejects-dangerous-tex ()
  (should (my/read-eww-math--safe-tex-p "\\frac{x}{2}"))
  (should-not (my/read-eww-math--safe-tex-p "\\input{/etc/passwd}"))
  (should-not (my/read-eww-math--safe-tex-p "\\csname input\\endcsname"))
  (let ((my/read-eww-math-max-tex-length 3))
    (should-not (my/read-eww-math--safe-tex-p "1234"))))

(ert-deftest my-read-eww-math-queues-trusted-formula-with-text-fallback ()
  (with-temp-buffer
    (eww-mode)
    (setq-local eww-data '(:url "https://arxiv.org/html/test"))
    (setq-local my/read-eww-math--generation 7)
    (let ((inhibit-read-only t))
      (my/read-eww-math-render
       '(math nil
              (semantics nil
                         (mi nil "x")
                         (annotation ((encoding . "application/x-tex"))
                                     "x^2")))))
    (should (equal (buffer-string) "x^2"))
    (should (= (length my/read-eww-math--queue) 1))
    (should (= (plist-get (car my/read-eww-math--queue) :generation) 7))
    (should (equal (my/read-eww-math--job-region
                    (car my/read-eww-math--queue))
                   '(1 . 4)))))

(ert-deftest my-read-eww-math-keeps-untrusted-page-as-text ()
  (with-temp-buffer
    (eww-mode)
    (setq-local eww-data '(:url "https://example.com/paper"))
    (let ((inhibit-read-only t))
      (my/read-eww-math-render
       '(math nil
              (semantics nil
                         (mi nil "x")
                         (annotation ((encoding . "application/x-tex"))
                                     "x^2")))))
    (should (equal (buffer-string) "x^2"))
    (should-not my/read-eww-math--queue)))

(ert-deftest my-read-eww-math-keeps-queue-through-shr-layout-pass ()
  (with-temp-buffer
    (eww-mode)
    (setq-local eww-data '(:url "https://arxiv.org/html/test"))
    (my/read-eww-math-setup)
    (eww-display-document
     '(base ((href . "https://arxiv.org/html/test"))
            (html nil
                  (body nil
                        (p nil "A paragraph before the formula.")
                        (table nil
                               (tbody nil
                                      (tr nil
                                          (td nil
                                              (math nil
                                                    (semantics nil
                                                     (mi nil "x")
                                                     (annotation
                                                      ((encoding . "application/x-tex"))
                                                      "x^2"))))))))))
     nil (current-buffer))
    (let ((valid-job (seq-find #'my/read-eww-math--job-valid-p
                               my/read-eww-math--queue)))
      (should valid-job)
      (should (equal (plist-get valid-job :tex) "x^2")))))

(ert-deftest my-read-eww-math-embeds-foreground-and-stroke-in-svg ()
  (let ((svg-file (make-temp-file "my-read-eww-math-test-" nil ".svg"))
        (my/read-eww-math-svg-stroke-width 0.18)
        (my/read-eww-math-svg-padding 1.0))
    (unwind-protect
        (progn
          (with-temp-file svg-file
            (insert "<svg xmlns='http://www.w3.org/2000/svg' "
                    "width='10pt' height='5pt' viewBox='1 2 10 5'>"
                    "<path fill='currentColor'/></svg>"))
          (my/read-eww-math--set-svg-foreground svg-file "00FF00")
          (with-temp-buffer
            (insert-file-contents svg-file)
            (should (search-forward "<svg color='#00FF00'" nil t))
            (should (search-forward "stroke='currentColor'" nil t))
            (should (search-forward "stroke-width='0.18'" nil t))
            (should (search-forward "paint-order='stroke fill'" nil t))
            (should (search-forward "width='12.000000pt'" nil t))
            (should (search-forward "height='7.000000pt'" nil t))
            (should (search-forward "viewBox='0.000000 1.000000 12.000000 7.000000'"
                                    nil t))
            (should (search-forward "fill='currentColor'" nil t))))
      (delete-file svg-file))))

(ert-deftest my-read-eww-math-auto-scale-multiplies-font-matched-size ()
  (let ((my/read-eww-math-image-scale nil)
        (my/read-eww-math-image-scale-multiplier 1.5)
        (my/read-eww-math-inline-scale-multiplier 1.25))
    (cl-letf (((symbol-function 'face-attribute)
               (lambda (&rest _) 220)))
      (should (= (my/read-eww-math--image-scale t) 2.75))
      (should (= (my/read-eww-math--image-scale) 3.4375)))))

(ert-deftest my-read-eww-math-replacement-preserves-reading-point ()
  (with-temp-buffer
    (insert "prefix FORMULA suffix")
    (add-text-properties 8 15 '(my/read-eww-math-job 1))
    (goto-char 16)
    (let ((job (list :tex "FORMULA"
                     :display nil
                     :buffer (current-buffer)
                     :generation 0
                     :id 1)))
      (cl-letf (((symbol-function 'create-image) (lambda (&rest _) 'image))
                ((symbol-function 'insert-image)
                 (lambda (_image &optional _string _area _slice)
                   (insert "I"))))
        (my/read-eww-math--replace-placeholder job "/unused/formula.svg"))
      (should (looking-at "suffix"))
      (should (equal (buffer-string) "prefix I suffix")))))

(ert-deftest my-read-eww-math-fills-concurrent-process-slots ()
  (with-temp-buffer
    (let ((my/read-eww-math-max-processes 4)
          (my/read-eww-math--queue '(one two three four five))
          (my/read-eww-math--active-processes nil)
          compiled)
      (cl-letf (((symbol-function 'my/read-eww-math--job-valid-p)
                 (lambda (_job) t))
                ((symbol-function 'my/read-eww-math--cache-file)
                 (lambda (job) (format "/unused/%s.svg" job)))
                ((symbol-function 'file-exists-p) (lambda (_file) nil))
                ((symbol-function 'executable-find) (lambda (_program) t))
                ((symbol-function 'my/read-eww-math--compile)
                 (lambda (job _cache)
                   (push job compiled)
                   (push (make-symbol (format "process-%s" job))
                         my/read-eww-math--active-processes))))
        (my/read-eww-math--next (current-buffer)))
      (should (= (length compiled) 4))
      (should (= (length my/read-eww-math--active-processes) 4))
      (should (equal my/read-eww-math--queue '(five))))))

(ert-deftest my-read-eww-background-only-lightens-arxiv-article-images ()
  (with-temp-buffer
    (eww-mode)
    (setq-local my/read--eww-image-background-installed-p t)
    (let ((my/read-eww-article-image-background "#f5f5f5")
          (my/read-eww-article-svg-max-width 720)
          (article '(image :type svg
                          :data "<svg viewBox='-1.5 2 10.25 20.5'></svg>"))
          (formula '(image :type svg :file "/tmp/formula.svg"))
          (logo '(image :type svg :data "logo")))
      (let ((inhibit-read-only t))
        (insert "A M L")
        (put-text-property 1 2 'display article)
        (put-text-property
         1 2 'image-url
         "https://arxiv.org/html/1706.03762v7/Figures/ModalNet-20.png")
        (put-text-property 3 4 'display formula)
        (put-text-property 5 6 'display logo)
        (put-text-property
         5 6 'image-url
         "https://arxiv.org/static/base/1.0.1/images/arxiv-logo.svg"))
      (goto-char 3)
      (cl-letf (((symbol-function 'my/read--eww-rasterize-svg)
                 (lambda (_data _color) "rasterized-png")))
        (should (= (my/read--eww-apply-article-image-background) 1)))
      (should (= (point) 3))
      (should (equal (plist-get (cdr (get-text-property 1 'display))
                                :background)
                     nil))
      (should (eq (plist-get (cdr (get-text-property 1 'display)) :type)
                  'png))
      (should (equal (plist-get (cdr (get-text-property 1 'display)) :data)
                     "rasterized-png"))
      (should (numberp
               (plist-get (cdr (get-text-property 1 'display)) :scale)))
      (should-not (plist-get (cdr (get-text-property 3 'display)) :background))
      (should-not (plist-get (cdr (get-text-property 5 'display)) :background)))))

(ert-deftest my-read-eww-svg-rasterization-fallback-never-enlarges-native-svg ()
  (let ((my/read-eww-article-image-background "#f5f5f5"))
    (cl-letf (((symbol-function 'my/read--eww-rasterize-svg)
               (lambda (&rest _) nil)))
      (let* ((result
              (my/read--eww-image-with-background
               '(image :type svg
                       :scale 3.0
                       :data "<svg viewBox='0 0 10 20'></svg>")))
             (properties (cdr result)))
        (should (eq (plist-get properties :type) 'svg))
        (should (eq (plist-get properties :scale) 'default))
        (should (string-match-p "my-read-eww-background"
                                (plist-get properties :data)))))))

(ert-deftest my-read-eww-rasterizes-svg-to-png-with-librsvg ()
  (skip-unless (executable-find my/read-eww-svg-raster-program))
  (let ((my/read-eww-article-svg-max-width 2))
    (let ((png (my/read--eww-rasterize-svg
                "<svg xmlns='http://www.w3.org/2000/svg' width='2' height='2'/>"
                "#f5f5f5")))
      (should (string-prefix-p (unibyte-string #x89 ?P ?N ?G) png)))))

(ert-deftest my-read-unified-layout-has-left-reading-and-right-utility-panes ()
  (save-window-excursion
    (let* ((frame (selected-frame))
           (kindle-buffer (generate-new-buffer " *my-read-layout-kindle*"))
           (epub-buffer (generate-new-buffer " *my-read-layout-epub*"))
           (dired-buffer (generate-new-buffer " *my-read-layout-dired*"))
           (my/read-book-path "/virtual/book.epub")
           (lookup-frame-height
            (frame-parameter frame 'lookup-window-height))
           opened-paths)
      (unwind-protect
          (cl-letf (((symbol-function 'find-file)
                     (lambda (path)
                       (push path opened-paths)
                       (switch-to-buffer epub-buffer)
                       (setq major-mode 'nov-mode)))
                    ((symbol-function 'dired-noselect)
                     (lambda (_directory) dired-buffer))
                    ((symbol-function 'my-read-lookup-follow-mode) #'ignore)
                    ((symbol-function 'my-read-translate-follow-mode) #'ignore)
                    ((symbol-function 'my/read-lookup-follow-post-command) #'ignore)
                    ((symbol-function 'my/read-translate-follow-post-command) #'ignore)
                    ((symbol-function 'my/read-org-noter-follow-source) #'ignore))
            (set-frame-parameter frame 'my-reading-frame t)
            (my/read--setup-frame frame kindle-buffer)
            (let ((kindle-window (my/read-kindle-window frame))
                  (epub-window (my/read-epub-window frame))
                  (pdf-window (my/read-pdf-window frame))
                  (dired-window (my/read-dired-window frame))
                  (eww-window (my/read-eww-window frame))
                  (translate-window (my/read-translate-window frame))
                  (lookup-window (my/read-lookup-window frame))
                  (note-window (my/read-note-window frame))
                  (pdf-buffer (frame-parameter frame 'my-reading-pdf-buffer))
                  (eww-buffer (frame-parameter frame 'my-reading-eww-buffer)))
              (should (= (length (window-list frame)) 4))
              (should (window-live-p kindle-window))
              (should (window-live-p epub-window))
              (should (window-live-p pdf-window))
              (should (window-live-p dired-window))
              (should (window-live-p eww-window))
              (should (window-live-p translate-window))
              (should (window-live-p lookup-window))
              (should (window-live-p note-window))
              (should (eq kindle-window epub-window))
              (should (eq epub-window pdf-window))
              (should (eq pdf-window dired-window))
              (should (eq epub-window eww-window))
              (let ((reading-edges (window-edges kindle-window))
                    (note-edges (window-edges note-window))
                    (translate-edges (window-edges translate-window))
                    (lookup-edges (window-edges lookup-window)))
                (should (> (car note-edges) (car reading-edges)))
                (should (> (car translate-edges) (car reading-edges)))
                (should (= (car note-edges) (car translate-edges)))
                (should (= (car translate-edges) (car lookup-edges)))
                (should (= (cadr note-edges) (cadr reading-edges)))
                (should (> (cadr translate-edges) (cadr note-edges)))
                (should (> (cadr lookup-edges) (cadr translate-edges)))
                (should (= (nth 3 lookup-edges) (nth 3 reading-edges))))
              (should (eq (frame-parameter frame 'my-reading-note-window)
                          note-window))
              (with-current-buffer (window-buffer note-window)
                (should (derived-mode-p 'org-mode)))
              (should (= (frame-parameter frame 'lookup-window-height)
                         my/read-lookup-entry-window-height))
              (should (equal opened-paths
                             (list (expand-file-name my/read-book-path))))
              (should (= (length (my/read-center-windows frame)) 1))
              (should (eq (window-buffer dired-window) dired-buffer))
              (with-current-buffer kindle-buffer
                (should my-read-center-tab-mode)
                (should (equal (my/read-center-tab-buffers)
                               (list dired-buffer kindle-buffer pdf-buffer
                                     epub-buffer eww-buffer)))
                (should (equal (mapcar #'my/read-center-tab-name
                                       (my/read-center-tab-buffers))
                               '(" DIRED " " KINDLE " " PDF " " EPUB "
                                 " EWW ")))
                (with-current-buffer pdf-buffer
                  (should (eq my/read-center-tab-placeholder-type 'pdf))))
              (set-window-buffer kindle-window eww-buffer)
              (with-current-buffer eww-buffer
                (should (equal (plist-get eww-data :url) my/read-eww-url))
                (should (= line-spacing my/read-eww-line-spacing))
                (should (eq (cdr (assq 'math
                                       shr-external-rendering-functions))
                            #'my/read-eww-math-render))
                (should english-reading-mode)
                (should (eq (key-binding (kbd "j"))
                            #'english-reading-mode-next-sentence))
                (should (eq (key-binding (kbd "k"))
                            #'english-reading-mode-previous-sentence))
                (should (eq (key-binding (kbd "SPC"))
                            #'english-reading-mode-speak-current-sentence))
                (should-not (eq (key-binding (kbd "i"))
                                #'english-reading-mode-previous-sentence))
                (should (eq (key-binding (kbd "l"))
                            #'my/read-previous-word))
                (should (eq (key-binding (kbd ";"))
                            #'my/read-next-word)))
              (set-window-buffer dired-window dired-buffer)
              (my/read-toggle-center-tab)
              (should (eq (window-buffer kindle-window) kindle-buffer))
              (my/read-toggle-center-tab)
              (should (eq (window-buffer pdf-window) pdf-buffer))
              (my/read-toggle-center-tab)
              (should (eq (window-buffer epub-window) epub-buffer))
              (my/read-toggle-center-tab)
              (should (eq (window-buffer eww-window) eww-buffer))
              (should-not (my/read--center-automatic-lookup-p eww-window))
              (let ((my/read-eww-enable-automatic-lookup t))
                (should (my/read--center-automatic-lookup-p eww-window)))
              (my/read-toggle-center-tab)
              (should (eq (window-buffer dired-window) dired-buffer))))
        (dolist (buffer (list kindle-buffer epub-buffer dired-buffer
                              (frame-parameter frame 'my-reading-pdf-buffer)
                              (frame-parameter frame 'my-reading-eww-buffer)
                              (frame-parameter frame 'my-reading-translate-buffer)
                              (frame-parameter frame 'my-reading-lookup-ready-buffer)
                              (frame-parameter frame 'my-reading-note-ready-buffer)))
          (when (buffer-live-p buffer) (kill-buffer buffer)))
        (dolist (parameter '(my-reading-frame my-reading-center-window
                             my-reading-center-windows my-reading-kindle-window
                             my-reading-epub-window my-reading-pdf-window
                             my-reading-dired-window my-reading-eww-window
                             my-reading-kindle-buffer my-reading-epub-buffer
                             my-reading-pdf-buffer my-reading-dired-buffer
                             my-reading-kindle-placeholder-buffer
                             my-reading-pdf-placeholder-buffer
                             my-reading-epub-placeholder-buffer
                             my-reading-lookup-window my-reading-translate-window
                             my-reading-note-window my-reading-note-ready-buffer))
          (set-frame-parameter frame parameter nil))
        (set-frame-parameter frame 'my-reading-translate-buffer nil)
        (set-frame-parameter frame 'my-reading-lookup-ready-buffer nil)
        (set-frame-parameter frame 'my-reading-note-ready-buffer nil)
        (set-frame-parameter frame 'my-reading-eww-buffer nil)
        (set-frame-parameter frame 'lookup-window-height
                             lookup-frame-height)))))

(ert-deftest my-read-k-r-restarts-the-connection ()
  (let ((my-read-k--reconnect-function
         (lambda () (interactive) 'reconnected)))
    (should (eq (call-interactively #'my-read-k-reconnect) 'reconnected))))

(ert-deftest my-read-lookup-entry-keys-dispatch-in-pane-and-restore-center ()
  (my-read-k-test--isolated
   (save-window-excursion
     (let* ((frame (selected-frame))
            (center (selected-window))
            (lookup (split-window-right))
            (lookup-buffer (generate-new-buffer " *my-read-lookup-test*"))
            (seen nil))
       (unwind-protect
           (progn
             (set-frame-parameter frame 'my-reading-frame t)
             (set-frame-parameter frame 'my-reading-center-window center)
             (set-frame-parameter frame 'my-reading-lookup-window lookup)
             (set-window-buffer lookup lookup-buffer)
             (with-current-buffer lookup-buffer
               (let ((map (make-sparse-keymap)))
                 (define-key map (kbd "n")
                             (lambda ()
                               (interactive)
                               (push (list 'next (selected-window)) seen)))
                 (define-key map (kbd "p")
                             (lambda ()
                               (interactive)
                               (push (list 'previous (selected-window)) seen)))
                 (use-local-map map)))
             (select-window center)
             (my/read-lookup-next-entry)
             (should (eq (selected-window) center))
             (my/read-lookup-previous-entry)
             (should (eq (selected-window) center))
             (should (equal seen
                            (list (list 'previous lookup)
                                  (list 'next lookup)))))
         (set-frame-parameter frame 'my-reading-frame nil)
         (set-frame-parameter frame 'my-reading-center-window nil)
         (set-frame-parameter frame 'my-reading-lookup-window nil)
         (when (buffer-live-p lookup-buffer)
           (kill-buffer lookup-buffer)))))))

(ert-deftest my-read-lookup-builds-and-caches-private-dictionary-module ()
  (let ((my/read-lookup-dictionary-ids '("dict-a" "dict-b:one"))
        (my/read--lookup-module nil)
        (my/read--lookup-module-signature nil)
        specs
        setups)
    (cl-letf (((symbol-function 'my/read--lookup-ensure-runtime)
               (lambda () t))
              ((symbol-function 'lookup-new-module)
               (lambda (spec)
                 (push spec specs)
                 (list 'private-module spec)))
              ((symbol-function 'lookup-module-setup)
               (lambda (module) (push module setups))))
      (let ((first (my/read--lookup-reading-module))
            (second (my/read--lookup-reading-module)))
        (should (eq first second))
        (should (equal specs '(("%my-read" "dict-a" "dict-b:one"))))
        (should (= (length setups) 1)))
      (setq my/read-lookup-dictionary-ids '("dict-c"))
      (my/read--lookup-reading-module)
      (should (equal (car specs) '("%my-read" "dict-c")))
      (should (= (length setups) 2)))))

(ert-deftest my-read-lookup-pattern-advice-uses-private-module-only-in-frame ()
  (let (calls)
    (cl-letf (((symbol-function 'my/read-frame-p) (lambda (&optional _) t))
              ((symbol-function 'my/read--lookup-reading-module)
               (lambda () 'private-module)))
      (my/read--lookup-pattern-around
       (lambda (pattern module) (push (list pattern module) calls))
       "word" nil)
      (my/read--lookup-pattern-around
       (lambda (pattern module) (push (list pattern module) calls))
       "word" 'explicit-module))
    (should (equal calls
                   '(("word" explicit-module)
                     ("word" private-module))))))

(defmacro my-read-vocab-test--with-file (&rest body)
  `(let* ((file (make-temp-file "my-read-vocabulary-" nil ".org"))
          (my/read-vocabulary-file file))
     (unwind-protect
         (progn ,@body)
       (when-let ((buffer (get-file-buffer file)))
         (set-buffer-modified-p nil)
         (kill-buffer buffer))
       (when (file-exists-p file)
         (delete-file file)))))

(defun my-read-vocab-test--data (term type timestamp book sentence
                                      &optional meaning translation)
  (list :term term :type type :timestamp timestamp :book book
        :sentence sentence :meaning meaning :translation translation))

(ert-deftest my-read-vocabulary-target-prefers-region-and-normalizes-whitespace ()
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (insert "She felt anxiety in spite\n   of everything.")
      (goto-char (point-min))
      (search-forward "anxiety")
      (backward-word)
      (should (equal (my/read-vocab-target-at-point (selected-window))
                     "anxiety"))
      (search-forward "in spite")
      (set-mark (match-beginning 0))
      (search-forward "of")
      (setq transient-mark-mode t)
      (activate-mark)
      (should (equal (my/read-vocab-target-at-point (selected-window))
                     "in spite of"))
      (deactivate-mark)
      (erase-buffer)
      (insert "   ")
      (goto-char (point-min))
      (should-not (my/read-vocab-target-at-point (selected-window))))))

(ert-deftest my-read-vocabulary-capture-deactivates-selected-region ()
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (insert "In spite of everything, she went.")
      (goto-char (point-min))
      (set-mark (point))
      (search-forward "in spite of")
      (setq transient-mark-mode t)
      (activate-mark)
      (should (use-region-p))
      (cl-letf (((symbol-function 'my/read--center-window-active-p)
                 (lambda () t))
                ((symbol-function 'my/read-vocab-lookup-meaning)
                 (lambda (_term _callback &rest _))))
        (my/read-vocab-capture))
      (should-not mark-active))))

(ert-deftest my-read-vocabulary-normalized-key-folds-case-and-punctuation ()
  (should (equal (my/read-vocab-normalize-key " Anxiety, ") "anxiety"))
  (should (equal (my/read-vocab-normalize-key "  In\n spite   of! ")
                 "in spite of")))

(ert-deftest my-read-vocabulary-key-is-local-to-center-tab-mode ()
  ;; Inspect the raw map entry because `lookup-key' applies the center-window
  ;; menu-item filter, which is intentionally false in this isolated test.
  (let ((binding (cdr (assq ?u my-read-center-tab-mode-map))))
    (should (eq (nth 2 binding) 'my/read-vocab-capture)))
  (should-not (eq (lookup-key global-map (kbd "u"))
                  'my/read-vocab-capture)))

(ert-deftest my-read-vocabulary-title-reuses-kindle-metadata ()
  (let ((frame (selected-frame))
        (buffer (generate-new-buffer " *my-read-vocabulary-title*")))
    (unwind-protect
        (progn
          (set-frame-parameter frame 'my-reading-kindle-buffer buffer)
          (set-frame-parameter frame 'my-reading-kindle-book-name
                               "Some Light Novel Vol. 1")
          (should (equal (my/read-vocab-current-book-title buffer frame)
                         "Some Light Novel Vol. 1")))
      (set-frame-parameter frame 'my-reading-kindle-buffer nil)
      (set-frame-parameter frame 'my-reading-kindle-book-name nil)
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest my-read-vocabulary-meaning-collects-english-and-japanese-content ()
  (save-window-excursion
    (let* ((frame (selected-frame))
           (center (selected-window))
           (lookup-current-session 'test-session)
           results)
      (cl-letf (((symbol-function 'require) (lambda (&rest _) t))
                ((symbol-function 'lookup-pattern) (lambda (&rest _) t))
                ((symbol-function 'my/read--lookup-reading-module)
                 (lambda () 'private-module))
                ((symbol-function 'lookup-session-entries)
                 (lambda (_session) '(english-entry japanese-entry)))
                ((symbol-function 'lookup-entry-dictionary) #'identity)
                ((symbol-function 'lookup-dictionary-title)
                 (lambda (dictionary)
                   (if (eq dictionary 'english-entry)
                       "English"
                     "Japanese - English")))
                ((symbol-function 'my/read-vocab--lookup-entry-content)
                 (lambda (entry)
                   (if (eq entry 'english-entry)
                       "noun a loud and confused noise."
                     "名詞 騒音、喧噪。"))))
        (my/read-vocab-lookup-meaning
         "clamor" (lambda (value) (setq results value)) frame center))
      (should (equal (plist-get results :english-title) "English"))
      (should (string-match-p "loud and confused"
                              (plist-get results :english)))
      (should (equal (plist-get results :japanese-title)
                     "Japanese - English"))
      (should (string-match-p "喧噪" (plist-get results :japanese))))))

(ert-deftest my-read-vocabulary-meaning-formats-three-sources ()
  (let ((meaning
         (my/read-vocab--format-meaning
          '(:english-title "English"
            :english "noun a loud and confused noise."
            :japanese-title "Japanese - English"
            :japanese "名詞 騒音、喧噪。")
          "騒音")))
    (should (string-match-p "English-English \\[English\\]:" meaning))
    (should (string-match-p "English-Japanese \\[Japanese - English\\]:"
                            meaning))
    (should (string-match-p "Google Translate:\n騒音" meaning))))

(ert-deftest my-read-vocabulary-new-entry-has-canonical-structure ()
  (my-read-vocab-test--with-file
   (should
    (equal
     (my/read-vocab--write
      (my-read-vocab-test--data
       "Anxiety," 'word "[2026-08-23 Sun 07:20]" "Novel One"
       "She felt anxiety." "不安、心配" "彼女は不安を感じた。"))
     '(added . 1)))
   (with-temp-buffer
     (insert-file-contents my/read-vocabulary-file)
     (let ((text (buffer-string)))
       (should (= (how-many "^\\* Anxiety$" (point-min) (point-max)) 1))
       (should (string-match-p "^:TYPE: word$" text))
       (should (string-match-p "^:CREATED: \\[2026-08-23 Sun 07:20\\]$" text))
       (should (string-match-p "^:UPDATED: \\[2026-08-23 Sun 07:20\\]$" text))
       (should (string-match-p "^:COUNT: 1$" text))
       (should (string-match-p "^\\*\\* Meaning$" text))
       (should (string-match-p "^\\*\\* Examples$" text))
       (should (= (how-many "^\\*\\*\\* " (point-min) (point-max)) 1))))))

(ert-deftest my-read-vocabulary-existing-entry-merges-and-increments ()
  (my-read-vocab-test--with-file
   (my/read-vocab--write
    (my-read-vocab-test--data
     "Anxiety" 'word "[2026-08-23 Sun 07:20]" "Novel One"
     "She felt anxiety." "不安" "彼女は不安を感じた。"))
   (should
    (equal
     (my/read-vocab--write
      (my-read-vocab-test--data
       " anxiety, " 'word "[2026-08-23 Sun 07:26]" "Novel Two"
       "His anxiety vanished." "不安、心配、不安感" "彼の不安は消えた。"))
     '(saved . 2)))
   (with-temp-buffer
     (insert-file-contents my/read-vocabulary-file)
     (let ((text (buffer-string)))
       (should (= (how-many "^\\* Anxiety$" (point-min) (point-max)) 1))
       (should (string-match-p "^:COUNT:[ \t]+2$" text))
       (should (string-match-p
                "^:UPDATED:[ \t]+\\[2026-08-23 Sun 07:26\\]$" text))
       (should (= (how-many "^\\*\\*\\* " (point-min) (point-max)) 2))
       (should (string-match-p "不安、心配、不安感" text))
       (should (string-match-p "Novel One" text))
       (should (string-match-p "Novel Two" text))))))

(ert-deftest my-read-vocabulary-region-entry-is-a-phrase ()
  (my-read-vocab-test--with-file
   (my/read-vocab--write
    (my-read-vocab-test--data
     "in spite of" 'phrase "[2026-08-23 Sun 08:10]" "Novel One"
     "In spite of everything, she went." nil "それでも彼女は行った。"))
   (with-temp-buffer
     (insert-file-contents my/read-vocabulary-file)
     (should (string-match-p "^\\* in spite of$" (buffer-string)))
     (should (string-match-p "^:TYPE: phrase$" (buffer-string))))))

(ert-deftest my-read-vocabulary-malformed-entry-is-left-unchanged ()
  (my-read-vocab-test--with-file
   (with-temp-file my/read-vocabulary-file
     (insert "* anxiety\n:PROPERTIES:\n:COUNT: 1\n:END:\n"))
   (let ((before (with-temp-buffer
                   (insert-file-contents my/read-vocabulary-file)
                   (buffer-string))))
     (should-error
      (my/read-vocab--write
       (my-read-vocab-test--data
        "anxiety" 'word "[2026-08-23 Sun 09:00]" "Novel"
        "Anxiety remained." nil nil)))
     (should
      (equal before
             (with-temp-buffer
               (insert-file-contents my/read-vocabulary-file)
               (buffer-string)))))))

(ert-deftest my-read-vocabulary-capture-survives-missing-services ()
  (my-read-vocab-test--with-file
   (save-window-excursion
     (let* ((frame (selected-frame))
            (window (selected-window))
            (buffer (generate-new-buffer "my-read-vocab-capture-test"))
            term-backend)
       (unwind-protect
           (progn
             (set-window-buffer window buffer)
             (set-frame-parameter frame 'my-reading-frame t)
             (set-frame-parameter frame 'my-reading-center-window window)
             (set-frame-parameter frame 'my-reading-center-windows (list window))
             (set-frame-parameter frame 'my-reading-kindle-buffer buffer)
             (with-current-buffer buffer
               (insert "She felt anxiety about the situation.")
               (goto-char (point-min))
               (search-forward "anxiety")
               (backward-word)
               (setq-local my/read-center-tab-frame frame))
             (cl-letf (((symbol-function 'my/read-vocab-lookup-meaning)
                        (lambda (_term callback &rest _)
                          (funcall callback nil)))
                       ((symbol-function 'my/read-vocab-translate-text)
                        (lambda (_text callback &optional backend &rest _)
                          (setq term-backend backend)
                          (funcall callback nil)))
                       ((symbol-function 'my/read-vocab-translate-sentence)
                        (lambda (_sentence callback &rest _)
                          (funcall callback nil))))
               (with-current-buffer buffer
                 (my/read-vocab-capture)))
             (should (eq term-backend 'google))
             (with-temp-buffer
               (insert-file-contents my/read-vocabulary-file)
               (let ((text (buffer-string)))
                 (should (string-match-p "^\\* anxiety$" text))
                 (should (string-match-p "She felt anxiety about the situation\\." text))
                 (should (string-match-p "^Japanese:$" text)))))
         (set-frame-parameter frame 'my-reading-frame nil)
         (set-frame-parameter frame 'my-reading-center-window nil)
         (set-frame-parameter frame 'my-reading-center-windows nil)
         (set-frame-parameter frame 'my-reading-kindle-buffer nil)
         (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(provide 'my-read-k-tests)
;;; my-read-k-tests.el ends here
