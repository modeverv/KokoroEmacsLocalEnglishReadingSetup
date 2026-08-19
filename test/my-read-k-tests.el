;;; my-read-k-tests.el --- Tests for my-read-k -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

;; `my-read.el' references this optional package at runtime.  The tests stub
;; network-facing functions and need only the feature to load the local code.
(unless (featurep 'google-translate-core)
  (provide 'google-translate-core))

(require 'my-read-k)

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
         (my-read-k--frame nil)
         (my-read-k--buffer nil)
         (my-read-k--last-fingerprint nil)
         (my-read-k--current-result nil)
         (my-read-k--prefetch-queue nil)
         (my-read-k--prefetch-source-fingerprint nil)
         (my-read-k--prefetch-attempted-fingerprint nil)
         (my-read-k--back-queue nil)
         (my-read-k--back-source-fingerprint nil))
     ,@body))

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

(ert-deftest my-read-k-page-replacement-keeps-normal-read-only-text ()
  (my-read-k-test--isolated
   (with-temp-buffer
     (setq my-read-k--buffer (current-buffer))
     (my-read-k--apply-page
      '((text . "First sentence.\n\nSecond sentence.")
        (fingerprint . "abc") (ocrMs . 12) (lines . nil))
      'next nil)
     (should buffer-read-only)
     (should (equal (buffer-string) "First sentence.\n\nSecond sentence.\n"))
     (should (equal (thing-at-point 'word t) "First"))
     (should (equal my-read-k--last-fingerprint "abc"))
     (should (equal (my-read-k--alist-get 'text my-read-k--current-result)
                    "First sentence.\n\nSecond sentence.")))))

(ert-deftest my-read-k-mode-keeps-kindle-buffer-read-only ()
  (my-read-k-test--isolated
   (with-temp-buffer
     (my-read-k-mode 1)
     (should buffer-read-only)
     (my-read-k-mode -1)
     (should-not buffer-read-only))))

(ert-deftest english-reading-mode-j-and-k-use-single-sentence-bounds ()
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
         (english-reading-mode-next-sentence)
         (should (equal (car spoken) "First sentence."))
         (should (looking-at-p "Second sentence\\."))
         (english-reading-mode-previous-sentence)
         (should (equal (car spoken) "First sentence."))
         (should (= (point) (point-min)))
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

(ert-deftest my-read-k-next-consumes-cache-and-advances-without-ocr ()
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

(ert-deftest my-read-k-forward-within-buffer-reuses-existing-j ()
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
         (should (equal request '(next t))))))))

(ert-deftest my-read-k-backward-at-first-sentence-requests-prev-page ()
  (my-read-k-test--isolated
   (with-temp-buffer
     (insert "First sentence. Second sentence.")
     (goto-char (point-min))
     (let (request)
       (cl-letf (((symbol-function 'my-read-k--request-page)
                  (lambda (direction &optional speak)
                    (setq request (list direction speak)))))
         (my-read-k-backward)
         (should (equal request '(prev t))))))))

(ert-deftest my-read-k-busy-input-is-serialized-as-last-intent ()
  (my-read-k-test--isolated
   (setq my-read-k--busy-p t)
   (my-read-k-forward)
   (should (equal my-read-k--pending-intent '(next . t)))
   (my-read-k-backward)
   (should (equal my-read-k--pending-intent '(prev . t)))))

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

(ert-deftest my-read-k-keeps-original-my-read-entry-and-j-binding ()
  (should (commandp 'my-read))
  (should (equal (help-function-arglist #'my/read--setup-frame t)
                 '(frame &optional center-buffer)))
  (should (eq (lookup-key english-reading-mode-map (kbd "j"))
              #'english-reading-mode-next-sentence))
  (should (eq (lookup-key english-reading-mode-map (kbd "k"))
              #'english-reading-mode-previous-sentence))
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
              #'my-read-k-prev-page)))

(provide 'my-read-k-tests)
;;; my-read-k-tests.el ends here
