"""Loopback-only FastAPI pronunciation editor, owned by the speech server."""
from contextlib import contextmanager
from pathlib import Path
import socket
import threading

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, Response
from pydantic import BaseModel, Field
from starlette.middleware.trustedhost import TrustedHostMiddleware

from speech_http.pronunciation import DictionaryStore, prepare_entry, validate_entry, spoken_reading


class EntryInput(BaseModel):
    word: str = Field(min_length=1, max_length=100)
    reading: str = Field(min_length=1, max_length=100)


def create_app(store=None, verifier=None, renderer=None):
    store = store or DictionaryStore()
    app = FastAPI(title="Reader 読み辞書", docs_url=None, redoc_url=None)
    app.add_middleware(TrustedHostMiddleware, allowed_hosts=["127.0.0.1", "localhost"])
    slot = threading.Lock()
    app.state.worker = None

    def worker():
        from speech_http.native import NativeWorker
        current = app.state.worker
        if current is None or current.process.poll() is not None:
            app.state.worker = NativeWorker(dictionary=store.path)
        return app.state.worker

    @app.middleware("http")
    async def local_editor(request: Request, call_next):
        if request.method != "GET":
            # Same-origin JSON + a custom header blocks cross-site form writes.
            origin = request.headers.get("origin")
            if (origin and origin != str(request.base_url).rstrip("/")) or request.headers.get("x-reader-dictionary") != "1":
                return Response("同じ画面から操作してください。", status_code=403)
        response = await call_next(request)
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Content-Security-Policy"] = "default-src 'self'; script-src 'self'; style-src 'self'; media-src 'self' blob:; frame-ancestors 'none'"
        return response

    @app.get("/", response_class=HTMLResponse)
    def index():
        return (Path(__file__).parent / "dictionary.html").read_text(encoding="utf-8")

    @app.get("/dictionary.js")
    def javascript():
        return Response((Path(__file__).parent / "dictionary.js").read_text(), media_type="text/javascript")

    @app.get("/dictionary.css")
    def css():
        return Response((Path(__file__).parent / "dictionary.css").read_text(), media_type="text/css")

    @app.get("/api/entries")
    def entries():
        try:
            return store.read()
        except (OSError, ValueError) as exc:
            raise HTTPException(500, str(exc)) from exc

    @app.post("/api/entries")
    def register(data: EntryInput):
        try:
            word, reading = validate_entry(data.word, data.reading)
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from exc
        if not slot.acquire(blocking=False):
            raise HTTPException(503, "読みを確認中です。少し待ってからお試しください。")
        try:
            entry = verifier(word, reading) if verifier else prepare_entry(word, reading, worker())
            store.save(entry=entry)
            return entry
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from exc
        except Exception as exc:
            raise HTTPException(503, "音声生成または辞書保存に失敗しました。登録されていません。") from exc
        finally:
            slot.release()

    @app.post("/api/preview")
    def preview(data: EntryInput):
        try:
            _, reading = validate_entry(data.word, data.reading)
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from exc
        if not slot.acquire(blocking=False):
            raise HTTPException(503, "読みを確認中です。少し待ってからお試しください。")
        try:
            spoken = spoken_reading(reading)
            raw = renderer(spoken) if renderer else worker().render(spoken, dictionary=False)
            return Response(raw, media_type="audio/wav")
        except Exception as exc:
            raise HTTPException(503, "試聴音声を生成できませんでした。") from exc
        finally:
            slot.release()

    @app.delete("/api/entries")
    def remove(word: str):
        try:
            return store.save(delete=word)
        except (OSError, ValueError) as exc:
            raise HTTPException(500, "辞書を保存できませんでした。") from exc

    return app


@contextmanager
def running_ui(port):
    """Bind synchronously so an occupied UI port never masquerades as ready."""
    import uvicorn
    app = create_app()
    sock = socket.socket()
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(("127.0.0.1", port))
        sock.listen(32)
        server = uvicorn.Server(uvicorn.Config(app, log_level="warning", access_log=False))
        thread = threading.Thread(target=server.run, kwargs={"sockets": [sock]}, daemon=True)
        thread.start()
        try:
            yield
        finally:
            server.should_exit = True
            thread.join(timeout=5)
            if app.state.worker is not None:
                app.state.worker.close()
    finally:
        sock.close()


def main():
    import webbrowser
    from speech_http.service import ensure
    result = ensure()
    url = result.get("dictionary_url")
    if not url:
        raise SystemExit("音声サーバーを再起動してから、もう一度開いてください。")
    webbrowser.open(url)


if __name__ == "__main__":
    main()
