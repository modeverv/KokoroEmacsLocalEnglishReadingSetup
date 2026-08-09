# Kokoro + Emacs local english reading setup

## 1. Install dependencies in the `tomoko` project

```sh
uv add 'mlx-audio[server]' 'misaki[en]' 'spacy>=3.8,<4'
uv run python -m spacy download en_core_web_sm
```

The earlier successful Kokoro CLI environment may already contain some of these.

## 2. Start the dedicated server

Place `kokoro_server.py` in the project root, then run:

```sh
uv run python kokoro_server.py --host 127.0.0.1 --port 8000
```

Health check:

```sh
curl -s http://127.0.0.1:8000/health
```

End-to-end test:

```sh
curl --fail-with-body \
  -X POST http://127.0.0.1:8000/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "mlx-community/Kokoro-82M-bf16",
    "input": "A short time later, the doctor came into the room.",
    "voice": "bf_emma",
    "speed": 1.0,
    "lang_code": "b",
    "response_format": "wav",
    "stream": false
  }' \
  --output /tmp/kokoro-test.wav

afplay /tmp/kokoro-test.wav
```

The server binds only to `127.0.0.1` by default, loads Kokoro at startup, and serializes inference on one dedicated worker thread.

## 3. Install the Emacs client

Copy `kokoro-reader.el` somewhere on `load-path`, for example:

```sh
mkdir -p ~/.emacs.d/lisp
cp kokoro-reader.el ~/.emacs.d/lisp/
cp english-reading-mode.el ~/.emacs.d/lisp/
```

Add this to `init.el`:

```elisp
(add-to-list 'load-path (expand-file-name "lisp" user-emacs-directory))
(require 'kokoro-reader)
(require 'english-reading-mode)

(setq kokoro-reader-endpoint
      "http://127.0.0.1:8000/v1/audio/speech"
      kokoro-reader-voice "bf_emma"
      kokoro-reader-lang-code "b"
      kokoro-reader-speed 1.0)

;; Enable automatically when EPUBs are read with nov.el.
(add-hook 'nov-mode-hook #'english-reading-mode)
```

For another reading mode, run `M-x kokoro-reader-mode` in that buffer.

## Keys

| Key | Action |
|---|---|
| `C-c p` | Read paragraph |
| `C-c n` | Read sentence and move to the next sentence |
| `C-c k` | Cancel generation or stop playback |

The client is asynchronous: Emacs remains usable during synthesis and playback. Starting another utterance automatically cancels the previous one.

## EPUB English reading mode

`english-reading-mode` is a minor mode for reading English EPUBs in `nov.el`.
It uses the same local Kokoro server settings as `kokoro-reader-mode`:

| Key | Action |
|---|---|
| `j` | Read the sentence at point, then move to the next sentence |
| `k` | Move to the previous sentence and read it |
| `C-c C-k` | Stop reading |
