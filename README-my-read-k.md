# my-read-k

`my-read-k` adds the visible page of Kindle Web Reader as an OCR text source to
the existing `my-read` workspace. Chrome remains the authenticated renderer;
the bridge captures only the current viewport through CDP and recognizes the
configured crop with Apple Vision. It does not read Kindle book DOM content,
cookies, or hidden resources.

## Requirements

- macOS 13 or later with Apple Vision
- Swift 6
- Emacs with this directory on `load-path`
- Chrome started with a loopback remote-debugging port and a dedicated profile
- an English book open in Kindle Web Reader, preferably one-page/one-column

Build the persistent bridge and run all automated tests:

```sh
make my-read-k-build
make my-read-k-check
```

To launch a separate Chrome profile on the default port `9000`:

```sh
scripts/launch-kindle-chrome.sh
```

The current browser can instead be kept as-is. Match its port in Emacs:

```elisp
(setq my-read-k-cdp-port 9000)
```

Keep the debugging address on `127.0.0.1`; a CDP endpoint gives powerful
control of its browser profile.

## Emacs setup and use

```elisp
(add-to-list 'load-path "~/Sync/emacs.d/reader")
(require 'my-read-k)
```

Open the English Kindle page in Chrome, then run:

```text
M-x my-read-k
```

The command creates the existing `my-read` three-column frame, attaches the
bridge asynchronously, and places OCR text in `*my-read-k:english*`. The center
is a normal read-only text buffer, so the existing word Lookup, paragraph
Google Translate, search/copy, and Kokoro integration continue to work.

Primary keys in the OCR buffer:

| Key | Action |
| --- | --- |
| `j` | Existing Kokoro next-sentence behavior; at the page boundary, fetch the next Kindle page and continue |
| `k` | Existing Kokoro previous-sentence behavior; at the page boundary, fetch the previous Kindle page and continue |
| `C-c ]` | Direct next-page/OCR command |
| `C-c [` | Direct previous-page/OCR command |
| `C-c g` | OCR the current page again |

Commands are also available as `my-read-k-next-page`, `my-read-k-prev-page`,
`my-read-k-refresh`, `my-read-k-attach`, `my-read-k-detach`,
`my-read-k-status`, and `my-read-k-show-last-error`.

## Configuration

The important options are:

- `my-read-k-cdp-host` / `my-read-k-cdp-port`
- `my-read-k-url-pattern`
- `my-read-k-crop`: `(x y width height)` normalized to the screenshot, with a
  top-left origin
- `my-read-k-language`
- `my-read-k-settle-poll-ms`, `my-read-k-settle-stable-samples`, and
  `my-read-k-settle-timeout-ms`

The default crop is `(0.08 0.06 0.84 0.88)`. Adjust it if Kindle controls,
headers, or page margins are being recognized.

## Behavior and troubleshooting

The bridge is one persistent JSON Lines process. Every request has an ID and a
monotonic generation; stale page results are ignored. Page navigation first
tries CDP ArrowLeft/ArrowRight. If Kindle ignores the key, it clicks the safe
left/right viewport margin, then requires the page fingerprint to change and
remain identical for consecutive samples before OCR.

Errors distinguish an unavailable CDP endpoint, missing target, disconnect,
invalid crop, navigation timeout, screenshot failure, OCR failure/no text, and
malformed protocol data. Run `M-x my-read-k-show-last-error` for the detailed
log. Closing the frame or running `M-x my-read-k-detach` stops the bridge
without blocking Emacs.

Screenshots and OCR page data remain in memory. There is no whole-book crawl,
batch export, or persistent OCR archive.
