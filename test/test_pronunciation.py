"""Dictionary persistence, automatic selection, API contracts and native use."""
import concurrent.futures
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import wave

import numpy as np
from fastapi.testclient import TestClient

from speech_http.dictionary_ui import create_app
from speech_http.pronunciation import (DictionaryStore, acoustic_distance, ipa_candidates,
                                       prepare_entry, validate_entry)
from speech_http import server


def tone(hz=400):
    pcm = (np.sin(np.arange(24000) * 2 * np.pi * hz / 24000) * 8000).astype("<i2")
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setparams((1, 2, 24000, 0, "NONE", "not compressed"))
        wav.writeframes(pcm.tobytes())
    return output.getvalue()


class DictionaryTests(unittest.TestCase):
    def test_validation_and_candidates(self):
        self.assertEqual(validate_entry(" 重複 ", " ちょうふく "), ("重複", "ちょうふく"))
        for word, reading in [("", "ねこ"), ("猫", "ネコ"), ("猫", "neko"), ("猫", "ねこ\nだ"), ("a\0", "あ")]:
            with self.assertRaises(ValueError):
                validate_entry(word, reading)
        self.assertIn("ne.ko", ipa_candidates("ねこ"))
        self.assertTrue(ipa_candidates("きょうと"))
        self.assertEqual(ipa_candidates("ぁっ"), [])

    def test_atomic_concurrent_edits_upsert_delete_and_bad_file(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "dictionary.json"
            def add(i):
                DictionaryStore(path).save(entry=dict(word=f"猫{i}", reading="ねこ"))
            with concurrent.futures.ThreadPoolExecutor(4) as pool:
                list(pool.map(add, range(20)))
            store = DictionaryStore(path)
            self.assertEqual(len(store.read()["entries"]), 20)
            old = store.read()["revision"]
            store.save(entry=dict(word="猫1", reading="にゃんこ"))
            self.assertEqual(len(store.read()["entries"]), 20)
            self.assertNotEqual(store.read()["revision"], old)
            store.save(delete="猫1")
            self.assertEqual(len(store.read()["entries"]), 19)
            path.write_text("broken")
            with self.assertRaises(ValueError):
                store.save(entry=dict(word="犬", reading="いぬ"))
            self.assertEqual(path.read_text(), "broken")

    def test_acoustic_guard(self):
        self.assertLess(acoustic_distance(tone(), tone()), .000001)
        self.assertGreater(acoustic_distance(tone(), tone(2000)), .025)

    def test_automatic_selection_and_utf16_ranges(self):
        class Worker:
            def describe(self, voice):
                return dict(voiceIdentifier="voice", osVersion="os")
            def render(self, text, **kwargs):
                spans = kwargs.get("spans")
                if spans:
                    self.last = spans[0]
                return tone()
        worker = Worker()
        entry = prepare_entry("𠮷野", "ねこ", worker)
        self.assertEqual(entry["strategy"], "ipa")
        self.assertEqual(worker.last["length"], 3)
        self.assertEqual(worker.last["location"], 3)
        with patch("speech_http.pronunciation.acoustic_distance", return_value=.5):
            self.assertEqual(prepare_entry("猫", "ねこ", worker)["strategy"], "reading")

    def test_http_macos_uses_native_and_keeps_rate(self):
        with patch("speech_http.native.synthesize", return_value=tone()) as synth:
            server.synthesize("日本語", server.validate(dict(text="日本語", language="ja", rate=540)))
            synth.assert_called_once_with("日本語", "Kyoko", 540)

    def test_chunk_cut_does_not_split_dictionary_word(self):
        text = "あ" * 238 + "東京都" + "い" * 20
        chunks = list(server.split_text(text, protected_words=["東京都"]))
        self.assertEqual("".join(chunks), text)
        self.assertTrue(any("東京都" in chunk for chunk in chunks))
        self.assertTrue(all(len(chunk) <= 240 for chunk in chunks))


class DictionaryAPITests(unittest.TestCase):
    def test_editor_save_preview_delete_security_and_invalid_reading(self):
        with tempfile.TemporaryDirectory() as folder:
            store = DictionaryStore(Path(folder) / "dict.json")
            app = create_app(store, verifier=lambda w, r: dict(word=w, reading=r, strategy="reading"), renderer=lambda r: tone())
            with TestClient(app, base_url="http://localhost") as client:
                headers = {"X-Reader-Dictionary": "1"}
                payload = dict(word="重複", reading="ちょうふく")
                self.assertIn("読み辞書", client.get("/").text)
                self.assertEqual(client.post("/api/entries", json=payload).status_code, 403)
                self.assertEqual(client.post("/api/entries", json=payload, headers={**headers, "Origin": "https://bad.test"}).status_code, 403)
                self.assertEqual(client.get("/", headers={"Host": "bad.test"}).status_code, 400)
                self.assertEqual(client.post("/api/entries", json=dict(word="猫", reading="neko"), headers=headers).status_code, 422)
                self.assertEqual(client.post("/api/entries", json=payload, headers=headers).status_code, 200)
                self.assertEqual(client.get("/api/entries").json()["entries"][0]["word"], "重複")
                result = client.post("/api/preview", json=payload, headers=headers)
                self.assertEqual(result.content, tone())
                self.assertEqual(result.headers["content-type"], "audio/wav")
                self.assertEqual(client.delete("/api/entries", params={"word": "重複"}, headers=headers).status_code, 200)
                self.assertEqual(store.read()["entries"], [])

    def test_generation_failure_does_not_register(self):
        with tempfile.TemporaryDirectory() as folder:
            store = DictionaryStore(Path(folder) / "dict.json")
            def fail(*args):
                raise RuntimeError("synthesis failed")
            with TestClient(create_app(store, verifier=fail), base_url="http://localhost") as client:
                self.assertEqual(client.post("/api/entries", json=dict(word="猫", reading="ねこ"),
                                             headers={"X-Reader-Dictionary": "1"}).status_code, 503)
                self.assertEqual(store.read()["entries"], [])


@unittest.skipUnless(os.environ.get("READER_NATIVE_AUDIO_TESTS") == "1", "native synthesis opt-in")
class NativeDictionaryTests(unittest.TestCase):
    def test_live_dictionary_reload_longest_match_unicode_and_voice_scope(self):
        from speech_http.native import NativeWorker
        with tempfile.TemporaryDirectory() as folder:
            store = DictionaryStore(Path(folder) / "dict.json")
            store.save(entry=dict(word="東京", reading="ねこ"))
            store.save(entry=dict(word="東京都", reading="いぬ"))
            store.save(entry=dict(word="𠮷野", reading="きつね"))
            worker = NativeWorker(dictionary=store.path)
            try:
                actual = worker.render("東京都と𠮷野", rate=180)
                expected = worker.render("イヌとキツネ", rate=180, dictionary=False)
                self.assertEqual(actual, expected)
                store.save(entry=dict(word="東京都", reading="さくら"))
                self.assertEqual(worker.render("東京都", rate=180), worker.render("サクラ", rate=180, dictionary=False))
                baseline = worker.render("東京", rate=180, dictionary=False)
                changed = worker.render("東京", rate=180, dictionary=False,
                                        spans=[dict(location=0, length=2, ipa="ne.ko")])
                self.assertNotEqual(baseline, changed)
                self.assertEqual(baseline, worker.render("東京", rate=180, dictionary=False))
                voice = worker.describe()
                entry = dict(word="東京", reading="ねこ", strategy="ipa", ipa="ne.ko",
                             voice_identifier=voice["voiceIdentifier"], os_version=voice["osVersion"])
                store.save(entry=entry)
                self.assertEqual(worker.render("東京", rate=180), changed)
                store.save(entry=dict(entry, os_version="another OS"))
                self.assertEqual(worker.render("東京", rate=180), worker.render("ネコ", rate=180, dictionary=False))
                store.save(entry=dict(word="API", reading="ねこ"))
                self.assertEqual(worker.render("CAPITAL", rate=180), worker.render("CAPITAL", rate=180, dictionary=False))
                store.save(entry=dict(word="葉山", reading="はやま"))
                self.assertEqual(worker.render("葉山は来ます。", rate=180),
                                 worker.render("ハヤマは来ます。", rate=180, dictionary=False))
                original = store.path.read_bytes()
                store.path.write_text("broken")
                worker.process.stdin.write(json.dumps(dict(command="render", id=999, text="東京", voice="Kyoko",
                                                           path=str(Path(folder) / "invalid.caf"))) + "\n")
                worker.process.stdin.flush()
                with self.assertRaises(RuntimeError):
                    worker._until("rendered", 999, 10)
                store.path.write_bytes(original)
                self.assertEqual(worker.render("東京", rate=180), worker.render("ネコ", rate=180, dictionary=False))
            finally:
                worker.close()
