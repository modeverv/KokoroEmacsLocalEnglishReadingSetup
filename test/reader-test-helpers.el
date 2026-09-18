;;; reader-test-helpers.el --- Shared reader test fixtures -*- lexical-binding: t; -*-

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

(defmacro my-read-vocab-test--with-file (&rest body)
  `(let* ((file (make-temp-file "my-read-vocabulary-" nil ".org"))
          (my/read-vocabulary-file file))
     (unwind-protect
         (progn ,@body)
       (when-let* ((buffer (get-file-buffer file)))
         (set-buffer-modified-p nil)
         (kill-buffer buffer))
       (when (file-exists-p file)
         (delete-file file)))))

(defun my-read-vocab-test--data (term type timestamp book sentence
                                      &optional meaning translation)
  (list :term term :type type :timestamp timestamp :book book
        :sentence sentence :meaning meaning :translation translation))

(provide 'reader-test-helpers)
