;;; reader-vocabulary-tests.el --- Vocabulary regressions -*- lexical-binding: t; -*-

(require 'reader-test-helpers)

(ert-deftest my-read-vocabulary-target-prefers-region-and-normalizes-whitespace ()
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (insert "She felt anxiety in spite\n   of everything.")
      (goto-char (point-min))
      (search-forward "anxiety")
      (backward-word)
      (should (equal (my/read-vocab-target-at-point (selected-window))
                     "anxiety"))
      (search-forward "in spite")
      (set-mark (match-beginning 0))
      (search-forward "of")
      (setq transient-mark-mode t)
      (activate-mark)
      (should (equal (my/read-vocab-target-at-point (selected-window))
                     "in spite of"))
      (deactivate-mark)
      (erase-buffer)
      (insert "   ")
      (goto-char (point-min))
      (should-not (my/read-vocab-target-at-point (selected-window))))))

(ert-deftest my-read-vocabulary-capture-deactivates-selected-region ()
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (insert "In spite of everything, she went.")
      (goto-char (point-min))
      (set-mark (point))
      (search-forward "in spite of")
      (setq transient-mark-mode t)
      (activate-mark)
      (should (use-region-p))
      (cl-letf (((symbol-function 'my/read--center-window-active-p)
                 (lambda () t))
                ((symbol-function 'my/read-vocab-lookup-meaning)
                 (lambda (_term _callback &rest _))))
        (my/read-vocab-capture))
      (should-not mark-active))))

(ert-deftest my-read-vocabulary-normalized-key-folds-case-and-punctuation ()
  (should (equal (my/read-vocab-normalize-key " Anxiety, ") "anxiety"))
  (should (equal (my/read-vocab-normalize-key "  In\n spite   of! ")
                 "in spite of")))

