;;; my-read-position.el --- Position for the reader -*- lexical-binding: t; -*-

(require 'my-read-core)
(require 'reader-state-file)
(require 'url-parse)
(require 'url-util)

(defcustom my/read-position-directory
  "/Users/seijiro/Library/Mobile Documents/iCloud~md~obsidian/Documents/seijiro/000_org/read-log"
  "Directory where PDF and EPUB reading positions are stored."
  :type 'directory
  :group 'my-read)

(defcustom my/read-position-save-delay 1.0
  "Idle seconds before saving the current PDF, EPUB, or text position."
  :type 'number
  :group 'my-read)

(defconst my/read-position-file-name "read-positions.el"
  "File name used below `my/read-position-directory'.")

(defvar-local my/read-position--restored-p nil)

(defvar-local my/read-position--restoring-p nil)

(defvar-local my/read-position--save-timer nil)

(defun my/read-position-file ()
  "Return the persistent PDF/EPUB/text position file."
  (expand-file-name my/read-position-file-name my/read-position-directory))

(defun my/read-position--source-type ()
  "Return this document's persistent source type, or nil."
  (reader-document-call :persistent-type))

(defun my/read-position--source-file ()
  "Return a stable source file for persistable documents."
  (when-let* ((file (and (my/read-position--source-type)
                         (reader-document-source))))
    (condition-case nil
        (file-truename file)
      (file-error (expand-file-name file)))))

(defun my/read-position--empty-data ()
  "Return an empty position data object."
  '(:version 1 :entries nil))

(defun my/read-position--valid-data-p (data)
  "Return non-nil when DATA is a valid position data object."
  (and (listp data)
       (equal (plist-get data :version) 1)
       (let ((entries (plist-get data :entries)))
         (and (listp entries)
              (cl-every (lambda (entry)
                          (and (consp entry)
                               (stringp (car entry))
                               (listp (cdr entry))))
                        entries)))))

(defun my/read-position--read-data ()
  "Read validated state without overwriting a corrupted file."
  (reader-state-file-read (my/read-position-file) #'my/read-position--valid-data-p
                          (my/read-position--empty-data) "読書位置"))

(defun my/read-position--write-data (data)
  "Atomically persist DATA with private permissions."
  (reader-state-file-write (my/read-position-file) data
                           ";;; my-read PDF/EPUB/text positions -*- mode: emacs-lisp; -*-"))

(defun my/read-position--snapshot (&optional window)
  "Return the document backend's persistent location for WINDOW."
  (when (my/read-position--source-type)
    (reader-document-current-location window)))

(defun my/read-position--merge-record (old new)
  "Merge non-nil values from NEW into position record OLD."
  (let ((record (copy-sequence old)))
    (while new
      (let ((key (pop new))
            (value (pop new)))
        (when value
          (setq record (plist-put record key value)))))
    (plist-put record :updated (float-time))))

(defun my/read-position-save-buffer (buffer &optional window)
  "Persist BUFFER's current PDF, EPUB, or text position, optionally using WINDOW."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when-let* ((key (and (not my/read-position--restoring-p)
                            (my/read-position--source-file)))
                  (snapshot (my/read-position--snapshot window)))
        (let ((data (my/read-position--read-data)))
          (unless (eq data :invalid)
            (let* ((entries (copy-tree (plist-get data :entries)))
                   (old (cdr (assoc-string key entries t)))
                   (record (my/read-position--merge-record old snapshot)))
              (setq entries (cons (cons key record)
                                  (cl-remove key entries
                                             :key #'car :test #'string-equal)))
              (setq entries (sort entries
                                  (lambda (a b) (string-lessp (car a) (car b)))))
              (my/read-position--write-data
               (list :version 1 :entries entries)))))))))

(defun my/read-position--save-buffer-now ()
  "Save the current reading buffer immediately."
  (when (timerp my/read-position--save-timer)
    (cancel-timer my/read-position--save-timer))
  (setq my/read-position--save-timer nil)
  (my/read-position-save-buffer
   (current-buffer) (get-buffer-window (current-buffer) t)))

(defun my/read-position--idle-save (buffer)
  "Save BUFFER after the configured idle delay."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq my/read-position--save-timer nil)
      (my/read-position-save-buffer
       buffer (get-buffer-window buffer t)))))

(defun my/read-position--schedule-save ()
  "Schedule a debounced position save for the current reading buffer."
  (when (and (my/read-position--source-type)
             (not my/read-position--restoring-p))
    (when (timerp my/read-position--save-timer)
      (cancel-timer my/read-position--save-timer))
    (setq my/read-position--save-timer
          (run-with-idle-timer my/read-position-save-delay nil
                               #'my/read-position--idle-save
                               (current-buffer)))))

(defalias 'my/read-position--clamp #'reader-document-text--clamp)


(defalias 'my/read-position--restore-epub #'reader-document-epub--restore)

(defalias 'my/read-position--restore-text #'reader-document-text--restore)

(defun my/read-position--speech-start (context)
  "Save a text source's spoken position even without keyboard activity."
  (let ((buffer (plist-get context :buffer))
        (frame (plist-get context :frame))
        (window (plist-get context :window)))
    (when (and (buffer-live-p buffer)
               (frame-live-p frame)
               (my/read-frame-p frame)
               (my/read--center-source-window-p window frame))
      (with-current-buffer buffer
        (when (memq (my/read-position--source-type) '(text html))
          (let ((english-reading-mode--active-speech context))
            (my/read-position-save-buffer buffer window)))))))

(add-hook 'english-reading-mode-speech-start-hook
          #'my/read-position--speech-start)

(defun my/read-position-restore-buffer (buffer frame)
  "Restore BUFFER's saved position in FRAME once."
  (when (and (buffer-live-p buffer) (frame-live-p frame))
    (with-current-buffer buffer
      (unless (or my/read-position--restored-p
                  (and (memq (my/read-position--source-type) '(text html))
                       (not (eq buffer (window-buffer
                                        (my/read-center-window frame))))))
        (setq my/read-position--restored-p t)
        (when-let* ((key (my/read-position--source-file))
                    (window (my/read-center-window frame)))
          (let ((data (my/read-position--read-data)))
            (unless (eq data :invalid)
              (when-let* ((record
                           (cdr (assoc-string
                                 key (plist-get data :entries) t))))
                (let ((my/read-position--restoring-p t))
                  (reader-document-restore-location record window))))))))))

(defun my/read-position-setup-buffer (buffer frame)
  "Enable persistent position tracking for BUFFER in FRAME."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (my/read-position--source-type)
        (add-hook 'post-command-hook #'my/read-position--schedule-save nil t)
        (add-hook 'kill-buffer-hook #'my/read-position--save-buffer-now nil t)
        (my/read-position-restore-buffer buffer frame)))))

(defun my/read-position-save-frame (frame)
  "Persist PDF, EPUB, and text positions belonging to FRAME."
  (when (framep frame)
    (let ((window (and (frame-live-p frame) (my/read-center-window frame))))
      (dolist (buffer
               (delete-dups
                (delq nil
                      (list (frame-parameter frame 'my-reading-epub-buffer)
                            (frame-parameter frame 'my-reading-pdf-buffer)
                            (frame-parameter frame 'my-reading-text-buffer)
                            (frame-parameter frame 'my-reading-eww-buffer)
                            (and (window-live-p window)
                                 (window-buffer window))))))
        (my/read-position-save-buffer
         buffer (and (window-live-p window)
                     (eq (window-buffer window) buffer)
                     window))))))

(provide 'my-read-position)
;;; my-read-position.el ends here
