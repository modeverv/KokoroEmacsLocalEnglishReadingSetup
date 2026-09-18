;;; my-read-lookup.el --- Lookup for the reader -*- lexical-binding: t; -*-

(declare-function lookup-module-setup "lookup")
(declare-function lookup-default-module "lookup")
(declare-function lookup-dictionary-alist "lookup")
(declare-function lookup-dictionary-id "lookup")
(declare-function lookup-dictionary-title "lookup")
(declare-function lookup-new-module "lookup")
(declare-function lookup-module-dictionaries "lookup")
(require 'my-read-core)

(defvar lookup-open-function)
(defvar lookup-sub-window)

(defcustom my/read-lookup-dictionary-ids
  '("nmacos"
    "ndeb+~/Sync/004_dic/ee/:simpleen"
    "ndeb+~/Sync/004_dic/chujisnd/"
    "ndspell")
  "Lookup dictionary IDs used only by my-read and my-read-k.

Each string may be a complete dictionary ID or an ID prefix.  For example,
`nmacos' selects all macOS Dictionary agents, while a complete NDEB ID selects
one dictionary.  An empty list disables Lookup searches in reading frames;
it never falls back to Lookup's full default module.  Changing this option
rebuilds the private module automatically on the next search."
  :type '(repeat string)
  :group 'my-read)

(defcustom my/read-lookup-idle-delay 0.12
  "Seconds to wait before looking up the word at point in my-read."
  :type 'number
  :group 'my-read)

(defcustom my/read-lookup-entry-window-height 4
  "Height in lines of the Lookup dictionary-entry list in my-read.

This frame-local value takes precedence over the normal
`lookup-window-height'.  Keeping it as a small integer prevents a fractional
global setting from shrinking the dictionary content window."
  :type 'integer
  :group 'my-read)

(defvar my/read-lookup-timer nil)

(defvar my/read-lookup-last-target nil)

(defvar my/read-lookup-running-p nil)

(defvar my/read--lookup-module nil)

(defvar my/read--lookup-module-signature nil)

(defun my/read-reset-lookup-dictionary-module ()
  "Discard the cached private Lookup module used by reading frames."
  (interactive)
  (setq my/read--lookup-module nil
        my/read--lookup-module-signature nil
        my/read-lookup-last-target nil))

(defun my/read-lookup-list-dictionaries ()
  "Show available Lookup dictionary IDs and the current my-read selection."
  (interactive)
  (my/read--lookup-ensure-runtime)
  (lookup-module-setup (lookup-default-module))
  (let ((buffer (get-buffer-create "*my-read Lookup Dictionaries*"))
        (dictionaries
         (mapcar #'cdr (lookup-dictionary-alist t))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "my-read / my-read-k Lookup dictionaries\n\n")
        (insert "Customize: M-x customize-option RET my/read-lookup-dictionary-ids\n\n")
        (dolist (dictionary dictionaries)
          (let* ((id (lookup-dictionary-id dictionary))
                 (selected
                  (cl-some (lambda (prefix)
                             (string-prefix-p prefix id))
                           my/read-lookup-dictionary-ids)))
            (insert (format "%s %s\n    %s\n"
                            (if selected "[*]" "[ ]")
                            id
                            (lookup-dictionary-title dictionary)))))
        (special-mode)
        (goto-char (point-min))))
    (pop-to-buffer buffer)))

(defun my/read--lookup-reading-module ()
  "Return the private Lookup module configured for my-read and my-read-k."
  (my/read--lookup-ensure-runtime)
  (unless my/read-lookup-dictionary-ids
    (user-error "my/read-lookup-dictionary-ids is empty"))
  (unless (and (fboundp 'lookup-new-module)
               (fboundp 'lookup-module-setup))
    (error "This Lookup version cannot create a private dictionary module"))
  (unless (equal my/read--lookup-module-signature
                 my/read-lookup-dictionary-ids)
    (let ((module
           (lookup-new-module
            (cons "%my-read" my/read-lookup-dictionary-ids))))
      ;; Resolve IDs now so an invalid configuration fails here instead of
      ;; silently searching the full default module.
      (lookup-module-setup module)
      (setq my/read--lookup-module module
            my/read--lookup-module-signature
            (copy-sequence my/read-lookup-dictionary-ids))))
  my/read--lookup-module)

(defun my/read--lookup-reading-dictionaries ()
  "Return dictionaries in the private my-read Lookup module."
  (lookup-module-dictionaries (my/read--lookup-reading-module)))

(defun my/read--lookup-pattern-around
    (function pattern &optional module)
  "Use my-read's private module around Lookup FUNCTION for PATTERN.

An explicitly supplied MODULE is respected.  A normal search outside a reading
frame is passed through unchanged."
  (funcall function
           pattern
           (if (and (my/read-frame-p) (null module))
               (my/read--lookup-reading-module)
             module)))

(defun my/read--install-lookup-advice ()
  "Restrict manual Lookup searches only when they originate in my-read.

Also remove advice left by older my-read revisions so reloading this file in
an existing Emacs session cannot call the destructive profile-switch code."
  ;; Use the user's normal `lookup-pattern' path.  In the user's config this
  ;; already has frame-safety and "open first entry" advice attached, so keeping
  ;; my-read on the same command path preserves that working behavior.
  (when (fboundp 'lookup-pattern)
    (when (fboundp 'my/read--lookup-call-with-reading-scope)
      (advice-remove 'lookup-pattern #'my/read--lookup-call-with-reading-scope))
    (advice-remove 'lookup-pattern #'my/read--lookup-pattern-around)
    (advice-add 'lookup-pattern :around #'my/read--lookup-pattern-around)))

(with-eval-after-load 'lookup
  (my/read--install-lookup-advice))

(defun my/read--lookup-enter ()
  "Prepare Lookup for my-read without mutating the normal Lookup runtime."
  (my/read--lookup-ensure-runtime)
  (my/read--install-lookup-advice))

(defun my/read--lookup-restore-normal ()
  "Compatibility cleanup hook.

There is nothing to restore because my-read no longer mutates the user's
normal Lookup agents, dictionaries or modules."
  nil)

(defun my/read-word-at-window (window)
  "Return the word at WINDOW's point, or nil."
  (when (window-live-p window)
    (with-current-buffer (window-buffer window)
      (unless (derived-mode-p 'dired-mode)
        (let ((virtual
               (and (fboundp 'english-reading-mode-current-text-location)
                    (english-reading-mode-current-text-location
                     (current-buffer)))))
          (with-current-buffer (or (nth 1 virtual) (current-buffer))
            (save-excursion
              (goto-char (or (nth 2 virtual) (window-point window)))
              (when-let* ((word (thing-at-point 'word t)))
                (setq word (string-trim word))
                (unless (string-empty-p word)
                  word)))))))))

(defun my/read-lookup-open-pane (buffer)
  "Display Lookup BUFFER in the fixed Lookup pane of the current my-read frame.

This intentionally overrides the user's normal `lookup-open-function' only
for automatic searches performed by my-read.  It never creates another pane."
  (let* ((frame (selected-frame))
         (pane (my/read-lookup-window frame)))
    (if (window-live-p pane)
        (progn
          (set-window-dedicated-p pane nil)
          (set-window-buffer pane buffer)
          ;; Lookup open functions normally select the destination window.
          ;; Do that here too so Entry/Content setup can complete normally;
          ;; `save-selected-window' in `my/read-lookup-run' restores CENTER.
          (select-window pane)
          pane)
      ;; Fallback should only be needed outside a valid my-read layout.
      (display-buffer buffer))))

(defun my/read-lookup-run (frame center target)
  "Run Lookup for TARGET in FRAME using CENTER as the source window."
  (setq my/read-lookup-timer nil)
  (when (and my-read-lookup-follow-mode
             (not my/read-lookup-running-p)
             (frame-live-p frame)
             (my/read-frame-p frame)
             (window-live-p center)
             (my/read--center-automatic-lookup-p center)
             (equal target my/read-lookup-last-target))
    (let ((word (caddr target)))
      (when (and word
                 (or (featurep 'lookup)
                     (require 'lookup nil t))
                 (fboundp 'lookup-pattern))
        (setq my/read-lookup-running-p t)
        (unwind-protect
            (with-selected-frame frame
              (save-selected-window
                ;; Run from the book window so Lookup's frame/module state is
                ;; associated with the reading pane.  WORD itself is passed
                ;; explicitly to `lookup-pattern'.
                (with-selected-window center
                  ;; Never reuse a Lookup main/sub window belonging to another
                  ;; frame.  This mirrors the user's normal Lookup protection.
                  (when (and (boundp 'lookup-main-window)
                             (window-live-p lookup-main-window)
                             (not (eq (window-frame lookup-main-window) frame)))
                    (setq lookup-main-window nil
                          lookup-sub-window nil))
                  ;; my-read already owns a Lookup pane, so dynamically route
                  ;; this search there instead of creating another outer pane.
                  ;;
                  ;; IMPORTANT: use `lookup-pattern', not `lookup-word'.  The
                  ;; user's normal Lookup configuration attaches frame handling
                  ;; and "open the first entry" behavior to `lookup-pattern'.
                  ;; Calling it non-interactively with WORD does not open the
                  ;; minibuffer, but does preserve those existing advices.
                  (let ((lookup-open-function #'my/read-lookup-open-pane))
                    (condition-case err
                        (lookup-pattern
                         word
                         (my/read--lookup-reading-module))
                      (error
                       (message "my-read Lookup error for %S: %s"
                                word (error-message-string err))))))))
          (setq my/read-lookup-running-p nil))))))

(defun my/read-lookup-follow-post-command ()
  "Automatically look up the word at point in a my-read center window."
  (when my-read-lookup-follow-mode
    (let* ((frame (selected-frame))
           (center (my/read-center-window frame)))
      (when (and (my/read-frame-p frame)
                 (my/read--center-source-window-p center frame)
                 (eq (selected-window) center)
                 (my/read--center-automatic-lookup-p center)
                 (not my/read-lookup-running-p))
        (let* ((word (my/read-word-at-window center))
               (target (and word
                            (list frame (window-buffer center) word))))
          (unless (equal target my/read-lookup-last-target)
            (setq my/read-lookup-last-target target)
            (when (timerp my/read-lookup-timer)
              (cancel-timer my/read-lookup-timer)
              (setq my/read-lookup-timer nil))
            (when word
              (setq my/read-lookup-timer
                    (run-with-idle-timer
                     my/read-lookup-idle-delay
                     nil
                     #'my/read-lookup-run
                     frame center target)))))))))

(define-minor-mode my-read-lookup-follow-mode
  "Automatically show Lookup results for the word at point in my-read."
  :global t
  :group 'my-read
  :lighter " Lookup↔"
  (if my-read-lookup-follow-mode
      (progn
        (setq my/read-lookup-last-target nil
              my/read-lookup-running-p nil)
        (add-hook 'post-command-hook #'my/read-lookup-follow-post-command))
    (remove-hook 'post-command-hook #'my/read-lookup-follow-post-command)
    (when (timerp my/read-lookup-timer)
      (cancel-timer my/read-lookup-timer))
    (setq my/read-lookup-timer nil
          my/read-lookup-last-target nil
          my/read-lookup-running-p nil)))

(defun my/read-lookup-status ()
  "Show the current my-read Lookup follower state in the echo area."
  (interactive)
  (let* ((frame (selected-frame))
         (center (my/read-center-window frame))
         (word (and (window-live-p center)
                    (my/read-word-at-window center)))
         (dicts (condition-case _err
                    (and (my/read-frame-p frame)
                         (my/read--lookup-reading-dictionaries))
                  (error nil))))
    (message
     "my-read Lookup: mode=%s center=%s word=%S dicts=%S last=%S timer=%s running=%s"
     my-read-lookup-follow-mode
     (window-live-p center)
     word
     (and dicts
          (mapcar (lambda (dict)
                    (if (fboundp 'lookup-dictionary-id)
                        (lookup-dictionary-id dict)
                      dict))
                  dicts))
     my/read-lookup-last-target
     (timerp my/read-lookup-timer)
     my/read-lookup-running-p)))

(defun my/read-lookup-dispatch-key (key)
  "Run the command bound to KEY in the current my-read Lookup pane.

The command is executed with the left Lookup window temporarily selected, then
focus is restored to the center reading window."
  (let* ((frame (selected-frame))
         (center (my/read-center-window frame))
         (lookup (my/read-lookup-window frame)))
    (unless (and (my/read-frame-p frame)
                 (window-live-p center)
                 (eq (selected-window) center))
      (user-error "Use this command from the my-read center window"))
    (unless (window-live-p lookup)
      (user-error "The my-read Lookup window is not available"))
    (let ((command
           (with-selected-window lookup
             (key-binding (kbd key) t))))
      (unless (and (commandp command)
                   (not (memq command '(self-insert-command undefined))))
        (user-error "Lookup has no command bound to %s in the current view"
                    key))
      (with-selected-window lookup
        (call-interactively command)))))

(defun my/read-lookup-next-entry ()
  "Move to the next Lookup entry while focus stays in the reading pane."
  (interactive)
  (my/read-lookup-dispatch-key "n"))

(defun my/read-lookup-previous-entry ()
  "Move to the previous Lookup entry while focus stays in the reading pane."
  (interactive)
  (my/read-lookup-dispatch-key "p"))

;; `english-reading-mode' is active in both my-read center buffers.  Install
;; these explicitly so re-evaluating my-read.el updates a live session too.
(keymap-set
 english-reading-mode-map "p"
 '(menu-item "Next Lookup entry" my/read-lookup-next-entry
             :filter english-reading-mode--filter-key-binding))

(keymap-set
 english-reading-mode-map "o"
 '(menu-item "Previous Lookup entry" my/read-lookup-previous-entry
             :filter english-reading-mode--filter-key-binding))

(provide 'my-read-lookup)
;;; my-read-lookup.el ends here
