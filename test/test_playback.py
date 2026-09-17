import asyncio
import io
import json
import threading
import time
import unittest
import wave

import aiohttp
from aiohttp.test_utils import TestServer

from speech_http.client import deliver
from speech_http.delivery import targets_from_json, validate_delivery
from speech_http.playback import PlaybackService, decode_wav
from speech_http.playback_queue import PlaybackQueue, RATE
from speech_http.server import SpeechServer


def wav(pcm=b"\x01\x00" * 2400):
    output = io.BytesIO()
    with wave.open(output, "wb") as writer:
        writer.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
        writer.writeframes(pcm)
    return output.getvalue()


class QueueTests(unittest.TestCase):
    def test_gapless_boundary_and_device_clock_completion(self):
        queue = PlaybackQueue(0)
        for id, pcm in ((1, b"\x01\x00" * 4), (2, b"\x02\x00" * 4)):
            queue.reserve(id)
            queue.append(id, 0, pcm)
            queue.complete(id, 1)
        self.assertEqual(queue.render(8, 10), b"\x01\x00" * 4 + b"\x02\x00" * 4)
        self.assertEqual(queue.due_events(9.99), [])
        self.assertEqual(queue.due_events(10), [(10, "started", 1)])
        self.assertEqual(queue.due_events(10 + 4 / RATE),
                         [(10 + 4 / RATE, "finished", 1), (10 + 4 / RATE, "started", 2)])
        self.assertEqual(queue.due_events(11), [(10 + 8 / RATE, "finished", 2)])

    def test_cancel_invalidates_audio_and_scheduled_finish(self):
        queue = PlaybackQueue(0)
        queue.reserve(1)
        queue.append(1, 0, b"\x01\x00" * 4)
        queue.complete(1, 1)
        queue.render(8, 10)
        queue.stop()
        self.assertEqual(queue.due_events(20), [])
        with self.assertRaises(ValueError):
            queue.append(1, 1, b"\x01\x00")
        with self.assertRaises(ValueError):
            queue.reserve(1)
        queue.reserve(2)

    def test_partial_delivery_does_not_finish_and_order_is_enforced(self):
        queue = PlaybackQueue(0)
        queue.reserve(1)
        queue.append(1, 0, b"\x01\x00" * 4)
        queue.render(8, 10)
        self.assertEqual([e[1] for e in queue.due_events(20)], ["started"])
        with self.assertRaises(ValueError):
            queue.append(1, 0, b"\x01\x00")
        with self.assertRaises(ValueError):
            queue.complete(1, 2)
        queue.complete(1, 1)
        queue.render(8, 20)
        self.assertEqual(queue.due_events(20), [(10 + 4 / RATE, "finished", 1)])

    def test_hold_prebuffer_and_short_final_utterance(self):
        queue = PlaybackQueue(1)
        queue.held = True
        queue.reserve(1)
        queue.append(1, 0, b"\x01\x00" * 4)
        self.assertEqual(queue.render(4, 0), bytes(8))
        queue.play(2)
        self.assertEqual(queue.render(4, 0), bytes(8))
        queue.complete(1, 1)
        self.assertEqual(queue.render(4, 0), b"\x01\x00" * 4)

    def test_volume_and_wav_validation(self):
        queue = PlaybackQueue(0)
        queue.reserve(1, .5)
        queue.append(1, 0, b"\x04\x00" * 4)
        self.assertEqual(queue.render(4, 0), b"\x02\x00" * 4)
        self.assertEqual(decode_wav(wav()), b"\x01\x00" * 2400)
        with self.assertRaises(ValueError):
            decode_wav(wav()[:-2])

    def test_target_allowlist(self):
        targets = targets_from_json('{"desktop":"http://127.0.0.1:8768"}')
        for data in (None, {"target": []}, {"target": "other"}, {"target": "desktop", "session": "../x"}):
            with self.assertRaises(ValueError):
                validate_delivery(data, targets)
        with self.assertRaises(ValueError):
            targets_from_json('{"desktop":"file:///etc/passwd"}')


