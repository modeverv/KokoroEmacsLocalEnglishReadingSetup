# Kokoro Emacs Reader

Read English text aloud from Emacs using a local [Kokoro](https://github.com/hexgrad/kokoro) TTS server.
The Emacs client sends text asynchronously, highlights the text being read,
and plays the generated WAV audio with macOS `afplay`.

## Requirements

- macOS with `/usr/bin/curl` and `/usr/bin/afplay`
- Python 3.11–3.13
- [`uv`](https://docs.astral.sh/uv/)
- An MLX-compatible Apple Silicon Mac
- Emacs 29 or later

## Installation

Install the Python dependencies from the repository root:

```sh
uv sync
```

Load the Emacs packages from this directory, or copy them to your Emacs
`load-path`:

```elisp
(add-to-list 'load-path "/path/to/reader")
(require 'kokoro-reader)
(require 'english-reading-mode)

;; Optional settings.
(setq kokoro-reader-voice "bf_emma"
      kokoro-reader-lang-code "b"
      kokoro-reader-speed 1.0)
```

## Usage

Enable `kokoro-reader-mode` with `M-x kokoro-reader-mode`, then use:

| Key | Action |
| --- | --- |
| `C-c p` | Read the paragraph at point |
| `C-c n` | Read the current sentence and move forward |
| `C-c k` | Cancel synthesis or stop playback |

For EPUB reading with `nov.el`, enable the companion mode:

```elisp
(add-hook 'nov-mode-hook #'english-reading-mode)
```

Its default keys are `j` for the current sentence, `k` for the previous
sentence, and `C-c C-k` to stop reading.

## Automatic server startup

The first speech request checks `http://127.0.0.1:8000/health`. If Kokoro is
not already running, Emacs automatically starts:

```sh
uv run python kokoro_server.py --host 127.0.0.1 --port 8000
```

It waits until the server is ready before sending the speech request. When the
client file is copied elsewhere, configure the server directory explicitly:

```elisp
(setq kokoro-reader-server-directory "/path/to/reader")
```

The server command and health endpoint can also be customized with
`kokoro-reader-server-command` and `kokoro-reader-health-endpoint`.

To start the server manually instead, run `make run` or the command above.
Detailed setup and API examples are available in
[`README-kokoro-emacs.md`](README-kokoro-emacs.md).

## License

This project is licensed under the [MIT License](LICENSE).
