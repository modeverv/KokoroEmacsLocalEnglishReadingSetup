#!/usr/bin/env python3
"""Validate a speech server from any LAN client with Python's standard library."""
import argparse
import base64
import io
import json
import time
import urllib.request
import wave


def check(endpoint, backend, language):
    text = "Hello. This is a speech server test." if language == "en" else "こんにちは。音声生成サーバーの確認です。"
    request = urllib.request.Request(endpoint.rstrip("/") + "/v1/speech/stream",
                                     data=json.dumps(dict(text=text, language=language, backend=backend)).encode(),
                                     headers={"Content-Type": "application/json"})
    start = time.monotonic()
    chunks = frames = 0
    done = False
    with urllib.request.urlopen(request, timeout=300) as response:
        for line in response:
            event = json.loads(line)
            if event["type"] == "audio":
                if event["index"] != chunks:
                    raise RuntimeError("Audio chunk order is incorrect")
                with wave.open(io.BytesIO(base64.b64decode(event["wav"], validate=True))) as wav:
                    if (wav.getframerate(), wav.getnchannels(), wav.getsampwidth()) != (24000, 1, 2):
                        raise RuntimeError("Unexpected WAV format")
                    if not wav.getnframes() or len(wav.readframes(wav.getnframes())) != wav.getnframes() * 2:
                        raise RuntimeError("Empty or truncated audio")
                    frames += wav.getnframes()
                chunks += 1
            elif event["type"] == "error":
                raise RuntimeError(event["message"])
            elif event["type"] == "done":
                done = True
    if not done or not chunks:
        raise RuntimeError("Incomplete audio response")
    return dict(ok=True, endpoint=endpoint, backend=backend, language=language,
                chunks=chunks, audio_seconds=round(frames / 24000, 2),
                elapsed_seconds=round(time.monotonic() - start, 2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("endpoint")
    parser.add_argument("--backend", choices=("macos", "kokoro", "irodori"), default="kokoro")
    parser.add_argument("--language", choices=("en", "ja"), default="en")
    args = parser.parse_args()
    try:
        print(json.dumps(check(args.endpoint, args.backend, args.language)))
    except Exception as exc:
        parser.exit(1, f"Speech test failed: {exc}\n")
