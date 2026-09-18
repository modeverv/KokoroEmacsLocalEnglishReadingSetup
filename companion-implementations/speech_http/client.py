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
import time
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


def open_speech_request(request, timeout=300, busy_timeout=30):
    """Retry only rejected requests, never an accepted/partly delivered stream."""
    deadline = time.monotonic() + busy_timeout
    delay = .2
    while True:
        try:
            return urllib.request.urlopen(request, timeout=timeout)
        except urllib.error.HTTPError as exc:
            try:
                detail = json.loads(exc.read(4096)).get("error")
                if isinstance(detail, str):
                    exc.msg = detail
            except (ValueError, OSError, AttributeError):
                pass
            finally:
                exc.close()
            remaining = deadline - time.monotonic()
            if exc.code != 503 or remaining <= 0:
                raise
            time.sleep(min(delay, remaining))
            delay = min(delay * 2, 2)


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
        with open_speech_request(request, timeout=timeout) as response:
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


def download(endpoint, payload, output):
    """Collect ordered PCM into a WAV for a resident player's reserved slot.

The caller must only load the file after this process exits successfully.
"""
    chunks = queue.Queue(maxsize=8)
    threading.Thread(target=receive, args=(endpoint, payload, chunks,
                     os.getenv("READER_SPEECH_TOKEN", "")), daemon=True).start()
    try:
        with wave.open(output, "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(RATE)
            while True:
                item = chunks.get()
                if isinstance(item, Exception):
                    raise item
                if item is None:
                    break
                wav.writeframesraw(item)
    except BaseException:
        if os.path.exists(output):
            os.unlink(output)
        raise


def deliver(endpoint, payload):
    """Wait for delivery acknowledgement, never report it as playback finish."""
    headers = {"Content-Type": "application/json"}
    if token := os.getenv("READER_SPEECH_TOKEN", ""):
        headers["Authorization"] = "Bearer " + token
    request = urllib.request.Request(endpoint.rstrip("/") + "/v1/speech/deliver",
                                     data=json.dumps(payload).encode(), headers=headers)
    count, started = 0, False
    with open_speech_request(request) as response:
        for line in response:
            event = json.loads(line)
            if event.get("type") == "start" and not started and event.get("protocol") == 1:
                started = True
            elif event.get("type") == "delivered" and started and event.get("index") == count:
                count += 1
            elif event.get("type") == "done" and started and count:
                return
            elif event.get("type") == "error":
                raise RuntimeError(event.get("message", "delivery failed"))
            else:
                raise RuntimeError("invalid delivery response")
    raise RuntimeError("generation connection closed before delivery completed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", default="http://127.0.0.1:8765")
    parser.add_argument("--prebuffer", type=float, default=8)
    parser.add_argument("--player", default="ffplay")
    parser.add_argument("--output", help="Save received chunks as one WAV instead of playing")
    parser.add_argument("--deliver", action="store_true", help="Send audio directly to the playback server")
    parser.add_argument("--auto-start", action="store_true", help="Start the local service when unavailable")
    parser.add_argument("--listen-host", default="0.0.0.0")
    args = parser.parse_args()
    if not 0 < args.prebuffer <= 120:
        parser.error("prebuffer must be >0 and <=120 seconds")
    try:
        payload = json.load(sys.stdin)
        if args.auto_start:
            from speech_http.service import ensure
            ensure(args.endpoint, args.listen_host)
        if args.deliver:
            deliver(args.endpoint, payload)
        elif args.output:
            download(args.endpoint, payload, args.output)
        else:
            play(args.endpoint, payload, args.prebuffer, args.player)
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