(ert-deftest my-read-vocabulary-key-is-local-to-center-tab-mode ()
  ;; Inspect the raw map entry because `lookup-key' applies the center-window
  ;; menu-item filter, which is intentionally false in this isolated test.
  (let ((binding (cdr (assq ?u my-read-center-tab-mode-map))))
    (should (eq (nth 2 binding) 'my/read-vocab-capture)))
  (should-not (eq (lookup-key global-map (kbd "u"))
                  'my/read-vocab-capture)))

(ert-deftest my-read-vocabulary-title-reuses-kindle-metadata ()
  (let ((frame (selected-frame))
        (buffer (generate-new-buffer " *my-read-vocabulary-title*")))
    (unwind-protect
        (progn
          (set-frame-parameter frame 'my-reading-kindle-buffer buffer)
          (set-frame-parameter frame 'my-reading-kindle-book-name
                               "Some Light Novel Vol. 1")
          (should (equal (my/read-vocab-current-book-title buffer frame)
                         "Some Light Novel Vol. 1")))
      (set-frame-parameter frame 'my-reading-kindle-buffer nil)
      (set-frame-parameter frame 'my-reading-kindle-book-name nil)
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest my-read-vocabulary-meaning-collects-english-and-japanese-content ()
  (save-window-excursion
    (let* ((frame (selected-frame))
           (center (selected-window))
           (lookup-current-session 'test-session)
           results)
      (cl-letf (((symbol-function 'require) (lambda (&rest _) t))
                ((symbol-function 'lookup-pattern) (lambda (&rest _) t))
                ((symbol-function 'my/read--lookup-reading-module)
                 (lambda () 'private-module))
                ((symbol-function 'lookup-session-entries)
                 (lambda (_session) '(english-entry japanese-entry)))
                ((symbol-function 'lookup-entry-dictionary) #'identity)
                ((symbol-function 'lookup-dictionary-title)
                 (lambda (dictionary)
                   (if (eq dictionary 'english-entry)
                       "English"
                     "Japanese - English")))
                ((symbol-function 'my/read-vocab--lookup-entry-content)
                 (lambda (entry)
                   (if (eq entry 'english-entry)
                       "noun a loud and confused noise."
                     "名詞 騒音、喧噪。"))))
        (my/read-vocab-lookup-meaning
         "clamor" (lambda (value) (setq results value)) frame center))
      (should (equal (plist-get results :english-title) "English"))
      (should (string-match-p "loud and confused"
                              (plist-get results :english)))
      (should (equal (plist-get results :japanese-title)
                     "Japanese - English"))
      (should (string-match-p "喧噪" (plist-get results :japanese))))))

(ert-deftest my-read-vocabulary-meaning-formats-three-sources ()
  (let ((meaning
         (my/read-vocab--format-meaning
          '(:english-title "English"
            :english "noun a loud and confused noise."
            :japanese-title "Japanese - English"
            :japanese "名詞 騒音、喧噪。")
          "騒音")))
    (should (string-match-p "English-English \\[English\\]:" meaning))
    (should (string-match-p "English-Japanese \\[Japanese - English\\]:"
                            meaning))
    (should (string-match-p "Google Translate:\n騒音" meaning))))

(ert-deftest my-read-vocabulary-new-entry-has-canonical-structure ()
  (my-read-vocab-test--with-file
   (should
    (equal
     (my/read-vocab--write
      (my-read-vocab-test--data
       "Anxiety," 'word "[2026-08-23 Sun 07:20]" "Novel One"
       "She felt anxiety." "不安、心配" "彼女は不安を感じた。"))
     '(added . 1)))
   (with-temp-buffer
     (insert-file-contents my/read-vocabulary-file)
     (let ((text (buffer-string)))
       (should (= (how-many "^\\* Anxiety$" (point-min) (point-max)) 1))
       (should (string-match-p "^:TYPE: word$" text))
       (should (string-match-p "^:CREATED: \\[2026-08-23 Sun 07:20\\]$" text))
       (should (string-match-p "^:UPDATED: \\[2026-08-23 Sun 07:20\\]$" text))
       (should (string-match-p "^:COUNT: 1$" text))
       (should (string-match-p "^\\*\\* Meaning$" text))
       (should (string-match-p "^\\*\\* Examples$" text))
       (should (= (how-many "^\\*\\*\\* " (point-min) (point-max)) 1))))))

(ert-deftest my-read-vocabulary-existing-entry-merges-and-increments ()
  (my-read-vocab-test--with-file
   (my/read-vocab--write
    (my-read-vocab-test--data
     "Anxiety" 'word "[2026-08-23 Sun 07:20]" "Novel One"
     "She felt anxiety." "不安" "彼女は不安を感じた。"))
   (should
    (equal
     (my/read-vocab--write
      (my-read-vocab-test--data
       " anxiety, " 'word "[2026-08-23 Sun 07:26]" "Novel Two"
       "His anxiety vanished." "不安、心配、不安感" "彼の不安は消えた。"))
     '(saved . 2)))
   (with-temp-buffer
     (insert-file-contents my/read-vocabulary-file)
     (let ((text (buffer-string)))
       (should (= (how-many "^\\* Anxiety$" (point-min) (point-max)) 1))
       (should (string-match-p "^:COUNT:[ \t]+2$" text))
       (should (string-match-p
                "^:UPDATED:[ \t]+\\[2026-08-23 Sun 07:26\\]$" text))
       (should (= (how-many "^\\*\\*\\* " (point-min) (point-max)) 2))
       (should (string-match-p "不安、心配、不安感" text))
       (should (string-match-p "Novel One" text))
       (should (string-match-p "Novel Two" text))))))

(ert-deftest my-read-vocabulary-region-entry-is-a-phrase ()
  (my-read-vocab-test--with-file
   (my/read-vocab--write
    (my-read-vocab-test--data
     "in spite of" 'phrase "[2026-08-23 Sun 08:10]" "Novel One"
     "In spite of everything, she went." nil "それでも彼女は行った。"))
   (with-temp-buffer
     (insert-file-contents my/read-vocabulary-file)
     (should (string-match-p "^\\* in spite of$" (buffer-string)))
     (should (string-match-p "^:TYPE: phrase$" (buffer-string))))))

(ert-deftest my-read-vocabulary-malformed-entry-is-left-unchanged ()
  (my-read-vocab-test--with-file
   (with-temp-file my/read-vocabulary-file
     (insert "* anxiety\n:PROPERTIES:\n:COUNT: 1\n:END:\n"))
   (let ((before (with-temp-buffer
                   (insert-file-contents my/read-vocabulary-file)
                   (buffer-string))))
     (should-error
      (my/read-vocab--write
       (my-read-vocab-test--data
        "anxiety" 'word "[2026-08-23 Sun 09:00]" "Novel"
        "Anxiety remained." nil nil)))
     (should
      (equal before
             (with-temp-buffer
               (insert-file-contents my/read-vocabulary-file)
               (buffer-string)))))))

(ert-deftest my-read-vocabulary-capture-survives-missing-services ()
  (my-read-vocab-test--with-file
   (save-window-excursion
     (let* ((frame (selected-frame))
            (window (selected-window))
            (buffer (generate-new-buffer "my-read-vocab-capture-test"))
            term-backend)
       (unwind-protect
           (progn
             (set-window-buffer window buffer)
             (set-frame-parameter frame 'my-reading-frame t)
             (set-frame-parameter frame 'my-reading-center-window window)
             (set-frame-parameter frame 'my-reading-center-windows (list window))
             (set-frame-parameter frame 'my-reading-kindle-buffer buffer)
             (with-current-buffer buffer
               (insert "She felt anxiety about the situation.")
               (goto-char (point-min))
               (search-forward "anxiety")
               (backward-word)
               (setq-local my/read-center-tab-frame frame))
             (cl-letf (((symbol-function 'my/read-vocab-lookup-meaning)
                        (lambda (_term callback &rest _)
                          (funcall callback nil)))
                       ((symbol-function 'my/read-vocab-translate-text)
                        (lambda (_text callback &optional backend &rest _)
                          (setq term-backend backend)
                          (funcall callback nil)))
                       ((symbol-function 'my/read-vocab-translate-sentence)
                        (lambda (_sentence callback &rest _)
                          (funcall callback nil))))
               (with-current-buffer buffer
                 (my/read-vocab-capture)))
             (should (eq term-backend 'google))
             (with-temp-buffer
               (insert-file-contents my/read-vocabulary-file)
               (let ((text (buffer-string)))
                 (should (string-match-p "^\\* anxiety$" text))
                 (should (string-match-p "She felt anxiety about the situation\\." text))
                 (should (string-match-p "^Japanese:$" text)))))
         (set-frame-parameter frame 'my-reading-frame nil)
         (set-frame-parameter frame 'my-reading-center-window nil)
         (set-frame-parameter frame 'my-reading-center-windows nil)
         (set-frame-parameter frame 'my-reading-kindle-buffer nil)
         (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(provide 'reader-vocabulary-tests)
