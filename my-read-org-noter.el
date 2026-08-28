;;; my-read-org-noter.el --- Org-noter integration for my-read -*- lexical-binding: t; -*-

;; This module keeps org-noter's document model and note format, but teaches it
;; how to use the fixed my-read window layout and the virtual Kindle document.

(require 'cl-lib)
(require 'eww)
(require 'org)
(require 'subr-x)
(require 'org-noter)

(defgroup my-read-org-noter nil
  "Org-noter integration for the my-read workspace."
  :group 'my-read)

(defcustom my/read-org-noter-directory
  (expand-file-name
   "/Users/seijiro/Library/Mobile Documents/iCloud~md~obsidian/Documents/seijiro/000_org/read")
  "Root directory for Org-noter files created by my-read."
  :type 'directory
  :group 'my-read-org-noter)

(defcustom my/read-org-noter-file-name "org-noter.org"
  "File name used below each source directory."
  :type 'string
  :group 'my-read-org-noter)

(defvar my-read-k--current-result)
(defvar my-read-k--last-fingerprint)
(defvar my-read-k--page-number)
(defvar my-read-k--target-url)
(defvar my/read-eww-history-page-p)

(declare-function my/read-center-window "my-read" (&optional frame))
(declare-function my/read-frame-p "my-read" (&optional frame))
(declare-function my/read-note-window "my-read" (&optional frame))
(declare-function my/read-vocab-current-book-title "my-read" (&optional buffer frame))
(declare-function my-read-k--alist-get "my-read-k" (key alist))

(defvar my/read-org-noter--sync-timer nil
  "Idle timer used to synchronize the active Org-noter notes pane.")

(defun my/read-org-noter--slug (title)
  "Return a filesystem-safe directory name for TITLE."
  (let* ((title (string-trim (or title "Unknown source")))
         (slug (replace-regexp-in-string "[\0/:\\]+" "_" title)))
    (setq slug (replace-regexp-in-string "[[:space:]]+" " " slug))
    (if (> (length slug) 100) (substring slug 0 100) slug)))

(defun my/read-org-noter--kindle-buffer-p (buffer)
  "Return non-nil when BUFFER is the my-read Kindle document."
  (and (buffer-live-p buffer)
       (buffer-local-value 'my-read-k-mode buffer)))

(defun my/read-org-noter--eww-buffer-p (buffer)
  "Return non-nil when BUFFER is a rendered EWW document."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (derived-mode-p 'eww-mode))))

(defun my/read-org-noter--eww-url (&optional buffer)
  "Return BUFFER's canonical EWW URL without a fragment."
  (with-current-buffer (or buffer (current-buffer))
    (when-let ((url (and (boundp 'eww-data)
                         (plist-get eww-data :url))))
      (replace-regexp-in-string "#.*\\'" "" url))))

(defun my/read-org-noter--eww-property (&optional buffer)
  "Return the virtual NOTER_DOCUMENT value for EWW BUFFER."
  (when-let ((url (my/read-org-noter--eww-url buffer)))
    (format "[[eww:%s]]" (org-link-escape url))))

(defun my/read-org-noter--eww-url-from-property (property)
  "Return the URL encoded by EWW document PROPERTY, or nil."
  (when (stringp property)
    (let ((path
           (cond
            ((and (string-prefix-p "[[eww:" property)
                  (string-suffix-p "]]" property))
             (substring property 6 -2))
            ((string-prefix-p "eww:" property)
             (substring property 4)))))
      (and path (org-link-unescape path)))))

(defun my/read-org-noter--eww-mode-p (mode)
  "Return non-nil when MODE identifies a virtual EWW document."
  (or (eq mode 'eww-mode)
      (my/read-org-noter--eww-url-from-property mode)))

(defun my/read-org-noter--document-file (buffer)
  "Return the real document filename represented by BUFFER, or nil."
  (with-current-buffer buffer
    (or (and (derived-mode-p 'nov-mode)
             (boundp 'nov-file-name)
             nov-file-name)
        buffer-file-name)))

(defun my/read-org-noter--kindle-property (&optional buffer frame)
  "Return the virtual NOTER_DOCUMENT value for Kindle BUFFER in FRAME."
  (let ((title (my/read-vocab-current-book-title
                (or buffer (current-buffer))
                (or frame (selected-frame)))))
    ;; Org-noter's document validator accepts Org links.  The custom opener
    ;; below resolves this virtual link back to the live Kindle buffer.
    (format "[[kindle:%s]]" (secure-hash 'sha1 title))))

(defun my/read-org-noter--kindle-mode-p (mode)
  "Return non-nil when MODE identifies the virtual Kindle document."
  (or (eq mode 'my-read-k-document-mode)
      (and (stringp mode) (string-prefix-p "[[kindle:" mode))))

(defun my/read-org-noter--document-property (buffer frame)
  "Return Org-noter's document property for BUFFER in FRAME."
  (cond
   ((my/read-org-noter--kindle-buffer-p buffer)
    (my/read-org-noter--kindle-property buffer frame))
   ((my/read-org-noter--eww-buffer-p buffer)
    (my/read-org-noter--eww-property buffer))
   (t (my/read-org-noter--document-file buffer))))

(defun my/read-org-noter--supported-buffer-p (buffer)
  "Return non-nil when BUFFER is a PDF, EPUB, EWW, or Kindle source."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (or (my/read-org-noter--kindle-buffer-p buffer)
             (and (memq major-mode
                        '(doc-view-mode pdf-view-mode nov-mode eww-mode))
                  (not (and (eq major-mode 'eww-mode)
                            (bound-and-true-p
                             my/read-eww-history-page-p))))))))

(defun my/read-org-noter--notes-file (buffer frame)
  "Return the canonical notes filename for BUFFER in FRAME."
  (let ((title (my/read-vocab-current-book-title buffer frame)))
    (expand-file-name
     my/read-org-noter-file-name
     (expand-file-name (my/read-org-noter--slug title)
                       my/read-org-noter-directory))))

(defun my/read-org-noter--ensure-root (buffer frame)
  "Return (NOTES-BUFFER . ROOT-POSITION) for source BUFFER in FRAME."
  (let* ((property (my/read-org-noter--document-property buffer frame))
         (title (my/read-vocab-current-book-title buffer frame))
         (file (my/read-org-noter--notes-file buffer frame))
         (directory (file-name-directory file))
         root)
    (unless property
      (user-error "This reader buffer has no document identity"))
    (make-directory directory t)
    (with-current-buffer (find-file-noselect file)
      (unless (derived-mode-p 'org-mode) (org-mode))
      (org-with-wide-buffer
       (goto-char (point-min))
       (while (and (not root)
                   (re-search-forward
                    (org-re-property org-noter-property-doc-file) nil t))
         (when (or (equal (match-string-no-properties 3) property)
                   ;; Migrate notes created by the first virtual-document
                   ;; revision, before the Kindle identity became an Org link.
                   (and (string-prefix-p "[[kindle:" property)
                        (equal (match-string-no-properties 3)
                               (substring property 2 -2))))
           (setq root (save-excursion
                        (org-back-to-heading t)
                        (point)))
           (org-entry-put root org-noter-property-doc-file property)))
       (unless root
         (goto-char (point-max))
         (unless (or (= (point) (point-min)) (bolp)) (insert "\n"))
         (unless (= (point) (point-min)) (insert "\n"))
         (setq root (point))
         (insert "* " title "\n")
         (org-entry-put root org-noter-property-doc-file property)
         (save-buffer))
       (when (buffer-modified-p) (save-buffer)))
      (cons (current-buffer) root))))

(defun my/read-org-noter--session-for-buffer (buffer)
  "Return the live Org-noter session whose document is BUFFER."
  (cl-find-if
   (lambda (session)
     (and (org-noter--valid-session session)
          (eq (org-noter--session-doc-buffer session) buffer)))
   org-noter--sessions))

(defun my/read-org-noter-close-source (buffer)
  "Close BUFFER's Org-noter session without deleting its my-read frame.

Return non-nil when an active session was found.  The caller must first move
the document and notes windows to other buffers; this prevents Org-noter's
normal session teardown from deleting those windows."
  (when-let ((session (my/read-org-noter--session-for-buffer buffer)))
    (let ((frame (org-noter--session-frame session))
          (notes-buffer (org-noter--session-notes-buffer session))
          completed)
      (unwind-protect
          (condition-case err
              (progn
                ;; `org-noter-kill-session' normally treats the session frame
                ;; as disposable.  my-read owns it, so detach it only for the
                ;; synchronous teardown.
                (setf (org-noter--session-frame session) nil)
                (org-noter-kill-session session)
                (setq completed t))
            (error
             ;; Org-noter removes the session before parsing its notes root.
             ;; If that parsing fails, finish the buffer-local cleanup so the
             ;; caller can still kill the PDF without re-entering teardown.
             (setq org-noter--sessions (delq session org-noter--sessions))
             (dolist (owned-buffer (list buffer notes-buffer))
               (when (buffer-live-p owned-buffer)
                 (with-current-buffer owned-buffer
                   (remove-hook 'kill-buffer-hook
                                #'org-noter--handle-kill-buffer t))))
             (message "Org-noter cleanup fallback: %s"
                      (error-message-string err))))
        (when (and (not completed) (memq session org-noter--sessions))
          (setf (org-noter--session-frame session) frame))))
    t))

(defun my/read-org-noter--reattach-session (session)
  "Restore Org-noter buffer-local state for an existing SESSION.

Changing a PDF buffer from DocView to PDF Tools runs a new major mode and
clears Org-noter's buffer-local handler, minor mode, and session pointer."
  (let ((document-buffer (org-noter--session-doc-buffer session)))
    (with-current-buffer document-buffer
      (unless (and org-noter-doc-mode
                   (eq org-noter--session session))
        (or (run-hook-with-args-until-success
             'org-noter-set-up-document-hook major-mode)
            (run-hook-with-args-until-success
             'org-noter-set-up-document-hook
             (org-noter--session-property-text session))
            (error "This document handler is not supported :/"))
        (setf (org-noter--session-doc-mode session) major-mode)
        (org-noter-doc-mode 1)
        (setq org-noter--session session)
        (add-hook 'kill-buffer-hook #'org-noter--handle-kill-buffer nil t)))))

(defun my/read-org-noter--setup-windows (original session)
  "Use fixed my-read panes for SESSION, otherwise call ORIGINAL."
  (let* ((frame (org-noter--session-frame session))
         (center (and (frame-live-p frame) (my/read-center-window frame)))
         (notes (and (frame-live-p frame) (my/read-note-window frame))))
    (if (not (and (my/read-frame-p frame)
                  (window-live-p center)
                  (window-live-p notes)))
        (funcall original session)
      (set-window-buffer center (org-noter--session-doc-buffer session))
      (set-window-buffer notes (org-noter--session-notes-buffer session))
      (with-current-buffer (org-noter--session-notes-buffer session)
        (unless org-noter-disable-narrowing
          (org-noter--narrow-to-root (org-noter--parse-root session)))
        (org-noter--set-notes-scroll notes))
      notes)))

(advice-remove 'org-noter--setup-windows #'my/read-org-noter--setup-windows)
(advice-add 'org-noter--setup-windows :around #'my/read-org-noter--setup-windows)

(defun my/read-org-noter--kindle-open-document (property)
  "Return a live Kindle buffer matching virtual document PROPERTY."
  (when (and (stringp property)
             (or (string-prefix-p "kindle:" property)
                 (string-prefix-p "[[kindle:" property)))
    (cl-find-if
     (lambda (buffer)
       (and (my/read-org-noter--kindle-buffer-p buffer)
            (let ((frame (buffer-local-value 'my/read-center-tab-frame buffer)))
              (and (frame-live-p frame)
                   (equal property
                          (my/read-org-noter--kindle-property buffer frame))))))
     (buffer-list))))

(add-to-list 'org-noter-open-document-functions
             #'my/read-org-noter--kindle-open-document)

(defun my/read-org-noter--eww-open-document (property)
  "Return an EWW buffer for virtual document PROPERTY."
  (when-let ((url (my/read-org-noter--eww-url-from-property property)))
    (or (cl-find-if
         (lambda (buffer)
           (and (my/read-org-noter--eww-buffer-p buffer)
                (equal url (my/read-org-noter--eww-url buffer))))
         (buffer-list))
        (save-window-excursion
          (eww url t)
          (current-buffer)))))

(add-to-list 'org-noter-open-document-functions
             #'my/read-org-noter--eww-open-document)

(defun my/read-org-noter--eww-heading-positions (&optional buffer)
  "Return ordered SHR heading positions in EWW BUFFER."
  (with-current-buffer (or buffer (current-buffer))
    (let ((position (point-min))
          positions)
      (while (< position (point-max))
        (when (and (get-text-property position 'outline-level)
                   (or (= position (point-min))
                       (not (get-text-property (1- position)
                                               'outline-level))))
          (push position positions))
        (setq position
              (or (next-single-property-change
                   position 'outline-level nil (point-max))
                  (point-max))))
      (nreverse positions))))

(defun my/read-org-noter--eww-location-at (position)
  "Return EWW section and body offset for buffer POSITION."
  (let* ((position (min (max position (point-min)) (point-max)))
         (headings (my/read-org-noter--eww-heading-positions))
         (section 0)
         (base (point-min)))
    (catch 'found
      (dolist (heading headings)
        (if (> heading position)
            (throw 'found nil)
          (setq section (1+ section)
                base heading))))
    (cons section (max 0 (- position base)))))

(defun my/read-org-noter--eww-heading-at-location (location)
  "Return the heading text represented by EWW LOCATION."
  (let* ((section (car location))
         (heading (and (> section 0)
                       (nth (1- section)
                            (my/read-org-noter--eww-heading-positions)))))
    (if heading
        (string-trim
         (save-excursion
           (goto-char heading)
           (buffer-substring-no-properties heading (line-end-position))))
      "Top")))

(defun my/read-org-noter--eww-approx-location
    (mode &optional precise-info _force-new-ref)
  "Return Org-noter section and body offset for EWW document MODE."
  (when (my/read-org-noter--eww-mode-p mode)
    (my/read-org-noter--eww-location-at
     (cond
      ((numberp precise-info) precise-info)
      ((and (consp precise-info) (numberp (car precise-info)))
       (car precise-info))
      (t (point))))))

(add-to-list 'org-noter--doc-approx-location-hook
             #'my/read-org-noter--eww-approx-location)

(defun my/read-org-noter--eww-scroll (&rest _)
  "Schedule EWW note synchronization after window scrolling."
  (my/read-org-noter--schedule-sync))

(defun my/read-org-noter--eww-after-render ()
  "Follow a newly rendered URL when this EWW buffer is visible in my-read."
  (when-let ((frame (and (boundp 'my/read-center-tab-frame)
                         my/read-center-tab-frame)))
    (let ((center (and (frame-live-p frame)
                       (my/read-center-window frame))))
      (when (and (window-live-p center)
                 (eq (window-buffer center) (current-buffer)))
        (my/read-org-noter-follow-source frame)))))

(defun my/read-org-noter--eww-setup (mode)
  "Set up Org-noter synchronization for EWW document MODE."
  (when (my/read-org-noter--eww-mode-p mode)
    (add-hook 'post-command-hook #'my/read-org-noter--schedule-sync nil t)
    (add-hook 'window-scroll-functions #'my/read-org-noter--eww-scroll nil t)
    (add-hook 'eww-after-render-hook
              #'my/read-org-noter--eww-after-render nil t)
    t))

(add-to-list 'org-noter-set-up-document-hook
             #'my/read-org-noter--eww-setup)

(defun my/read-org-noter--eww-current-view (mode)
  "Return Org-noter's current continuous view for EWW MODE."
  (when (my/read-org-noter--eww-mode-p mode)
    (vector 'nov
            (my/read-org-noter--eww-location-at (window-start))
            (my/read-org-noter--eww-location-at (window-end nil t)))))

(add-to-list 'org-noter--get-current-view-hook
             #'my/read-org-noter--eww-current-view)

(defun my/read-org-noter--eww-pretty-location (location)
  "Serialize EWW LOCATION in Org-noter's readable form."
  (org-noter--with-valid-session
   (when (my/read-org-noter--eww-mode-p
          (org-noter--session-doc-mode session))
     (format "%S" location))))

(add-to-list 'org-noter--pretty-print-location-hook
             #'my/read-org-noter--eww-pretty-location)

(defun my/read-org-noter--eww-title-location (location)
  "Return a heading-aware title fragment for EWW LOCATION."
  (org-noter--with-valid-session
   (when (my/read-org-noter--eww-mode-p
          (org-noter--session-doc-mode session))
     (with-current-buffer (org-noter--session-doc-buffer session)
       (format "%s +%s"
               (my/read-org-noter--eww-heading-at-location location)
               (cdr location))))))

(add-to-list 'org-noter--pretty-print-location-for-title-hook
             #'my/read-org-noter--eww-title-location)

(defun my/read-org-noter--eww-goto (mode location &optional _window)
  "Go to the EWW heading and body offset represented by LOCATION."
  (when (my/read-org-noter--eww-mode-p mode)
    (let* ((section (car location))
           (headings (my/read-org-noter--eww-heading-positions))
           (base (if (> section 0)
                     (or (nth (1- section) headings) (car (last headings)))
                   (point-min)))
           (next (and (> section 0) (nth section headings)))
           (limit (or next (point-max)))
           (target (min limit (+ (or base (point-min)) (cdr location)))))
      (goto-char (max (point-min) target))
      (recenter)
      t)))

(add-to-list 'org-noter--doc-goto-location-hook
             #'my/read-org-noter--eww-goto)

(defun my/read-org-noter--eww-selected-text (mode)
  "Return selected EWW text for Org-noter document MODE."
  (when (and (my/read-org-noter--eww-mode-p mode) (use-region-p))
    (buffer-substring-no-properties (region-beginning) (region-end))))

(add-to-list 'org-noter-get-selected-text-hook
             #'my/read-org-noter--eww-selected-text)

(defun my/read-org-noter--kindle-page ()
  "Return Kindle's best current numeric page/location identifier."
  (or (and (listp my-read-k--current-result)
           (my-read-k--alist-get 'start my-read-k--current-result))
      my-read-k--page-number
      1))

(defun my/read-org-noter--kindle-approx-location
    (mode &optional precise-info _force-new-ref)
  "Return Org-noter location for Kindle document MODE."
  (when (my/read-org-noter--kindle-mode-p mode)
    (cons (my/read-org-noter--kindle-page)
          (if (numberp precise-info) precise-info (point)))))

(add-to-list 'org-noter--doc-approx-location-hook
             #'my/read-org-noter--kindle-approx-location)

(defun my/read-org-noter--kindle-setup (mode)
  "Set up Org-noter synchronization for Kindle document MODE."
  (when (my/read-org-noter--kindle-mode-p mode)
    (add-hook 'post-command-hook #'my/read-org-noter--schedule-sync nil t)
    t))

(add-to-list 'org-noter-set-up-document-hook
             #'my/read-org-noter--kindle-setup)
(add-to-list 'org-noter-supported-modes 'my-read-k-document-mode)

(defun my/read-org-noter--kindle-current-view (mode)
  "Return Org-noter's current paged view for Kindle MODE."
  (when (my/read-org-noter--kindle-mode-p mode)
    (vector 'paged (my/read-org-noter--kindle-page))))

(add-to-list 'org-noter--get-current-view-hook
             #'my/read-org-noter--kindle-current-view)

(defun my/read-org-noter--kindle-pretty-location (location)
  "Serialize Kindle LOCATION in Org-noter's standard readable form."
  (org-noter--with-valid-session
   (when (my/read-org-noter--kindle-mode-p
          (org-noter--session-doc-mode session))
     (format "%S" location))))

(add-to-list 'org-noter--pretty-print-location-hook
             #'my/read-org-noter--kindle-pretty-location)

(defun my/read-org-noter--kindle-title-location (location)
  "Return a human-readable title fragment for Kindle LOCATION."
  (org-noter--with-valid-session
   (when (my/read-org-noter--kindle-mode-p
          (org-noter--session-doc-mode session))
     (format "Kindle %s" (car location)))))

(add-to-list 'org-noter--pretty-print-location-for-title-hook
             #'my/read-org-noter--kindle-title-location)

(defun my/read-org-noter--kindle-goto (mode location &optional _window)
  "Go to Kindle LOCATION when it belongs to the currently visible MODE page."
  (when (my/read-org-noter--kindle-mode-p mode)
    (unless (= (car location) (my/read-org-noter--kindle-page))
      (user-error
       "Kindle cannot jump to an arbitrary saved location; open location %s first"
       (car location)))
    (goto-char (min (max (cdr location) (point-min)) (point-max)))
    (recenter)
    t))

(add-to-list 'org-noter--doc-goto-location-hook
             #'my/read-org-noter--kindle-goto)

(defun my/read-org-noter--kindle-selected-text (mode)
  "Return the selected Kindle text for Org-noter document MODE."
  (when (and (my/read-org-noter--kindle-mode-p mode) (use-region-p))
    (buffer-substring-no-properties (region-beginning) (region-end))))

(add-to-list 'org-noter-get-selected-text-hook
             #'my/read-org-noter--kindle-selected-text)

(defun my/read-org-noter--record-kindle-metadata ()
  "Append stable Kindle page/location metadata to a newly inserted note."
  (when (and org-noter--session
             (my/read-org-noter--kindle-mode-p
              (org-noter--session-doc-mode org-noter--session)))
    (let* ((doc (org-noter--session-doc-buffer org-noter--session))
           (result (and (buffer-live-p doc)
                        (buffer-local-value 'my-read-k--current-result doc)))
           (start (and result (my-read-k--alist-get 'start result)))
           (end (and result (my-read-k--alist-get 'end result)))
           (fingerprint (and result
                             (my-read-k--alist-get 'fingerprint result)))
           (offset (cdr (with-current-buffer doc
                          (my/read-org-noter--kindle-approx-location
                           'my-read-k-document-mode)))))
      (org-entry-put nil "KINDLE_LOCATION"
                     (if start
                         (format "%s-%s, offset %s" start (or end "?") offset)
                       (format "page %s, offset %s"
                               (with-current-buffer doc
                                 (my/read-org-noter--kindle-page))
                               offset)))
      (when fingerprint
        (org-entry-put nil "KINDLE_FINGERPRINT" fingerprint)))))

(add-hook 'org-noter-insert-heading-hook
          #'my/read-org-noter--record-kindle-metadata)

(defun my/read-org-noter--sync-now (buffer)
  "Synchronize Org-noter notes for document BUFFER."
  (setq my/read-org-noter--sync-timer nil)
  (when (buffer-live-p buffer)
    (let* ((frame (buffer-local-value 'my/read-center-tab-frame buffer))
           (center (and (frame-live-p frame)
                        (my/read-center-window frame))))
      ;; This idle timer may fire after EPUB or EWW has been selected.
      ;; Org-noter's handler otherwise recreates its hidden document window
      ;; by replacing the newly selected tab with this stale Kindle buffer.
      (when (and (buffer-local-value 'org-noter--session buffer)
                 (window-live-p center)
                 (eq (window-buffer center) buffer))
        (with-current-buffer buffer
          (ignore-errors (org-noter--doc-location-change-handler)))))))

(defun my/read-org-noter--schedule-sync ()
  "Debounce Org-noter synchronization after document movement."
  (when (timerp my/read-org-noter--sync-timer)
    (cancel-timer my/read-org-noter--sync-timer))
  (setq my/read-org-noter--sync-timer
        (run-with-idle-timer 0.15 nil
                            #'my/read-org-noter--sync-now
                            (current-buffer))))

(defun my/read-org-noter--session-matches-source-p (session source frame)
  "Return non-nil when SESSION still represents SOURCE in FRAME."
  (or (not (my/read-org-noter--eww-buffer-p source))
      (equal (org-noter--session-property-text session)
             (my/read-org-noter--document-property source frame))))

(defun my/read-org-noter--detach-reused-eww-session (session)
  "Detach SESSION without killing its reused EWW document buffer."
  (setq org-noter--sessions (delq session org-noter--sessions))
  (let ((document (org-noter--session-doc-buffer session))
        (notes (org-noter--session-notes-buffer session)))
    (when (buffer-live-p document)
      (with-current-buffer document
        (remove-hook 'kill-buffer-hook #'org-noter--handle-kill-buffer t)
        (when org-noter-doc-mode (org-noter-doc-mode -1))
        (setq org-noter--session nil)))
    (when (buffer-live-p notes)
      (with-current-buffer notes
        (remove-hook 'kill-buffer-hook #'org-noter--handle-kill-buffer t)
        (when org-noter-notes-mode (org-noter-notes-mode -1))
        (setq org-noter--session nil)))))

(defun my/read-org-noter-follow-source (&optional frame)
  "Show or create the Org-noter notes session for FRAME's active source."
  (interactive)
  (let* ((frame (or frame (selected-frame)))
         (frame-name (frame-parameter frame 'name))
         (center (my/read-center-window frame))
         (notes-window (my/read-note-window frame))
         (source (and (window-live-p center) (window-buffer center))))
    (when (and (window-live-p notes-window)
               (my/read-org-noter--supported-buffer-p source)
               (or (not (my/read-org-noter--kindle-buffer-p source))
                   (frame-parameter frame 'my-reading-kindle-book-name)))
      (let ((session (my/read-org-noter--session-for-buffer source)))
        (when (and session
                   (not (my/read-org-noter--session-matches-source-p
                         session source frame)))
          (my/read-org-noter--detach-reused-eww-session session)
          (setq session nil))
        (if session
            (progn
              (my/read-org-noter--reattach-session session)
              (set-window-buffer notes-window
                                 (org-noter--session-notes-buffer session)))
          (pcase-let* ((`(,notes-buffer . ,root)
                        (my/read-org-noter--ensure-root source frame))
                       (org-noter-always-create-frame nil)
                       (org-noter-notes-window-behavior '(start scroll))
                       (org-noter-disable-narrowing nil))
            (set-window-buffer notes-window notes-buffer)
            (with-selected-frame frame
              (with-selected-window notes-window
                (goto-char root)
                (org-noter)))
            ;; Org-noter renames a reused frame.  Keep the workspace identity
            ;; stable because other reader UI and the user refer to it as my-read.
            (set-frame-parameter frame 'name frame-name))))
      ;; PDF setup (and especially a DocView -> PDF Tools transition) may run
      ;; the major mode again, which clears my-read's buffer-local minor modes.
      (my/read--configure-center-tab-buffer source frame))))

(provide 'my-read-org-noter)
;;; my-read-org-noter.el ends here
