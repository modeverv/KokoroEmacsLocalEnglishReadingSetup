"""Versioned NDJSON stream of independent PCM WAV chunks (stdlib HTTP)."""
from __future__ import annotations

import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
import io
import json
import os
import re
import subprocess
import tempfile
import threading
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

RATE = 24000
MAX_BODY = 100_000
MAX_TEXT = 24_000


def validate(data):
    if not isinstance(data, dict):
        raise ValueError("JSON object required")
    text = data.get("text")
    if not isinstance(text, str) or not text.strip() or len(text) > MAX_TEXT:
        raise ValueError(f"text must contain 1..{MAX_TEXT} characters")
    language = data.get("language", "en")
    if language not in ("en", "ja"):
        raise ValueError("language must be en or ja")
    backend = data.get("backend", "kokoro" if language == "en" else "macos")
    if backend not in ("kokoro", "macos", "irodori"):
        raise ValueError("backend must be kokoro, macos or irodori")
    if backend == "irodori" and language != "ja":
        raise ValueError("irodori supports Japanese only")
    speed = data.get("speed", 1.0)
    if isinstance(speed, bool) or not isinstance(speed, (int, float)) or not 0.5 <= speed <= 2:
        raise ValueError("speed must be between 0.5 and 2")
    defaults = {"kokoro": "bf_emma" if language == "en" else "jf_alpha",
                "macos": "Samantha" if language == "en" else "Kyoko", "irodori": "asuka"}
    voice = data.get("voice", defaults[backend])
    if not isinstance(voice, str) or len(voice) > 100 or voice.startswith("-"):
        raise ValueError("invalid voice")
    rate = data.get("rate")
    if rate is not None and (backend != "macos" or type(rate) is not int or rate <= 0):
        raise ValueError("rate must be a positive integer for the macos backend")
    lang_code = data.get("lang_code", "b" if language == "en" else "j")
    if lang_code not in (("a", "b") if language == "en" else ("j", "ja")):
        raise ValueError("lang_code does not match language")
    return dict(text=text.strip(), language=language, backend=backend, speed=speed, voice=voice,
                rate=rate, lang_code=lang_code)


def split_text(text, limit=240):
    """Keep punctuation, bound long sentences, never drop non-whitespace text."""
    for sentence in re.split(r"(?<=[。！？.!?])\s*|\n+", text):
        sentence = sentence.strip()
        while len(sentence) > limit:
            cut = sentence.rfind(" ", 0, limit + 1)
            if cut < limit // 2:
                cut = limit
            yield sentence[:cut]
            sentence = sentence[cut:].lstrip()
        if sentence:
            yield sentence


def synthesize(text, options):
    """Run exclusively on the persistent model worker; return canonical PCM WAV."""
    backend, voice, speed = (options[k] for k in ("backend", "voice", "speed"))
    if backend == "macos":
        with tempfile.TemporaryDirectory(prefix="reader-speech-") as directory:
            source, output = Path(directory) / "text.txt", Path(directory) / "speech.wav"
            source.write_text(text, encoding="utf-8")
            subprocess.run(["/usr/bin/say", "-v", voice, "-r", str(options.get("rate") or round(250 * speed)),
                            "-f", str(source), "-o", str(output), "--file-format=WAVE",
                            "--data-format=LEI16@24000"], check=True, capture_output=True, timeout=180)
            wav = output.read_bytes()
    elif backend == "irodori":
        import irodori_backend
        wav = irodori_backend.synthesize(text, voice, speed)
    else:
        import kokoro_server
        wav = kokoro_server._synthesize_wav(text, voice, speed,
                                          options["lang_code"])
    # Every backend has the same wire format, independent of native model output.
    pcm = subprocess.run(["ffmpeg", "-v", "error", "-i", "pipe:0", "-f", "s16le",
                          "-ar", str(RATE), "-ac", "1", "pipe:1"], input=wav,
                         capture_output=True, check=True, timeout=60).stdout
    if not pcm:
        raise RuntimeError("backend returned empty audio")
    output = io.BytesIO()
    with wave.open(output, "wb") as writer:
        writer.setnchannels(1)
        writer.setsampwidth(2)
        writer.setframerate(RATE)
        writer.writeframes(pcm)
    return output.getvalue()


class SpeechServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, synthesizer=synthesize, token="", playback_targets=None):
        super().__init__(address, Handler)
        self.synthesizer = synthesizer
        self.token = token
        self.playback_targets = playback_targets or {}
        self.worker = ThreadPoolExecutor(max_workers=1, thread_name_prefix="speech-model")
        self.slots = threading.BoundedSemaphore(4)

    def server_close(self):
        super().server_close()
        self.worker.shutdown(wait=False, cancel_futures=True)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass  # Do not retain submitted book text or request credentials.

    def setup(self):
        super().setup()
        self.connection.settimeout(300)

    def reply(self, status, data):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self.reply(200, {"ok": True, "service": "reader-speech", "protocol": 1,
                             "sample_rate": RATE, "pid": os.getpid(),
                             "host": self.server.server_address[0], "port": self.server.server_port})
        else:
            self.reply(404, {"error": "not found"})

    def do_POST(self):
        if self.path not in ("/v1/speech/stream", "/v1/speech/deliver"):
            return self.reply(404, {"error": "not found"})
        if self.server.token and self.headers.get("Authorization") != "Bearer " + self.server.token:
            return self.reply(401, {"error": "unauthorized"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= MAX_BODY:
                raise ValueError("invalid Content-Length")
            data = json.loads(self.rfile.read(length))
            options = validate(data)
            delivery = None
            if self.path == "/v1/speech/deliver":
                from speech_http.delivery import validate_delivery
                delivery = validate_delivery(data.get("playback"), self.server.playback_targets)
        except (ValueError, UnicodeError) as exc:
            return self.reply(400, {"error": str(exc)})
        if not self.server.slots.acquire(blocking=False):
            return self.reply(503, {"error": "server busy; retry later"})
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/x-ndjson")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Accel-Buffering", "no")
            self.end_headers()
            self.event({"type": "start", "protocol": 1, "sample_rate": RATE})
            count = 0
            for index, text in enumerate(split_text(options["text"])):
                if delivery:
                    from speech_http.delivery import upload
                    upload(delivery, "check")
                wav = self.server.worker.submit(self.server.synthesizer, text, options).result()
                if delivery:
                    upload(delivery, str(index), wav, "audio/wav")
                    self.event({"type": "delivered", "index": index})
                else:
                    self.event({"type": "audio", "index": index,
                                "wav": base64.b64encode(wav).decode("ascii")})
                count += 1
            if delivery:
                upload(delivery, "done", json.dumps({"count": count}).encode())
            self.event({"type": "done"})
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass
        except Exception as exc:
            try:
                self.event({"type": "error", "message": str(exc)})
            except OSError:
                pass
        finally:
            self.server.slots.release()

    def event(self, value):
        self.wfile.write(json.dumps(value).encode() + b"\n")
        self.wfile.flush()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    from speech_http.delivery import targets_from_json
    targets = targets_from_json(os.getenv("READER_SPEECH_PLAYBACK_TARGETS", "{}"))
    with SpeechServer((args.host, args.port), token=os.getenv("READER_SPEECH_TOKEN", ""),
                      playback_targets=targets) as server:
        print(f"Speech server http://{args.host}:{args.port}", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
