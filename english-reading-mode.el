;;; english-reading-mode.el --- Sentence-by-sentence English reading -*- lexical-binding: t; -*-

;; j/k and Kokoro lifecycle belong here.  Consumers such as my-read.el can
;; observe speech without reimplementing cursor movement or advising Kokoro.

(require 'cl-lib)
(require 'kokoro-reader)
(require 'thingatpt)
(require 'subr-x)

(defgroup english-reading-mode nil
  "Sentence-by-sentence English reading with Kokoro."
  :group 'multimedia)

(defvar english-reading-mode-speech-start-hook nil
  "Hook run when an English-reading Kokoro utterance starts.

Each function receives one CONTEXT plist with keys :id, :buffer, :frame,
:window, :beg, :end and :text.  :text is the normalized text handed to Kokoro.")

(defvar english-reading-mode-speech-finish-hook nil
  "Hook run when the current English-reading Kokoro utterance finishes.

Each function receives the same CONTEXT object as the matching start hook.
This also runs on synthesis failure or explicit stop.")

(defvar english-reading-mode--speech-sequence 0)
(defvar english-reading-mode--active-speech nil)

(defun english-reading-mode--sentence-bounds ()
  "Return the sentence at point, or signal a user error."
  (or (bounds-of-thing-at-point 'sentence)
      (user-error "Place point in an English sentence")))

(defun english-reading-mode--make-context (beg end)
  "Create a speech context for BEG..END in the current buffer."
  (list :id (cl-incf english-reading-mode--speech-sequence)
        :buffer (current-buffer)
        :frame (selected-frame)
        :window (selected-window)
        :beg beg
        :end end
        :text (if (fboundp 'kokoro-reader--text)
                  (kokoro-reader--text beg end)
                (string-trim
                 (replace-regexp-in-string
                  "[ \t\n\r]+" " "
                  (buffer-substring-no-properties beg end))))))

(defvar english-reading-mode--speech-watch-timer nil
  "Timer used to watch Kokoro request/playback lifetime.")

(defvar english-reading-mode--speech-start-time nil
  "Time when the active English-reading utterance was handed to Kokoro.")

(defvar english-reading-mode--speech-player-seen-p nil
  "Non-nil after the active utterance has reached actual audio playback.")

(defun english-reading-mode--finish (context)
  "Finish CONTEXT once and notify listeners."
  (when (eq context english-reading-mode--active-speech)
    (setq english-reading-mode--active-speech nil)
    (when (timerp english-reading-mode--speech-watch-timer)
      (cancel-timer english-reading-mode--speech-watch-timer))
    (setq english-reading-mode--speech-watch-timer nil
          english-reading-mode--speech-start-time nil
          english-reading-mode--speech-player-seen-p nil)
    (run-hook-with-args 'english-reading-mode-speech-finish-hook context)))

(defun english-reading-mode--kokoro-busy-p ()
  "Return non-nil while Kokoro is synthesizing or actually playing audio."
  (or (and (boundp 'kokoro-reader--request-process)
           (process-live-p kokoro-reader--request-process))
      (and (boundp 'kokoro-reader--player-process)
           (process-live-p kokoro-reader--player-process))))

(defun english-reading-mode--watch-speech (context)
  "Finish CONTEXT only after Kokoro's actual playback has ended.

There can be a very small event-loop gap between curl finishing and afplay's
process being installed.  Treating that gap as completion unlocks translation
at exactly the wrong moment, just before Kokoro starts speaking.  Therefore
we wait until playback has actually been observed, or until a short grace
period proves that synthesis failed before playback started."
  (cond
   ;; A newer utterance replaced CONTEXT.  Its own watcher owns the lifecycle.
   ((not (eq context english-reading-mode--active-speech))
    nil)

   ;; Actual playback exists: remember that we reached the speaking phase.
   ((and (boundp 'kokoro-reader--player-process)
         (process-live-p kokoro-reader--player-process))
    (setq english-reading-mode--speech-player-seen-p t))

   ;; Curl is still synthesizing/downloading audio.
   ((and (boundp 'kokoro-reader--request-process)
         (process-live-p kokoro-reader--request-process))
    nil)

   ;; Once afplay has been seen, no player now means playback really ended.
   (english-reading-mode--speech-player-seen-p
    (english-reading-mode--finish context))

   ;; Before playback has been seen, tolerate the curl -> afplay transition.
   ;; If nothing appears for 0.75s, regard it as synthesis failure/cancellation.
   ((and english-reading-mode--speech-start-time
         (> (float-time
             (time-subtract (current-time)
                            english-reading-mode--speech-start-time))
            0.75))
    (english-reading-mode--finish context))))

(defun english-reading-mode--start-watch (context)
  "Start watching Kokoro lifetime for CONTEXT."
  (when (timerp english-reading-mode--speech-watch-timer)
    (cancel-timer english-reading-mode--speech-watch-timer))
  (setq english-reading-mode--speech-watch-timer
        (run-with-timer 0.05 0.05
                        #'english-reading-mode--watch-speech
                        context)))

(defun english-reading-mode--around-kokoro-speak-bounds
    (original-function beg end &rest arguments)
  "Track Kokoro ORIGINAL-FUNCTION for BEG..END when this mode is active."
  (if (not english-reading-mode)
      (apply original-function beg end arguments)
    (let ((context (english-reading-mode--make-context beg end)))
      ;; ORIGINAL-FUNCTION creates Kokoro's request process.  Only after that
      ;; succeeds do we publish the new speech context.  `j' moves point after
      ;; this wrapper returns, so listeners lock to the old/current sentence
      ;; before point advances.
      (prog1
          (apply original-function beg end arguments)
        (setq english-reading-mode--active-speech context
              english-reading-mode--speech-start-time (current-time)
              english-reading-mode--speech-player-seen-p nil)
        (run-hook-with-args 'english-reading-mode-speech-start-hook context)
        ;; Do not infer completion from a request sentinel: Kokoro switches
        ;; from curl -> afplay at that boundary.  Poll the actual request/player
        ;; process variables and finish only when BOTH are no longer alive.
        (english-reading-mode--start-watch context)))))

(defun english-reading-mode--after-kokoro-stop (&rest _)
  "Finish the active context after an explicit/internal Kokoro stop."
  (when english-reading-mode--active-speech
    (english-reading-mode--finish english-reading-mode--active-speech)))

;; Re-evaluation safe lifecycle integration.
(advice-remove 'kokoro-reader--speak-bounds
               #'english-reading-mode--around-kokoro-speak-bounds)
(advice-add 'kokoro-reader--speak-bounds
            :around
            #'english-reading-mode--around-kokoro-speak-bounds)
(advice-remove 'kokoro-reader-stop
               #'english-reading-mode--after-kokoro-stop)
(advice-add 'kokoro-reader-stop
            :after
            #'english-reading-mode--after-kokoro-stop)

(defun english-reading-mode--speak-at-point ()
  "Speak the sentence at point with Kokoro."
  (pcase-let ((`(,beg . ,end) (english-reading-mode--sentence-bounds)))
    (kokoro-reader--speak-bounds beg end)))

(defun english-reading-mode-next-sentence ()
  "Read the sentence at point, then immediately move to the next sentence."
  (interactive)
  (pcase-let ((`(,beg . ,end) (english-reading-mode--sentence-bounds)))
    ;; Start hook is emitted before this call returns.
    (kokoro-reader--speak-bounds beg end)
    ;; Keep the desired j behaviour: audio continues while point is already
    ;; positioned at the following sentence.
    (goto-char end)
    (skip-chars-forward " \t\n\r")))

(defun english-reading-mode-previous-sentence ()
  "Move to the previous sentence and read it with Kokoro.

At the beginning of the buffer, do not signal `beginning-of-buffer'; just
leave point at the current sentence and report that there is nowhere to go."
  (interactive)
  (pcase-let ((`(,beg . ,_) (english-reading-mode--sentence-bounds)))
    (goto-char beg)
    (let ((origin (point))
          (moved nil))
      (condition-case nil
          (progn
            (backward-sentence)
            (skip-chars-forward " \t\n\r")
            (setq moved (< (point) origin)))
        (beginning-of-buffer
         (goto-char origin))
        (error
         (goto-char origin)))
      (if moved
          (english-reading-mode--speak-at-point)
        (goto-char origin)
        (message "Already at the first sentence")))))

(defun english-reading-mode-stop ()
  "Stop the current Kokoro reading."
  (interactive)
  (kokoro-reader-stop))

(defvar-keymap english-reading-mode-map
  :doc "Keymap for `english-reading-mode'."
  "j" #'english-reading-mode-next-sentence
  "k" #'english-reading-mode-previous-sentence
  "p" #'kokoro-reader-speak-paragraph
  "C-c C-k" #'english-reading-mode-stop)

;;;###autoload
(define-minor-mode english-reading-mode
  "Read English EPUB text one sentence at a time with local Kokoro.

`j' reads the sentence at point and immediately advances point to the next
sentence.  `k' moves back and reads the previous sentence.  `p' reads the
current paragraph without moving point.  Speech lifecycle
is exposed through `english-reading-mode-speech-start-hook' and
`english-reading-mode-speech-finish-hook'."
  :lighter " EnglishRead"
  :keymap english-reading-mode-map
  (when english-reading-mode
    (unless (derived-mode-p 'nov-mode)
      (message "english-reading-mode is designed for nov.el/EPUB buffers")))
  (unless english-reading-mode
    (english-reading-mode-stop)))

(provide 'english-reading-mode)
;;; english-reading-mode.el ends here
