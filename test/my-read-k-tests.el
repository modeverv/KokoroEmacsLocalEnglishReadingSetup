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
         (my-read-k--pending-intent nil)
         (my-read-k--state 'detached)
         (my-read-k--frame nil)
         (my-read-k--buffer nil))
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
     (should (equal my-read-k--last-fingerprint "abc")))))

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
              #'english-reading-mode-previous-sentence)))

(provide 'my-read-k-tests)
;;; my-read-k-tests.el ends here
