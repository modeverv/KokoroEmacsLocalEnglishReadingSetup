;;; my-read-k.el --- Shared Kindle.app reader UI for my-read -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'thingatpt)
(require 'my-read)

(defgroup my-read-k nil
  "Read the visible page exposed by Kindle.app accessibility."
  :group 'my-read)

(defcustom my-read-k-settle-poll-ms 100
  "Milliseconds between accessibility reads while waiting for a page change."
  :type 'integer
  :group 'my-read-k)

(defcustom my-read-k-settle-stable-samples 2
  "Number of identical changed page reads required for a stable page."
  :type 'integer
  :group 'my-read-k)

(defcustom my-read-k-settle-timeout-ms 4000
  "Maximum milliseconds to wait for a changed page to become stable."
  :type 'integer
  :group 'my-read-k)

(defcustom my-read-k-prefetch-enabled t
  "When non-nil, keep upcoming Kindle.app pages in a memory-only FIFO queue."
  :type 'boolean
  :group 'my-read-k)

(defcustom my-read-k-prefetch-count 2
  "Number of upcoming Kindle pages to keep ready.
The bridge currently supports two."
  :type 'integer
  :group 'my-read-k)

(defcustom my-read-k-history-count 2
  "Number of previously displayed Kindle pages to keep ready in memory."
  :type 'integer
  :group 'my-read-k)

(defvar my-read-k--bridge-command-function nil
  "Function returning the command for the active accessibility bridge.")

(defvar my-read-k--reconnect-function nil
  "Interactive function used to reconnect the active Kindle.app bridge.")

(defconst my-read-k-buffer-name "*my-read-k:english*")
(defconst my-read-k-log-buffer-name "*my-read-k-log*")

(defvar my-read-k--process nil)
(defvar my-read-k--stopping-p nil)
(defvar my-read-k--process-output "")
(defvar my-read-k--callbacks (make-hash-table :test #'eql))
(defvar my-read-k--request-id 0)
(defvar my-read-k--generation 0)
(defvar my-read-k--busy-p nil)
(defvar my-read-k--prefetch-busy-p nil)
(defvar my-read-k--sync-busy-p nil)
(defvar my-read-k--pending-intent nil)
(defvar my-read-k--last-error nil)
(defvar my-read-k--state 'detached)
(defvar my-read-k--frame nil)
(defvar my-read-k--buffer nil)
(defvar my-read-k--last-fingerprint nil)
(defvar my-read-k--current-result nil)
(defvar my-read-k--target-title nil)
(defvar my-read-k--target-url nil)
(defvar my-read-k--detected-language nil)
(defvar my-read-k--prefetch-queue nil)
(defvar my-read-k--prefetch-source-fingerprint nil)
(defvar my-read-k--prefetch-attempted-fingerprint nil)
(defvar my-read-k--back-queue nil)
(defvar my-read-k--back-source-fingerprint nil)

(defconst my-read-k--nonterminal-abbreviations
  '("Mr." "Mrs." "Ms." "Dr." "Prof." "Sr." "Jr." "St." "Mt."
    "Gen." "Rep." "Sen." "Gov." "Lt." "Col." "Sgt." "Capt."
    "Cmdr." "Rev." "Hon." "Pres." "No." "Nos." "Fig." "Figs."
    "Eq." "Eqs." "Vol." "p." "pp." "vs." "etc." "e.g." "i.e."
    "a.m." "p.m.")
  "Abbreviations that do not end a displayed sentence line.")

(defun my-read-k--alist-get (key alist)
  "Return KEY from JSON ALIST, accepting symbol or string keys."
  (or (alist-get key alist)
      (alist-get (symbol-name key) alist nil nil #'string=)))

(defun my-read-k--language-from-result (result)
  "Return RESULT's normalized source language, defaulting to English."
  (let* ((reported (my-read-k--alist-get 'language result))
         (language (and (stringp reported) (downcase reported))))
    (cond
     ((and language (string-prefix-p "zh" language)) "zh")
     ((and language (string-prefix-p "ja" language)) "ja")
     ((and language (string-prefix-p "en" language)) "en")
     ((and language (string-match "\\`[a-z]+" language))
      (match-string 0 language))
     (t "en"))))

(defun my-read-k--configure-buffer-language (result)
  "Apply RESULT's source language to the Kindle buffer and frame."
  (let ((language (my-read-k--language-from-result result)))
    (setq my-read-k--detected-language language)
    (when (frame-live-p my-read-k--frame)
      (set-frame-parameter my-read-k--frame
                           'my-reading-source-language language))
    (with-current-buffer my-read-k--buffer
      (setq-local my/read-source-language language)
      (kill-local-variable 'kokoro-reader-backend)
      (kill-local-variable 'kokoro-reader-lang-code)
      (kill-local-variable 'kokoro-reader-voice)
      (kill-local-variable 'kokoro-reader-macos-voice))
    language))

(defun my-read-k--nonterminal-abbreviation-p (sentence)
  "Return non-nil when SENTENCE ends in a nonterminal abbreviation."
  (let ((bare (replace-regexp-in-string "[\"'”’)]*\\'" "" sentence)))
    (or (cl-some (lambda (abbreviation)
                   (string-suffix-p abbreviation bare t))
                 my-read-k--nonterminal-abbreviations)
        (string-match-p "\\b[[:upper:]]\\.\\'" bare))))

(defun my-read-k--one-sentence-per-line (text)
  "Return Kindle TEXT normalized to one logical sentence per line.
Accessibility text contains no paragraph boundaries, so this function does
not attempt to reconstruct them.  A leading chapter label is kept on its own
line, and common abbreviations are not treated as sentence endings."
  (let* ((normalized (replace-regexp-in-string
                      "[[:space:]\u00a0]+" " " (string-trim text)))
         (case-fold-search t)
         heading
         candidates
         sentences)
    (when (string-match
           "\\`\\(Prologue\\|Epilogue\\|Chapter[[:space:]]+\\(?:[0-9]+\\|[IVXLCDM]+\\)\\)[[:space:]]+"
           normalized)
      (setq heading (match-string 1 normalized)
            normalized (substring normalized (match-end 0))))
    (with-temp-buffer
      (insert normalized)
      (setq-local sentence-end-double-space nil)
      (goto-char (point-min))
      (while (< (point) (point-max))
        (skip-chars-forward "[:space:]")
        (let ((beginning (point)))
          (forward-sentence)
          (let ((sentence
                 (string-trim
                  (buffer-substring-no-properties beginning (point)))))
            (unless (string-empty-p sentence)
              (push sentence candidates))))))
    (dolist (sentence (nreverse candidates))
      (if (and sentences
               (my-read-k--nonterminal-abbreviation-p (car sentences)))
          (setcar sentences (concat (car sentences) " " sentence))
        (push sentence sentences)))
    (string-join (append (and heading (list heading))
                         (nreverse sentences))
                 "\n")))

(defun my-read-k--target-book-name (title url)
  "Return a stable Kindle book identifier from target TITLE and URL."
  (let ((asin
         (and (stringp url)
              (string-match "[?&]asin=\\([^&#]+\\)" url)
              (match-string 1 url)))
        (generic-title-p
         (and (stringp title)
              (string-match-p
               "\\`Kindle\\(?: Cloud Reader\\)?\\'"
               (string-trim title)))))
    (cond
     ((and (stringp title)
           (not (string-empty-p (string-trim title)))
           (not generic-title-p))
      (string-trim title))
     (asin (format "Kindle-%s" asin))
     ((and (stringp title) (not (string-empty-p (string-trim title))))
      (string-trim title))
     (t "Kindle"))))

(defun my-read-k--remember-target (target)
  "Remember Kindle TARGET metadata and expose its book name to my-read."
  (let ((title (my-read-k--alist-get 'title target))
        (url (my-read-k--alist-get 'url target)))
    (setq my-read-k--target-title title
          my-read-k--target-url url)
    (when (frame-live-p my-read-k--frame)
      (set-frame-parameter
       my-read-k--frame
       'my-reading-kindle-book-name
       (my-read-k--target-book-name title url)))))

(defun my-read-k--bridge-command ()
  "Return the command list used to launch the accessibility bridge."
  (unless (functionp my-read-k--bridge-command-function)
    (user-error "No Kindle.app accessibility bridge is configured"))
  (funcall my-read-k--bridge-command-function))

(defun my-read-k--log (format-string &rest arguments)
  "Append a timestamped message to the my-read-k log."
  (with-current-buffer (get-buffer-create my-read-k-log-buffer-name)
    (goto-char (point-max))
    (insert (format-time-string "[%H:%M:%S] "))
    (insert (apply #'format format-string arguments) "\n")))

(defun my-read-k--record-error (code message)
  "Record and display a bridge error CODE and MESSAGE."
  (setq my-read-k--last-error (list :code code :message message))
  (my-read-k--log "%s: %s" code message)
  (message "my-read-k: %s" message))

(defun my-read-k--show-connection-status (text &optional error-p)
  "Show Kindle connection TEXT and an `r' reconnect hint.
When ERROR-P is non-nil, mark the Kindle header as disconnected."
  (when (buffer-live-p my-read-k--buffer)
    (with-current-buffer my-read-k--buffer
      (setq header-line-format
            (format " Kindle: %s | press r to reconnect"
                    (if error-p "disconnected" "connecting")))
      ;; Preserve a previously recognized page across a transient disconnect.
      (unless my-read-k--current-result
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert text "\n\nKindle.appで本を開いてから r を押すと再接続します。\n")
          (set-buffer-modified-p nil))))))

(defun my-read-k--process-sentinel (process event)
  "Handle bridge PROCESS termination described by EVENT."
  (when (memq (process-status process) '(exit signal failed closed))
    (when (eq process my-read-k--process)
      (setq my-read-k--process nil
            my-read-k--state 'detached
            my-read-k--busy-p nil
            my-read-k--prefetch-busy-p nil
            my-read-k--sync-busy-p nil
            my-read-k--pending-intent nil)
      (setq my-read-k--prefetch-queue nil
            my-read-k--prefetch-source-fingerprint nil
            my-read-k--prefetch-attempted-fingerprint nil
            my-read-k--back-queue nil
            my-read-k--back-source-fingerprint nil)
      (my-read-k--update-prefetch-header)
      (clrhash my-read-k--callbacks)
      (unless (or my-read-k--stopping-p
                  (string-match-p "finished" event))
        (my-read-k--record-error "BRIDGE_EXIT" (string-trim event))
        (my-read-k--show-connection-status "Kindle bridge disconnected." t)))))

(defun my-read-k--dispatch-response (response)
  "Dispatch decoded bridge RESPONSE to its registered callback."
  (let* ((id (my-read-k--alist-get 'id response))
         (callback (gethash id my-read-k--callbacks)))
    (when callback
      (remhash id my-read-k--callbacks)
      (condition-case err
          (funcall callback response)
        (error
         (my-read-k--record-error "CALLBACK_ERROR" (error-message-string err)))))))

(defun my-read-k--process-filter (_process chunk)
  "Assemble JSON Lines from bridge output CHUNK."
  (setq my-read-k--process-output (concat my-read-k--process-output chunk))
  (let ((start 0))
    (while (string-match "\n" my-read-k--process-output start)
      ;; Save both offsets before parsing/callbacks: either may change Emacs's
      ;; global match data and otherwise corrupt framing of the next JSON line.
      (let* ((line-end (match-beginning 0))
             (next-start (match-end 0))
             (line (substring my-read-k--process-output start line-end)))
        (unless (string-empty-p line)
          (condition-case err
              (my-read-k--dispatch-response
               (json-parse-string line :object-type 'alist :array-type 'list
                                  :null-object nil :false-object nil))
            (error
             (my-read-k--record-error
              "MALFORMED_RESPONSE" (error-message-string err)))))
        (setq start next-start)))
    (setq my-read-k--process-output
          (substring my-read-k--process-output start))))

(defun my-read-k--ensure-process ()
  "Start the persistent bridge if necessary and return it."
  (unless (process-live-p my-read-k--process)
    (setq my-read-k--process-output ""
          my-read-k--state 'starting)
    (clrhash my-read-k--callbacks)
    (let ((log (get-buffer-create my-read-k-log-buffer-name)))
      (setq my-read-k--process
            (make-process
             :name "my-read-k-bridge"
             :command (my-read-k--bridge-command)
             :connection-type 'pipe
             :coding 'utf-8-unix
             :noquery t
             :buffer nil
             :stderr log
             :filter #'my-read-k--process-filter
             :sentinel #'my-read-k--process-sentinel))))
  my-read-k--process)

(defun my-read-k--send (command params callback &optional generation)
  "Send COMMAND with PARAMS and register CALLBACK."
  (let* ((process (my-read-k--ensure-process))
         (id (cl-incf my-read-k--request-id))
         (request `((id . ,id)
                    (command . ,command)
                    (generation . ,(or generation my-read-k--generation))
                    (params . ,(or params (make-hash-table :test #'equal))))))
    (puthash id callback my-read-k--callbacks)
    (process-send-string
     process
     (concat (json-serialize request :null-object nil :false-object :json-false)
             "\n"))
    id))

(defun my-read-k--navigation-params ()
  "Return bridge page-navigation parameters."
  `((settle . ((pollMs . ,my-read-k-settle-poll-ms)
               (stableSamples . ,my-read-k-settle-stable-samples)
               (timeoutMs . ,my-read-k-settle-timeout-ms)))))

(defun my-read-k--update-prefetch-header ()
  "Show the number of forward and backward cached pages in the header."
  (when (buffer-live-p my-read-k--buffer)
    (with-current-buffer my-read-k--buffer
      (let ((base (replace-regexp-in-string
                   (concat " | next ready\\(?:: [0-9]+\\)?"
                           "\\(?: | prev ready: [0-9]+\\)?\\'")
                   ""
                   (format "%s" header-line-format))))
        (setq header-line-format
              (format "%s | next ready: %d | prev ready: %d"
                      base (length my-read-k--prefetch-queue)
                      (length my-read-k--back-queue)))))))

(defun my-read-k--clear-prefetch ()
  "Discard the transient next-page queue."
  (setq my-read-k--prefetch-queue nil
        my-read-k--prefetch-source-fingerprint nil
        my-read-k--prefetch-attempted-fingerprint nil)
  (my-read-k--update-prefetch-header))

(defun my-read-k--clear-history ()
  "Discard the transient previous-page queue."
  (setq my-read-k--back-queue nil
        my-read-k--back-source-fingerprint nil)
  (my-read-k--update-prefetch-header))

(defun my-read-k--clear-navigation-caches ()
  "Discard all page queues and the current cached result."
  (my-read-k--clear-prefetch)
  (my-read-k--clear-history)
  (setq my-read-k--current-result nil))

(defun my-read-k--prefetch-valid-p ()
  "Return non-nil when the cached next page belongs to the displayed page."
  (and my-read-k--prefetch-queue
       (stringp my-read-k--last-fingerprint)
       (equal my-read-k--prefetch-source-fingerprint
              my-read-k--last-fingerprint)))

(defun my-read-k--history-valid-p ()
  "Return non-nil when the cached previous page belongs to the displayed page."
  (and my-read-k--back-queue
       (stringp my-read-k--last-fingerprint)
       (equal my-read-k--back-source-fingerprint
              my-read-k--last-fingerprint)))

(defun my-read-k--trim-queue (queue count)
  "Return at most COUNT entries from QUEUE."
  (cl-subseq queue 0 (min (length queue) (max 0 count))))

(defun my-read-k--remember-transition (old-result direction)
  "Move OLD-RESULT into the opposite cache after DIRECTION navigation."
  (when old-result
    (pcase direction
      ('next
       (setq my-read-k--back-queue
             (my-read-k--trim-queue
              (cons old-result my-read-k--back-queue)
              my-read-k-history-count)
             my-read-k--back-source-fingerprint
             (and my-read-k--back-queue my-read-k--last-fingerprint)))
      ('prev
       (setq my-read-k--prefetch-queue
             (my-read-k--trim-queue
              (cons old-result my-read-k--prefetch-queue)
              (min 2 (max 1 my-read-k-prefetch-count)))
             my-read-k--prefetch-source-fingerprint
             (and my-read-k--prefetch-queue my-read-k--last-fingerprint))))
    (my-read-k--update-prefetch-header)))

(defun my-read-k--run-pending-intent ()
  "Run the last serialized navigation intent when all bridge work is idle."
  (when (and my-read-k--pending-intent
             (not my-read-k--busy-p)
             (not my-read-k--prefetch-busy-p)
             (not my-read-k--sync-busy-p))
    (pcase-let ((`(,direction . ,speak)
                 (prog1 my-read-k--pending-intent
                   (setq my-read-k--pending-intent nil))))
      (my-read-k--request-page direction speak))))

(defun my-read-k--response-error (response)
  "Record RESPONSE's error and return non-nil when it failed."
  (unless (my-read-k--alist-get 'ok response)
    (setq my-read-k--state 'error)
    (let ((error (my-read-k--alist-get 'error response)))
      (my-read-k--record-error
       (or (my-read-k--alist-get 'code error) "BRIDGE_ERROR")
       (or (my-read-k--alist-get 'message error) "Unknown bridge error")))
    t))

(defun my-read-k--refresh-followers ()
  "Refresh existing Lookup and translation followers once."
  (let ((window (and (frame-live-p my-read-k--frame)
                     (my/read-kindle-window my-read-k--frame))))
    (when (and (window-live-p window)
               (eq (window-buffer window) my-read-k--buffer))
      (with-selected-frame my-read-k--frame
        (with-selected-window window
          (my/read-lookup-follow-post-command)
          (my/read-translate-follow-post-command))))))

(defun my-read-k--position-for-direction (direction)
  "Position point after replacing a page in DIRECTION."
  (if (eq direction 'prev)
      (progn
        (goto-char (point-max))
        (skip-chars-backward " \t\n\r")
        (condition-case nil (backward-sentence) (error (goto-char (point-min)))))
    (goto-char (point-min))
    (skip-chars-forward " \t\n\r")))

(defun my-read-k--apply-page (result direction speak)
  "Replace the Kindle buffer from RESULT and finish DIRECTION update.
When SPEAK is non-nil, continue the existing j/k Kokoro flow."
  (let ((text (my-read-k--alist-get 'text result)))
    (unless (and (stringp text) (not (string-empty-p text)))
      (error "Bridge returned no page text"))
    (setq my-read-k--last-fingerprint (my-read-k--alist-get 'fingerprint result)
          my-read-k--current-result result)
    (let* ((language (my-read-k--configure-buffer-language result))
           (backend
            (with-current-buffer my-read-k--buffer
              kokoro-reader-backend)))
      (with-current-buffer my-read-k--buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (my-read-k--one-sentence-per-line text))
          (unless (bolp) (insert "\n"))
          (my-read-k--position-for-direction direction)
          (setq buffer-read-only t)
          (set-buffer-modified-p nil)
          (setq header-line-format
                (format " Kindle: attached | %s/%s | Accessibility"
                        (upcase language)
                        (if (eq backend 'kokoro) "Kokoro" "macOS"))))))
    (when-let ((center (and (frame-live-p my-read-k--frame)
                            (my/read-kindle-window my-read-k--frame)
                            (eq (window-buffer
                                 (my/read-kindle-window my-read-k--frame))
                                my-read-k--buffer)
                            (my/read-kindle-window my-read-k--frame))))
      (set-window-point center (with-current-buffer my-read-k--buffer (point))))
    (when speak
      (condition-case err
          (cond
           ((and (frame-live-p my-read-k--frame)
                 (window-live-p (my/read-kindle-window my-read-k--frame))
                 (eq (window-buffer (my/read-kindle-window my-read-k--frame))
                     my-read-k--buffer))
            (with-selected-frame my-read-k--frame
              (with-selected-window (my/read-kindle-window my-read-k--frame)
                (if (eq direction 'prev)
                    (english-reading-mode--speak-at-point)
                  (english-reading-mode-next-sentence)))))
           ;; Unit-level and non-workspace callers still support speech, but a
           ;; live workspace must never speak a hidden Kindle tab.
           ((not (frame-live-p my-read-k--frame))
            (with-current-buffer my-read-k--buffer
              (if (eq direction 'prev)
                  (english-reading-mode--speak-at-point)
                (english-reading-mode-next-sentence)))))
        (error (my-read-k--record-error "TTS_ERROR" (error-message-string err)))))
    (my-read-k--refresh-followers)))

(defun my-read-k--finish-page-request (response generation direction speak)
  "Finish a page RESPONSE for GENERATION, DIRECTION and SPEAK intent."
  (when (= generation my-read-k--generation)
    (unwind-protect
        (unless (my-read-k--response-error response)
          (let ((old-result my-read-k--current-result))
            (setq my-read-k--last-error nil)
            (pcase direction
              ('next
               (unless (my-read-k--history-valid-p)
                 (my-read-k--clear-history))
               (my-read-k--clear-prefetch))
              ('prev
               (unless (my-read-k--prefetch-valid-p)
                 (my-read-k--clear-prefetch))
               (my-read-k--clear-history))
              (_ (my-read-k--clear-navigation-caches)))
            (my-read-k--apply-page (my-read-k--alist-get 'result response)
                                   direction speak)
            (when (memq direction '(next prev))
              (my-read-k--remember-transition old-result direction)))
          (setq my-read-k--state 'attached))
      (setq my-read-k--busy-p nil)
      (when (eq my-read-k--state 'busy)
        (setq my-read-k--state 'error))
      (my-read-k--run-pending-intent)
      (my-read-k--maybe-prefetch-next))))

(defun my-read-k--finish-prefetch (response source-fingerprint)
  "Store prefetched RESPONSE when SOURCE-FINGERPRINT is still displayed."
  (unwind-protect
      (if (my-read-k--alist-get 'ok response)
          (let* ((result (my-read-k--alist-get 'result response))
                 (pages (or (my-read-k--alist-get 'pages result)
                            (list result)))
                 (bridge-source
                  (my-read-k--alist-get 'prefetchSourceFingerprint result)))
            (when (and (equal source-fingerprint my-read-k--last-fingerprint)
                       (equal bridge-source source-fingerprint))
              (setq my-read-k--last-error nil
                    my-read-k--prefetch-queue pages
                    my-read-k--prefetch-source-fingerprint source-fingerprint)
              (my-read-k--update-prefetch-header)))
        ;; End-of-book and transient prefetch failures must not interrupt the
        ;; current reading page.  The normal boundary request remains usable.
        (let ((error (my-read-k--alist-get 'error response)))
          (my-read-k--log
           "Prefetch skipped [%s]: %s"
           (or (my-read-k--alist-get 'code error) "PREFETCH_ERROR")
           (or (my-read-k--alist-get 'message error) "Unknown prefetch error"))))
    (setq my-read-k--prefetch-busy-p nil)
    (my-read-k--run-pending-intent)))

(defun my-read-k--maybe-prefetch-next ()
  "Keep the next-page FIFO filled independently of sentence or point position."
  (when (and my-read-k-prefetch-enabled
             (buffer-live-p my-read-k--buffer)
             (eq my-read-k--state 'attached)
             (not my-read-k--busy-p)
             (not my-read-k--prefetch-busy-p)
             (not my-read-k--sync-busy-p)
             (stringp my-read-k--last-fingerprint)
             (< (length my-read-k--prefetch-queue)
                (min 2 (max 1 my-read-k-prefetch-count)))
             (not (equal my-read-k--prefetch-attempted-fingerprint
                         my-read-k--last-fingerprint)))
    (let ((source-fingerprint my-read-k--last-fingerprint))
      (setq my-read-k--prefetch-busy-p t
            my-read-k--prefetch-attempted-fingerprint source-fingerprint)
      (my-read-k--send
       "prefetchNext"
       (append (my-read-k--navigation-params)
               `((prefetchCount . ,(min 2 (max 1 my-read-k-prefetch-count)))))
       (lambda (response)
         (my-read-k--finish-prefetch response source-fingerprint))
       my-read-k--generation))))

(defun my-read-k--finish-advance
    (response generation expected-fingerprint direction)
  "Finish DIRECTION sync for GENERATION and EXPECTED-FINGERPRINT."
  (when (= generation my-read-k--generation)
    (unwind-protect
        (if (my-read-k--response-error response)
            nil
          (let* ((result (my-read-k--alist-get 'result response))
                 (fingerprint (my-read-k--alist-get 'fingerprint result)))
            (if (equal fingerprint expected-fingerprint)
                (setq my-read-k--state 'attached
                      my-read-k--last-error nil)
              (my-read-k--record-error
               "CACHE_SYNC_MISMATCH"
               (format "Kindle.app moved %s to a page different from the cache"
                       direction)))))
      (setq my-read-k--sync-busy-p nil)
      (my-read-k--run-pending-intent)
      (my-read-k--maybe-prefetch-next))))

(defun my-read-k--consume-prefetch (speak)
  "Display the cached next page immediately, then advance Kindle.app."
  (let* ((old-result my-read-k--current-result)
         (result (pop my-read-k--prefetch-queue))
         (expected-fingerprint (my-read-k--alist-get 'fingerprint result))
         (generation (cl-incf my-read-k--generation)))
    (setq my-read-k--sync-busy-p t
          my-read-k--state 'syncing)
    (my-read-k--apply-page result 'next speak)
    (my-read-k--remember-transition old-result 'next)
    (setq my-read-k--prefetch-source-fingerprint
          (and my-read-k--prefetch-queue expected-fingerprint))
    (my-read-k--update-prefetch-header)
    (my-read-k--send
     "advanceNext" (my-read-k--navigation-params)
     (lambda (response)
       (my-read-k--finish-advance
        response generation expected-fingerprint 'next))
     generation)))

(defun my-read-k--consume-history (speak)
  "Display the cached previous page immediately, then move Kindle.app."
  (let* ((old-result my-read-k--current-result)
         (result (pop my-read-k--back-queue))
         (expected-fingerprint (my-read-k--alist-get 'fingerprint result))
         (generation (cl-incf my-read-k--generation)))
    (setq my-read-k--sync-busy-p t
          my-read-k--state 'syncing)
    (my-read-k--apply-page result 'prev speak)
    (my-read-k--remember-transition old-result 'prev)
    (setq my-read-k--back-source-fingerprint
          (and my-read-k--back-queue expected-fingerprint))
    (my-read-k--update-prefetch-header)
    (my-read-k--send
     "advancePrev" (my-read-k--navigation-params)
     (lambda (response)
       (my-read-k--finish-advance
        response generation expected-fingerprint 'prev))
     generation)))

(defun my-read-k--request-page (direction &optional speak)
  "Request capture or navigation in DIRECTION; optionally SPEAK after update."
  (cond
   ;; A cache hit updates Emacs immediately even while the bridge is refilling.
   ;; The Kindle.app move is serialized by the persistent bridge process.
   ((and (not my-read-k--busy-p)
         (eq direction 'next) (my-read-k--prefetch-valid-p))
    (my-read-k--consume-prefetch speak))
   ((and (not my-read-k--busy-p)
         (eq direction 'prev) (my-read-k--history-valid-p))
    (my-read-k--consume-history speak))
   ((or my-read-k--busy-p my-read-k--prefetch-busy-p my-read-k--sync-busy-p)
    (setq my-read-k--pending-intent (cons direction speak)))
   (t
    (setq my-read-k--busy-p t
          my-read-k--state 'busy)
    (let* ((generation (cl-incf my-read-k--generation))
           (command (pcase direction
                      ('next "next") ('prev "prev") (_ "capture")))
           (params (if (memq direction '(next prev))
                       (my-read-k--navigation-params)
                     nil)))
      (my-read-k--send
       command params
       (lambda (response)
         (my-read-k--finish-page-request
          response generation direction speak))
       generation)))))

;;;###autoload
(defun my-read-k-detach ()
  "Stop the bridge and invalidate all outstanding responses."
  (interactive)
  (cl-incf my-read-k--generation)
  (setq my-read-k--busy-p nil
        my-read-k--prefetch-busy-p nil
        my-read-k--sync-busy-p nil
        my-read-k--pending-intent nil
        my-read-k--state 'detached
        my-read-k--detected-language nil)
  (when (frame-live-p my-read-k--frame)
    (set-frame-parameter my-read-k--frame 'my-reading-source-language nil))
  (my-read-k--clear-navigation-caches)
  (clrhash my-read-k--callbacks)
  (when (process-live-p my-read-k--process)
    (setq my-read-k--stopping-p t)
    (unwind-protect
        (delete-process my-read-k--process)
      (setq my-read-k--stopping-p nil)))
  (setq my-read-k--process nil)
  (message "my-read-k detached"))

;;;###autoload
(defun my-read-k-refresh ()
  "Refresh the currently displayed Kindle.app page."
  (interactive)
  (my-read-k--request-page 'refresh))

;;;###autoload
(defun my-read-k-reconnect ()
  "Restart and reconnect the configured Kindle.app bridge."
  (interactive)
  (unless (commandp my-read-k--reconnect-function)
    (user-error "No Kindle.app reconnect command is configured"))
  (call-interactively my-read-k--reconnect-function))

;;;###autoload
(defun my-read-k-next-page ()
  "Turn to the next Kindle.app page and wait for stable accessibility text."
  (interactive)
  (my-read-k--request-page 'next))

;;;###autoload
(defun my-read-k-prev-page ()
  "Turn to the previous Kindle.app page and wait for stable accessibility text."
  (interactive)
  (my-read-k--request-page 'prev))

(defun my-read-k--sentence-at-point-p ()
  "Return non-nil when point is on readable sentence text."
  (and (< (point) (point-max))
       (bounds-of-thing-at-point 'sentence)))

(defun my-read-k--previous-sentence-available-p ()
  "Return non-nil when the current buffer has a previous sentence."
  (when-let ((bounds (bounds-of-thing-at-point 'sentence)))
    (save-excursion
      (goto-char (car bounds))
      (let ((origin (point)))
        (condition-case nil
            (progn (backward-sentence) (< (point) origin))
          (error nil))))))

(defun my-read-k-forward ()
  "Run existing j behavior, fetching the next Kindle page at the boundary."
  (interactive)
  (cond
   (my-read-k--busy-p
    (setq my-read-k--pending-intent (cons 'next t)))
   ((my-read-k--sentence-at-point-p)
    (english-reading-mode-next-sentence))
   (t (my-read-k--request-page 'next t))))

(defun my-read-k-backward ()
  "Run existing k behavior, fetching the previous Kindle page at the boundary."
  (interactive)
  (cond
   (my-read-k--busy-p
    (setq my-read-k--pending-intent (cons 'prev t)))
   ((my-read-k--previous-sentence-available-p)
    (english-reading-mode-previous-sentence))
   (t (my-read-k--request-page 'prev t))))

(defun my-read-k--move-line-or-page (move-function direction)
  "Call MOVE-FUNCTION, or request a page in DIRECTION at a buffer edge."
  (if my-read-k--busy-p
      (setq my-read-k--pending-intent (cons direction nil))
    ;; A failed vertical motion is not a page boundary: with a very long
    ;; wrapped sentence, point can remain unchanged even though more of the
    ;; buffer is visible.  Only the actual buffer endpoints turn Kindle pages.
    (if (if (eq direction 'next) (eobp) (bobp))
        (my-read-k--request-page direction)
      (condition-case nil
          (funcall move-function 1)
        ((beginning-of-buffer end-of-buffer error) nil)))))

(defun my-read-k-down ()
  "Move one visual line down, or fetch the next page at buffer bottom."
  (interactive)
  (my-read-k--move-line-or-page #'next-line 'next))

(defun my-read-k-up ()
  "Move one visual line up, or fetch the previous page at buffer top."
  (interactive)
  (my-read-k--move-line-or-page #'previous-line 'prev))

(defvar-keymap my-read-k-mode-map
  :doc "Keymap for the Kindle.app accessibility source."
  "j" #'my-read-k-forward
  "k" #'my-read-k-backward
  "<down>" #'my-read-k-down
  "<up>" #'my-read-k-up
  "C-n" #'my-read-k-down
  "C-p" #'my-read-k-up
  "C-v" #'my-read-k-next-page
  "M-v" #'my-read-k-prev-page
  "C-c ]" #'my-read-k-next-page
  "C-c [" #'my-read-k-prev-page
  "C-c g" #'my-read-k-refresh
  "r" #'my-read-k-reconnect)

;; `defvar-keymap' preserves an existing map on reload; install the new binding
;; explicitly so a live my-read-k session gains it without restarting Emacs.
(keymap-set my-read-k-mode-map "<down>" #'my-read-k-down)
(keymap-set my-read-k-mode-map "<up>" #'my-read-k-up)
(keymap-set my-read-k-mode-map "C-n" #'my-read-k-down)
(keymap-set my-read-k-mode-map "C-p" #'my-read-k-up)
(keymap-set my-read-k-mode-map "C-v" #'my-read-k-next-page)
(keymap-set my-read-k-mode-map "M-v" #'my-read-k-prev-page)
(keymap-set my-read-k-mode-map "r" #'my-read-k-reconnect)

(define-minor-mode my-read-k-mode
  "Treat the current text buffer as a Kindle.app accessibility source."
  :lighter " Kindle"
  :keymap my-read-k-mode-map
  (if my-read-k-mode
      (progn
        (read-only-mode 1)
        (add-hook 'post-command-hook #'my-read-k--maybe-prefetch-next nil t))
    (read-only-mode -1)
    (remove-hook 'post-command-hook #'my-read-k--maybe-prefetch-next t)))

;;;###autoload
(defun my-read-k-status ()
  "Display local state and ask the bridge for target status when running."
  (interactive)
  (if (not (process-live-p my-read-k--process))
      (message "my-read-k: %s" my-read-k--state)
    (my-read-k--send
     "status" nil
     (lambda (response)
       (if (my-read-k--response-error response)
           nil
         (let* ((result (my-read-k--alist-get 'result response))
                (target (my-read-k--alist-get 'target result)))
           (my-read-k--remember-target target)
           (message "my-read-k: %s — %s — next %d / prev %d cached"
                    my-read-k--state
                    (or (my-read-k--alist-get 'title target) "detached")
                    (length my-read-k--prefetch-queue)
                    (length my-read-k--back-queue))))))))

;;;###autoload
(defun my-read-k-show-last-error ()
  "Show the last detailed error and open the log buffer."
  (interactive)
  (pop-to-buffer (get-buffer-create my-read-k-log-buffer-name))
  (when my-read-k--last-error
    (message "%s: %s" (plist-get my-read-k--last-error :code)
             (plist-get my-read-k--last-error :message))))

(defun my-read-k--frame-deleted (frame)
  "Clean up the Kindle session owned by deleted FRAME."
  (when (eq frame my-read-k--frame)
    (my-read-k-detach)
    (when (buffer-live-p my-read-k--buffer)
      (kill-buffer my-read-k--buffer))
    (setq my-read-k--frame nil my-read-k--buffer nil)))

(add-hook 'delete-frame-functions #'my-read-k--frame-deleted)

(defun my-read-k--prepare-buffer ()
  "Create and initialize the Kindle pane used by the unified workspace."
  (let ((buffer (get-buffer-create my-read-k-buffer-name)))
    (with-current-buffer buffer
      (text-mode)
      (visual-line-mode 1)
      (my-read-k-mode 1)
      (english-reading-mode 1)
      (setq-local my/read-source-language nil)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Connecting to Kindle.app…\n\n"
                "Kindle.appで英語の本を開いてから r を押すと再接続します。\n")
        (set-buffer-modified-p nil))
      (read-only-mode 1))
    buffer))

(provide 'my-read-k)
;;; my-read-k.el ends here
