"""Translate Emacs's newline JSON commands/events to a playback WebSocket."""
import argparse
import asyncio
import json
import os
import sys
import threading

import aiohttp


async def run(endpoint):
    commands = asyncio.Queue(maxsize=64)
    loop = asyncio.get_running_loop()

    def stdin():
        try:
            for line in sys.stdin:
                asyncio.run_coroutine_threadsafe(commands.put(line), loop).result()
        finally:
            if not loop.is_closed():
                asyncio.run_coroutine_threadsafe(commands.put(None), loop)

    threading.Thread(target=stdin, daemon=True).start()
    headers = {}
    if token := os.getenv("READER_PLAYBACK_TOKEN", ""):
        headers["Authorization"] = "Bearer " + token
    async with aiohttp.ClientSession(headers=headers) as session:
        async with session.ws_connect(endpoint.rstrip("/") + "/v1/control", heartbeat=10) as ws:
            async def send():
                while (line := await commands.get()) is not None:
                    await ws.send_json(json.loads(line))
                await ws.close()

            task = asyncio.create_task(send())
            try:
                async for message in ws:
                    if message.type == aiohttp.WSMsgType.TEXT:
                        # Only metadata travels to Emacs; no WAV on this link.
                        print(message.data, flush=True)
                if not task.done():
                    raise RuntimeError("playback connection closed")
                await task
            finally:
                task.cancel()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", required=True)
    args = parser.parse_args()
    try:
        asyncio.run(run(args.endpoint))
    except aiohttp.WSServerHandshakeError as exc:
        reason = {
            409: "playback server is controlled by another Emacs; disconnect its playback session first",
            401: "authentication failed; check READER_PLAYBACK_TOKEN against the playback app",
            404: "wrong endpoint; use the playback server port (normally 8768), not the synthesis server",
        }.get(exc.status, "check the playback server endpoint and logs")
        print(f"Playback connection failed: HTTP {exc.status}: {reason}", file=sys.stderr)
        sys.exit(1)
    except Exception as exc:
        print(f"Playback connection failed: {type(exc).__name__}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
