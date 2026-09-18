;;; reader-speech-queue-tests.el --- Queue ownership regressions -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'reader-http-speech-transport)

(defmacro reader-queue-test--isolated (&rest body)
  `(let ((kokoro-reader--macos-prefetch-queue nil)
         (kokoro-reader--macos-current-entry nil)
         (kokoro-reader--macos-bridge-process nil)
         (kokoro-reader--kokoro-pending-entries nil)
         (kokoro-reader--kokoro-request-processes nil)
         (kokoro-reader--kokoro-api-ready-p nil)
         (kokoro-reader--kokoro-health-pending-p nil)
         (reader-speech-queue--generation 0)
         (reader-speech-queue-last-error nil)
         (reader-speech-queue-transport nil)
         (reader-speech-queue-event-functions nil)
         (reader-speech-queue-connect-functions nil))
     ,@body))

(ert-deftest reader-queue-seconds-count-contiguous-future-audio-only ()
  (reader-queue-test--isolated
   (setq kokoro-reader--macos-prefetch-queue
         '((:id 1 :started t :loaded t :duration 99)
           (:id 2 :loaded t :duration 2.5)
           (:id 3 :loaded nil)
           (:id 4 :loaded t :duration 8)))
   (let ((snapshot (reader-speech-queue-snapshot)))
     (should (= (plist-get snapshot :seconds) 2.5))
     (should (= (plist-get snapshot :ready) 2))
     (should (= (plist-get snapshot :contiguous-ready) 1))
     (should (eq (plist-get snapshot :stage) 'playing)))))

(ert-deftest reader-queue-native-generation-is-visible ()
  (reader-queue-test--isolated
   (setq kokoro-reader--macos-prefetch-queue
         '((:id 1 :command "enqueue" :loaded nil)
           (:id 2 :command "enqueue" :loaded t :duration 2)))
   (should (= (plist-get (reader-speech-queue-snapshot) :inflight) 1))))

(ert-deftest reader-queue-unknown-duration-is-not-zero ()
  (reader-queue-test--isolated
   (setq kokoro-reader--macos-prefetch-queue '((:id 1 :loaded t)))
   (should-not (plist-get (reader-speech-queue-snapshot) :seconds))
   (should (= (plist-get (reader-speech-queue-snapshot) :unknown-durations) 1))))

(ert-deftest reader-queue-submit-delegates-through-captured-start-operation ()
  (reader-queue-test--isolated
   (let (wire started)
     (cl-letf (((symbol-function 'kokoro-reader--ensure-macos-bridge) (lambda () 'bridge))
               ((symbol-function 'process-send-string) (lambda (_p data) (setq wire data))))
       (let ((entry (reader-speech-queue-submit '(test-key) t
                     (list :start (lambda (request) (setq started request)) :volume 1.0))))
         (should (eq started entry))
         (should (eq entry (car kokoro-reader--macos-prefetch-queue)))
         (should-not kokoro-reader--kokoro-pending-entries)
         (should (string-match-p "reserve" wire)))))))

(ert-deftest reader-queue-cancelled-completion-cannot-advance-or-refill ()
  (reader-queue-test--isolated
   (let ((entry (list :id 1 :process 'old :announced t)) advanced)
     (setq kokoro-reader--macos-prefetch-queue (list entry))
     (cl-letf (((symbol-function 'kokoro-reader--launch-pending-requests)
                (lambda () (setq advanced t))))
       (reader-speech-queue-cancel)
       (reader-speech-queue-request-finished 'old entry nil)
       (should (plist-get entry :cancelled))
       (should-not advanced)
       (should-not kokoro-reader--macos-prefetch-queue)))))

(ert-deftest reader-queue-stale-process-cannot-complete-new-entry ()
  (reader-queue-test--isolated
   (let ((old (list :id 1 :process 'old))
         (new (list :id 1 :process 'new)) loaded)
     (setq kokoro-reader--macos-prefetch-queue (list new))
     (cl-letf (((symbol-function 'process-send-string) (lambda (&rest _) (setq loaded t))))
       (reader-speech-queue-request-finished 'old old nil)
       (should-not loaded)
       (should (eq new (car kokoro-reader--macos-prefetch-queue)))))))

(ert-deftest reader-queue-delivery-is-not-playback-completion ()
  (reader-queue-test--isolated
   (let* ((entry (list :id 2 :process 'request :remote-playback t :announced t))
          (kokoro-reader-player-finish-hook (list (lambda () (ert-fail "Advanced on delivery")))))
     (setq kokoro-reader--macos-prefetch-queue (list entry))
     (cl-letf (((symbol-function 'process-exit-status) (lambda (_) 0)))
       (reader-speech-queue-request-finished 'request entry nil))
     (should (memq entry kokoro-reader--macos-prefetch-queue)))))

(ert-deftest reader-queue-remote-finish-before-http-exit-refills-only-same-session ()
  (reader-queue-test--isolated
   (let ((entry (list :id 1 :process 'request :generation 0)) (refills 0))
     (cl-letf (((symbol-function 'kokoro-reader--launch-pending-requests)
                (lambda () (cl-incf refills))))
       (reader-speech-queue-request-finished 'request entry nil)
       (should (= refills 1))
       (reader-speech-queue-cancel)
       (reader-speech-queue-request-finished 'request entry nil)
       (should (= refills 1))))))

(ert-deftest reader-queue-stale-health-callback-is-ignored-after-cancel ()
  (reader-queue-test--isolated
   (let (callback launched)
     (cl-letf (((symbol-function 'kokoro-reader--ensure-server)
                (lambda (ready _error) (setq callback ready)))
               ((symbol-function 'kokoro-reader--launch-pending-requests)
                (lambda () (setq launched t))))
       (reader-speech-queue-ensure-legacy)
       (reader-speech-queue-cancel)
       (funcall callback)
       (should-not launched)
       (should-not kokoro-reader--kokoro-api-ready-p)))))

(ert-deftest reader-queue-duration-notification-does-not-finish-reading ()
  (reader-queue-test--isolated
   (let ((entry (list :id 3 :announced t))
         (finished 0))
     (setq kokoro-reader--macos-prefetch-queue (list entry))
     (let ((kokoro-reader-player-finish-hook (list (lambda () (cl-incf finished)))))
       (reader-speech-queue-notify '(:event "loaded" :id 3 :duration 4.25))
       (should (= (plist-get entry :duration) 4.25))
       (should (zerop finished))
       (reader-speech-queue-notify '(:event "finished" :id 3))
       (reader-speech-queue-notify '(:event "finished" :id 3))
       (should (= finished 1))))))

(ert-deftest reader-queue-http-mode-registers-operations-without-advice ()
  (reader-queue-test--isolated
   (let ((reader-http-speech-transport-mode nil))
     (cl-letf (((symbol-function 'english-reading-mode-stop-continuous) #'ignore))
       (reader-http-speech-transport-mode 1)
       (should (functionp (plist-get reader-speech-queue-transport :prepare)))
       (should-not (advice-member-p 'reader-http-speech-transport--key 'kokoro-reader--macos-key))
       (should-not (advice-member-p 'reader-http-speech-transport--start-request 'kokoro-reader--start-kokoro-request))
       (reader-http-speech-transport-mode -1)
       (should-not reader-speech-queue-transport)))))

(provide 'reader-speech-queue-tests)
