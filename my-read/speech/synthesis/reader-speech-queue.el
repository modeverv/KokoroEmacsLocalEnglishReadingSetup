;;; reader-speech-queue.el --- Shared synthesis and playback queue -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'json)
(require 'seq)

;; Legacy state names remain readable for callers and existing configuration.
;; Only this module mutates entry lifecycle and queue membership.
(defvar kokoro-reader--macos-prefetch-queue nil)
(defvar kokoro-reader--macos-next-id 0)
(defvar kokoro-reader--macos-current-entry nil)
(defvar kokoro-reader--kokoro-pending-entries nil)
(defvar kokoro-reader--kokoro-request-processes nil)
(defvar kokoro-reader--kokoro-api-ready-p nil)
(defvar kokoro-reader--kokoro-health-pending-p nil)
(defvar kokoro-reader--macos-bridge-process)
(defvar kokoro-reader--macos-bridge-ready-p)
(defvar kokoro-reader-kokoro-prefetch-concurrency)
(defvar kokoro-reader-macos-queued-start-hook)
(defvar kokoro-reader-player-finish-hook)
(defvar kokoro-reader--playback-succeeded-p)
(declare-function kokoro-reader--ensure-server "kokoro-reader" (on-ready on-error))
(declare-function kokoro-reader--ensure-macos-bridge "kokoro-reader" ())
(declare-function kokoro-reader--delete-overlay "kokoro-reader" ())
(declare-function kokoro-reader--start-kokoro-request "kokoro-reader" (entry))
(declare-function kokoro-reader--launch-pending-requests "kokoro-reader" ())
(declare-function kokoro-reader--delete-entry-audio-file "kokoro-reader" (entry))
(declare-function kokoro-reader--discard-resident-entry "kokoro-reader" (entry &optional notify))
(declare-function kokoro-reader--macos-entry-for-id "kokoro-reader" (id))
(declare-function english-reading-mode-stop-continuous "english-reading-speech" (&optional quiet))

(defvar reader-speech-queue--generation 0)
(defvar reader-speech-queue-transport nil
  "Selected transport plist: :prepare (TEXT -> request) and :key (KEY -> KEY).
Each request captures :start (ENTRY -> process side effects), optional :ensure,
:remote-playback, :failure-policy, and immutable payload/endpoint settings.")
(defvar reader-speech-queue-connect-functions nil
  "Functions returning the selected playback connection, or nil for native.")
(defvar reader-speech-queue-event-functions nil
  "Functions receiving a player event; return non-nil to consume it.")
(defvar reader-speech-queue-last-error nil
  "Last failure metadata (:time :stage :message), without speech text.")

(defun reader-speech-queue--put (entry property value)
  "Update ENTRY in place, preserving the identity shared with callbacks."
  (if-let* ((tail (plist-member entry property)))
      (setcar (cdr tail) value)
    (nconc entry (list property value)))
  value)

(defun reader-speech-queue-snapshot ()
  "Return text-free queue statistics; seconds count contiguous future audio.
Unknown durations stay unknown, and out-of-order ready entries are not counted
as playable seconds beyond a missing predecessor. Current playback is excluded."
  (let* ((entries kokoro-reader--macos-prefetch-queue)
         (future (seq-remove (lambda (e) (plist-get e :started)) entries))
         (ready (seq-filter (lambda (e) (plist-get e :loaded)) future))
         (prefix (seq-take-while (lambda (e) (plist-get e :loaded)) future))
         (unknown (seq-count (lambda (e) (not (numberp (plist-get e :duration)))) prefix))
         (inflight (+ (seq-count #'process-live-p kokoro-reader--kokoro-request-processes)
                      (seq-count (lambda (e)
                                   (and (equal (plist-get e :command) "enqueue")
                                        (not (plist-get e :loaded))))
                                 entries))))
    (list :total (length entries) :pending (length kokoro-reader--kokoro-pending-entries)
          :inflight inflight :ready (length ready) :contiguous-ready (length prefix)
          :seconds (unless (> unknown 0)
                     (apply #'+ (mapcar (lambda (e) (plist-get e :duration)) prefix)))
          :unknown-durations unknown
          :stage (cond ((null entries) 'idle)
                       ((plist-get (car entries) :started) 'playing)
                       (kokoro-reader--kokoro-health-pending-p 'connecting)
                       ((not (plist-get (car entries) :loaded)) 'generating)
                       (t 'buffering))
          :last-error reader-speech-queue-last-error)))

(defun reader-speech-queue-select-transport (transport)
  "Select TRANSPORT after cancelling requests owned by the previous one."
  (reader-speech-queue-cancel)
  (setq reader-speech-queue-transport transport
        kokoro-reader--kokoro-api-ready-p nil))

(defun reader-speech-queue-key (key)
  "Add selected transport identity to KEY."
  (if-let* ((function (plist-get reader-speech-queue-transport :key)))
      (funcall function key)
    key))

(defun reader-speech-queue-announce (entry)
  "Associate ENTRY with the displayed reading context."
  (when (memq entry kokoro-reader--macos-prefetch-queue)
    (reader-speech-queue--put entry :announced t)))

(defun reader-speech-queue-live-p (entry)
  "Return non-nil only while this exact ENTRY is still owned by the queue."
  (and (not (plist-get entry :cancelled))
       (memq entry kokoro-reader--macos-prefetch-queue)))

(defun reader-speech-queue-record-error (stage message-text)
  "Remember failure STAGE and safe MESSAGE-TEXT for diagnostics."
  (setq reader-speech-queue-last-error
        (list :time (current-time) :stage stage :message message-text)))

(defun reader-speech-queue-submit (key announced request)
  "Reserve ordered playback and submit REQUEST under KEY.
REQUEST is a transport descriptor, never a mutation of queue internals."
  (let* ((process (condition-case err
                      (kokoro-reader--ensure-macos-bridge)
                    (error
                     (reader-speech-queue-delete-audio request)
                     (signal (car err) (cdr err)))))
         (id (cl-incf kokoro-reader--macos-next-id))
         (entry (append (list :id id :key key :announced announced :queued nil
                              :loaded nil :started nil :cancelled nil :process nil
                              :generation reader-speech-queue--generation)
                        request))
         (native (equal (plist-get request :command) "enqueue")))
    (setq kokoro-reader--macos-prefetch-queue
          (append kokoro-reader--macos-prefetch-queue (list entry)))
    (condition-case err
        (progn
          (process-send-string
           process
           (concat (json-encode
                    (if native
                        `((command . "enqueue") (id . ,id)
                          (text . ,(plist-get request :text))
                          (voice . ,(plist-get request :voice))
                          (rate . ,(plist-get request :rate))
                          (volume . ,(plist-get request :volume)))
                      `((command . "reserve") (id . ,id)
                        (volume . ,(plist-get request :volume))))) "\n"))
          (unless native
            (setq kokoro-reader--kokoro-pending-entries
                  (append kokoro-reader--kokoro-pending-entries (list entry)))
            (if-let* ((ensure (plist-get request :ensure)))
                (funcall ensure)
              (setq kokoro-reader--kokoro-api-ready-p t)
              (kokoro-reader--launch-pending-requests)))
          entry)
      (error
       (reader-speech-queue-discard entry)
       (signal (car err) (cdr err))))))

(defun reader-speech-queue-attach-process (entry process)
  "Associate PROCESS with live ENTRY, or cancel a late process immediately."
  (if (reader-speech-queue-live-p entry)
      (progn (reader-speech-queue--put entry :process process)
             (push process kokoro-reader--kokoro-request-processes))
    (when (process-live-p process) (delete-process process))))

(defun reader-speech-queue-request-finished (process entry stderr-buffer)
  "Complete transport reception, never infer playback completion from it."
  (setq entry (or (reader-speech-queue-find (plist-get entry :id)) entry))
  (setq kokoro-reader--kokoro-request-processes
        (delq process kokoro-reader--kokoro-request-processes))
  (unwind-protect
      (progn
        (when (and (reader-speech-queue-live-p entry)
                   (eq process (plist-get entry :process)))
          (let ((file (plist-get entry :audio-file)))
            (cond
             ((not (zerop (process-exit-status process)))
              (reader-speech-queue-record-error
               'request (format "Request %s exited with status %s"
				(plist-get entry :id) (process-exit-status process)))
              (when (and (plist-get entry :error-buffer) (buffer-live-p stderr-buffer))
		(with-current-buffer (get-buffer-create (plist-get entry :error-buffer))
                  (goto-char (point-max)) (insert-buffer-substring stderr-buffer)))
              (reader-speech-queue-fail entry))
             ((plist-get entry :remote-playback) nil)
             ((and file (file-exists-p file)
                   (> (file-attribute-size (file-attributes file)) 44))
              (process-send-string
               (kokoro-reader--ensure-macos-bridge)
               (concat (json-encode `((command . "loadFile") (id . ,(plist-get entry :id))
                                      (path . ,file) (volume . ,(plist-get entry :volume)))) "\n")))
             (t
              (reader-speech-queue-record-error 'request "Missing or empty generated WAV")
              (reader-speech-queue-fail entry)))))
        ;; A short remote utterance can finish playing before its HTTP response
        ;; exits. Still refill that session, but never a cancelled/new session.
        (when (and (eq process (plist-get entry :process))
                   (not (plist-get entry :cancelled))
                   (or (reader-speech-queue-live-p entry)
                       (eql (plist-get entry :generation) reader-speech-queue--generation)))
          (kokoro-reader--launch-pending-requests)))
    (when (buffer-live-p stderr-buffer) (kill-buffer stderr-buffer))))

(defun reader-speech-queue-fail (entry)
  "Apply ENTRY's failure policy without accepting a failed chunk as finished."
  (setq kokoro-reader--kokoro-api-ready-p nil)
  (if (eq (plist-get entry :failure-policy) 'stop)
      (progn
        (if (fboundp 'english-reading-mode-stop-continuous)
            (english-reading-mode-stop-continuous)
          (reader-speech-queue-cancel))
        (message "HTTP speech stopped; see *HTTP Speech Errors*"))
    (reader-speech-queue-discard entry (plist-get entry :announced))))

(defun reader-speech-queue-cancel ()
  "Cancel all queued resident speech without killing its bridge."
  (cl-incf reader-speech-queue--generation)
  (dolist (entry kokoro-reader--macos-prefetch-queue)
    (reader-speech-queue--put entry :cancelled t))
  (dolist (process kokoro-reader--kokoro-request-processes)
    (when (process-live-p process)
      (delete-process process)))
  (dolist (entry kokoro-reader--macos-prefetch-queue)
    (when-let* ((audio-file (plist-get entry :audio-file)))
      (when (file-exists-p audio-file)
        (ignore-errors (delete-file audio-file)))))
  (when (process-live-p kokoro-reader--macos-bridge-process)
    (process-send-string kokoro-reader--macos-bridge-process
                         "{\"command\":\"stop\"}\n"))
  (setq kokoro-reader--macos-prefetch-queue nil
        kokoro-reader--macos-current-entry nil
        kokoro-reader--kokoro-pending-entries nil
        kokoro-reader--kokoro-request-processes nil
        kokoro-reader--kokoro-health-pending-p nil)
  (kokoro-reader--delete-overlay))


(defun reader-speech-queue-delete-audio (entry)
  "Delete ENTRY's temporary WAV file, when present."
  (when-let* ((audio-file (plist-get entry :audio-file)))
    (when (file-exists-p audio-file)
      (ignore-errors (delete-file audio-file)))
    (reader-speech-queue--put entry :audio-file nil)))


(defun reader-speech-queue-discard (entry &optional notify)
  "Remove resident ENTRY and optionally NOTIFY speech completion."
  (when entry (reader-speech-queue--put entry :cancelled t))
  (when (and entry (process-live-p kokoro-reader--macos-bridge-process))
    (process-send-string
     kokoro-reader--macos-bridge-process
     (concat (json-serialize
              `((command . "discard") (id . ,(plist-get entry :id))))
             "\n")))
  (setq kokoro-reader--macos-prefetch-queue
        (delq entry kokoro-reader--macos-prefetch-queue)
        kokoro-reader--kokoro-pending-entries
        (delq entry kokoro-reader--kokoro-pending-entries))
  (when (eq entry kokoro-reader--macos-current-entry)
    (setq kokoro-reader--macos-current-entry nil))
  (kokoro-reader--delete-entry-audio-file entry)
  (when notify
    (kokoro-reader--delete-overlay)
    (run-hooks 'kokoro-reader-player-finish-hook)))


(defun reader-speech-queue-launch ()
  "Fill available Kokoro synthesis slots from the resident pending queue."
  (setq kokoro-reader--kokoro-request-processes
        (seq-filter #'process-live-p kokoro-reader--kokoro-request-processes))
  (while (and kokoro-reader--kokoro-api-ready-p
              kokoro-reader--kokoro-pending-entries
              (< (length kokoro-reader--kokoro-request-processes)
                 kokoro-reader-kokoro-prefetch-concurrency))
    (let ((entry (pop kokoro-reader--kokoro-pending-entries)))
      (when (reader-speech-queue-live-p entry)
        (condition-case err
            (funcall (or (plist-get entry :start) #'kokoro-reader--start-kokoro-request) entry)
          (error
           (reader-speech-queue-record-error 'request "Could not start speech request")
           (reader-speech-queue-fail entry)
           (signal (car err) (cdr err))))))))


(defun reader-speech-queue-find (id)
  "Return the resident speech queue entry identified by ID."
  (seq-find (lambda (entry) (= id (plist-get entry :id)))
            kokoro-reader--macos-prefetch-queue))


(defun reader-speech-queue-notify (event)
  "Handle one decoded AVSpeechSynthesizer bridge EVENT plist."
  (unless (run-hook-with-args-until-success 'reader-speech-queue-event-functions event)
    (let* ((name (plist-get event :event))
           (id (plist-get event :id))
           (entry (and (integerp id) (kokoro-reader--macos-entry-for-id id))))
      (pcase name
	("ready"
	 (setq kokoro-reader--macos-bridge-ready-p t))
	("queued"
	 (when entry (reader-speech-queue--put entry :queued t)))
	("loaded"
	 (when entry
           (reader-speech-queue--put entry :loaded t)
           (reader-speech-queue--put entry :duration (plist-get event :duration))
           ;; The native process has copied the WAV into an AVAudioPCMBuffer.
           (kokoro-reader--delete-entry-audio-file entry)))
	("started"
	 (when entry
           (setq kokoro-reader--macos-current-entry entry)
           (reader-speech-queue--put entry :started t)
           (unless (plist-get entry :announced)
             (run-hooks 'kokoro-reader-macos-queued-start-hook))))
	("finished"
	 (when entry
           (setq kokoro-reader--macos-prefetch-queue
		 (delq entry kokoro-reader--macos-prefetch-queue))
           (when (eq entry kokoro-reader--macos-current-entry)
             (setq kokoro-reader--macos-current-entry nil))
           (kokoro-reader--delete-entry-audio-file entry)
           (when (plist-get entry :announced)
             (kokoro-reader--delete-overlay)
             (let ((kokoro-reader--playback-succeeded-p t))
               (run-hooks 'kokoro-reader-player-finish-hook)))))
	("cancelled"
	 (when entry
           (setq kokoro-reader--macos-prefetch-queue
		 (delq entry kokoro-reader--macos-prefetch-queue))
           (when (eq entry kokoro-reader--macos-current-entry)
             (setq kokoro-reader--macos-current-entry nil))
           (kokoro-reader--delete-entry-audio-file entry)))
	("error"
	 (reader-speech-queue-record-error 'player (or (plist-get event :message) "Player error"))
	 (message "resident speech bridge: %s" (or (plist-get event :message)
                                                   "unknown error"))
	 (when entry
           (kokoro-reader--discard-resident-entry
            entry (plist-get entry :announced))))))))

(defun reader-speech-queue-ensure-legacy ()
  "Start the legacy API, rejecting callbacks from a cancelled session."
  (if kokoro-reader--kokoro-api-ready-p
      (kokoro-reader--launch-pending-requests)
    (unless kokoro-reader--kokoro-health-pending-p
      (setq kokoro-reader--kokoro-health-pending-p t)
      (let ((generation reader-speech-queue--generation))
        (kokoro-reader--ensure-server
         (lambda ()
           (when (= generation reader-speech-queue--generation)
             (setq kokoro-reader--kokoro-health-pending-p nil
                   kokoro-reader--kokoro-api-ready-p t)
             (kokoro-reader--launch-pending-requests)))
         (lambda (_error-text)
           (when (= generation reader-speech-queue--generation)
             (setq kokoro-reader--kokoro-health-pending-p nil)
             (reader-speech-queue-record-error 'server "Legacy speech server unavailable")
             (dolist (entry (copy-sequence kokoro-reader--kokoro-pending-entries))
               (reader-speech-queue-discard entry (plist-get entry :announced))))))))))

(provide 'reader-speech-queue)
;;; reader-speech-queue.el ends here
