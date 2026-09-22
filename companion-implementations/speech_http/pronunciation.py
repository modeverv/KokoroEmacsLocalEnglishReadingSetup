"""IME-style dictionary and conservative, local acoustic IPA verification.

IPA is an optimization, not a requirement for a reading. If the generated
candidate cannot reproduce the kana reference, retain the supplied reading.
"""
from __future__ import annotations

from contextlib import contextmanager
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import re
import tempfile
import unicodedata
import uuid
import wave

import numpy as np


def dictionary_path():
    return Path(os.environ.get("READER_SPEECH_DICTIONARY",
                str(Path(__file__).resolve().parents[2] / "pronunciations.json"))).expanduser()


def spoken_reading(reading):
    """Use katakana for lexical readings so は/へ are not treated as particles."""
    return "".join(chr(ord(c) + 0x60) if "ぁ" <= c <= "ゖ" else c for c in reading)


def validate_entry(word, reading):
    if not isinstance(word, str) or not isinstance(reading, str):
        raise ValueError("単語とよみを入力してください。")
    word = unicodedata.normalize("NFC", word.strip())
    reading = unicodedata.normalize("NFC", reading.strip())
    if not 1 <= len(word) <= 100 or any(unicodedata.category(c).startswith("C") for c in word):
        raise ValueError("単語は制御文字を含まない1〜100文字にしてください。")
    if not re.fullmatch(r"[ぁ-ゖー]{1,100}", reading):
        raise ValueError("よみはひらがな（長音「ー」も可）で1〜100文字にしてください。")
    return word, reading


