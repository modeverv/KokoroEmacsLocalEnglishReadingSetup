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
                   (list "swift" "run" "--package-path"
                         (expand-file-name "my-read-k2/bridge" reader-companion-directory)
                         "--configuration" "release" "my-read-k2-bridge")))))

(ert-deftest my-read-k2-configures-the-accessibility-bridge ()
  (let ((my-read-k2-bridge-program "/tmp/my-read-k2-bridge"))
    (cl-letf (((symbol-function 'file-executable-p) (lambda (_path) t)))
      (should (equal (my-read-k--bridge-command)
                     '("/tmp/my-read-k2-bridge")))
      (should (eq my-read-k--reconnect-function #'my-read-k2-reconnect)))))

(ert-deftest my-read-opens-the-kindle-app-backend ()
  (let (calls)
    (cl-letf (((symbol-function 'my-read-restart-japanese-speech)
               (lambda () (push 'restart calls)))
              ((symbol-function 'my-read-k2--open-unified-workspace)
               (lambda () (push 'open calls))))
      (my-read)
      (should (equal (nreverse calls) '(restart open))))))

(ert-deftest my-read-k2-reports-the-actual-connection-error ()
  (should
   (equal
    (my-read-k2--connection-error-message
     '((error (code . "NO_PAGE_TEXT")
              (message . "No open Kindle page was found."))))
    "Kindle.appの本文を取得できません。本を開いて本文ページを表示してから r で再接続してください。")))

(ert-deftest my-read-end-deletes-the-reading-frame ()
  (let ((reading-frame 'reading-frame)
        deleted)
    (cl-letf (((symbol-function 'frame-list)
               (lambda () (list reading-frame 'ordinary-frame)))
              ((symbol-function 'my/read-frame-p)
               (lambda (&optional frame) (eq frame reading-frame)))
              ((symbol-function 'delete-frame)
               (lambda (frame &optional force)
                 (setq deleted (list frame force)))))
      (my-read-end)
      (should (equal deleted (list reading-frame t))))))

(ert-deftest my-read-k2-is-not-a-public-command ()
  (should-not (fboundp 'my-read-k2)))

(ert-deftest my-read-k2-reconnect-key-does-not-leak-into-org-mode ()
  (let ((text-binding (lookup-key text-mode-map (kbd "r")))
        (buffer (my-read-k2--prepare-buffer)))
    (unwind-protect
        (progn
          (should (equal (lookup-key text-mode-map (kbd "r")) text-binding))
          (with-temp-buffer
            (org-mode)
            (should (eq (key-binding (kbd "r"))
                        #'org-self-insert-command))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(provide 'my-read-k2-tests)
;;; my-read-k2-tests.el ends here
