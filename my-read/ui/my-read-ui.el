;;; my-read-ui.el --- Ui for the reader -*- lexical-binding: t; -*-

(defvar lookup-sub-window)
(defvar my-read-k--buffer)
(declare-function my-read-k-detach "my-read-k")
(declare-function my-read-k--prepare-buffer "my-read-k")
(require 'my-read-core)
(require 'my-read-position)
(require 'my-read-speech-settings)
(require 'my-read-lookup)
(require 'my-read-translation)
(require 'my-read-vocabulary)
(require 'my-read-eww)
(require 'my-read-pdf)
(require 'my-read-org-noter)
(require 'dired)
(require 'dired-x)
(require 'seq)

(defvar-local my/read-dired-owner-frame nil
  "Frame owning this private my-read Dired buffer.")

(defun my/read-focus-center ()
  "Return keyboard focus to the current my-read frame's reading pane."
  (interactive)
  (let ((window (and (my/read-frame-p)
                     (my/read-center-window))))
    (unless (window-live-p window)
      (user-error "このフレームにはmy-readの本文ペインがありません"))
    (select-window window)))

(defun my/read--filter-workspace-key-binding (binding)
  "Enable BINDING in any my-read pane, excluding the minibuffer."
  (when (and (my/read-frame-p) (not (minibufferp))) binding))

(defvar my-read-workspace-keys-mode-map (make-sparse-keymap)
  "Keys shared by every pane in a my-read frame.")
(keymap-set my-read-workspace-keys-mode-map "C-c b"
            '(menu-item "Return to reading pane" my/read-focus-center
                        :filter my/read--filter-workspace-key-binding))

(define-minor-mode my-read-workspace-keys-mode
  "Provide frame-scoped my-read navigation from every buffer."
  :global t
  :keymap my-read-workspace-keys-mode-map)

(my-read-workspace-keys-mode 1)

(defun my/read--private-dired-buffer (source frame)
  "Return a private Dired buffer for SOURCE belonging to FRAME.
SOURCE is a Dired buffer.  Keep private listings out of the ordinary
Dired buffer registry, including when the listing is reverted."
  (with-current-buffer source
    (if (eq my/read-dired-owner-frame frame)
        source
      (let* ((directory dired-directory)
             (file (dired-get-filename nil t))
             (existing
              (seq-find
               (lambda (buffer)
                 (with-current-buffer buffer
                   (and (eq my/read-dired-owner-frame frame)
                        (equal dired-directory directory))))
               (buffer-list)))
             (private
              (or existing
                  (let ((dired-buffers nil))
                    (dired-noselect directory)))))
        (with-current-buffer private
          (unless existing
            (rename-buffer (format "*my-read DIRED: %s*"
                                   (buffer-name source)) t)
            (setq-local my/read-dired-owner-frame frame)
            (setq-local dired-buffers
                        (list (cons (expand-file-name default-directory)
                                    private)))
            (dired-hide-details-mode 1)
            (setq-local dired-omit-files "\\`\\.\\(?:[^.]\\|\\..\\)"
                        dired-omit-extensions nil
                        dired-omit-lines nil
                        dired-omit-size-limit nil)
            (dired-omit-mode 1))
          (when file (dired-goto-file file)))
        private))))

(defcustom my/read-book-path
  "/Users/seijiro/Library/Mobile Documents/iCloud~md~obsidian/Documents/seijiro/000_org/einglish-book"
  "File or directory opened in the center reading window."
  :type 'file
  :group 'my-read)

(defcustom my/read-frame-name "my-read"
  "Base name of a frame created by `my-read'."
  :type 'string
  :group 'my-read)

(defun my/read-center-tab-buffers ()
  "Return FRAME's registered center-tab buffers in display order."
  (let ((frame my/read-center-tab-frame))
    (when (frame-live-p frame)
      (delq nil
            (mapcar (lambda (parameter)
                      (let ((buffer (frame-parameter frame parameter)))
                        (and (buffer-live-p buffer) buffer)))
                    '(my-reading-dired-buffer
                      my-reading-kindle-buffer
                      my-reading-pdf-buffer
                      my-reading-epub-buffer
                      my-reading-text-buffer
                      my-reading-eww-buffer))))))

(defun my/read-center-tab-name (buffer &optional _buffers)
  "Return a compact tab label for center reading BUFFER."
  (let ((frame (buffer-local-value 'my/read-center-tab-frame buffer)))
    (cond
     ((and (frame-live-p frame)
           (eq buffer (frame-parameter frame 'my-reading-kindle-buffer)))
      " KINDLE ")
     ((and (frame-live-p frame)
           (eq buffer (frame-parameter frame 'my-reading-epub-buffer)))
      " EPUB ")
     ((and (frame-live-p frame)
           (eq buffer (frame-parameter frame 'my-reading-pdf-buffer)))
      " PDF ")
     ((and (frame-live-p frame)
           (eq buffer (frame-parameter frame 'my-reading-dired-buffer)))
      " DIRED ")
     ((and (frame-live-p frame)
           (eq buffer (frame-parameter frame 'my-reading-eww-buffer)))
      " EWW ")
     ((and (frame-live-p frame)
           (eq buffer (frame-parameter frame 'my-reading-text-buffer)))
      " TEXT ")
     (t (format " %s " (buffer-name buffer))))))

(defun my/read--center-automatic-lookup-p (window)
  "Return non-nil when automatic Lookup should run for WINDOW."
  (and (window-live-p window)
       (with-current-buffer (window-buffer window)
         (or (not (derived-mode-p 'eww-mode))
             my/read-eww-enable-automatic-lookup))))

(defun my/read--center-source-buffer-p (buffer frame)
  "Return non-nil when BUFFER is a registered reading source in FRAME."
  (and (buffer-live-p buffer)
       (frame-live-p frame)
       (memq buffer
             (delq nil
                   (mapcar
                    (lambda (parameter)
                      (let ((candidate (frame-parameter frame parameter)))
                        (and (buffer-live-p candidate) candidate)))
                    '(my-reading-kindle-buffer
                      my-reading-pdf-buffer
                      my-reading-epub-buffer
                      my-reading-eww-buffer
                      my-reading-dired-buffer
                      my-reading-text-buffer))))))

(defun my/read--center-source-window-p (window frame)
  "Return non-nil when WINDOW displays a registered source in FRAME."
  (and (window-live-p window)
       (eq (window-frame window) frame)
       (memq window (my/read-center-windows frame))
       (my/read--center-source-buffer-p (window-buffer window) frame)))

(defun my/read--center-window-active-p ()
  "Return non-nil only in the selected my-read center reading window."
  (let* ((frame (selected-frame))
         (window (selected-window)))
    (and (my/read-frame-p frame)
         (my/read--center-source-window-p window frame)
         (eq (window-buffer window) (current-buffer))
         (eq my/read-center-tab-frame frame))))

(defun my/read--filter-center-key-binding (binding)
  "Return BINDING only while point is in my-read's center reading window."
  (when (my/read--center-window-active-p)
    binding))

(defun my/read-close-document ()
  "Close the active document and return to DIRED, preserving my-read."
  (interactive)
  (unless (my/read--center-window-active-p)
    (user-error "my-readのドキュメントペインで実行してください"))
  (let* ((frame (selected-frame))
         (center (selected-window))
         (source (current-buffer))
         (dired (frame-parameter frame 'my-reading-dired-buffer))
         (notes (my/read-note-window frame))
         (type (cl-find-if
                (lambda (kind)
                  (eq source (frame-parameter
                              frame (intern (format "my-reading-%s-buffer" kind)))))
                '(kindle pdf epub text eww))))
    (unless (buffer-live-p dired)
      (user-error "my-readのDIREDタブが見つかりません"))
    (if (or (not type) my/read-center-tab-placeholder-type)
        (progn
          (set-window-buffer center dired)
          (message "閉じるドキュメントがありません"))
      (my/read-position-save-buffer source center)
      (english-reading-mode-stop-continuous)
      ;; Move Org-noter's windows before its teardown can delete them.
      (when (window-live-p notes)
        (set-window-buffer notes (my/read--prepare-notes-buffer frame)))
      (set-window-buffer center dired)
      (select-window center)
      (my/read-org-noter-close-source source)
      (when (buffer-live-p source) (kill-buffer source))
      ;; A kill query may refuse closure.  Keep the document registered.
      (if (buffer-live-p source)
          (set-window-buffer center source)
        (when (eq type 'kindle)
          (my-read-k-detach)
          (set-frame-parameter frame 'my-reading-kindle-book-name nil))
        (let* ((parameter (intern (format "my-reading-%s-buffer" type)))
               (replacement
                (pcase type
                  ('eww
                   (set-frame-parameter frame parameter nil)
                   (my/read--prepare-eww-buffer frame))
                  ('kindle
                   (let ((buffer (my-read-k--prepare-buffer)))
                     (setq my-read-k--buffer buffer)
                     (with-current-buffer buffer
                       (let ((inhibit-read-only t))
                         (erase-buffer)
                         (insert "Kindleのドキュメントを閉じました。r で再接続します。\n")
                         (set-buffer-modified-p nil)))
                     buffer))
                  (_ (my/read--prepare-center-tab-placeholder frame type)))))
          (set-frame-parameter frame parameter replacement)
          (my/read--configure-center-tab-buffer replacement frame))
        (my/read-lookup-follow-post-command)
        (my/read-translate-follow-post-command)
        (message "%sのドキュメントを閉じました" (upcase (symbol-name type)))))))

(defun my/read--filter-eww-close-key-binding (binding)
  "Return BINDING only in the active my-read EWW reading pane."
  (when (and (my/read--center-window-active-p) (derived-mode-p 'eww-mode))
    binding))

(defun my/read-next-word ()
  "Move point to the beginning of the next word in the reading pane."
  (interactive)
  (let* ((origin (point))
         (bounds (bounds-of-thing-at-point 'word))
         (search-start (if bounds (cdr bounds) (point))))
    (goto-char search-start)
    (forward-word 1)
    (if (> (point) search-start)
        (backward-word 1)
      (goto-char origin)
      (message "Already at the last word"))))

(defun my/read-previous-word ()
  "Move point to the beginning of the previous word in the reading pane."
  (interactive)
  (let* ((origin (point))
         (bounds (bounds-of-thing-at-point 'word))
         (search-start (if bounds (car bounds) (point))))
    (goto-char search-start)
    (backward-word 1)
    (when (= (point) search-start)
      (goto-char origin)
      (message "Already at the first word"))))

(defvar my-read-center-tab-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c t")
                '(menu-item "Switch my-read tab" my/read-toggle-center-tab
                            :filter my/read--filter-center-key-binding))
    (define-key map (kbd "C-c p")
                '(menu-item "Read paragraph" kokoro-reader-speak-paragraph
                            :filter my/read--filter-center-key-binding))
    (define-key map (kbd "C-c n")
                '(menu-item "Read and advance" kokoro-reader-speak-and-forward
                            :filter my/read--filter-center-key-binding))
    (define-key map (kbd "C-c k")
                '(menu-item "Stop reading" kokoro-reader-stop
                            :filter my/read--filter-center-key-binding))
    (define-key map (kbd "C-c o")
                '(menu-item "Open Org-noter notes" my/read-org-noter-follow-source
                            :filter my/read--filter-center-key-binding))
    (define-key map (kbd "C-x k")
                '(menu-item "Close my-read document" my/read-close-document
                            :filter my/read--filter-center-key-binding))
    (define-key map (kbd "u")
                '(menu-item "Save vocabulary" my/read-vocab-capture
                            :filter my/read--filter-center-key-binding))
    (define-key map (kbd ";")
                '(menu-item "Next word" my/read-next-word
                            :filter my/read--filter-center-key-binding))
    (define-key map (kbd "l")
                '(menu-item "Previous word" my/read-previous-word
                            :filter my/read--filter-center-key-binding))
    map)
  "Keymap active in the my-read center tabs.")

;; Keep re-evaluation effective in a live Emacs where `defvar' preserves the
;; existing map object.
;; The review command now lives on `j' in the reading mode maps.
(define-key my-read-center-tab-mode-map (kbd "f") nil)

(keymap-set my-read-center-tab-mode-map "C-c t"
            '(menu-item "Switch my-read tab" my/read-toggle-center-tab
                        :filter my/read--filter-center-key-binding))

(keymap-set my-read-center-tab-mode-map "C-c p"
            '(menu-item "Read paragraph" kokoro-reader-speak-paragraph
                        :filter my/read--filter-center-key-binding))

(keymap-set my-read-center-tab-mode-map "C-c n"
            '(menu-item "Read and advance" kokoro-reader-speak-and-forward
                        :filter my/read--filter-center-key-binding))

(keymap-set my-read-center-tab-mode-map "C-c k"
            '(menu-item "Stop reading" kokoro-reader-stop
                        :filter my/read--filter-center-key-binding))

(keymap-set my-read-center-tab-mode-map "C-c o"
            '(menu-item "Open Org-noter notes" my/read-org-noter-follow-source
                        :filter my/read--filter-center-key-binding))

(keymap-set my-read-center-tab-mode-map "C-x k"
            '(menu-item "Close my-read document" my/read-close-document
                        :filter my/read--filter-center-key-binding))

(keymap-set my-read-center-tab-mode-map "u"
            '(menu-item "Save vocabulary" my/read-vocab-capture
                        :filter my/read--filter-center-key-binding))

(keymap-set my-read-center-tab-mode-map ";"
            '(menu-item "Next word" my/read-next-word
                        :filter my/read--filter-center-key-binding))

(keymap-set my-read-center-tab-mode-map "l"
            '(menu-item "Previous word" my/read-previous-word
                        :filter my/read--filter-center-key-binding))

(keymap-set my-read-center-tab-mode-map "C-x C-k"
            '(menu-item "Close my-read EWW page" my/read-close-eww
                        :filter my/read--filter-eww-close-key-binding))

(define-minor-mode my-read-center-tab-mode
  "Display the my-read center sources as a dedicated tab line."
  :init-value nil
  :lighter nil
  :keymap my-read-center-tab-mode-map
  (when (fboundp 'tab-line-mode)
    (tab-line-mode (if my-read-center-tab-mode 1 -1))))

(defun my/read--configure-center-tab-buffer (buffer frame)
  "Configure BUFFER as one of FRAME's center reading tabs."
  (when (buffer-live-p buffer)
    (my/read--repair-pdf-view-window buffer frame)
    (with-current-buffer buffer
      (setq-local my/read-center-tab-frame frame)
      (setq-local english-reading-mode-key-active-predicate
                  #'my/read--center-window-active-p)
      (setq-local tab-line-tabs-function #'my/read-center-tab-buffers)
      (setq-local tab-line-tab-name-function #'my/read-center-tab-name)
      (setq-local tab-line-close-button-show nil)
      (setq-local tab-line-new-button-show nil)
      (when (or (derived-mode-p 'nov-mode)
                (my/read--text-file-buffer-p))
        (my/read--configure-speech-language))
      (when (or (derived-mode-p 'nov-mode 'eww-mode 'doc-view-mode 'pdf-view-mode)
                (my/read--text-file-buffer-p))
        (english-reading-mode 1))
      (my/read--enable-pdf-continuous-scroll buffer frame)
      (my/read-position-setup-buffer buffer frame)
      (my-read-center-tab-mode 1))))

(defun my/read-toggle-center-tab ()
  "Cycle FRAME's center window through its registered tabs."
  (interactive)
  (let* ((frame (or my/read-center-tab-frame (selected-frame)))
         (window (my/read-center-window frame))
         (tabs (and (window-live-p window)
                    (with-current-buffer (window-buffer window)
                      (my/read-center-tab-buffers))))
         (current (and (window-live-p window) (window-buffer window)))
         (target (and (> (length tabs) 1)
                      (or (cadr (memq current tabs)) (car tabs)))))
    (unless (and target (not (eq target current)))
      (user-error "切り替えられる読書タブがありません"))
    (set-window-buffer window target)
    (select-window window)
    (my/read--repair-pdf-view-window target frame)
    (if (my/read--center-automatic-lookup-p window)
        (my/read-lookup-follow-post-command)
      ;; Do not let a Lookup queued by the previous EPUB/Kindle tab run after
      ;; the window has switched to EWW.
      (when (timerp my/read-lookup-timer)
        (cancel-timer my/read-lookup-timer))
      (setq my/read-lookup-timer nil
            my/read-lookup-last-target nil))
    (my/read-translate-follow-post-command)
    (when (fboundp 'my/read-org-noter-follow-source)
      (my/read-org-noter-follow-source frame))))

(defun my/read--track-center-tab-buffer (frame)
  "Remember a newly displayed center buffer in FRAME by source type."
  (when (and (frame-live-p frame) (my/read-frame-p frame))
    (when-let* ((window (my/read-center-window frame)))
      (when-let* ((file (with-current-buffer (window-buffer window)
                          (my/read--local-html-file))))
        (my/read--open-html-in-eww file frame))
      (let* ((buffer (window-buffer window))
             (kindle (frame-parameter frame 'my-reading-kindle-buffer))
             (parameter
              (unless (eq buffer kindle)
                (with-current-buffer buffer
                  (cond
                   ((derived-mode-p 'eww-mode)
                    'my-reading-eww-buffer)
                   ((derived-mode-p 'nov-mode)
                    'my-reading-epub-buffer)
                   ((derived-mode-p 'doc-view-mode 'pdf-view-mode)
                    'my-reading-pdf-buffer)
                   ((derived-mode-p 'dired-mode)
                    'my-reading-dired-buffer)
                   ((my/read--text-file-buffer-p)
                    'my-reading-text-buffer))))))
        (when parameter
          (when (eq parameter 'my-reading-dired-buffer)
            (setq buffer (my/read--private-dired-buffer buffer frame))
            (unless (eq buffer (window-buffer window))
              (set-window-buffer window buffer)))
          (set-frame-parameter frame parameter buffer)
          (my/read--configure-center-tab-buffer buffer frame)
          (when (and (eq window (my/read-center-window frame))
                     (fboundp 'my/read-org-noter-follow-source))
            (my/read-org-noter-follow-source frame)))))))

(add-hook 'window-buffer-change-functions #'my/read--track-center-tab-buffer)

(defun my/read--lookup-ensure-runtime ()
  "Ensure the user's normal Lookup runtime is initialized.

Do not assume that a particular Lookup fork exposes
`lookup-dictionary-list'.  A usable default module is enough for
`lookup-pattern', so only initialize when the module runtime is absent."
  (unless (featurep 'lookup)
    (require 'lookup))
  (when (and (fboundp 'lookup-initialize)
             (or (not (boundp 'lookup-module-list))
                 (null (symbol-value 'lookup-module-list))))
    (lookup-initialize))
  t)

(defun my/read-vocab-normalize-text (text)
  "Trim TEXT and collapse each run of whitespace to one space."
  (when (stringp text)
    (string-trim
     (replace-regexp-in-string "[[:space:]\u00a0]+" " " text))))

(defun my/read--prepare-notes-buffer (frame)
  "Create and return FRAME's Org-noter landing buffer."
  (let ((buffer (frame-parameter frame 'my-reading-note-ready-buffer)))
    (unless (buffer-live-p buffer)
      (setq buffer (generate-new-buffer "*Org-noter Ready*"))
      (set-frame-parameter frame 'my-reading-note-ready-buffer buffer))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (org-mode)
        (insert "* Org-noter\n\nPDF / EPUB / Kindleを開くと、この領域にノートを表示します。\n")))
    buffer))

(defun my/read--prepare-ready-buffer (frame)
  "Create and return FRAME's Lookup placeholder buffer."
  (let ((buffer (frame-parameter frame 'my-reading-lookup-ready-buffer)))
    (unless (buffer-live-p buffer)
      (setq buffer (generate-new-buffer "*Lookup Ready*"))
      (set-frame-parameter frame 'my-reading-lookup-ready-buffer buffer))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Lookup\n\n中央の単語へカーソルを置くと自動検索")
        (special-mode)))
    buffer))

(defun my/read--prepare-center-tab-placeholder (frame type)
  "Return FRAME's persistent empty center-tab placeholder for TYPE."
  (let* ((parameter (intern (format "my-reading-%s-placeholder-buffer" type)))
         (buffer (frame-parameter frame parameter)))
    (unless (buffer-live-p buffer)
      (setq buffer
            (generate-new-buffer
             (format "*my-read %s*" (upcase (symbol-name type)))))
      (set-frame-parameter frame parameter buffer))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode))
      (setq-local my/read-center-tab-placeholder-type type))
    buffer))

(defun my/read--setup-frame (frame &optional kindle-buffer)
  "Build the my-read layout inside FRAME.
When KINDLE-BUFFER is live, expose it with the center document tabs."
  (with-selected-frame frame
    (delete-other-windows)

    (let* ((center-window (selected-window))
           ;; Two columns: reading on the left, three utilities on the right.
           (note-window (split-window-right))
           epub-buffer
           text-buffer
           pdf-buffer
           dired-buffer
           eww-buffer
           translate-window
           lookup-window)

      ;; Right column: Org-noter, translation, then Lookup.
      (select-window note-window)
      (setq translate-window
            (split-window-below
             (max window-min-height
                  (floor (/ (window-total-height note-window) 3.0)))))
      (select-window translate-window)
      (setq lookup-window (split-window-below))

      ;; Store window identity on the frame.
      (set-frame-parameter frame 'my-reading-lookup-window lookup-window)
      (set-frame-parameter frame 'my-reading-center-window center-window)
      (set-frame-parameter frame 'my-reading-kindle-window center-window)
      (set-frame-parameter frame 'my-reading-epub-window center-window)
      (set-frame-parameter frame 'my-reading-pdf-window center-window)
      (set-frame-parameter frame 'my-reading-dired-window center-window)
      (set-frame-parameter frame 'my-reading-eww-window center-window)
      (set-frame-parameter frame 'my-reading-center-windows (list center-window))
      (set-frame-parameter frame 'my-reading-kindle-buffer kindle-buffer)
      (set-frame-parameter frame 'my-reading-translate-window translate-window)
      (set-frame-parameter frame 'my-reading-note-window note-window)
      ;; Lookup otherwise honors the user's global fractional height (0.7 in
      ;; this setup), which leaves too little room for dictionary content.
      (set-frame-parameter frame 'lookup-window-height
                           my/read-lookup-entry-window-height)

      ;; Lookup must not reuse stale internal windows from another frame.
      (when (boundp 'lookup-main-window)
        (setq lookup-main-window nil
              lookup-sub-window nil))

      ;; Right top: Org-noter notes placeholder (replaced by a live session).
      (set-window-buffer note-window (my/read--prepare-notes-buffer frame))

      ;; Right bottom: Lookup placeholder.
      (set-window-buffer lookup-window (my/read--prepare-ready-buffer frame))

      ;; Right middle: local translation with Google fallback.
      (let ((buffer (my/read-translate-buffer frame)))
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert
             (propertize "Translation\n\n"
                         'face 'font-lock-keyword-face))
            (insert
             "カーソル位置の1文を翻訳します。\nKokoro読み上げ中は読み上げている1文を翻訳します。")))
        (set-window-buffer translate-window buffer)
        (set-window-dedicated-p translate-window t))

      ;; Open the configured path and register it by source type.  Keep its
      ;; containing Dired buffer alive as a permanent tab even after RET opens
      ;; an EPUB or PDF in this same window.
      (select-window center-window)
      (let ((book-path (expand-file-name my/read-book-path)))
        (find-file book-path)
        (cond
         ((derived-mode-p 'dired-mode)
          (setq dired-buffer (current-buffer)))
         ((or (derived-mode-p 'pdf-view-mode 'doc-view-mode)
              (string-match-p "\\.pdf\\'" book-path))
          (setq pdf-buffer (current-buffer)))
         ((my/read--local-html-file)
          (setq eww-buffer
                (my/read--open-html-in-eww (my/read--local-html-file) frame)))
         ((my/read--text-file-buffer-p)
          (setq text-buffer (current-buffer)))
         (t
          (setq epub-buffer (current-buffer))))
        (unless (buffer-live-p dired-buffer)
          (require 'dired)
          (setq dired-buffer
                (dired-noselect
                 (if (file-directory-p book-path)
                     book-path
                   (file-name-directory book-path))))))
      (setq dired-buffer (my/read--private-dired-buffer dired-buffer frame))
      (unless (buffer-live-p kindle-buffer)
        (setq kindle-buffer
              (my/read--prepare-center-tab-placeholder frame 'kindle)))
      (unless (buffer-live-p pdf-buffer)
        (setq pdf-buffer
              (my/read--prepare-center-tab-placeholder frame 'pdf)))
      (unless (buffer-live-p epub-buffer)
        (setq epub-buffer
              (my/read--prepare-center-tab-placeholder frame 'epub)))
      (unless (buffer-live-p text-buffer)
        (setq text-buffer
              (my/read--prepare-center-tab-placeholder frame 'text)))
      (set-frame-parameter frame 'my-reading-kindle-buffer kindle-buffer)
      (set-frame-parameter frame 'my-reading-epub-buffer epub-buffer)
      (set-frame-parameter frame 'my-reading-pdf-buffer pdf-buffer)
      (set-frame-parameter frame 'my-reading-dired-buffer dired-buffer)
      (set-frame-parameter frame 'my-reading-text-buffer text-buffer)
      (dolist (buffer (list kindle-buffer pdf-buffer epub-buffer dired-buffer
                            text-buffer))
        (my/read--configure-center-tab-buffer buffer frame))

      ;; Keep an EWW buffer ready for arXiv without fetching the network until
      ;; the user opens the tab and presses `G'.
      (unless (buffer-live-p eww-buffer)
        (setq eww-buffer (my/read--prepare-eww-buffer frame)))
      (my/read--configure-center-tab-buffer eww-buffer frame)

      ;; DIRED is the leftmost and initially selected center tab.
      (when (buffer-live-p dired-buffer)
        (set-window-buffer center-window dired-buffer))

      ;; Start with the book directory visible.
      (select-window center-window)

      ;; Self-contained Lookup follower from this file.
      (my-read-lookup-follow-mode 1)

      ;; Translation follower from this file.
      (my-read-translate-follow-mode 1)

      ;; Initial refresh.
      (my/read-lookup-follow-post-command)
      (my/read-translate-follow-post-command)
      ;; Kindle attaches asynchronously; EPUB/PDF can start immediately.
      (my/read-org-noter-follow-source frame))))

;; Reading keys are installed buffer-locally by
;; `my/read--configure-center-tab-buffer' and filtered by the selected window.
;; Remove registrations left by older revisions when this file is reloaded.
(remove-hook 'nov-mode-hook #'english-reading-mode)

(remove-hook 'doc-view-mode-hook #'english-reading-mode)

(dolist (entry '(("C-c p" . kokoro-reader-speak-paragraph)
                 ("C-c n" . kokoro-reader-speak-and-forward)
                 ("C-c k" . kokoro-reader-stop)))
  (when (eq (lookup-key global-map (kbd (car entry))) (cdr entry))
    (define-key global-map (kbd (car entry)) nil)))

(provide 'my-read-ui)
;;; my-read-ui.el ends here
