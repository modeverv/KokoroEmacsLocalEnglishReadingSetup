"""Cross-platform playback server: HTTP WAV input, WebSocket control/events."""
from __future__ import annotations

import argparse
import asyncio
import contextlib
import io
import os
import secrets
import wave

from aiohttp import web
from speech_http.playback_queue import PlaybackQueue, RATE


def decode_wav(data):
    with wave.open(io.BytesIO(data)) as wav:
        if (wav.getframerate(), wav.getnchannels(), wav.getsampwidth(), wav.getcomptype()) != (RATE, 1, 2, "NONE"):
            raise ValueError("WAV must be mono PCM16 at 24000 Hz")
        pcm = wav.readframes(wav.getnframes())
        if not pcm or len(pcm) != wav.getnframes() * 2:
            raise ValueError("empty or truncated WAV")
        return pcm


class AudioDevice:
    def __init__(self, queue, device=None):
        import sounddevice as sd
        self.queue = queue
        self.failure = None

        def callback(output, frames, timing, status):
            try:
                output[:] = queue.render(frames, timing.outputBufferDacTime)
                if status.output_underflow:
                    self.failure = "audio device underflow; playback timing is no longer reliable"
            except Exception:
                output[:] = bytes(frames * 2)
                self.failure = "audio callback failed"

        self.stream = sd.RawOutputStream(samplerate=RATE, channels=1, dtype="int16",
                                         blocksize=480, latency="high", device=device, callback=callback)
        self.stream.start()

    def time(self):
        if self.failure:
            raise RuntimeError(self.failure)
        if not self.stream.active:
            raise RuntimeError("audio device stopped")
        return self.stream.time

    def stop(self):
        self.stream.abort()
        self.queue.stop()
        self.failure = None
        self.stream.start()

    def close(self):
        self.stream.abort()
        self.stream.close()


class PlaybackService:
    def __init__(self, token="", device_factory=AudioDevice, prebuffer=1.0):
        self.token = token
        self.device_factory = device_factory
        self.prebuffer = prebuffer
        self.session = None

    async def control(self, request):
        if self.token and request.headers.get("Authorization") != "Bearer " + self.token:
            raise web.HTTPUnauthorized()
        if self.session is not None:
            raise web.HTTPConflict(text="playback device already controlled by another session")
        ws = web.WebSocketResponse(heartbeat=10, max_msg_size=8192)
        queue = PlaybackQueue(self.prebuffer)
        session = dict(id=secrets.token_hex(16), token=secrets.token_hex(32), queue=queue, ws=ws)
        self.session = session
        device = pump = None
        try:
            await ws.prepare(request)
            device = self.device_factory(queue)
            await ws.send_json(dict(event="ready", protocol=1, session=session["id"],
                                    delivery_token=session["token"]))

            async def events():
                try:
                    while not ws.closed:
                        for stamp, event, id in queue.due_events(device.time()):
                            await ws.send_json(dict(event=event, id=id, device_time=stamp))
                        await asyncio.sleep(.005)
                except Exception:
                    await ws.send_json(dict(event="error", message="audio device failed"))
                    await ws.close()

            pump = asyncio.create_task(events())
            async for message in ws:
                if message.type != web.WSMsgType.TEXT:
                    break
                try:
                    data = message.json()
                    command = data["command"]
                    if command == "reserve":
                        queue.reserve(data["id"], data.get("volume", 1.0))
                        await ws.send_json(dict(event="queued", id=data["id"]))
                    elif command == "stop":
                        device.stop()
                        await ws.send_json(dict(event="stopped"))
                    elif command == "hold":
                        queue.held = True
                    elif command == "play":
                        queue.play(data.get("warmup", 1))
                    elif command == "discard":
                        # Discard is used for a failed slot. Stop the entire
                        # device so already submitted samples cannot leak out.
                        device.stop()
                        await ws.send_json(dict(event="error", message="utterance discarded"))
                    else:
                        raise ValueError("unsupported playback command")
                except (KeyError, TypeError, ValueError) as exc:
                    device.stop()
                    await ws.send_json(dict(event="error", message=str(exc)))
        except Exception:
            if not ws.closed:
                await ws.send_json(dict(event="error", message="cannot open playback device"))
        finally:
            if pump:
                pump.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await pump
            if device:
                device.close()
            queue.stop()
            if self.session is session:
                self.session = None
            await ws.close()
        return ws

    async def upload(self, request):
        session = self.session
        if (session is None or request.match_info["session"] != session["id"] or
                not secrets.compare_digest(request.headers.get("Authorization", ""),
                                           "Bearer " + session["token"])):
            raise web.HTTPUnauthorized()
        try:
            id = int(request.match_info["id"])
            kind = request.match_info["part"]
            if kind == "check":
                session["queue"].find(id)
            elif kind == "done":
                data = await request.json()
                if self.session is not session:
                    raise ValueError("session closed")
                session["queue"].complete(id, data["count"])
                await session["ws"].send_json(dict(event="loaded", id=id))
            else:
                pcm = decode_wav(await request.read())
                if self.session is not session:
                    raise ValueError("session closed")
                session["queue"].append(id, int(kind), pcm)
        except (ValueError, KeyError, TypeError, wave.Error, EOFError) as exc:
            raise web.HTTPConflict(text=str(exc)) from exc
        return web.json_response({"ok": True})

    def app(self):
        app = web.Application(client_max_size=16 * 1024 * 1024)
        async def health(_request):
            return web.json_response({"ok": True, "service": "reader-playback", "protocol": 1})

        app.router.add_get("/health", health)
        app.router.add_get("/v1/control", self.control)
        app.router.add_post("/v1/sessions/{session}/audio/{id}/{part}", self.upload)

        async def shutdown(_app):
            if self.session:
                await self.session["ws"].close(code=1001)

        app.on_shutdown.append(shutdown)
        return app


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8768)
    parser.add_argument("--device", help="output device name (see --list-devices)")
    parser.add_argument("--list-devices", action="store_true")
    parser.add_argument("--prebuffer", type=float, default=1.0)
    args = parser.parse_args()
    if args.list_devices:
        import sounddevice as sd
        print(sd.query_devices())
        return
    if not 0 <= args.prebuffer <= 30:
        parser.error("prebuffer must be between 0 and 30 seconds")
    service = PlaybackService(os.getenv("READER_PLAYBACK_TOKEN", ""),
                              lambda queue: AudioDevice(queue, args.device), args.prebuffer)
    web.run_app(service.app(), host=args.host, port=args.port, access_log=None)


if __name__ == "__main__":
    main()
