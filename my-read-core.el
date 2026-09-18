;;; my-read-core.el --- Core for the reader -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)
(require 'thingatpt)
(require 'english-reading-mode)

(defgroup my-read nil
  "Dedicated English reading workspace."
  :group 'convenience)

(defvar-local my/read-center-tab-frame nil
  "my-read frame owning this center-tab buffer.")

(defvar-local my/read-center-tab-placeholder-type nil
  "Source type represented by this empty fixed-tab placeholder.")

(defun my/read-frame-p (&optional frame)
  "Return non-nil when FRAME is a frame created by `my-read'."
  (frame-parameter (or frame (selected-frame)) 'my-reading-frame))

(defun my/read-window (parameter &optional frame)
  "Return live window stored in FRAME PARAMETER, or nil."
  (let ((window (frame-parameter (or frame (selected-frame)) parameter)))
    (and (window-live-p window) window)))

(defun my/read-lookup-window (&optional frame)
  "Return FRAME's Lookup window."
  (my/read-window 'my-reading-lookup-window frame))

(defun my/read-center-windows (&optional frame)
  "Return all live center reading windows belonging to FRAME."
  (let* ((frame (or frame (selected-frame)))
         (windows (frame-parameter frame 'my-reading-center-windows)))
    (or (delq nil (mapcar (lambda (window)
                            (and (window-live-p window) window))
                          windows))
        (when-let* ((window (my/read-window 'my-reading-center-window frame)))
          (list window)))))

(defun my/read-center-window (&optional frame)
  "Return the active center reading window in FRAME.
The Kindle, PDF, EPUB, EWW, and DIRED sources share one window as tabs."
  (let* ((frame (or frame (selected-frame)))
         (windows (my/read-center-windows frame))
         (selected (and (eq frame (selected-frame)) (selected-window))))
    (if (memq selected windows)
        selected
      (car windows))))

(defun my/read-center-window-for-buffer (frame buffer)
  "Return FRAME's center window displaying BUFFER, or its active center."
  (or (cl-find-if (lambda (window)
                    (eq (window-buffer window) buffer))
                  (my/read-center-windows frame))
      (my/read-center-window frame)))

(defun my/read-kindle-window (&optional frame)
  "Return FRAME's center window hosting the Kindle.app tab."
  (my/read-window 'my-reading-kindle-window frame))

(defun my/read-epub-window (&optional frame)
  "Return FRAME's center window hosting the EPUB tab."
  (my/read-window 'my-reading-epub-window frame))

(defun my/read-pdf-window (&optional frame)
  "Return FRAME's center window hosting the PDF tab."
  (my/read-window 'my-reading-pdf-window frame))

(defun my/read-dired-window (&optional frame)
  "Return FRAME's center window hosting the persistent DIRED tab."
  (my/read-window 'my-reading-dired-window frame))

(defun my/read-eww-window (&optional frame)
  "Return FRAME's center window hosting the EWW tab."
  (my/read-window 'my-reading-eww-window frame))

(defun my/read-translate-window (&optional frame)
  "Return FRAME's Google Translate window."
  (my/read-window 'my-reading-translate-window frame))

(defun my/read-note-window (&optional frame)
  "Return FRAME's Org-noter notes window."
  (my/read-window 'my-reading-note-window frame))

(defun my/read--text-file-buffer-p ()
  "Return non-nil for a prose file, including Markdown, Org, and plain text.
Require a visiting file so temporary notes and capture buffers stay editable."
  (and buffer-file-name
       (derived-mode-p 'text-mode)
       (not (derived-mode-p 'nov-mode))))

(defun my/read--other-reading-frame-p (frame)
  "Return non-nil if a live my-read frame other than FRAME exists."
  (cl-some
   (lambda (candidate)
     (and (not (eq candidate frame))
          (frame-live-p candidate)
          (my/read-frame-p candidate)))
   (frame-list)))

(defun my/read-current-sentence-at-window (window)
  "Return (TEXT BUFFER BEG END) for the document in WINDOW."
  (when (window-live-p window)
    (with-current-buffer (window-buffer window)
      (save-excursion
        (goto-char (window-point window))
        (reader-document-current-sentence)))))


(provide 'my-read-core)
;;; my-read-core.el ends here
