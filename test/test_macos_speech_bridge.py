"""Opt-in native audio lifecycle regression; outputs silent PCM only.

Run after make my-read-speech-build with READER_NATIVE_AUDIO_TESTS=1.
"""
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import wave

BRIDGE = Path(__file__).resolve().parents[1] / "companion-implementations/macos-speech-bridge/my-read-speech-bridge"


@unittest.skipUnless(sys.platform == "darwin" and os.getenv("READER_NATIVE_AUDIO_TESTS") == "1",
                     "requires an available macOS audio device and explicit native test opt-in")
class NativePlaybackTests(unittest.TestCase):
    def test_underrun_waits_for_warmup_and_emits_every_start(self):
        events = queue.Queue()
        with tempfile.TemporaryDirectory() as directory:
            audio = str(Path(directory) / "silence.wav")
            with wave.open(audio, "wb") as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(24000)
                wav.writeframes(b"\0\0" * 3600)
            process = subprocess.Popen([str(BRIDGE)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.DEVNULL, text=True)
            def read():
                for line in process.stdout:
                    events.put(json.loads(line))
            thread = threading.Thread(target=read, daemon=True)
            thread.start()
            def send(command, **args):
                process.stdin.write(json.dumps(dict(command=command, **args)) + "\n")
                process.stdin.flush()
            def until(name, identifier=None):
                found = []
                deadline = time.monotonic() + 8
                while time.monotonic() < deadline:
                    event = events.get(timeout=max(.01, deadline - time.monotonic()))
                    self.assertNotEqual(event["event"], "error", event)
                    if event["event"] == "loaded":
                        self.assertAlmostEqual(event["duration"], .15, places=5)
                    found.append((event["event"], event.get("id")))
                    if found[-1] == (name, identifier):
                        return found
                self.fail("native playback event timed out")
            try:
                until("ready")
                send("hold")
                for identifier in range(1, 5):
                    send("reserve", id=identifier)
                for identifier in (1, 2):
                    send("loadFile", id=identifier, path=audio)
                send("play", warmup=2)
                initial = until("finished", 2)
                self.assertIn(("started", 1), initial)
                self.assertIn(("started", 2), initial)
                send("loadFile", id=3, path=audio)
                until("loaded", 3)
                # A running starved player used to consume this file silently
                # before warmup, producing finished(3) without started(3).
                with self.assertRaises(queue.Empty):
                    events.get(timeout=.4)
                send("loadFile", id=4, path=audio)
                resumed = until("finished", 4)
                playback = [event for event in resumed if event[0] in ("started", "finished")]
                self.assertEqual(playback, [("started", 3), ("finished", 3),
                                            ("started", 4), ("finished", 4)])
            finally:
                process.terminate()
                process.wait(timeout=5)
                process.stdin.close()
                thread.join(timeout=2)
                process.stdout.close()
