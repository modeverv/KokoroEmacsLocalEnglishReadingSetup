;;; reader-notes-tests.el --- Notes regressions -*- lexical-binding: t; -*-

(require 'reader-test-helpers)

(ert-deftest my-read-note-insertion-focus-and-return ()
  (save-window-excursion
    (let* ((frame (selected-frame))
           (center (selected-window))
           (notes-window (split-window-right))
           (notes (generate-new-buffer " *note-focus-test*"))
           (session (make-org-noter--session :notes-buffer notes))
           (org-noter--session session))
      (unwind-protect
          (cl-letf (((symbol-function 'my/read-frame-p) (lambda (&optional _) t))
                    ((symbol-function 'my/read-center-window) (lambda (&optional _) center))
                    ((symbol-function 'my/read-note-window) (lambda (&optional _) notes-window)))
            (set-window-buffer notes-window notes)
            ;; Model Org-noter's final highlight step returning to the source.
            (should (eq (my/read-org-noter--focus-inserted-note
                         (lambda () (select-window center) 'inserted)) 'inserted))
            (should (eq (selected-window) notes-window))
            (should (eq (key-binding (kbd "C-c b")) #'my/read-focus-center))
            (call-interactively (key-binding (kbd "C-c b")))
            (should (eq (selected-window) center))
            ;; An aborted insertion must not move focus.
            (should-error
             (my/read-org-noter--focus-inserted-note (lambda () (error "Cancelled"))))
            (should (eq (selected-window) center)))
        (kill-buffer notes)))))

(ert-deftest my-read-workspace-return-key-is-frame-scoped ()
  (cl-letf (((symbol-function 'my/read-frame-p) (lambda (&optional _) nil)))
    (should-not (eq (key-binding (kbd "C-c b")) #'my/read-focus-center))
    (should-error (my/read-focus-center) :type 'user-error)))

(ert-deftest my-read-org-noter-uses-obsidian-read-directory ()
  (should
   (equal my/read-org-noter-directory
          "/Users/seijiro/Library/Mobile Documents/iCloud~md~obsidian/Documents/seijiro/000_org/read")))

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

(provide 'reader-notes-tests)
