"""Resident AVSpeechSynthesizer workers shared with the Emacs native bridge."""
from __future__ import annotations

import atexit
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading

BRIDGE_DIR = Path(__file__).resolve().parents[1] / "macos-speech-bridge"
BRIDGE = BRIDGE_DIR / "my-read-speech-bridge"
_build_lock = threading.Lock()
_local = threading.local()
_workers = []
_workers_lock = threading.Lock()


def ensure_bridge():
    with _build_lock:
        source = BRIDGE_DIR / "main.m"
        if not BRIDGE.exists() or BRIDGE.stat().st_mtime < source.stat().st_mtime:
            output = BRIDGE.with_name(f".bridge-{os.getpid()}")
            try:
                subprocess.run(["/usr/bin/clang", "-fobjc-arc", "-O2", "-Wall", "-Wextra", "-mmacosx-version-min=13.0",
                                "-framework", "Foundation", "-framework", "AVFoundation",
                                str(source), "-o", str(output)], check=True, capture_output=True, timeout=60)
                output.replace(BRIDGE)
            finally:
                output.unlink(missing_ok=True)


class NativeWorker:
    def __init__(self, dictionary=None):
        ensure_bridge()
        env = dict(os.environ)
        if dictionary is not None:
            env["READER_SPEECH_DICTIONARY"] = str(dictionary)
        self.process = subprocess.Popen([str(BRIDGE)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True, encoding="utf-8", env=env)
        self.events = queue.Queue()
        self.lock = threading.Lock()
        self.identifier = 0
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()
        try:
            self._until("ready", None, 30)
        except Exception:
            self.close()
            raise

    def _read(self):
        try:
            for line in self.process.stdout:
                self.events.put(json.loads(line))
        except (ValueError, OSError) as exc:
            self.events.put(exc)
        finally:
            self.events.put(RuntimeError("native speech worker exited"))

    def _until(self, name, identifier, timeout):
        import time
        deadline = time.monotonic() + timeout
        while True:
            try:
                event = self.events.get(timeout=max(0, deadline - time.monotonic()))
            except queue.Empty:
                raise TimeoutError("AVSpeechSynthesizer timed out") from None
            if isinstance(event, Exception):
                raise event
            if event.get("event") == "error":
                raise RuntimeError(event.get("message", "native speech error"))
            if event.get("event") == name and event.get("id") == identifier:
                return event

    def render(self, text, voice="Kyoko", rate=250, *, spans=None, dictionary=True):
        with self.lock, tempfile.TemporaryDirectory(prefix="reader-avspeech-") as directory:
            self.identifier += 1
            output = Path(directory) / "speech.caf"
            command = dict(command="render", id=self.identifier, text=text, voice=voice,
                           rate=rate, path=str(output), useDictionary=dictionary)
            if spans is not None:
                command["ipaSpans"] = spans
            try:
                self.process.stdin.write(json.dumps(command, ensure_ascii=False) + "\n")
                self.process.stdin.flush()
                self._until("rendered", self.identifier, 180)
                # CAF demuxing needs a seekable input; do not feed it via stdin.
                wav = Path(directory) / "speech.wav"
                subprocess.run(["ffmpeg", "-v", "error", "-i", str(output), "-ar", "24000",
                                "-ac", "1", "-c:a", "pcm_s16le", str(wav)],
                               check=True, capture_output=True, timeout=60)
                from speech_http.server import canonical_wav
                return canonical_wav(wav.read_bytes())
            except Exception:
                self.close()
                raise

    def describe(self, voice="Kyoko"):
        with self.lock:
            self.identifier += 1
            self.process.stdin.write(json.dumps(dict(command="describeVoice", id=self.identifier, voice=voice)) + "\n")
            self.process.stdin.flush()
            return self._until("voice", self.identifier, 30)

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.process.stdin.close()
        self.reader.join(timeout=3)
        self.process.stdout.close()


def synthesize(text, voice, rate):
    worker = getattr(_local, "worker", None)
    if worker is None or worker.process.poll() is not None:
        worker = NativeWorker()
        _local.worker = worker
        with _workers_lock:
            _workers.append(worker)
    return worker.render(text, voice, rate)


@atexit.register
def close_workers():
    with _workers_lock:
        workers, _workers[:] = list(_workers), []
    for worker in workers:
        worker.close()
