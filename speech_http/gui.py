"""Local browser GUI supervising an independent speech-server subprocess."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import secrets
import signal
import subprocess
import sys
import threading
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Controller:
    def __init__(self, host, port):
        self.host, self.port = host, port
        self.process = None
        self.lock = threading.RLock()
        self.csrf = secrets.token_urlsafe(32)

    def status(self):
        with self.lock:
            running = self.process is not None and self.process.poll() is None
            ready = False
            if running:
                try:
                    with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/health", timeout=.4) as response:
                        health = json.load(response)
                        ready = health.get("ok", False) and health.get("pid") == self.process.pid
                except (OSError, ValueError):
                    pass
            return {"running": running, "ready": ready, "host": self.host, "port": self.port}

    def start(self):
        with self.lock:
            if self.process is None or self.process.poll() is not None:
                self.process = subprocess.Popen([sys.executable, "-m", "speech_http.server",
                                                 "--host", self.host, "--port", str(self.port)],
                                                cwd=Path(__file__).resolve().parent.parent,
                                                start_new_session=True)

    def stop(self):
        with self.lock:
            if self.process is not None and self.process.poll() is None:
                os.killpg(self.process.pid, signal.SIGTERM)
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(self.process.pid, signal.SIGKILL)
                    self.process.wait()
            self.process = None


PAGE = """<!doctype html><html lang="ja"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Reader Speech Server</title>
<style>body{font:18px system-ui;max-width:620px;margin:80px auto;padding:24px;background:#f5f6fa;color:#202536}
main{background:white;padding:36px;border-radius:20px}button{font:inherit;padding:14px 24px;margin:8px;border:0;border-radius:10px;cursor:pointer}
#start{background:#245c48;color:white}#status{padding:18px 0}code{font-size:15px}</style>
<main><h1>Reader Speech Server</h1><p>英語・日本語の音声をHTTPで配信します。</p>
<div id="status" role="status">確認中…</div><button id="start" onclick="act('start')">サーバースタート</button>
<button id="stop" onclick="act('stop')">停止</button><p id="address"></p>
<p>ブラウザーを閉じても動作します。終了するときは停止ボタンを押してください。</p></main>
<script>
async function refresh(){try{let s=await (await fetch('/status')).json();
document.querySelector('#status').textContent=s.ready?'● 稼働中':s.running?'起動中…':'○ 停止中';
document.querySelector('#start').disabled=s.running;document.querySelector('#stop').disabled=!s.running;
document.querySelector('#address').textContent='接続先: http://'+s.host+':'+s.port;
}catch(e){document.querySelector('#status').textContent='管理GUIへの接続が切れました';}}
async function act(action){await fetch('/'+action,{method:'POST',headers:{'X-Control-Token':'TOKEN'}});await refresh();}
refresh();setInterval(refresh,1500);</script></html>"""


def make_handler(controller):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def reply(self, code, body, content_type="application/json"):
            self.send_response(code)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/":
                self.reply(200, PAGE.replace("TOKEN", controller.csrf).encode(), "text/html; charset=utf-8")
            elif self.path == "/status":
                self.reply(200, json.dumps(controller.status()).encode())
            else:
                self.reply(404, b'{}')

        def do_POST(self):
            if self.headers.get("X-Control-Token") != controller.csrf:
                return self.reply(403, b'{}')
            if self.path == "/start":
                controller.start()
            elif self.path == "/stop":
                controller.stop()
            else:
                return self.reply(404, b'{}')
            self.reply(200, json.dumps(controller.status()).encode())
    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1", choices=("127.0.0.1", "0.0.0.0"))
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--gui-port", type=int, default=8766)
    parser.add_argument("--no-browser", action="store_true")
    args = parser.parse_args()
    controller = Controller(args.host, args.port)
    def stop_gui(_signum, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, stop_gui)
    signal.signal(signal.SIGHUP, stop_gui)
    try:
        with ThreadingHTTPServer(("127.0.0.1", args.gui_port), make_handler(controller)) as server:
            address = f"http://127.0.0.1:{args.gui_port}"
            print(f"Speech GUI: {address}", flush=True)
            if not args.no_browser:
                webbrowser.open(address)
            server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        controller.stop()


if __name__ == "__main__":
    main()
