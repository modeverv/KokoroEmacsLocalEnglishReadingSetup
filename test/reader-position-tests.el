;;; reader-position-tests.el --- Position regressions -*- lexical-binding: t; -*-

(require 'reader-test-helpers)

(ert-deftest my-read-positions-use-obsidian-read-log-directory ()
  (should
   (equal my/read-position-directory
          "/Users/seijiro/Library/Mobile Documents/iCloud~md~obsidian/Documents/seijiro/000_org/read-log"))
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
          ;; PDF Tools expands current-page to image-mode-window-get when compiled.
          (cl-letf (((symbol-function 'image-mode-window-get)
                     (lambda (property &optional _window)
                       (when (eq property 'page) 12)))
                    ((symbol-function 'pdf-view-current-page)
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
            ;; PDF Tools expands current-page to image-mode-window-get when compiled.
            (cl-letf (((symbol-function 'image-mode-window-get)
                       (lambda (property &optional _window)
                         (when (eq property 'page) 1)))
                      ((symbol-function 'pdf-view-current-page)
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
              (vscroll 275 test-window)
              (display 4 test-window)
              (start test-window 104 t)
              (force test-window))))))

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

(ert-deftest my-read-text-position-persists-speech-and-restores-on-reopen ()
  (save-window-excursion
    (let* ((my/read-position-directory (make-temp-file "my-read-text-pos-" t))
           (frame (selected-frame))
           (saved-parameters (frame-parameters frame))
           (file (expand-file-name "book.org" my/read-position-directory))
           source)
      (unwind-protect
          (progn
            (with-temp-file file (insert "* Heading\nFirst sentence.\nSecond sentence.\n"))
            (setq source (find-file-noselect file))
            (switch-to-buffer source)
            (set-frame-parameter frame 'my-reading-frame t)
            (set-frame-parameter frame 'my-reading-center-window (selected-window))
            (set-frame-parameter frame 'my-reading-center-windows (list (selected-window)))
            (set-frame-parameter frame 'my-reading-text-buffer source)
            (my/read--configure-center-tab-buffer source frame)
            (goto-char 27)
            ;; Persist the speech start, rather than an already advanced cursor.
            (my/read-position--speech-start
             (list :buffer source :frame frame :window (selected-window) :beg 11))
            (let* ((data (my/read-position--read-data))
                   (record (cdr (assoc (file-truename file) (plist-get data :entries)))))
              (should (eq (plist-get record :type) 'text))
              (should (= (plist-get record :point) 11)))
            ;; Closing after moving manually saves the new reading position.
            (kill-buffer source)
            (setq source (find-file-noselect file))
            (switch-to-buffer source)
            (my/read--configure-center-tab-buffer source frame)
            (should (= (point) 27))
            (goto-char 30)
            (my/read--configure-center-tab-buffer source frame)
            (should (= (point) 30))
            ;; Shortened files clamp stale offsets instead of failing.
            (my/read-position--restore-text '(:point 9999 :window-start 9999)
                                            (selected-window))
            (should (= (point) (point-max))))
        (when (buffer-live-p source) (kill-buffer source))
        (dolist (parameter '(my-reading-frame my-reading-center-window
                             my-reading-center-windows my-reading-text-buffer))
          (set-frame-parameter frame parameter (cdr (assq parameter saved-parameters))))
        (delete-directory my/read-position-directory t)))))

(provide 'reader-position-tests)
