"""Read a JSON request from stdin, prebuffer WAV chunks and play one PCM stream."""
from __future__ import annotations

import argparse
import base64
import io
import json
import os
import queue
import signal
import subprocess
import sys
import threading
import urllib.error
import urllib.request
import wave

RATE = 24000


def decode_audio(event):
    data = base64.b64decode(event["wav"], validate=True)
    with wave.open(io.BytesIO(data), "rb") as wav:
        if (wav.getnchannels(), wav.getsampwidth(), wav.getframerate(), wav.getcomptype()) != (1, 2, RATE, "NONE"):
            raise ValueError("server WAV format must be mono PCM16 at 24000 Hz")
        pcm = wav.readframes(wav.getnframes())
        if not pcm or len(pcm) != wav.getnframes() * 2:
            raise ValueError("empty or truncated WAV")
        return pcm


def receive(endpoint, payload, target, token="", timeout=300):
    """A bounded queue provides backpressure; explicit done detects truncated HTTP."""
    try:
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        request = urllib.request.Request(endpoint.rstrip("/") + "/v1/speech/stream",
                                         data=json.dumps(payload).encode(), headers=headers)
        expected = 0
        started = False
        with urllib.request.urlopen(request, timeout=timeout) as response:
            for line in response:
                event = json.loads(line)
                kind = event.get("type")
                if kind == "start":
                    if started or event.get("protocol") != 1:
                        raise ValueError("unsupported speech protocol")
                    started = True
                elif kind == "audio":
                    if not started or event.get("index") != expected:
                        raise ValueError("out-of-order audio chunk")
                    target.put(decode_audio(event))
                    expected += 1
                elif kind == "done":
                    if not started or not expected:
                        raise ValueError("empty speech stream")
                    target.put(None)
                    return
                elif kind == "error":
                    raise RuntimeError(event.get("message", "synthesis failed"))
                else:
                    raise ValueError("unknown speech event")
        raise RuntimeError("speech stream disconnected before done")
    except Exception as exc:
        if isinstance(exc, urllib.error.HTTPError):
            exc.close()
        target.put(exc)


def play(endpoint, payload, prebuffer=8, player="ffplay"):
    chunks = queue.Queue(maxsize=8)
    threading.Thread(target=receive, args=(endpoint, payload, chunks,
                     os.getenv("READER_SPEECH_TOKEN", "")), daemon=True).start()
    buffered = []
    size = 0
    done = False
    while size < prebuffer * RATE * 2:
        item = chunks.get()
        if isinstance(item, Exception):
            raise item
        if item is None:
            done = True
            break
        buffered.append(item)
        size += len(item)
    process = subprocess.Popen([player, "-nodisp", "-autoexit", "-loglevel", "error",
                                "-f", "s16le", "-ar", str(RATE), "-ch_layout", "mono", "-i", "pipe:0"],
                               stdin=subprocess.PIPE, stdout=subprocess.DEVNULL)
    previous = {}

    def cancel(_signum, _frame):
        raise KeyboardInterrupt

    try:
        for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            previous[signum] = signal.signal(signum, cancel)
        print(json.dumps({"type": "playing", "buffered_seconds": size / (RATE * 2)}), flush=True)
        for pcm in buffered:
            process.stdin.write(pcm)
        while not done:
            item = chunks.get()
            if isinstance(item, Exception):
                raise item
            if item is None:
                break
            process.stdin.write(item)
        process.stdin.close()
        if process.wait() != 0:
            raise RuntimeError("audio player failed")
        print('{"type":"done"}', flush=True)
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        if not process.stdin.closed:
            try:
                process.stdin.close()
            except BrokenPipeError:
                pass
        for signum, handler in previous.items():
            signal.signal(signum, handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", default="http://127.0.0.1:8765")
    parser.add_argument("--prebuffer", type=float, default=8)
    parser.add_argument("--player", default="ffplay")
    args = parser.parse_args()
    if not 0 < args.prebuffer <= 120:
        parser.error("prebuffer must be >0 and <=120 seconds")
    try:
        play(args.endpoint, json.load(sys.stdin), args.prebuffer, args.player)
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
