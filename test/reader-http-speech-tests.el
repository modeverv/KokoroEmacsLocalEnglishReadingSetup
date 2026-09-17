;;; reader-http-speech-tests.el --- HTTP speech tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'reader-http-speech)

(ert-deftest reader-http-speech-language-parameters ()
  (let ((reader-http-speech-japanese-speed 1.5)
        (reader-http-speech-english-speed 0.8))
    (should (equal (alist-get 'backend (reader-http-speech--request "日本語" "ja")) "macos"))
    (should (= (alist-get 'speed (reader-http-speech--request "English" "en")) 0.8))
    (should (= (alist-get 'speed (reader-http-speech--request "日本語" "ja")) 1.5))))

(ert-deftest reader-http-speech-invalid-text-is-rejected ()
  (should-error (reader-http-speech--request "  " "ja") :type 'user-error)
  (should-error (reader-http-speech--request "text" "xx") :type 'user-error)
  (should-error (reader-http-speech--request (make-string 24001 ?a) "en") :type 'user-error))

(ert-deftest reader-http-speech-only-sends-selected-region ()
  (with-temp-buffer
    (insert "before selected after")
    (goto-char 8)
    (set-mark 16)
    (let ((transient-mark-mode t) (mark-active t) sent)
      (cl-letf (((symbol-function 'reader-http-speech-speak)
                 (lambda (text language) (setq sent (list text language)))))
        (reader-http-speech-read-japanese))
      (should (equal sent '("selected" "ja"))))))
