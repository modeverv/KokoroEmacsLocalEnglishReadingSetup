"""Protocol, failure, cancellation and continuous PCM playback contract tests."""
import base64
import io
import json
import os
from pathlib import Path
import queue
import socket
from functools import partial
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
        self.assertEqual(result, [b'\x01\x00' * 240, None])
        self.assertEqual([call[0] for call in self.calls], ["一文目です。 二文目です。"])
        self.assertEqual(self.calls[0][1]["voice"], "Kyoko")
        self.receive({"text": "English.", "language": "en"})
        self.assertEqual(self.calls[-1][1]["voice"], "bf_emma")
        self.receive({"text": "Another English sentence.", "language": "en"})
        self.assertEqual(len({call[2] for call in self.calls if call[1]["backend"] == "kokoro"}), 1)

    def test_auto_language_reaches_synthesis_and_start_metadata(self):
        import urllib.request
        for text, language, voice in (("APIの説明です。", "ja", "Kyoko"), ("Hello.", "en", "bf_emma")):
            payload = json.dumps(dict(text=text, language="auto")).encode()
            request = urllib.request.Request(self.endpoint + "/v1/speech/stream", data=payload,
                      headers={"Authorization": "Bearer test-secret", "Content-Type": "application/json"})
            with urllib.request.urlopen(request) as response:
                events = [json.loads(line) for line in response]
            self.assertEqual(events[0]["language"], language)
            self.assertEqual(events[0]["voice"], voice)
            self.assertEqual(events[-1]["type"], "done")
            self.assertEqual(self.calls[-1][1]["language"], language)

    def test_macos_prefetch_runs_while_model_and_first_macos_job_are_busy(self):
        release = threading.Event()
        model_busy, macos_busy = threading.Event(), threading.Event()
        def block(entered):
            entered.set()
            release.wait(5)
        self.http.worker.submit(block, model_busy)
        self.http.macos_worker.submit(block, macos_busy)
        try:
            self.assertTrue(model_busy.wait(1))
            self.assertTrue(macos_busy.wait(1))
            start = time.monotonic()
            result = self.receive({"text": "日本語です。", "language": "ja"})
            self.assertLess(time.monotonic() - start, 2, "macOS job waited behind a blocked worker")
            self.assertIsNone(result[-1])
            self.assertFalse(release.is_set())
        finally:
            release.set()

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
            opener = partial(client.open_speech_request, busy_timeout=.1)
            with patch.object(client, "open_speech_request", opener):
                error = self.receive({"text": "hello"})[0]
            self.assertEqual(error.code, 503)
            self.assertIn("server busy", str(error))
        finally:
            for _ in range(4):
                self.http.slots.release()

    def test_busy_retries_until_capacity_is_available(self):
        for _ in range(4):
            self.http.slots.acquire()
        timer = threading.Timer(.3, self.http.slots.release)
        timer.start()
        try:
            self.assertEqual(self.receive({"text": "hello"})[-1], None)
            self.assertEqual(len(self.calls), 1)
        finally:
            timer.join()
            for _ in range(3):
                self.http.slots.release()

    def test_cancelled_waiter_releases_slot_and_does_not_synthesize(self):
        busy, release = threading.Event(), threading.Event()
        def block_worker():
            busy.set()
            release.wait(5)
        self.http.worker.submit(block_worker)
        self.assertTrue(busy.wait(1))
        connection = socket.create_connection(("127.0.0.1", self.http.server_port))
        payload = json.dumps({"text": "cancelled"}).encode()
        connection.sendall(("POST /v1/speech/stream HTTP/1.0\r\n"
                            "Authorization: Bearer test-secret\r\n"
                            f"Content-Length: {len(payload)}\r\n\r\n").encode() + payload)
        try:
            self.assertIn(b"200", connection.recv(4096))
            connection.close()
            deadline = time.monotonic() + 2
            while self.http.slots._value != 4 and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertEqual(self.http.slots._value, 4)
            release.set()
            self.http.worker.submit(lambda: None).result(timeout=2)
            self.assertEqual(self.calls, [])
        finally:
            connection.close()
            release.set()

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
    def test_auto_language_script_rules_and_defaults(self):
        for text, language in [("日本語のAPIです。", "ja"), ("漢字", "ja"), ("ｶﾀｶﾅ", "ja"),
                               ("𠮷野家", "ja"), ("Hello!", "en"), ("Ｈｅｌｌｏ", "en"),
                               ("123 ! 😀", "en")]:
            with self.subTest(text=text):
                result = server.validate(dict(text=text, language="auto"))
                self.assertEqual(result["language"], language)
                self.assertEqual(result["text"], text)
                self.assertEqual(result["voice"], "Kyoko" if language == "ja" else "bf_emma")
                self.assertEqual(result["backend"], "macos" if language == "ja" else "kokoro")
        self.assertEqual(server.validate(dict(text="123。", language="auto", fallback_language="ja"))["language"], "ja")

    def test_auto_language_profiles_do_not_leak_across_languages(self):
        profiles = {"ja": dict(backend="macos", voice="Kyoko", rate=540),
                    "en": dict(backend="kokoro", voice="bf_emma", speed=1.2)}
        en = server.validate(dict(text="Hello", language="auto", language_options=profiles))
        ja = server.validate(dict(text="こんにちは", language="auto", language_options=profiles))
        self.assertIsNone(en["rate"])
        self.assertEqual(en["speed"], 1.2)
        self.assertEqual(ja["rate"], 540)
        self.assertEqual(ja["speed"], 1.0)

    def test_explicit_language_and_omitted_language_keep_old_behavior(self):
        self.assertEqual(server.validate(dict(text="Hello", language="ja"))["language"], "ja")
        self.assertEqual(server.validate(dict(text="日本語", language="en"))["language"], "en")
        self.assertEqual(server.validate(dict(text="日本語"))["language"], "en")

    def test_auto_language_rejects_ambiguous_or_invalid_settings(self):
        for extra in [dict(voice="Kyoko"), dict(rate=540), dict(lang_code="j"),
                      dict(fallback_language="auto"), dict(language_options=[]),
                      dict(language_options={"fr": {}}), dict(language_options={"ja": None}),
                      dict(language_options={"ja": {"text": "replace"}}),
                      dict(language_options={"ja": {"rate": -1}})]:
            with self.subTest(extra=extra), self.assertRaises(ValueError):
                server.validate(dict(text="日本語", language="auto", **extra))

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


