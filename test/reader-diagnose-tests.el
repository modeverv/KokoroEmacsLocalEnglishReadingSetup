;;; reader-diagnose-tests.el --- Read-only diagnostics tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'reader-diagnose)

(ert-deftest reader-diagnose-uses-playing-buffer-settings ()
  (with-temp-buffer
    (setq-local kokoro-reader-backend 'macos)
    (setq-local kokoro-reader-macos-voice "Kyoko")
    (setq-local kokoro-reader-macos-rate 540)
    (let ((source (current-buffer)))
      (with-temp-buffer
        (let ((english-reading-mode--continuous-state (list :buffer source)))
          (should (eq (reader-diagnose--source-buffer) source))
          (let ((data (reader-diagnose--collect source)))
            (should (equal (plist-get data :voice) "Kyoko"))
            (should (equal (plist-get data :speed) "540 語/分"))))))))

(ert-deftest reader-diagnose-metadata-does-not-contain-book-text-or-credentials ()
  (with-temp-buffer
    (insert "Private book passage")
    (let ((kokoro-reader--macos-prefetch-queue
           '((:id 1 :key ("Private book passage") :http-payload "secret-payload"))))
      (should-not (string-match-p "Private book\|secret-payload"
                                  (prin1-to-string (reader-speech-queue-snapshot)))))
    (should (equal (reader-diagnose--safe-url "http://user:secret@host:8765/?token=secret")
                   "http://[redacted]@host:8765/"))))

(ert-deftest reader-diagnose-refresh-does-not-start-services-or-stop-reading ()
  (let ((source (generate-new-buffer " *diagnose-source*")))
    (unwind-protect
        (with-temp-buffer
          (reader-diagnose-mode)
          (setq reader-diagnose--source source)
          (cl-letf (((symbol-function 'kokoro-reader-stop) (lambda (&rest _) (ert-fail "Stopped reading")))
                    ((symbol-function 'reader-http-speech--service-command)
                     (lambda (&rest _) (ert-fail "Managed service")))
                    ((symbol-function 'reader-diagnose--probe) #'ignore))
            (reader-diagnose-refresh)
            (should buffer-read-only)
            (should (string-match-p "Reader 診断" (buffer-string)))))
      (kill-buffer source))))

(ert-deftest reader-diagnose-stale-health-result-cannot-overwrite-refresh ()
  (with-temp-buffer
    (reader-diagnose-mode)
    (setq reader-diagnose--snapshot (reader-diagnose--collect (current-buffer)))
    (let (sentinel output)
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest args)
                   (setq sentinel (plist-get args :sentinel) output (plist-get args :buffer))
                   'probe))
                ((symbol-function 'process-status) (lambda (_) 'exit))
                ((symbol-function 'process-exit-status) (lambda (_) 0)))
        (reader-diagnose--probe 'speech "http://localhost:8765/health")
        (with-current-buffer output (insert "{\"ok\":true,\"pid\":123}"))
        (cl-incf reader-diagnose--generation)
        (funcall sentinel 'probe "done")
        (should-not reader-diagnose--health)
        (should-not (buffer-live-p output))
        (setq reader-diagnose--probes nil)))))

(ert-deftest reader-diagnose-health-failure-is-visible ()
  (with-temp-buffer
    (reader-diagnose-mode)
    (setq reader-diagnose--snapshot (reader-diagnose--collect (current-buffer)))
    (let (sentinel)
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest args) (setq sentinel (plist-get args :sentinel)) 'probe))
                ((symbol-function 'process-status) (lambda (_) 'exit))
                ((symbol-function 'process-exit-status) (lambda (_) 28)))
        (reader-diagnose--probe 'speech "http://localhost:8765/health")
        (funcall sentinel 'probe "timeout")
        (should (string-match-p "応答なし" (buffer-string)))
        (should-not reader-diagnose--probes)))))

(provide 'reader-diagnose-tests)