class FakeDevice:
    """A deterministic output-clock simulator, never opens speakers in tests."""
    def __init__(self, queue):
        self.queue = queue
        self.task = asyncio.create_task(self.tick())

    async def tick(self):
        while True:
            self.queue.render(480, self.time() + .05)
            await asyncio.sleep(.02)

    def time(self):
        return time.monotonic()

    def stop(self):
        self.queue.stop()

    def close(self):
        self.task.cancel()


class NetworkTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.service = PlaybackService("secret", FakeDevice, prebuffer=0)
        self.player = TestServer(self.service.app())
        await self.player.start_server()
        self.http = aiohttp.ClientSession()
        self.ws = await self.http.ws_connect(self.player.make_url("/v1/control"),
                                             headers={"Authorization": "Bearer secret"})
        self.ready = await self.ws.receive_json(timeout=2)
        self.generator = SpeechServer(("127.0.0.1", 0), synthesizer=lambda *_: wav(),
                                       playback_targets={"desktop": str(self.player.make_url(""))})
        self.thread = threading.Thread(target=self.generator.serve_forever, daemon=True)
        self.thread.start()

    async def asyncTearDown(self):
        await self.ws.close()
        await self.http.close()
        await self.player.close()
        await asyncio.to_thread(self.generator.shutdown)
        self.generator.server_close()
        self.thread.join(2)

    def delivery(self, id=1):
        return dict(target="desktop", session=self.ready["session"],
                    delivery_token=self.ready["delivery_token"], id=id)

    def url(self, part, id=1):
        return self.player.make_url(f'/v1/sessions/{self.ready["session"]}/audio/{id}/{part}')

    async def reserve(self, id=1):
        await self.ws.send_json(dict(command="reserve", id=id))
        self.assertEqual((await self.ws.receive_json(timeout=2))["event"], "queued")

    async def test_three_party_delivery_and_finished_only_after_play(self):
        await self.ws.send_json(dict(command="hold"))
        await self.reserve()
        payload = dict(text="One. Two.", language="en", playback=self.delivery())
        endpoint = f"http://127.0.0.1:{self.generator.server_port}"
        await asyncio.to_thread(deliver, endpoint, payload)
        self.assertEqual((await self.ws.receive_json(timeout=2))["event"], "loaded")
        self.assertEqual(len(self.service.session["queue"].entries), 1)
        await self.ws.send_json(dict(command="play"))
        started = await self.ws.receive_json(timeout=2)
        finished = await self.ws.receive_json(timeout=2)
        self.assertEqual([started["event"], finished["event"]], ["started", "finished"])
        self.assertGreaterEqual(finished["device_time"] - started["device_time"], .19)
        self.assertLessEqual(finished["device_time"], time.monotonic())

    async def test_stop_rejects_late_upload_and_frees_session(self):
        await self.reserve()
        await self.ws.send_json(dict(command="stop"))
        self.assertEqual((await self.ws.receive_json(timeout=2))["event"], "stopped")
        headers = {"Authorization": "Bearer " + self.ready["delivery_token"]}
        async with self.http.post(self.url("0"), data=wav(), headers=headers) as response:
            self.assertEqual(response.status, 409)
        await self.ws.close()
        await asyncio.sleep(.05)
        async with self.http.post(self.url("0"), data=wav(), headers=headers) as response:
            self.assertEqual(response.status, 401)

    async def test_auth_and_exclusive_control(self):
        for headers, code in (({}, 401), ({"Authorization": "Bearer secret"}, 409)):
            with self.assertRaises(aiohttp.WSServerHandshakeError) as caught:
                await self.http.ws_connect(self.player.make_url("/v1/control"), headers=headers)
            self.assertEqual(caught.exception.status, code)
        await self.reserve()
        async with self.http.post(self.url("0"), data=wav()) as response:
            self.assertEqual(response.status, 401)


if __name__ == "__main__":
    unittest.main()
