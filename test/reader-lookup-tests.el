;;; reader-lookup-tests.el --- Lookup regressions -*- lexical-binding: t; -*-

(require 'reader-test-helpers)

(ert-deftest my-read-lookup-entry-keys-dispatch-in-pane-and-restore-center ()
  (my-read-k-test--isolated
   (save-window-excursion
     (let* ((frame (selected-frame))
            (center (selected-window))
            (lookup (split-window-right))
            (lookup-buffer (generate-new-buffer " *my-read-lookup-test*"))
            (seen nil))
       (unwind-protect
           (progn
             (set-frame-parameter frame 'my-reading-frame t)
             (set-frame-parameter frame 'my-reading-center-window center)
             (set-frame-parameter frame 'my-reading-lookup-window lookup)
             (set-window-buffer lookup lookup-buffer)
             (with-current-buffer lookup-buffer
               (let ((map (make-sparse-keymap)))
                 (define-key map (kbd "n")
                             (lambda ()
                               (interactive)
                               (push (list 'next (selected-window)) seen)))
                 (define-key map (kbd "p")
                             (lambda ()
                               (interactive)
                               (push (list 'previous (selected-window)) seen)))
                 (use-local-map map)))
             (select-window center)
             (my/read-lookup-next-entry)
             (should (eq (selected-window) center))
             (my/read-lookup-previous-entry)
             (should (eq (selected-window) center))
             (should (equal seen
                            (list (list 'previous lookup)
                                  (list 'next lookup)))))
         (set-frame-parameter frame 'my-reading-frame nil)
         (set-frame-parameter frame 'my-reading-center-window nil)
         (set-frame-parameter frame 'my-reading-lookup-window nil)
         (when (buffer-live-p lookup-buffer)
           (kill-buffer lookup-buffer)))))))

(ert-deftest my-read-lookup-builds-and-caches-private-dictionary-module ()
  (let ((my/read-lookup-dictionary-ids '("dict-a" "dict-b:one"))
        (my/read--lookup-module nil)
        (my/read--lookup-module-signature nil)
        specs
        setups)
    (cl-letf (((symbol-function 'my/read--lookup-ensure-runtime)
               (lambda () t))
              ((symbol-function 'lookup-new-module)
               (lambda (spec)
                 (push spec specs)
                 (list 'private-module spec)))
              ((symbol-function 'lookup-module-setup)
               (lambda (module) (push module setups))))
      (let ((first (my/read--lookup-reading-module))
            (second (my/read--lookup-reading-module)))
        (should (eq first second))
        (should (equal specs '(("%my-read" "dict-a" "dict-b:one"))))
        (should (= (length setups) 1)))
      (setq my/read-lookup-dictionary-ids '("dict-c"))
      (my/read--lookup-reading-module)
      (should (equal (car specs) '("%my-read" "dict-c")))
      (should (= (length setups) 2)))))

(ert-deftest my-read-lookup-pattern-advice-uses-private-module-only-in-frame ()
  (let (calls)
    (cl-letf (((symbol-function 'my/read-frame-p) (lambda (&optional _) t))
              ((symbol-function 'my/read--lookup-reading-module)
               (lambda () 'private-module)))
      (my/read--lookup-pattern-around
       (lambda (pattern module) (push (list pattern module) calls))
       "word" nil)
      (my/read--lookup-pattern-around
       (lambda (pattern module) (push (list pattern module) calls))
       "word" 'explicit-module))
    (should (equal calls
                   '(("word" explicit-module)
                     ("word" private-module))))))

(provide 'reader-lookup-tests)