class DictionaryStore:
    def __init__(self, path=None):
        self.path = Path(path) if path is not None else dictionary_path()
        self.read()  # Validate on server startup as well as before each edit.

    def read(self):
        if not self.path.exists():
            return {"version": 1, "revision": "empty", "entries": []}
        if self.path.stat().st_size > 2 * 1024 * 1024:
            raise ValueError("辞書ファイルが大きすぎます。")
        data = json.loads(self.path.read_text(encoding="utf-8"))
        if not isinstance(data, dict) or data.get("version") != 1 or not isinstance(data.get("entries"), list):
            raise ValueError("辞書ファイルの形式が不正です。")
        words = set()
        for entry in data["entries"]:
            if not isinstance(entry, dict):
                raise ValueError("辞書の項目が不正です。")
            word, reading = validate_entry(entry.get("word"), entry.get("reading"))
            if word in words or word != entry["word"] or reading != entry["reading"]:
                raise ValueError("辞書に重複または正規化されていない単語があります。")
            words.add(word)
        data.setdefault("revision", hashlib.sha256(self.path.read_bytes()).hexdigest())
        return data

    @contextmanager
    def locked(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.path.with_suffix(".lock").open("a") as stream:
            fcntl.flock(stream, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(stream, fcntl.LOCK_UN)

    def save(self, entry=None, delete=None):
        if entry is not None:
            word, reading = validate_entry(entry.get("word"), entry.get("reading"))
            entry = dict(entry, word=word, reading=reading)
        with self.locked():
            data = self.read()
            word = entry["word"] if entry is not None else delete
            data["entries"] = [e for e in data["entries"] if e["word"] != word]
            if entry is not None:
                data["entries"].append(entry)
            if len(data["entries"]) > 2000:
                raise ValueError("登録上限は2000語です。")
            data["entries"].sort(key=lambda e: e["word"])
            data["revision"] = uuid.uuid4().hex
            raw = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
            if len(raw.encode()) > 2 * 1024 * 1024:
                raise ValueError("辞書ファイルが大きすぎます。")
            fd, name = tempfile.mkstemp(prefix=".pronunciations-", dir=self.path.parent)
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as stream:
                    stream.write(raw)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(name, self.path)
            finally:
                Path(name).unlink(missing_ok=True)
            return data


def ipa_candidates(reading):
    """Generate candidates only for known kana; unfamiliar sequences fall back."""
    table = dict(zip("あいうえお", ["a", "i", "ɯ", "e", "o"]))
    for row, consonant in [("かきくけこ", "k"), ("がぎぐげご", "ɡ"), ("さしすせそ", "s"),
                           ("ざじずぜぞ", "z"), ("たちつてと", "t"), ("だぢづでど", "d"),
                           ("なにぬねの", "n"), ("はひふへほ", "h"), ("ばびぶべぼ", "b"),
                           ("ぱぴぷぺぽ", "p"), ("まみむめも", "m"), ("らりるれろ", "ɾ")]:
        table.update(zip(row, [consonant + vowel for vowel in ["a", "i", "ɯ", "e", "o"]]))
    table.update({"し": "ɕi", "ち": "tɕi", "つ": "tsɯ", "じ": "dʑi", "ぢ": "dʑi",
                  "づ": "zɯ", "ひ": "çi", "ふ": "ɸɯ", "や": "ja", "ゆ": "jɯ", "よ": "jo",
                  "わ": "wa", "を": "o", "ん": "ɴ", "ゔ": "vɯ", "ゐ": "i", "ゑ": "e"})
    for kana, prefix in [("き", "kʲ"), ("ぎ", "ɡʲ"), ("し", "ɕ"), ("じ", "dʑ"), ("ち", "tɕ"),
                         ("に", "ɲ"), ("ひ", "ç"), ("び", "bʲ"), ("ぴ", "pʲ"), ("み", "mʲ"), ("り", "ɾʲ")]:
        for small, vowel in zip("ゃゅょ", ["a", "ɯ", "o"]):
            table[kana + small] = prefix + vowel
    table.update({"ふぁ": "ɸa", "ふぃ": "ɸi", "ふぇ": "ɸe", "ふぉ": "ɸo",
                  "てぃ": "ti", "でぃ": "di", "しぇ": "ɕe", "ちぇ": "tɕe", "じぇ": "dʑe"})
    parts, index, geminate = [], 0, False
    while index < len(reading):
        char = reading[index]
        if char == "っ":
            if geminate:
                return []
            geminate = True
            index += 1
            continue
        if char == "ー":
            if not parts or geminate:
                return []
            parts[-1] += "ː"
            index += 1
            continue
        key = reading[index:index + 2] if reading[index:index + 2] in table else char
        if key not in table:
            return []
        phone = table[key]
        if geminate:
            if phone[0] not in "kstpbdɡzɕtɸ":
                return []
            phone = phone[0] + "ː" + phone[1:]
            geminate = False
        parts.append(phone)
        index += len(key)
    if geminate:
        return []
    ipa = ".".join(parts)
    return list(dict.fromkeys([ipa, ipa.replace("ɾ", "ɽ"), ipa.replace("ɯ", "u").replace("ɾ", "r")]))


def acoustic_distance(reference, candidate):
    """Conservative mel-spectrum DTW distance, plus a strict duration guard.

This checks acoustic agreement, not linguistic correctness. It cannot certify
pitch accent in every sentence. On uncertainty the original kana is used.
"""
    def features(raw):
        with wave.open(io.BytesIO(raw)) as wav:
            if (wav.getframerate(), wav.getnchannels(), wav.getsampwidth()) != (24000, 1, 2):
                raise ValueError("expected mono 24kHz PCM")
            signal = np.frombuffer(wav.readframes(wav.getnframes()), dtype="<i2").astype(float) / 32768
        active = np.flatnonzero(abs(signal) > .002)
        if not len(active):
            raise ValueError("no audible speech")
        signal = signal[max(0, active[0] - 240):active[-1] + 241]
        signal = np.pad(signal, (0, max(0, 600 - len(signal))))
        frames = np.lib.stride_tricks.sliding_window_view(signal, 600)[::240]
        power = abs(np.fft.rfft(frames * np.hanning(600), n=1024)) ** 2
        hz = np.linspace(0, 12000, 513)
        edges = 700 * (10 ** (np.linspace(2595 * np.log10(1 + 80 / 700),
                                        2595 * np.log10(1 + 8000 / 700), 42) / 2595) - 1)
        filters = np.maximum(0, np.minimum((hz[None, :] - edges[:-2, None]) /
                             (edges[1:-1] - edges[:-2])[:, None],
                             (edges[2:, None] - hz[None, :]) / (edges[2:] - edges[1:-1])[:, None]))
        mel = np.log1p(power @ filters.T * 100)
        mel /= np.maximum(np.linalg.norm(mel, axis=1, keepdims=True), 1e-9)
        return mel, len(signal)
    left, n = features(reference)
    right, m = features(candidate)
    if abs(n - m) / max(n, m) > .12:
        return 1.0
    costs = np.maximum(0, 1 - left @ right.T)
    dp = np.full((len(left) + 1, len(right) + 1), np.inf)
    dp[0, 0] = 0
    for i in range(1, len(left) + 1):
        for j in range(max(1, i - 12), min(len(right), i + 12) + 1):
            dp[i, j] = costs[i - 1, j - 1] + min(dp[i - 1, j], dp[i, j - 1], dp[i - 1, j - 1])
    return float(dp[-1, -1] / max(len(left), len(right)))


def prepare_entry(word, reading, worker):
    word, reading = validate_entry(word, reading)
    voice = worker.describe("Kyoko")
    entry = dict(word=word, reading=reading, strategy="reading", ipa=None,
                 voice_identifier=voice["voiceIdentifier"], os_version=voice["osVersion"],
                 verification="kana_fallback", score=None)
    # Compare in a neutral sentence as well as alone, so a coincidental match
    # on a short isolated sound is not sufficient to adopt a candidate.
    spoken = spoken_reading(reading)
    references = [worker.render(spoken, rate=180, dictionary=False),
                  worker.render("これは" + spoken + "です。", rate=180, dictionary=False)]
    for ipa in ipa_candidates(reading):
        scores = []
        for prefix, suffix, reference in [("", "", references[0]), ("これは", "です。", references[1])]:
            try:
                raw = worker.render(prefix + word + suffix, rate=180, dictionary=False,
                                    spans=[dict(location=len(prefix.encode("utf-16-le")) // 2,
                                                length=len(word.encode("utf-16-le")) // 2, ipa=ipa)])
            except (RuntimeError, TimeoutError):
                return entry  # Kana was rendered successfully; an IPA failure must not burden the user.
            scores.append(acoustic_distance(reference, raw))
        score = max(scores)
        if score < .025:
            entry.update(strategy="ipa", ipa=ipa, score=round(score, 6), verification="acoustic_match")
            break
    return entry
