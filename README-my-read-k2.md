# my-read-k2: Kindle.app backend

`my-read-k2.el` adds a macOS Kindle.app backend to the shared `my-read-k`
reader UI. It is intended for English books and reads only Kindle's native
Accessibility text.

## Setup

1. Open an English book in Kindle.app.
2. Give Emacs Accessibility permission in **System Settings → Privacy &
   Security → Accessibility**. If the bridge is launched from a terminal while
   testing, that terminal may also need permission.
3. Add this directory to `load-path`, load `my-read.el`, then run:

   ```elisp
   (require 'my-read)
   (my-read)
   ```

`my-read` uses this Kindle.app backend by default. The first invocation builds
the Swift bridge in release mode when no release
binary exists. To build it ahead of time:

```sh
swift build --package-path my-read-k2/bridge --configuration release
```

The reader keys are the same as `my-read-k`: `j`/`k` read by sentence and cross
page boundaries, `C-v`/`M-v` turn pages directly, `C-c g` refreshes, and `r`
reconnects to Kindle.app.

The bridge automatically reads the current book title from Kindle's local
`BookData.sqlite` metadata database in read-only mode. It does not use OCR or
send library data over the network. To override the detected title manually:

```elisp
(setq my-read-k2-book-name "My preferred title")
```

The bridge never crawls or saves a whole book. It reads only the currently
visible page and temporarily visits at most two following pages for the
existing in-memory prefetch queue, restoring Kindle.app to the source page.
