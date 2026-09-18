;;; my-read-pdf.el --- Pdf for the reader -*- lexical-binding: t; -*-

(require 'my-read-core)

(autoload 'pdf-view-roll-minor-mode "pdf-roll" nil t)

(add-to-list 'auto-mode-alist '("\\.pdf\\'" . pdf-view-mode))

(defcustom my/read-pdf-continuous-scroll t
  "When non-nil, show my-read PDFs as a vertically continuous page roll.

This uses PDF Tools' `pdf-view-roll-minor-mode', so pages are rendered lazily
around the visible area instead of loading the entire document at once."
  :type 'boolean
  :group 'my-read)

(defun my/read-close-pdf ()
  "Close the active my-read PDF while keeping the workspace frame open."
  (interactive)
  (let* ((frame (selected-frame))
         (center (my/read-center-window frame))
         (pdf-buffer (current-buffer))
         (dired-buffer (frame-parameter frame 'my-reading-dired-buffer))
         (notes-window (my/read-note-window frame)))
    (unless (and (my/read--center-window-active-p)
                 (english-reading-mode--pdf-buffer-p pdf-buffer))
      (user-error "my-readのPDFペインで実行してください"))
    (unless (buffer-live-p dired-buffer)
      (user-error "my-readのDIREDタブが見つかりません"))

    (my/read-position-save-buffer pdf-buffer center)
    (when (fboundp 'kokoro-reader-stop)
      (kokoro-reader-stop))

    ;; Move both Org-noter-owned windows away before ending the session.  Its
    ;; stock kill hook otherwise deletes the my-read frame with the session.
    (when (window-live-p notes-window)
      (set-window-buffer notes-window (my/read--prepare-notes-buffer frame)))
    (set-window-buffer center dired-buffer)
    (select-window center)

    (when (fboundp 'my/read-org-noter-close-source)
      (my/read-org-noter-close-source pdf-buffer))
    ;; Org-noter normally kills its document itself.  Its cleanup can fail on
    ;; a malformed notes root, so make PDF closure an explicit final step.
    (when (buffer-live-p pdf-buffer)
      (kill-buffer pdf-buffer))

    (let ((placeholder
           (my/read--prepare-center-tab-placeholder frame 'pdf)))
      (set-frame-parameter frame 'my-reading-pdf-buffer placeholder)
      (my/read--configure-center-tab-buffer placeholder frame))
    (my/read-lookup-follow-post-command)
    (my/read-translate-follow-post-command)
    (message "PDFを閉じました")))

(defun my/read--pdf-view-window-overlay-valid-p (window)
  "Return non-nil when WINDOW has a live PDF Tools image overlay."
  (and (window-live-p window)
       (eq (window-buffer window) (current-buffer))
       (or (and (bound-and-true-p pdf-view-roll-minor-mode)
                (fboundp 'pdf-roll-page-overlay)
                (let ((overlay (pdf-roll-page-overlay 1 window)))
                  (and (overlayp overlay)
                       (eq (overlay-buffer overlay) (current-buffer))
                       (eq (overlay-get overlay 'window) window))))
           (and (boundp 'image-mode-winprops-alist)
                (listp image-mode-winprops-alist)
                (let* ((winprops (assq window image-mode-winprops-alist))
                       (overlay (cdr (assq 'overlay (cdr winprops)))))
                  (and (overlayp overlay)
                       (eq (overlay-buffer overlay) (current-buffer))
                       (eq (overlay-get overlay 'window) window)))))))

(defun my/read--enable-pdf-continuous-scroll (buffer frame)
  "Enable Preview-like continuous scrolling for PDF BUFFER in FRAME."
  (when (and my/read-pdf-continuous-scroll
             (buffer-live-p buffer)
             (frame-live-p frame)
             (fboundp 'pdf-view-roll-minor-mode))
    (when-let* ((window (my/read-center-window frame)))
      (when (and (eq (window-buffer window) buffer)
                 (with-current-buffer buffer
                   (derived-mode-p 'pdf-view-mode)))
        (with-selected-window window
          (with-current-buffer buffer
            (unless (bound-and-true-p pdf-view-roll-minor-mode)
              (pdf-view-roll-minor-mode 1))
            ;; The mode-line size indicator assumes a single live page
            ;; overlay.  Roll mode can temporarily have no overlay while it
            ;; updates the continuously displayed pages, making redisplay
            ;; signal `wrong-type-argument overlayp nil'.
            (when (and (bound-and-true-p
                        pdf-misc-size-indication-minor-mode)
                       (fboundp 'pdf-misc-size-indication-minor-mode))
              (pdf-misc-size-indication-minor-mode -1))))))))

(defun my/read--repair-pdf-view-window (buffer frame)
  "Repair BUFFER's PDF Tools image state in FRAME's center window.

Moving a PDF buffer between my-read tabs can leave `image-mode' with a dead
window overlay.  In that state the mode line still says PDFView while the raw
%PDF data is visible.  Reinitializing `pdf-view-mode' rebuilds the per-window
overlay; preserve the current page across that repair."
  (when (and (buffer-live-p buffer) (frame-live-p frame))
    (when-let* ((window (my/read-center-window frame)))
      (when (and (eq (window-buffer window) buffer)
                 (with-current-buffer buffer
                   (derived-mode-p 'pdf-view-mode))
                 (with-current-buffer buffer
                   (not (my/read--pdf-view-window-overlay-valid-p window))))
        (with-selected-window window
          (with-current-buffer buffer
            (let* ((winprops (and (listp image-mode-winprops-alist)
                                  (or (assq window image-mode-winprops-alist)
                                      (assq t image-mode-winprops-alist))))
                   (page (or (cdr (assq 'page (cdr winprops))) 1)))
              (pdf-view-mode)
              (pdf-view-goto-page page))))))))

(defalias 'my/read-position--restore-pdf #'reader-document-pdf--restore)

;; `my-read' treats PDF Tools as the canonical PDF viewer.  Keep this here as
;; well as in init.el so a PDF never falls back to a raw binary buffer when
;; this module is loaded independently.
(autoload 'pdf-view-mode "pdf-view" nil t)


(provide 'my-read-pdf)
;;; my-read-pdf.el ends here
