"""Reproducible native IPA probe; saves audio and evidence without playing it.

PYTHONPATH=companion-implementations companion-implementations/.venv/bin/python \
  scripts/verify_kyoko_ipa.py /tmp/reader-kyoko-verification
"""
import hashlib
import io
import json
from pathlib import Path
import sys
import wave

from speech_http.native import NativeWorker
from speech_http.pronunciation import acoustic_distance, prepare_entry


def main():
    output = Path(sys.argv[1])
    output.mkdir(parents=True, exist_ok=True)
    worker = NativeWorker()
    audio = {}
    try:
        report = {"voice": worker.describe("Kyoko"), "samples": {}}
        for label, text, ipa in [("baseline", "東京", None), ("baseline-repeat", "東京", None),
                                  ("ipa-neko", "東京", "ne.ko"), ("kana-neko", "ねこ", None),
                                  ("ipa-sakura", "東京", "sa.kɯ.ɾa"), ("kana-sakura", "さくら", None)]:
            raw = worker.render(text, rate=180, dictionary=False,
                                spans=[dict(location=0, length=2, ipa=ipa)] if ipa else None)
            audio[label] = raw
            (output / (label + ".wav")).write_bytes(raw)
            with wave.open(io.BytesIO(raw)) as wav:
                duration = wav.getnframes() / wav.getframerate()
            report["samples"][label] = dict(text=text, ipa=ipa, sha256=hashlib.sha256(raw).hexdigest(), seconds=duration)
        report["baseline_reproducible"] = audio["baseline"] == audio["baseline-repeat"]
        report["ipa_changes_audio"] = audio["baseline"] != audio["ipa-neko"]
        report["neko_reference_distance"] = acoustic_distance(audio["kana-neko"], audio["ipa-neko"])
        report["sakura_reference_distance"] = acoustic_distance(audio["kana-sakura"], audio["ipa-sakura"])
        report["registrations"] = [prepare_entry(word, reading, worker) for word, reading in
                                    [("東京", "ねこ"), ("重複", "ちょうふく"), ("固有名詞", "こゆうめいし")]]
        report["interpretation"] = "IPA attribute changes Kyoko audio; acoustic agreement with the supplied kana is checked separately. This is not a linguistic or pitch-accent certification."
        (output / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps(report, ensure_ascii=False, indent=2))
    finally:
        worker.close()


if __name__ == "__main__":
    main()
