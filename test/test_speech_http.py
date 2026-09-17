"""Protocol, failure, cancellation and continuous PCM playback contract tests."""
import base64
import io
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
from unittest.mock import patch
import urllib.error
import urllib.request
import wave

from speech_http import client, server, service


def wav_bytes(frames=240):
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(24000)
        wav.writeframes(b'\x01\x00' * frames)
    return output.getvalue()


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.calls = []
        def synth(text, options):
            self.calls.append((text, options, threading.get_ident()))
            if text == "fail":
                raise RuntimeError("test synthesis failure")
            return wav_bytes()
        self.http = server.SpeechServer(("127.0.0.1", 0), synthesizer=synth, token="test-secret")
        self.endpoint = f"http://127.0.0.1:{self.http.server_port}"
        self.thread = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.http.shutdown()
        self.http.server_close()
        self.thread.join()

    def receive(self, payload, token="test-secret"):
        output = queue.Queue()
        client.receive(self.endpoint, payload, output, token)
        result = []
        while not output.empty():
            result.append(output.get_nowait())
        return result

    def test_languages_chunk_order_pcm_and_single_worker(self):
        result = self.receive({"text": "一文目です。二文目です。", "language": "ja"})
        self.assertEqual(result, [b'\x01\x00' * 240] * 2 + [None])
        self.assertEqual([call[0] for call in self.calls], ["一文目です。", "二文目です。"])
        self.assertEqual(self.calls[0][1]["voice"], "Kyoko")
        self.receive({"text": "English.", "language": "en"})
        self.assertEqual(self.calls[-1][1]["voice"], "bf_emma")
        self.assertEqual(len({call[2] for call in self.calls}), 1)

    def test_rejects_unauthorized_before_synthesis(self):
        result = self.receive({"text": "hello"}, token="wrong")
        self.assertEqual(result[0].code, 401)
        self.assertEqual(self.calls, [])

    def test_invalid_request_has_http_error(self):
        result = self.receive({"text": "hello", "language": "xx"})
        self.assertEqual(result[0].code, 400)
        self.assertEqual(self.calls, [])

    def test_synthesis_failure_is_not_success(self):
        result = self.receive({"text": "fail"})
        self.assertIsInstance(result[0], RuntimeError)
        self.assertIn("test synthesis failure", str(result[0]))

    def test_busy_is_bounded(self):
        for _ in range(4):
            self.http.slots.acquire()
        try:
            self.assertEqual(self.receive({"text": "hello"})[0].code, 503)
        finally:
            for _ in range(4):
                self.http.slots.release()

    def test_one_player_concatenates_all_frames_without_wav_headers(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "pcm"
            player = Path(directory) / "player"
            player.write_text("#!/usr/bin/env python3\nimport sys\nfrom pathlib import Path\n"
                              f"Path({str(output)!r}).write_bytes(sys.stdin.buffer.read())\n")
            player.chmod(0o755)
            with patch.dict("os.environ", READER_SPEECH_TOKEN="test-secret"):
                client.play(self.endpoint, {"text": "First. Second. Third."}, prebuffer=.01,
                            player=str(player))
            self.assertEqual(output.read_bytes(), b'\x01\x00' * 720)

    def test_cancellation_reaps_audio_child(self):
        with tempfile.TemporaryDirectory() as directory:
            pidfile = Path(directory) / "pid"
            player = Path(directory) / "player"
            player.write_text("#!/usr/bin/env python3\nimport os,time\nfrom pathlib import Path\n"
                              f"Path({str(pidfile)!r}).write_text(str(os.getpid()))\ntime.sleep(60)\n")
            player.chmod(0o755)
            process = subprocess.Popen(
                [sys.executable, "-m", "speech_http.client", "--endpoint", self.endpoint,
                 "--prebuffer", ".01", "--player", str(player)], stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                env={**os.environ, "READER_SPEECH_TOKEN": "test-secret"})
            try:
                process.stdin.write(b'{"text":"Cancellation test."}')
                process.stdin.close()
                deadline = time.monotonic() + 5
                while not pidfile.exists() and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertTrue(pidfile.exists(), "audio player never started")
                pid = int(pidfile.read_text())
                process.terminate()
                self.assertEqual(process.wait(timeout=5), 130)
                with self.assertRaises(ProcessLookupError):
                    os.kill(pid, 0)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                process.stdout.close()
                process.stderr.close()

    def test_download_for_resident_player_preserves_all_frames(self):
        with tempfile.TemporaryDirectory() as directory:
            output = str(Path(directory) / "resident.wav")
            with patch.dict("os.environ", READER_SPEECH_TOKEN="test-secret"):
                client.download(self.endpoint, {"text": "First. Second."}, output)
            with wave.open(output, "rb") as wav:
                self.assertEqual(wav.getnframes(), 480)
                self.assertEqual(wav.readframes(480), b'\x01\x00' * 480)
            with patch.dict("os.environ", READER_SPEECH_TOKEN="test-secret"):
                with self.assertRaisesRegex(RuntimeError, "synthesis failure"):
                    client.download(self.endpoint, {"text": "fail"}, output)
            self.assertFalse(Path(output).exists())


class ValidationTests(unittest.TestCase):
    def test_splitting_preserves_content_and_bounds(self):
        text = "長い文章" * 200 + "。 Hello world! Last sentence."
        chunks = list(server.split_text(text))
        self.assertTrue(all(len(chunk) <= 240 for chunk in chunks))
        self.assertEqual(''.join(''.join(chunks).split()), ''.join(text.split()))

    def test_validation_rejects_bad_types_and_nonfinite_speed(self):
        for data in [[], {"text": " "}, {"text": 3}, {"text": "x", "speed": True},
                     {"text": "x", "speed": float('nan')}, {"text": "x", "voice": []},
                     {"text": "x", "backend": "irodori", "language": "en"}]:
            with self.subTest(data=data), self.assertRaises(ValueError):
                server.validate(data)

    def test_truncated_stream_and_wrong_order(self):
        for data in [b'{"type":"start","protocol":1}\n',
                     b'{"type":"audio","index":1}\n']:
            with patch.object(urllib.request, "urlopen", return_value=io.BytesIO(data)):
                result = queue.Queue()
                client.receive("http://example.test", {"text": "x"}, result)
                self.assertIsInstance(result.get(), Exception)

    def test_rejects_non_wav_audio(self):
        with self.assertRaises((wave.Error, EOFError)):
            client.decode_audio({"wav": base64.b64encode(b"not wav").decode()})

    def test_exact_macos_rate_above_multiplier_limit(self):
        options = server.validate({"text": "日本語", "language": "ja", "rate": 540})
        self.assertEqual(options["rate"], 540)
        for rate in (0, -1, True, 2.5):
            with self.assertRaises(ValueError):
                server.validate({"text": "日本語", "language": "ja", "rate": rate})

    def test_language_code_must_match_request_language(self):
        self.assertEqual(server.validate({"text": "Hello", "lang_code": "a"})["lang_code"], "a")
        with self.assertRaises(ValueError):
            server.validate({"text": "Hello", "language": "en", "lang_code": "j"})


class ServiceTests(unittest.TestCase):
    def test_running_service_is_reused_without_launch(self):
        with patch.object(service, "health", return_value={"ok": True, "pid": 42}), patch.object(service, "launchctl") as launch:
            self.assertEqual(service.ensure()["pid"], 42)
            launch.assert_not_called()

    def test_remote_failure_never_starts_local_server(self):
        with patch.object(service, "health", return_value=None), patch.object(service, "launchctl") as launch:
            with self.assertRaisesRegex(RuntimeError, "local-only"):
                service.ensure("http://192.0.2.1:8765")
            launch.assert_not_called()

    def test_stopped_service_starts_once_with_wildcard_bind(self):
        import plistlib
        with tempfile.TemporaryDirectory() as directory:
            paths = (Path(directory), "test.reader", "gui/501/test.reader")
            with patch.object(service, "service_paths", return_value=paths), patch.object(service, "health", side_effect=[None, None, {"ok": True}]), patch.object(service, "launchctl") as launch:
                self.assertTrue(service.ensure()["ok"])
                config = plistlib.loads((Path(directory) / "server.plist").read_bytes())
                self.assertIn("0.0.0.0", config["ProgramArguments"])
                self.assertFalse(config["KeepAlive"])
                self.assertEqual([call.args[0] for call in launch.call_args_list], ["bootout", "bootstrap"])

    def test_readiness_rechecked_after_lock_prevents_duplicate_start(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(service, "service_paths", return_value=(Path(directory), "test", "target")), patch.object(service, "health", side_effect=[None, {"ok": True}]), patch.object(service, "launchctl") as launch:
                service.ensure()
                launch.assert_not_called()


if __name__ == "__main__":
    unittest.main()
