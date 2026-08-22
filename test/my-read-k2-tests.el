;;; my-read-k2-tests.el --- Tests for my-read-k2 -*- lexical-binding: t; -*-

(require 'ert)

(unless (featurep 'google-translate-core)
  (provide 'google-translate-core))
(defvar google-translate-default-target-language "ja")
(defvar google-translate-default-source-language "en")

(require 'my-read-k2)

(ert-deftest my-read-k2-bridge-command-selects-native-package ()
  (let ((my-read-k2-bridge-program "/tmp/my-read-k2-test-bridge"))
    (should (equal (my-read-k2--bridge-command)
                   '("swift" "run" "--package-path"
                     "/Users/seijiro/Sync/emacs.d/reader/my-read-k2/bridge"
                     "--configuration" "release" "my-read-k2-bridge")))))

(ert-deftest my-read-k2-activate-selects-english-native-backend ()
  (let ((my-read-k2--active-p nil)
        (my-read-k2--saved-language :unset)
        (my-read-k--process nil)
        (my-read-k2-bridge-program "/tmp/my-read-k2-bridge")
        my-read-k-language)
    (cl-letf (((symbol-function 'file-executable-p) (lambda (_path) t)))
      (my-read-k2--activate-backend)
      (should my-read-k2--active-p)
      (should (equal (my-read-k--bridge-command)
                     '("/tmp/my-read-k2-bridge")))
      (should (equal my-read-k-language "en-US")))))

(ert-deftest my-read-k2-detach-restores-web-reader-language ()
  (let ((my-read-k2--active-p t)
        (my-read-k2--saved-language "auto")
        (my-read-k-language "en-US"))
    (my-read-k2--after-detach)
    (should-not my-read-k2--active-p)
    (should (equal my-read-k-language "auto"))))

(ert-deftest my-read-opens-the-kindle-app-backend ()
  (let (called)
    (cl-letf (((symbol-function 'my-read-k2--open-unified-workspace)
               (lambda () (setq called t))))
      (my-read)
      (should called))))

(ert-deftest my-read-k2-is-not-a-public-command ()
  (should-not (fboundp 'my-read-k2)))

(provide 'my-read-k2-tests)
;;; my-read-k2-tests.el ends here
