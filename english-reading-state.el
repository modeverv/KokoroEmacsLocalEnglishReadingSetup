;;; english-reading-state.el --- State for sentence reading -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)

(defgroup english-reading-mode nil
  "Sentence-by-sentence English reading with Kokoro."
  :group 'multimedia)

(defcustom english-reading-mode-pdftotext-program "pdftotext"
  "Program used to extract a text layer from PDF documents."
  :type 'string
  :group 'english-reading-mode)

(defcustom english-reading-mode-pdf-highlight-color "#FFD54F"
  "Fill color used to highlight the spoken sentence on a PDF page."
  :type 'color
  :group 'english-reading-mode)

(defcustom english-reading-mode-pdf-highlight-opacity 0.15
  "Opacity of the spoken-sentence highlight on a PDF page."
  :type 'number
  :group 'english-reading-mode)

(defcustom english-reading-mode-pdf-highlight-program "magick"
  "ImageMagick program used to draw borderless PDF speech highlights."
  :type 'string
  :group 'english-reading-mode)

(defcustom english-reading-mode-pdf-highlight-delay 0.001
  "Seconds to wait after PDF scrolling before drawing the speech highlight.

The short delay yields once to PDF Tools or DocView redisplay.  If scrolling is
still changing when it expires, the stability check schedules another delay
before drawing.  Speech playback is independent of highlight rendering."
  :type 'number
  :group 'english-reading-mode)

(defcustom english-reading-mode-pdf-highlight-watch-duration 0.25
  "Seconds to protect a fresh PDF highlight from delayed redisplay."
  :type 'number
  :group 'english-reading-mode)

(defcustom english-reading-mode-pdf-speech-screen-position 0.2
  "Vertical screen position used for continuous PDF speech.

The value is a ratio of the PDF viewport height: 0.0 is the top edge, 0.5 is
the center, and 1.0 is the bottom edge.  The default keeps the beginning of the
spoken text about one quarter of the way down from the top."
  :type 'number
  :group 'english-reading-mode)

(defcustom english-reading-mode-macos-continuous-sentence-count 2
  "Maximum number of sentences in one continuous macOS speech utterance.

Larger chunks take longer to render before the first playback, but reduce
queue bookkeeping between sentences.  One-shot commands such as
`english-reading-mode-speak-current-sentence' still speak one sentence."
  :type '(integer :tag "Sentences" 1)
  :group 'english-reading-mode)

(defcustom english-reading-mode-macos-prefetch-chunk-count 6
  "Number of future resident speech chunks prepared during continuous reading."
  :type '(integer :tag "Chunks" 1)
  :group 'english-reading-mode)

(defcustom english-reading-mode-macos-prefetch-check-interval 0.5
  "Seconds between checks that replenish resident speech prefetch."
  :type '(number :tag "Seconds")
  :group 'english-reading-mode)

(defvar english-reading-mode-pdf-text-buffer-hook nil
  "Hook run in a PDF's extracted text buffer after text normalization.

Clients can use this to detect the document language and select a matching
speech backend.  The extracted buffer, rather than the DocView image buffer,
is where PDF speech is actually synthesized.")

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

(defvar english-reading-mode--pdf-highlight-timer nil)

(defvar english-reading-mode--pdf-highlight-pending-context nil)

(defvar english-reading-mode--pdf-highlight-pending-scroll-state nil)

(defvar english-reading-mode--pdf-highlight-watch-timer nil)

(defvar english-reading-mode--pdf-highlight-watch-context nil)

(defvar english-reading-mode--pdf-highlight-watch-remaining 0)

(defvar english-reading-mode nil)

(defvar-local english-reading-mode--saved-sentence-end-double-space nil)

(defvar-local english-reading-mode--sentence-setting-saved-p nil)

(defvar-local english-reading-mode--sentence-setting-was-local-p nil)

(defvar-local english-reading-mode--saved-buffer-read-only nil)

(defvar-local english-reading-mode--read-only-setting-saved-p nil)

(defvar-local english-reading-mode--pdf-text-buffer nil)

(defvar-local english-reading-mode--pdf-page-ranges nil)

(defvar-local english-reading-mode--pdf-page nil)

(defvar-local english-reading-mode--pdf-text-point nil)

(defvar-local english-reading-mode--pdf-bbox-cache nil)

(defvar-local english-reading-mode--pdf-image-data-cache nil)

(defvar-local english-reading-mode--pdf-highlight-page nil)

(defvar-local english-reading-mode--pdf-highlight-state nil)

(defvar-local english-reading-mode-key-active-predicate nil
  "Optional function deciding whether this mode's keys are active.

When nil, `english-reading-mode' behaves as a normal buffer-local minor mode.
Consumers such as my-read can set this to a window-aware predicate so a
shared reading buffer does not keep its keys in unrelated windows.")

(defconst english-reading-mode--pdf-zoom-commands
  '(pdf-view-enlarge
    pdf-view-shrink
    pdf-view-scale-reset
    pdf-view-fit-page-to-window
    pdf-view-fit-height-to-window
    pdf-view-fit-width-to-window)
  "PDF commands after which continuous speech needs position correction.")

(defvar english-reading-mode--speech-watch-timer nil
  "Timer used to watch Kokoro request/playback lifetime.")

(defvar english-reading-mode--speech-start-time nil
  "Time when the active English-reading utterance was handed to Kokoro.")

(defvar english-reading-mode--speech-player-seen-p nil
  "Non-nil after the active utterance has reached actual audio playback.")

(defvar english-reading-mode--exact-player-finish-p nil
  "Non-nil while handling the audio player's exact exit notification.")

(defvar english-reading-mode--continuous-state nil
  "State plist for sentence-by-sentence continuous reading.")

(defvar english-reading-mode--continuous-generation 0
  "Generation invalidating delayed work after stop or a new reading session.")

(defvar english-reading-mode--continuous-timer nil
  "Timer that starts the next continuous-reading sentence.")

(defvar english-reading-mode--macos-prefetch-monitor-timer nil
  "Timer that keeps continuous macOS speech prefetch filled.")

(defvar english-reading-mode--continuous-warmup-timer nil
  "Timer waiting for the initial continuous macOS speech buffer to fill.")

(defconst english-reading-mode--pdf-manual-interaction-commands
  '(mwheel-scroll
    pixel-scroll-precision
    scroll-up-command
    scroll-down-command
    image-scroll-up
    image-scroll-down
    pdf-view-scroll-up-or-next-page
    pdf-view-scroll-down-or-previous-page
    pdf-view-next-line-or-next-page
    pdf-view-previous-line-or-previous-page
    pdf-view-next-page
    pdf-view-previous-page
    pdf-view-next-page-command
    pdf-view-previous-page-command
    pdf-roll-scroll-forward
    pdf-roll-scroll-backward
    pdf-roll-next-page
    pdf-roll-previous-page
    pdf-roll-goto-page
    pdf-view-first-page
    pdf-view-last-page
    pdf-view-goto-page
    english-reading-mode-next-page
    english-reading-mode-previous-page
    pdf-view-mouse-set-region
    pdf-view-mouse-set-region-rectangle)
  "Commands that make a PDF reader's manual position authoritative.")

(defvar-local english-reading-mode-continuous-next-function nil
  "Optional source-specific function that advances and speaks the next sentence.")

(defvar-local english-reading-mode-continuous-prefetch-text-function nil
  "Optional function returning future page text chunks for speech prefetch.

The function receives the active speech CONTEXT and a maximum COUNT.  It is
used after readable chunks in the current speech buffer have been exhausted.")

(defvar english-reading-mode-speech-prepare-hook nil
  "Functions called with the speech context before publishing it as active.")
(defvar english-reading-mode-speech-highlight-hook nil
  "Functions called with a newly active context before speech-start listeners.")

(provide 'english-reading-state)
;;; english-reading-state.el ends here
