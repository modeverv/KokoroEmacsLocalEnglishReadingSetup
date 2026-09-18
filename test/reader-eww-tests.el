;;; reader-eww-tests.el --- Eww regressions -*- lexical-binding: t; -*-

(require 'reader-test-helpers)

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

(ert-deftest my-read-local-html-renders-in-eww-tab ()
  (require 'eww)
  (save-window-excursion
    (let* ((frame (selected-frame))
           (saved-parameters (frame-parameters frame))
           (center (selected-window))
           (directory (make-temp-file "my-read-html-" t))
           (my/read-position-directory directory)
           (file (expand-file-name "local page.HTML" directory))
           (source nil)
           (web (generate-new-buffer " *my-read-html-eww*"))
           (eww-retrieve-command nil)
           (shr-use-fonts nil)
           (shr-width 80))
      (unwind-protect
          (cl-letf (((symbol-function 'my/read-org-noter-follow-source) #'ignore))
            (with-temp-file file
              (insert "<!doctype html><html><head><meta charset='utf-8'><title>Local Test</title></head><body><h1>Rendered heading</h1><p>本文です。</p><a href='next.html'>Next page</a></body></html>"))
            (setq source (find-file-noselect file))
            (with-current-buffer web (eww-mode))
            (set-frame-parameter frame 'my-reading-eww-buffer web)
            (set-frame-parameter frame 'my-reading-center-window center)
            (set-frame-parameter frame 'my-reading-center-windows (list center))
            ;; Ordinary editing outside my-read stays an HTML source buffer.
            (set-frame-parameter frame 'my-reading-frame nil)
            (set-window-buffer center source)
            (my/read--track-center-tab-buffer frame)
            (should (eq (window-buffer center) source))
            (set-frame-parameter frame 'my-reading-frame t)
            (my/read--track-center-tab-buffer frame)
            (should (eq (window-buffer center) web))
            (with-current-buffer web
              (let ((deadline (+ (float-time) 3)))
                (while (and (not (plist-get eww-data :dom))
                            (< (float-time) deadline))
                  (accept-process-output nil 0.01)))
              (should (derived-mode-p 'eww-mode))
              (should (equal (plist-get eww-data :title) "Local Test"))
              (should (string-match-p "Rendered heading" (buffer-string)))
              (should (string-match-p "本文です。" (buffer-string)))
              (should-not (string-match-p "<h1>" (buffer-string)))
              (should english-reading-mode)
              (should (equal my/read-source-language "ja"))
              (should (equal (my/read-center-tab-name web) " EWW "))
              (goto-char (point-min))
              (search-forward "Next page")
              (should (string-suffix-p "/next.html"
                                       (get-text-property (1- (point)) 'shr-url))))
            ;; Reopening must save the old rendered position before erasing,
            ;; then restore it after the new DOM has been rendered.
            (with-selected-window center
              (goto-char (point-min))
              (search-forward "本文")
              (let ((saved (point)))
                (my/read--open-html-in-eww file frame)
                (should (= (point) saved))
                (should (eq (my/read-position--source-type) 'html))
                (should (equal (my/read-position--source-file)
                               (file-truename file)))
                (let ((next (expand-file-name "other.html" directory)))
                  (with-temp-file next
                    (insert "<html><body>Another document.</body></html>"))
                  (my/read--open-html-in-eww next frame)
                  (should (= (point) (point-min)))
                  (my/read--open-html-in-eww file frame)
                  (should (= (point) saved)))))
            (should (buffer-live-p source))
            (with-current-buffer source (should-not (buffer-modified-p))))
        (dolist (parameter '(my-reading-frame my-reading-eww-buffer
                             my-reading-center-window my-reading-center-windows))
          (set-frame-parameter frame parameter
                               (cdr (assq parameter saved-parameters))))
        (when (buffer-live-p source) (kill-buffer source))
        (kill-buffer web)
        (delete-directory directory t)))))

(ert-deftest my-read-close-eww-keeps-workspace-and-replaces-page ()
  (save-window-excursion
    (let* ((frame (selected-frame))
           (parameters (frame-parameters frame))
           (center (selected-window))
           (page (generate-new-buffer " *close-eww-page*"))
           (dired (generate-new-buffer " *close-eww-dired*"))
           (ready (generate-new-buffer " *close-eww-ready*"))
           saved closed)
      (unwind-protect
          (cl-letf (((symbol-function 'my/read-position-save-buffer)
                     (lambda (buffer &optional _window) (setq saved buffer)))
                    ((symbol-function 'english-reading-mode-stop-continuous) #'ignore)
                    ((symbol-function 'my/read-org-noter-close-source)
                     (lambda (buffer)
                       (should (eq (window-buffer center) dired))
                       (setq closed buffer)))
                    ((symbol-function 'my/read--prepare-eww-buffer)
                     (lambda (f)
                       (set-frame-parameter f 'my-reading-eww-buffer ready)
                       ready))
                    ((symbol-function 'my/read-lookup-follow-post-command) #'ignore)
                    ((symbol-function 'my/read-translate-follow-post-command) #'ignore))
            (with-current-buffer page (eww-mode))
            (set-frame-parameter frame 'my-reading-frame t)
            (set-frame-parameter frame 'my-reading-center-window center)
            (set-frame-parameter frame 'my-reading-center-windows (list center))
            (set-frame-parameter frame 'my-reading-note-window nil)
            (set-frame-parameter frame 'my-reading-eww-buffer page)
            (set-frame-parameter frame 'my-reading-dired-buffer dired)
            (switch-to-buffer page)
            (my/read--configure-center-tab-buffer page frame)
            (should (eq (key-binding (kbd "C-x C-k")) #'my/read-close-eww))
            (call-interactively (key-binding (kbd "C-x C-k")))
            (should (eq saved page))
            (should (eq closed page))
            (should-not (buffer-live-p page))
            (should (frame-live-p frame))
            (should (eq (window-buffer center) dired))
            (should (eq (frame-parameter frame 'my-reading-eww-buffer) ready)))
        (dolist (key '(my-reading-frame my-reading-center-window
                       my-reading-center-windows my-reading-note-window
                       my-reading-eww-buffer my-reading-dired-buffer))
          (set-frame-parameter frame key (cdr (assq key parameters))))
        (dolist (buffer (list page dired ready))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(provide 'reader-eww-tests)
