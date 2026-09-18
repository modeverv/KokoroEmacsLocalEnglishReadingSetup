;;; reader-state-file.el --- Validated atomic reader state files -*- lexical-binding: t; -*-

(defun reader-state-file-read (file validator empty label)
  "Read FILE using VALIDATOR, returning EMPTY if absent.
Return :invalid for unreadable or malformed data without changing FILE.
LABEL identifies the data in the recovery message.
Data is read, never evaluated."
  (if (not (file-exists-p file))
      empty
    (condition-case err
        (with-temp-buffer
          (insert-file-contents file)
          (let ((data (read (current-buffer))))
            (skip-chars-forward " \t\r\n")
            (unless (and (eobp) (funcall validator data))
              (error "invalid %s data" label))
            data))
      (error
       (message "my-read: %sファイルを保護しました（%s）"
                label (error-message-string err))
       :invalid))))

(defun reader-state-file-write (file data header)
  "Atomically write DATA to FILE, prefixed with HEADER, with private permissions."
  (let* ((file (expand-file-name file))
         (directory (file-name-directory file))
         temp)
    (make-directory directory t)
    (setq temp (make-temp-file (expand-file-name ".reader-state-" directory)))
    (unwind-protect
        (progn
          (with-temp-buffer
            (insert header "\n")
            (let ((print-length nil) (print-level nil))
              (prin1 data (current-buffer)))
            (insert "\n")
            (write-region (point-min) (point-max) temp nil 'silent))
          (set-file-modes temp #o600)
          (rename-file temp file t)
          (setq temp nil))
      (when (and temp (file-exists-p temp))
        (delete-file temp)))))

(provide 'reader-state-file)
;;; reader-state-file.el ends here
