# Kokoro + Emacs local english reading setup

## 1. Install dependencies

Run these commands in the reader checkout. The Emacs launcher enables the
`japanese` extra so Japanese support survives subsequent server starts.

```sh
uv sync --inexact --extra japanese
uv run --extra japanese python -m spacy download en_core_web_sm
```

On macOS, if building `pyopenjtalk` fails with `fatal error: 'fstream' file not
found` while the C++ headers exist inside the SDK, supply their include path:

```sh
CPLUS_INCLUDE_PATH="$(xcrun --show-sdk-path)/usr/include/c++/v1${CPLUS_INCLUDE_PATH:+:$CPLUS_INCLUDE_PATH}" uv sync --inexact --extra japanese
```

`--inexact` preserves the separately installed English spaCy model. The server
uses Misaki's `pyopenjtalk` frontend for Japanese. On first use, pyopenjtalk
may download its Open JTalk dictionary; a full UniDic download is not required.

Japanese speech uses `lang_code="j"`, voice `jf_alpha`, and its own speed
multiplier. In Emacs select `kokoro` with `my-read-set-japanese-speech-backend`;
select `macos` to return to the Apple voice. English remains `bf_emma`.

## 2. Start the dedicated server (optional)

Place `kokoro_server.py` in the project root, then run:

```sh
uv run --extra japanese python kokoro_server.py --host 127.0.0.1 --port 8000
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

The Emacs client checks `/health` whenever speech is requested. If the server is
not already running, it starts the command above automatically and waits for
the health check to succeed before sending the speech request. This requires
the client file to remain next to `kokoro_server.py` (the default server
working directory), or an explicit configuration such as:

```elisp
(setq kokoro-reader-server-directory "/path/to/reader")
```

You can override `kokoro-reader-server-command` if your Kokoro environment uses
a different command. `C-c k` stops the current synthesis/playback; the server
is intentionally kept running for the next request.

## 3. Install the Emacs client

Copy `kokoro-reader.el` somewhere on `load-path`, for example:

```sh
mkdir -p ~/.emacs.d/lisp
cp kokoro-reader.el english-reading-*.el reader-document*.el ~/.emacs.d/lisp/
```

Keep these modules together; `english-reading-mode.el` loads its document,
PDF, speech, and prefetch modules. Add this to `init.el`:

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
| `j` | Move to the next sentence |
| `k` | Move to the previous sentence |
| `SPC` | Read the sentence at point |
| `s` | Read continuously, one sentence at a time |
| `i` | Insert an Org-noter note while a session is active |
| `C-v` / `M-v` | Next / previous PDF page |
| `C-c C-k` | Stop reading |
