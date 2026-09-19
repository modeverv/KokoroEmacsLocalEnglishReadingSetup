;;; english-reading-speech.el --- Speech for sentence reading -*- lexical-binding: t; -*-

(declare-function english-reading-mode-speak-current-sentence "english-reading-mode")
(require 'english-reading-state)
(require 'reader-document-text)
(require 'english-reading-prefetch)
(require 'kokoro-reader)

(defun english-reading-mode--continuous-speech-buffer-owned-p (speech-buffer)
  "Return non-nil when SPEECH-BUFFER belongs to the continuous source."
  (let ((source (plist-get english-reading-mode--continuous-state :buffer)))
    (and (buffer-live-p source)
         (with-current-buffer source
           (reader-document-call :owns-speech speech-buffer)))))

(defun english-reading-mode--continuous-speech-page-range (speech-buffer position)
  "Return the backend's speech bounds for POSITION in SPEECH-BUFFER."
  (let ((source (plist-get english-reading-mode--continuous-state :buffer)))
    (when (buffer-live-p source)
      (with-current-buffer source
        (when (reader-document-has-p :speech-range)
          (reader-document-call :speech-range speech-buffer position))))))

(defun english-reading-mode--continuous-speech-page-end
    (speech-buffer position)
  "Return the PDF page end containing POSITION in SPEECH-BUFFER, or nil."
  (cdr (english-reading-mode--continuous-speech-page-range
        speech-buffer position)))

(defun english-reading-mode--macos-continuous-bounds (beg end &optional limit)
  "Extend BEG..END to a continuous macOS speech chunk.

At most `english-reading-mode-macos-continuous-sentence-count' sentences are
included.  LIMIT, when non-nil, prevents a PDF chunk from crossing its page."
  (if (or (not (english-reading-mode--continuous-speech-buffer-owned-p
                (current-buffer)))
          (not (eq kokoro-reader-backend 'macos))
          (<= english-reading-mode-macos-continuous-sentence-count 1))
      (cons beg end)
    (save-excursion
      (let ((chunk-end end)
            (remaining (1- english-reading-mode-macos-continuous-sentence-count))
            (boundary (or limit (point-max))))
        (goto-char (min end boundary))
        (while (and (> remaining 0) (< (point) boundary))
          (skip-chars-forward " \t\n\r" boundary)
          (if-let* ((bounds (and (< (point) boundary)
                                 (english-reading-mode--sentence-bounds-at-point))))
              (let ((next-end (min (cdr bounds) boundary)))
                (if (> next-end chunk-end)
                    (setq chunk-end next-end
                          remaining (1- remaining))
                  (setq remaining 0))
                (goto-char next-end))
            (setq remaining 0)))
        (cons beg chunk-end)))))

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

(defun english-reading-mode--position-spoken-start (context)
  "Keep the beginning of spoken CONTEXT at the configured window position."
  (let ((window (plist-get context :window))
        (buffer (plist-get context :buffer))
        (beg (plist-get context :beg)))
    ;; PDF speech uses a hidden extracted-text buffer while WINDOW displays the
    ;; DocView image, so normal text recentering applies only when they match.
    (when (and (window-live-p window)
               (buffer-live-p buffer)
               (eq (window-buffer window) buffer)
               (integer-or-marker-p beg)
               (<= (with-current-buffer buffer (point-min)) beg)
               (<= beg (with-current-buffer buffer (point-max))))
      (with-selected-window window
        (save-excursion
          (goto-char beg)
          ;; With a nil argument Emacs uses the visual center, accounting for
          ;; enlarged or variable-height reading text.
          (recenter))))))

(add-hook 'english-reading-mode-speech-start-hook
          #'english-reading-mode--position-spoken-start)

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

(defun english-reading-mode--player-finished ()
  "Finish the active speech context from the player's exact exit event.

The periodic speech watcher remains as a synthesis-failure fallback, but a
successful playback handoff should not wait for its 50 ms polling interval."
  (when (and english-reading-mode--active-speech
             (not (process-live-p kokoro-reader--request-process))
             (not (process-live-p kokoro-reader--player-process)))
    (let ((english-reading-mode--exact-player-finish-p t))
      (when kokoro-reader--playback-succeeded-p
        ;; Keep the context object shared by start/finish listeners identical.
        (nconc english-reading-mode--active-speech (list :completed t)))
      (english-reading-mode--finish english-reading-mode--active-speech))))

(defun english-reading-mode--kokoro-busy-p ()
  "Return non-nil while Kokoro is synthesizing or actually playing audio."
  (or (and (boundp 'kokoro-reader--request-process)
           (process-live-p kokoro-reader--request-process))
      (and (boundp 'kokoro-reader--player-process)
           (process-live-p kokoro-reader--player-process))
      (and (fboundp 'kokoro-reader-macos-speaking-p)
           (kokoro-reader-macos-speaking-p))))

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
   ((or (and (boundp 'kokoro-reader--player-process)
             (process-live-p kokoro-reader--player-process))
        (and (fboundp 'kokoro-reader-macos-speaking-p)
             (kokoro-reader-macos-speaking-p)))
    (setq english-reading-mode--speech-player-seen-p t))

   ;; Curl is still synthesizing/downloading audio.
   ((and (boundp 'kokoro-reader--request-process)
         (process-live-p kokoro-reader--request-process))
    nil)

   ;; Once playback has been seen, an idle backend means it really ended.
   ((and english-reading-mode--speech-player-seen-p
         (not (english-reading-mode--kokoro-busy-p)))
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
    (let ((context (english-reading-mode--make-context beg end)) result)
      ;; ORIGINAL-FUNCTION creates Kokoro's request process.  Only after that
      ;; succeeds do we publish the new speech context.  `j' moves point after
      ;; this wrapper returns, so listeners lock to the old/current sentence
      ;; before point advances.
      (condition-case err
          (prog1
              (setq result (apply original-function beg end arguments))
            (if (eq result 'skipped)
                (progn
                  (setq context (plist-put context :skipped t)
                        english-reading-mode--active-speech context)
                  (english-reading-mode--finish context))
              ;; Playback, scrolling and highlight rendering are deliberately
              ;; separate.  In particular, SVG generation must not delay audio.
              (run-hook-with-args 'english-reading-mode-speech-prepare-hook context)
              (setq english-reading-mode--active-speech context
                    english-reading-mode--speech-start-time (current-time)
                    english-reading-mode--speech-player-seen-p nil)
              (run-hook-with-args 'english-reading-mode-speech-highlight-hook context)
              (run-hook-with-args 'english-reading-mode-speech-start-hook context)
              ;; Do not infer completion from a request sentinel: Kokoro switches
              ;; from curl -> afplay at that boundary.  Poll the actual request/player
              ;; process variables and finish only when BOTH are no longer alive.
              (english-reading-mode--start-watch context)))
        (error
         (signal (car err) (cdr err)))))))

(defun english-reading-mode--after-kokoro-stop (&rest _)
  "Finish the active context after an explicit/internal Kokoro stop."
  (when english-reading-mode--active-speech
    (english-reading-mode--finish english-reading-mode--active-speech)))

(defun english-reading-mode--continuous-live-p ()
  "Return non-nil when continuous reading still owns the displayed source."
  (let ((buffer (plist-get english-reading-mode--continuous-state :buffer))
        (window (plist-get english-reading-mode--continuous-state :window))
        (frame (plist-get english-reading-mode--continuous-state :frame)))
    (and (buffer-live-p buffer)
         (window-live-p window)
         (frame-live-p frame)
         (eq (window-buffer window) buffer)
         (or (not (plist-member english-reading-mode--continuous-state :document))
             (equal (plist-get english-reading-mode--continuous-state :document)
                    (reader-document-identity buffer))))))

(defun english-reading-mode--session-timer (delay repeat function)
  "Schedule FUNCTION after DELAY with REPEAT only for this reading generation."
  (let ((generation english-reading-mode--continuous-generation))
    (funcall (if repeat #'run-with-timer #'run-at-time) delay repeat
             (lambda ()
               (when (= generation english-reading-mode--continuous-generation)
                 (funcall function))))))

(defun english-reading-mode--release-buffer ()
  "Stop speech owned by this document before it is disabled or killed."
  (when (or (eq (current-buffer)
                (plist-get english-reading-mode--continuous-state :buffer))
            (reader-document-call :owns-speech
                                  (plist-get english-reading-mode--active-speech :buffer)))
    (english-reading-mode-stop-continuous)))

(defun english-reading-mode-stop-continuous (&optional quiet)
  "Stop sentence-by-sentence continuous reading.
When QUIET is non-nil, do not stop an already active audio process."
  (interactive)
  (cl-incf english-reading-mode--continuous-generation)
  (setq english-reading-mode--continuous-state nil)
  (when (timerp english-reading-mode--continuous-timer)
    (cancel-timer english-reading-mode--continuous-timer))
  (when (timerp english-reading-mode--macos-prefetch-monitor-timer)
    (cancel-timer english-reading-mode--macos-prefetch-monitor-timer))
  (when (timerp english-reading-mode--continuous-warmup-timer)
    (cancel-timer english-reading-mode--continuous-warmup-timer))
  (setq english-reading-mode--continuous-timer nil
        english-reading-mode--macos-prefetch-monitor-timer nil
        english-reading-mode--continuous-warmup-timer nil)
  ;; QUIET leaves the current utterance playing, but future audio no longer
  ;; belongs to an active continuous-reading session.
  (when (and quiet (fboundp 'kokoro-reader--clear-macos-prefetch))
    (kokoro-reader--clear-macos-prefetch))
  (unless quiet (kokoro-reader-stop))
  (unless quiet (message "Continuous reading stopped")))


(defun english-reading-mode--continuous-default-next ()
  "Advance and speak using the current document backend."
  (reader-document-call :continue))

(defun english-reading-mode--continuous-resume-next-chunk ()
  "Resume the active document after its last completed speech chunk."
  (let* ((state english-reading-mode--continuous-state)
         (source (plist-get state :buffer))
         (speech (plist-get state :next-speech-buffer))
         (position (plist-get state :next-speech-position)))
    (when (and (buffer-live-p source) (buffer-live-p speech)
               (integer-or-marker-p position))
      (setq english-reading-mode--continuous-state
            (plist-put (plist-put state :next-speech-buffer nil)
                       :next-speech-position nil))
      (with-current-buffer source
        (reader-document-call :resume speech position)))))

(defun english-reading-mode--continuous-next ()
  "Advance and speak once for the active continuous-reading source."
  (setq english-reading-mode--continuous-timer nil)
  (if (not (english-reading-mode--continuous-live-p))
      (english-reading-mode-stop-continuous t)
    (let ((buffer (plist-get english-reading-mode--continuous-state :buffer))
          (window (plist-get english-reading-mode--continuous-state :window))
          (frame (plist-get english-reading-mode--continuous-state :frame)))
      (condition-case err
          (with-selected-frame frame
            (with-selected-window window
              (with-current-buffer buffer
                (unless (english-reading-mode--continuous-resume-next-chunk)
                  (if (functionp english-reading-mode-continuous-next-function)
                      (funcall english-reading-mode-continuous-next-function)
                    (english-reading-mode--continuous-default-next))))))
        (error
         (english-reading-mode-stop-continuous t)
         (message "Continuous reading finished: %s" (error-message-string err)))))))

(defun english-reading-mode--continuous-context-owned-p (context)
  "Return non-nil when speech CONTEXT belongs to the continuous source.

Normal text speaks directly from the displayed buffer.  A DocView PDF speaks
from its hidden `pdftotext' helper, so that helper must be treated as speech
originating from the displayed PDF buffer."
  (english-reading-mode--continuous-speech-buffer-owned-p
   (plist-get context :buffer)))

(defun english-reading-mode--continuous-speech-finished (context)
  "Continue immediately after the speech chunk represented by CONTEXT."
  (when (and english-reading-mode--continuous-state
             (english-reading-mode--continuous-context-owned-p context))
    (when (timerp english-reading-mode--continuous-timer)
      (cancel-timer english-reading-mode--continuous-timer))
    (setq english-reading-mode--continuous-state
          (plist-put
           (plist-put english-reading-mode--continuous-state
                      :next-speech-buffer (plist-get context :buffer))
           :next-speech-position (plist-get context :end)))
    (cond
     ;; No player event will arrive for a filtered-out chunk. Advance even
     ;; if the following prefetched utterance has already started.
     ((plist-get context :skipped)
      (setq english-reading-mode--continuous-timer
            (english-reading-mode--session-timer 0 nil #'english-reading-mode--continuous-next)))
     ;; AVSpeechSynthesizer owns the handoff when another utterance is already
     ;; queued.  Its didStart callback advances the text/PDF context exactly
     ;; when that queued voice begins.
     ((and (fboundp 'kokoro-reader-macos-has-pending-p)
           (kokoro-reader-macos-has-pending-p))
      nil)
     (english-reading-mode--exact-player-finish-p
      ;; The player's sentinel has already cleared the old process and audio
      ;; state, so a ready chunk can start synchronously.  Avoiding an
      ;; otherwise zero-delay timer removes one event-loop turn.
      (english-reading-mode--continuous-next))
     (t
      ;; Synthesis-failure and compatibility paths may finish from a polling
      ;; timer.  Leave that callback before advancing to avoid re-entrancy.
      (setq english-reading-mode--continuous-timer
            (english-reading-mode--session-timer 0 nil #'english-reading-mode--continuous-next))))))

(defun english-reading-mode--macos-queued-start ()
  "Activate the text and visual context for queued resident macOS speech."
  (when (and english-reading-mode--continuous-state
             (english-reading-mode--continuous-live-p))
    (english-reading-mode--continuous-next)))

(add-hook 'english-reading-mode-speech-finish-hook
          #'english-reading-mode--continuous-speech-finished)

(defun english-reading-mode--current-continuous-speech-spec ()
  "Return the current document's next speech chunk."
  (reader-document-call :speech-spec))

(defun english-reading-mode--continuous-warmup-check ()
  "Start playback after the initial macOS prefetch inventory is ready."
  (setq english-reading-mode--continuous-warmup-timer nil)
  (if (not (and english-reading-mode--continuous-state
                (english-reading-mode--continuous-live-p)))
      (english-reading-mode-stop-continuous t)
    (let* ((state english-reading-mode--continuous-state)
           (spec (plist-get state :warmup-spec))
           (texts (plist-get state :warmup-texts))
           (speech-buffer (plist-get spec :buffer)))
      (if (not (buffer-live-p speech-buffer))
          (english-reading-mode-stop-continuous t)
        (with-current-buffer speech-buffer
          (let ((kokoro-reader-macos-prefetch-count (length texts)))
            ;; Reconcile on every check so a failed render is retried
            ;; before playback begins instead of becoming a mid-reading miss.
            (kokoro-reader-prefetch-macos-texts texts))
          (if (cl-every #'kokoro-reader-macos-prefetch-ready-p texts)
              (let ((source-buffer (plist-get state :buffer))
                    (window (plist-get state :window))
                    (frame (plist-get state :frame)))
                (setq english-reading-mode--continuous-state
                      (plist-put
                       (plist-put state :warmup-spec nil)
                       :warmup-texts nil))
                (with-selected-frame frame
                  (with-selected-window window
                    (with-current-buffer source-buffer
                      (with-current-buffer speech-buffer
                        (kokoro-reader--speak-bounds
                         (plist-get spec :beg) (plist-get spec :end))))))
                (english-reading-mode--start-macos-prefetch-monitor)
                (message "Continuous reading started"))
            (setq english-reading-mode--continuous-warmup-timer
                  (english-reading-mode--session-timer 0.05 nil
                                                       #'english-reading-mode--continuous-warmup-check))))))))

(defun english-reading-mode--start-continuous-speech ()
  "Start continuous speech and fill the resident native audio queue."
  (let* ((spec (english-reading-mode--current-continuous-speech-spec))
         (speech-buffer (plist-get spec :buffer))
         (resident-native-p
          (and (buffer-live-p speech-buffer)
               (with-current-buffer speech-buffer
                 (memq kokoro-reader-backend '(macos kokoro irodori)))
               (fboundp 'kokoro-reader--ensure-macos-bridge))))
    (if resident-native-p
        (progn
          ;; Prevent the first fast render from starting before the synchronous
          ;; speech-start hook has submitted its future chunks.  The native
          ;; bridge renders those chunks in parallel, then schedules their PCM
          ;; buffers in document order.
          (with-current-buffer speech-buffer
            (kokoro-reader-macos-hold))
          (english-reading-mode-speak-current-sentence)
          (with-current-buffer speech-buffer
            (kokoro-reader-macos-play 2))
          (english-reading-mode--start-macos-prefetch-monitor)
          (message "Continuous reading started"))
      (if (and (buffer-live-p speech-buffer)
               (with-current-buffer speech-buffer
                 (eq kokoro-reader-backend 'macos))
               (fboundp 'kokoro-reader-macos-prefetch-ready-p))
          (let* ((context (list :buffer speech-buffer
                                :beg (plist-get spec :beg)
                                :end (plist-get spec :end)
                                :text (plist-get spec :text)))
                 (future (english-reading-mode--next-speech-texts
                          context english-reading-mode-macos-prefetch-chunk-count))
                 (texts (cons (plist-get spec :text) future)))
            (setq english-reading-mode--continuous-state
                  (plist-put
                   (plist-put english-reading-mode--continuous-state
                              :warmup-spec spec)
                   :warmup-texts texts))
            (message "Preparing %d continuous speech chunks…" (length texts))
            (english-reading-mode--continuous-warmup-check))
        (english-reading-mode-speak-current-sentence)
        (english-reading-mode--start-macos-prefetch-monitor)
        (message "Continuous reading started")))))

(defun english-reading-mode-continuous-read ()
  "Read continuously in speech chunks.
Press `s' again to stop."
  (interactive)
  (if english-reading-mode--continuous-state
      (english-reading-mode-stop-continuous)
    ;; Stop any unrelated one-shot utterance while STATE is still nil, so its
    ;; completion cannot schedule a spurious first advance.
    (kokoro-reader-stop)
    ;; Capture the manually displayed PDF page before continuous roll mode can
    ;; leave the previous page at the top during a boundary scroll.
    (reader-document-call :prepare)
    (cl-incf english-reading-mode--continuous-generation)
    (setq english-reading-mode--continuous-state
          (list :buffer (current-buffer)
                :document (reader-document-identity)
                :window (selected-window)
                :frame (selected-frame)))
    (condition-case err
        (english-reading-mode--start-continuous-speech)
      (error
       (english-reading-mode-stop-continuous t)
       (signal (car err) (cdr err))))))

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

(remove-hook 'kokoro-reader-player-finish-hook
             #'english-reading-mode--player-finished)

(add-hook 'kokoro-reader-player-finish-hook
          #'english-reading-mode--player-finished)

(remove-hook 'kokoro-reader-macos-queued-start-hook
             #'english-reading-mode--macos-queued-start)

(add-hook 'kokoro-reader-macos-queued-start-hook
          #'english-reading-mode--macos-queued-start)

(provide 'english-reading-speech)
;;; english-reading-speech.el ends here
