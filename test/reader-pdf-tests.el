;;; reader-pdf-tests.el --- Pdf regressions -*- lexical-binding: t; -*-

(require 'reader-test-helpers)

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

(ert-deftest my-read-japanese-pdf-helper-auto-selects-japanese-speech ()
  (with-temp-buffer
    (insert "応 用 情 報 技 術 者。")
    (english-reading-mode--normalize-pdf-japanese-spacing)
    (run-hooks 'english-reading-mode-pdf-text-buffer-hook)
    (should (equal (buffer-string) "応用情報技術者。"))
    (should (equal my/read-source-language "ja"))
    (should (eq kokoro-reader-backend 'macos))
    (should (equal kokoro-reader-macos-voice "Kyoko"))))

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
          (let (advanced)
            (cl-letf (((symbol-function 'english-reading-mode--continuous-next)
                       (lambda () (setq advanced t))))
              (funcall scheduled))
            (should advanced))
          (should (zerop scheduled-delay)))
      (kill-buffer pdf-buffer)
      (kill-buffer text-buffer))))

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
            ;; PDF Tools expands current-page to image-mode-window-get when compiled.
            (cl-letf (((symbol-function 'image-mode-window-get)
                       (lambda (property &optional _window)
                         (when (eq property 'page) shown-page)))
                      ((symbol-function 'pdf-view-current-page)
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

(ert-deftest english-reading-mode-pdf-roll-boundary-renders-next-visible-page ()
  ;; A 1000px page fills the 600px viewport at the old offset of zero.
  ;; At the destination offset of 900, page 5 must already be rendered.
  (let ((offset 0) visible-pages)
    (cl-letf (((symbol-function 'image-mode-window-put) #'ignore)
              ((symbol-function 'pdf-roll-set-vscroll)
               (lambda (value _window) (setq offset value)))
              ((symbol-function 'pdf-roll-display-pages)
               (lambda (page _window)
                 (setq visible-pages
                       (if (< (- 1000 offset) 600)
                           (list page (1+ page))
                         (list page)))))
              ((symbol-function 'pdf-roll-page-to-pos) #'identity)
              ((symbol-function 'set-window-start) #'ignore)
              ((symbol-function 'force-window-update) #'ignore))
      (english-reading-mode--pdf-roll-set-position 4 900 'test-window)
      (should (equal visible-pages '(4 5))))))

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
                            #'my/read-close-document))
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

(provide 'reader-pdf-tests)
