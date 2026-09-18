;;; my-read-vocabulary.el --- Vocabulary for the reader -*- lexical-binding: t; -*-

(defvar lookup-open-function)
(declare-function lookup-vse-insert-content "lookup")
(declare-function lookup-dictionary-title "lookup")
(declare-function lookup-entry-dictionary "lookup")
(require 'my-read-core)
(require 'my-read-lookup)
(require 'my-read-translation)
(require 'org)

(defcustom my/read-vocabulary-file
  (expand-file-name "~/my-read/vocabulary.org")
  "Org file used as the canonical my-read vocabulary store."
  :type 'file
  :group 'my-read)

(defcustom my/read-vocab-english-dictionary-title-regexp
  "\\`English\\'\\|英英\\|英語辞典"
  "Regexp matching Lookup dictionary titles used for English definitions."
  :type 'regexp
  :group 'my-read)

(defcustom my/read-vocab-japanese-dictionary-title-regexp
  "Japanese[[:space:]]*-[[:space:]]*English\\|英和\\|和英"
  "Regexp matching Lookup dictionary titles used for Japanese meanings."
  :type 'regexp
  :group 'my-read)

(defun my/read-vocab--strip-surrounding-punctuation (text)
  "Strip obvious quotation and sentence punctuation around TEXT."
  (let ((punctuation "[[:punct:]“”‘’]"))
    (setq text (replace-regexp-in-string
                (concat "\\`" punctuation "+") "" text))
    (replace-regexp-in-string (concat punctuation "+\\'") "" text)))

(defun my/read-vocab-normalize-key (text)
  "Return the case-folded vocabulary lookup key for TEXT."
  (downcase
   (my/read-vocab--strip-surrounding-punctuation
    (or (my/read-vocab-normalize-text text) ""))))

(defun my/read-vocab--display-text (text)
  "Return normalized display spelling for captured TEXT."
  (my/read-vocab--strip-surrounding-punctuation
   (or (my/read-vocab-normalize-text text) "")))

(defun my/read-vocab-target-at-point (&optional window)
  "Return the selected phrase or word at point in WINDOW.

An active region is preferred and its whitespace is normalized.  WINDOW
defaults to the selected window."
  (let ((window (or window (selected-window))))
    (if (use-region-p)
        (my/read-vocab--display-text
         (buffer-substring-no-properties (region-beginning) (region-end)))
      (when-let* ((word (my/read-word-at-window window)))
        (my/read-vocab--display-text word)))))

(defun my/read-vocab-current-book-title (&optional buffer frame)
  "Return document title metadata for BUFFER in FRAME."
  (if (buffer-live-p (or buffer (current-buffer)))
      (with-current-buffer (or buffer (current-buffer))
        (reader-document-title frame))
    "Unknown source"))

(defun my/read-vocab-current-source (&optional buffer frame)
  "Return document source metadata for BUFFER in FRAME."
  (if (buffer-live-p (or buffer (current-buffer)))
      (with-current-buffer (or buffer (current-buffer))
        (reader-document-source frame))
    nil))

(defun my/read-vocab--lookup-buffer-text (buffer)
  "Return useful plain text from Lookup BUFFER, or nil."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((text (string-trim
                   (buffer-substring-no-properties (point-min) (point-max)))))
        (unless (string-empty-p text) text)))))

(defun my/read-vocab--lookup-content-buffer ()
  "Return Lookup's rendered dictionary-content buffer, or nil."
  (let ((name
         (cond
          ((fboundp 'lookup-content-buffer) (lookup-content-buffer))
          ((boundp 'lookup-content-buffer)
           (symbol-value 'lookup-content-buffer)))))
    (and name (get-buffer name))))

(defun my/read-vocab--lookup-entry-content (entry)
  "Return the rendered plain-text content of Lookup ENTRY, or nil."
  (condition-case nil
      (with-temp-buffer
        (lookup-vse-insert-content entry)
        (my/read-vocab--lookup-buffer-text (current-buffer)))
    (error nil)))

(defun my/read-vocab--lookup-results ()
  "Return English and Japanese dictionary results from the current session."
  (let ((entries
         (and (boundp 'lookup-current-session)
              lookup-current-session
              (fboundp 'lookup-session-entries)
              (lookup-session-entries lookup-current-session)))
        english-entry
        japanese-entry)
    (dolist (entry entries)
      (let ((title
             (lookup-dictionary-title (lookup-entry-dictionary entry))))
        (cond
         ((and (null english-entry)
               (string-match-p
                my/read-vocab-english-dictionary-title-regexp title))
          (setq english-entry (cons title entry)))
         ((and (null japanese-entry)
               (string-match-p
                my/read-vocab-japanese-dictionary-title-regexp title))
          (setq japanese-entry (cons title entry))))))
    (let ((english (and english-entry
                        (my/read-vocab--lookup-entry-content
                         (cdr english-entry))))
          (japanese (and japanese-entry
                         (my/read-vocab--lookup-entry-content
                          (cdr japanese-entry)))))
      ;; Older Lookup variants may not expose their session entries.  Preserve
      ;; a useful first English result instead of dropping all dictionary text.
      (unless english
        (setq english
              (my/read-vocab--lookup-buffer-text
               (my/read-vocab--lookup-content-buffer))))
      (list :english-title (car english-entry)
            :english english
            :japanese-title (car japanese-entry)
            :japanese japanese))))

(defun my/read-vocab--format-meaning (lookup-results google-translation)
  "Format LOOKUP-RESULTS and GOOGLE-TRANSLATION for the Meaning section."
  (let ((english-title (plist-get lookup-results :english-title))
        (english (or (plist-get lookup-results :english) ""))
        (japanese-title (plist-get lookup-results :japanese-title))
        (japanese (or (plist-get lookup-results :japanese) ""))
        (google (or google-translation "")))
    (format "English-English%s:\n%s\n\nEnglish-Japanese%s:\n%s\n\nGoogle Translate:\n%s"
            (if english-title (format " [%s]" english-title) "")
            english
            (if japanese-title (format " [%s]" japanese-title) "")
            japanese
            google)))

(defun my/read-vocab-lookup-meaning (text callback &optional frame center)
  "Look up TEXT with my-read's Lookup stack, then call CALLBACK.

CALLBACK receives a plist containing English and Japanese dictionary results,
or nil when Lookup is unavailable or fails."
  (let ((frame (or frame (selected-frame)))
        (center (or center (selected-window)))
        results)
    (condition-case nil
        (when (and (frame-live-p frame)
                   (window-live-p center)
                   (or (featurep 'lookup) (require 'lookup nil t))
                   (fboundp 'lookup-pattern))
          (with-selected-frame frame
            (save-selected-window
              (with-selected-window center
                (let ((lookup-open-function #'my/read-lookup-open-pane))
                  (lookup-pattern text (my/read--lookup-reading-module)))))
            (setq results (my/read-vocab--lookup-results))))
      (error (setq results nil)))
    (funcall callback results)))

(defun my/read-vocab--translation-command
    (backend text frame source-buffer)
  "Return the existing my-read translation command for BACKEND and TEXT."
  (if (eq backend 'local)
      (list "curl" "-sS" "--fail-with-body"
            "--connect-timeout" "1"
            "--max-time" (number-to-string my/read-local-translation-timeout)
            "-H" "Content-Type: application/json"
            "--data-binary"
            (my/read--local-translation-request text frame source-buffer)
            my/read-local-translation-url)
    (list "curl" "-s" "-L" "-A" "Emacs"
          (my/read-google-translate-url text frame source-buffer))))

(defun my/read-vocab--translate-request
    (backend text callback frame source-buffer)
  "Translate TEXT with BACKEND and call CALLBACK with text or nil."
  (let* ((local-p (eq backend 'local))
         (buffer (generate-new-buffer " *my-read vocabulary translation*"))
         (process
          (make-process
           :name "my-read-vocabulary-translation"
           :buffer buffer
           :command (my/read-vocab--translation-command
                     backend text frame source-buffer)
           :coding 'utf-8-unix
           :noquery t
           :sentinel
           (lambda (proc _event)
             (when (memq (process-status proc) '(exit signal))
               (unwind-protect
                   (let ((translation
                          (and (= (process-exit-status proc) 0)
                               (condition-case nil
                                   (with-current-buffer (process-buffer proc)
                                     (my/read--translation-response
                                      backend (buffer-string)))
                                 (error nil)))))
                     (if (and (null translation)
                              local-p
                              my/read-google-translation-fallback)
                         (my/read-vocab--translate-request
                          'google text callback frame source-buffer)
                       (funcall callback translation)))
                 (when-let* ((process-buffer (process-buffer proc)))
                   (when (buffer-live-p process-buffer)
                     (kill-buffer process-buffer)))))))))
    process))

(defun my/read-vocab-translate-text
    (text callback &optional backend frame source-buffer)
  "Translate TEXT with BACKEND, then call CALLBACK.
BACKEND defaults to `my/read-translation-backend'."
  (if (string-empty-p (or text ""))
      (funcall callback nil)
    (condition-case nil
        (my/read-vocab--translate-request
         (or backend my/read-translation-backend) text callback
         (or frame (selected-frame)) source-buffer)
      (error (funcall callback nil)))))

(defun my/read-vocab-translate-sentence
    (sentence callback &optional frame source-buffer)
  "Translate SENTENCE with my-read's configured backend, then call CALLBACK."
  (my/read-vocab-translate-text
   sentence callback my/read-translation-backend frame source-buffer))

(defun my/read-vocab--find-entry (key)
  "Return the position of the unique top-level entry matching KEY.

Signal an error if duplicate normalized headings already exist."
  (save-excursion
    (goto-char (point-min))
    (let (matches)
      (while (re-search-forward "^\\* \\(.+?\\)[ \t]*$" nil t)
        (when (equal key (my/read-vocab-normalize-key (match-string 1)))
          (push (line-beginning-position) matches)))
      (when (> (length matches) 1)
        (error "Duplicate vocabulary headings already exist for %s" key))
      (car matches))))

(defun my/read-vocab--safe-body (text)
  "Return TEXT safe for insertion as ordinary Org body text."
  (let ((text (string-trim (or text ""))))
    (replace-regexp-in-string "^\\*" ",*" text)))

(defun my/read-vocab--example-text (data)
  "Return one Org example subtree for vocabulary DATA."
  (let ((timestamp (plist-get data :timestamp))
        (book (my/read-vocab-normalize-text (plist-get data :book)))
        (source (my/read-vocab-normalize-text (plist-get data :source)))
        (english (my/read-vocab--safe-body (plist-get data :sentence)))
        (japanese (my/read-vocab--safe-body (plist-get data :translation))))
    (concat
     (format "*** %s %s\n:PROPERTIES:\n:BOOK: %s\n"
             timestamp book book)
     (if (string-empty-p (or source "")) "" (format ":SOURCE: %s\n" source))
     ":END:\n\nEnglish:\n" english "\n\nJapanese:\n" japanese "\n")))

(defun my/read-vocab--validate-existing-entry (position)
  "Return the positive COUNT at vocabulary entry POSITION.

Signal before editing when the canonical entry structure is unsafe."
  (save-excursion
    (goto-char position)
    (org-back-to-heading t)
    (let* ((count-text (org-entry-get nil "COUNT"))
           (end (save-excursion (org-end-of-subtree t t) (point))))
      (unless (and count-text (string-match-p "\\`[1-9][0-9]*\\'" count-text))
        (error "Vocabulary entry has an invalid COUNT property"))
      (unless (re-search-forward "^\\*\\* Meaning[ \t]*$" end t)
        (error "Vocabulary entry has no safe Meaning section"))
      (unless (re-search-forward "^\\*\\* Examples[ \t]*$" end t)
        (error "Vocabulary entry has no safe Examples section"))
      (string-to-number count-text))))

(defun my/read-vocab--replace-meaning (position meaning)
  "Replace entry POSITION's Meaning body with non-empty MEANING."
  (unless (string-empty-p meaning)
    (save-excursion
      (goto-char position)
      (org-back-to-heading t)
      (let ((end (save-excursion (org-end-of-subtree t t) (point))))
        (unless (re-search-forward "^\\*\\* Meaning[ \t]*$" end t)
          (error "Vocabulary entry has no safe Meaning section"))
        (forward-line 1)
        (let ((body-start (point)))
          (unless (re-search-forward "^\\*\\* Examples[ \t]*$" end t)
            (error "Vocabulary entry has no safe Examples section"))
          (delete-region body-start (line-beginning-position))
          (goto-char body-start)
          (insert meaning "\n\n"))))))

(defun my/read-vocab--write (data)
  "Merge vocabulary DATA into `my/read-vocabulary-file'.

Return (STATUS . COUNT), where STATUS is `added' or `saved'."
  (let* ((file (expand-file-name my/read-vocabulary-file))
         (directory (file-name-directory file))
         (term (my/read-vocab--display-text (plist-get data :term)))
         (key (my/read-vocab-normalize-key term))
         (timestamp (plist-get data :timestamp))
         (type (plist-get data :type))
         (meaning (my/read-vocab--safe-body (plist-get data :meaning))))
    (when (string-empty-p key)
      (error "Vocabulary term is empty"))
    (when directory (make-directory directory t))
    (with-current-buffer (find-file-noselect file)
      (unless (derived-mode-p 'org-mode) (org-mode))
      (let* ((position (my/read-vocab--find-entry key))
             (old-count (and position
                             (my/read-vocab--validate-existing-entry position)))
             (new-count (if old-count (1+ old-count) 1))
             (status (if position 'saved 'added)))
        (atomic-change-group
          (if position
              (progn
                (goto-char position)
                (org-back-to-heading t)
                (org-entry-put nil "UPDATED" timestamp)
                (org-entry-put nil "COUNT" (number-to-string new-count))
                (my/read-vocab--replace-meaning position meaning)
                (goto-char position)
                (org-end-of-subtree t t)
                (unless (bolp) (insert "\n"))
                (insert "\n" (my/read-vocab--example-text data)))
            (goto-char (point-max))
            (unless (or (= (point) (point-min)) (bolp)) (insert "\n"))
            (unless (= (point) (point-min)) (insert "\n"))
            (insert (format "* %s\n:PROPERTIES:\n:TYPE: %s\n"
                            term (symbol-name type)))
            (insert (format ":CREATED: %s\n:UPDATED: %s\n:COUNT: 1\n:END:\n\n"
                            timestamp timestamp))
            (insert "** Meaning\n" meaning "\n\n** Examples\n\n")
            (insert (my/read-vocab--example-text data))))
        (save-buffer)
        (cons status new-count)))))

(defun my/read-vocab--finish-capture (data)
  "Persist completed vocabulary DATA and report success."
  (pcase-let ((`(,status . ,count) (my/read-vocab--write data)))
    (if (eq status 'added)
        (message "Vocabulary added: %s" (plist-get data :term))
      (message "Vocabulary saved: %s (%d examples)"
               (plist-get data :term) count))))

;;;###autoload
(defun my/read-vocab-capture ()
  "Capture the selected phrase or word at point into the vocabulary Org file."
  (interactive)
  (unless (my/read--center-window-active-p)
    (user-error "Use this command from the my-read center window"))
  (let* ((frame (selected-frame))
         (center (selected-window))
         (phrase-p (use-region-p))
         (term (my/read-vocab-target-at-point center)))
    (unless (and term (not (string-empty-p term)))
      (user-error "No word or phrase at point"))
    (when phrase-p
      (deactivate-mark))
    (let* ((sentence-data (my/read-current-sentence-at-window center))
           (sentence (my/read-vocab-normalize-text
                      (or (car sentence-data) term)))
           (source-buffer (or (nth 1 sentence-data) (window-buffer center)))
           (data (list :term term
                       :type (if phrase-p 'phrase 'word)
                       :timestamp (format-time-string "[%Y-%m-%d %a %H:%M]")
                       :book (my/read-vocab-current-book-title
                              source-buffer frame)
                       :source (my/read-vocab-current-source
                                source-buffer frame)
                       :sentence sentence)))
      (message "Capturing vocabulary: %s..." term)
      (my/read-vocab-lookup-meaning
       term
       (lambda (lookup-results)
         ;; The term/phrase meaning is deliberately always Google Translate;
         ;; sentence translation continues to honor the configured backend.
         (my/read-vocab-translate-text
          term
          (lambda (term-translation)
            (setq data
                  (plist-put
                   data :meaning
                   (my/read-vocab--format-meaning
                    lookup-results term-translation)))
            (my/read-vocab-translate-sentence
             sentence
             (lambda (translation)
               (setq data (plist-put data :translation translation))
               (my/read-vocab--finish-capture data))
             frame source-buffer))
          'google frame source-buffer))
       frame center))))

(provide 'my-read-vocabulary)
;;; my-read-vocabulary.el ends here
