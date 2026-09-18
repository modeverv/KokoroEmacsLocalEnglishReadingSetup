;;; reader-document.el --- Extensible document operations -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)

(defvar reader-document--backends nil
  "Backend descriptors, ordered from most specific to least specific.")

(defun reader-document-register (name predicate operations &optional parent)
  "Register NAME with PREDICATE, OPERATIONS plist and optional PARENT.
PREDICATE runs in the source buffer.  Operations run in that same buffer;
missing operations are inherited from PARENT.  Registering NAME again
replaces its descriptor, so loading a backend twice is safe."
  (when (eq name parent) (error "A document backend cannot inherit itself"))
  (if-let* ((existing (assq name reader-document--backends)))
      (setcdr existing (list predicate operations parent))
    (push (list name predicate operations parent) reader-document--backends))
  name)

(defun reader-document-backend (&optional buffer)
  "Return BUFFER's document backend, defaulting to the current buffer."
  (with-current-buffer (or buffer (current-buffer))
    (car (cl-find-if (lambda (entry) (funcall (nth 1 entry)))
                     reader-document--backends))))

(defun reader-document--operation (backend operation)
  "Resolve OPERATION on BACKEND, detecting invalid inheritance cycles."
  (let (seen function)
    (while (and backend (not function))
      (when (memq backend seen)
        (error "Cyclic document inheritance: %s" backend))
      (push backend seen)
      (let ((entry (assq backend reader-document--backends)))
        (setq function (plist-get (nth 2 entry) operation)
              backend (nth 3 entry))))
    function))

(defun reader-document-call (operation &rest arguments)
  "Call the current document's OPERATION with ARGUMENTS.
Signal a user error for unsupported operations rather than choosing another
document's implementation.  For optional capabilities, use
`reader-document-has-p'."
  (let* ((backend (reader-document-backend))
         (function (reader-document--operation backend operation)))
    (unless function
      (user-error "Document %s does not support %s" backend operation))
    (apply function arguments)))

(defun reader-document-has-p (operation)
  "Return non-nil if the current document implements OPERATION."
  (and (reader-document--operation (reader-document-backend) operation) t))

(defun reader-document-current-sentence ()
  "Return (TEXT BUFFER BEG END), or nil when no sentence is available."
  (reader-document-call :sentence))

(defun reader-document-next-sentence ()
  "Move the document cursor to the next sentence without speaking."
  (reader-document-call :next))

(defun reader-document-previous-sentence ()
  "Move the document cursor to the previous sentence without speaking."
  (reader-document-call :previous))

(defun reader-document-current-location (&optional window)
  "Return an opaque location record for the document in WINDOW."
  (reader-document-call :location window))

(defun reader-document-restore-location (record window)
  "Restore this document's RECORD in WINDOW."
  (reader-document-call :restore record window))

(defun reader-document-title (&optional frame)
  "Return the current document title, optionally scoped to FRAME."
  (reader-document-call :title frame))

(defun reader-document-source (&optional frame)
  "Return the document's source file or URL, optionally scoped to FRAME."
  (reader-document-call :source frame))

(defun reader-document-identity (&optional buffer)
  "Return BUFFER's identity, including a source rendered into a reused buffer."
  (with-current-buffer (or buffer (current-buffer))
    (list (current-buffer) (reader-document-backend)
          (reader-document-source))))

(provide 'reader-document)
;;; reader-document.el ends here