class SynthesisEfficiencyTests(unittest.TestCase):
    def test_macos_batches_short_sentences_but_bounds_long_requests(self):
        text = "短い文。次の文。" * 100
        chunks = list(server.synthesis_chunks({"text": text, "backend": "macos"}))
        self.assertTrue(all(len(chunk) <= 240 for chunk in chunks))
        self.assertEqual("".join(chunks).replace(" ", ""), text)
        self.assertLess(len(chunks), len(list(server.split_text(text))))

    def test_model_backends_keep_sentence_boundaries(self):
        for backend in ("kokoro", "irodori"):
            self.assertEqual(list(server.synthesis_chunks({"text": "One. Two.", "backend": backend})),
                             ["One.", "Two."])

    def test_canonical_wav_needs_no_conversion_process(self):
        wav = wav_bytes()
        with patch.object(server.subprocess, "run") as run:
            self.assertEqual(server.canonical_wav(wav), wav)
            run.assert_not_called()

    def test_truncated_pcm_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "truncated"):
            server.canonical_wav(wav_bytes()[:-10])


class ServiceTests(unittest.TestCase):
    def test_control_lock_timeout_is_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            with service.control_lock(Path(directory)):
                with self.assertRaisesRegex(RuntimeError, "still busy"):
                    with service.control_lock(Path(directory), timeout=.01):
                        self.fail("lock unexpectedly acquired")

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
