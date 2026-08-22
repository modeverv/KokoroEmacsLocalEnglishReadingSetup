#!/usr/bin/env python3
"""Local Kokoro TTS API server for Emacs/macOS.

The model is loaded once in a dedicated worker thread. All MLX/Kokoro inference
also runs on that same thread, which avoids concurrent access and keeps request
latency low after startup.
"""

from __future__ import annotations

import argparse
import asyncio
import importlib.util
import io
import os
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from typing import Literal

import numpy as np
import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel, Field

from mlx_audio.audio_io import write as audio_write
from mlx_audio.tts.utils import load_model


MODEL_ID = os.environ.get(
    "KOKORO_MODEL",
    "mlx-community/Kokoro-82M-bf16",
)
DEFAULT_VOICE = os.environ.get("KOKORO_VOICE", "bf_emma")
DEFAULT_LANG_CODE = os.environ.get("KOKORO_LANG_CODE", "b")

# Kokoro/MLX work is serialized on one persistent worker thread.
_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="kokoro-mlx")
_model = None


class SpeechRequest(BaseModel):
    """OpenAI-style subset used by this local Kokoro server."""

    model: str = MODEL_ID
    input: str = Field(min_length=1, max_length=12_000)
    voice: str = DEFAULT_VOICE
    speed: float = Field(default=1.0, ge=0.5, le=2.0)
    lang_code: str = DEFAULT_LANG_CODE
    response_format: Literal["wav"] = "wav"
    stream: bool = False


def _ensure_model():
    """Load and cache the model inside the dedicated MLX worker thread."""
    global _model
    if _model is None:
        print(f"[kokoro] loading model: {MODEL_ID}", flush=True)
        _model = load_model(MODEL_ID)
        print("[kokoro] model loaded", flush=True)
    return _model


def _ensure_japanese_pipeline(model) -> None:
    """Create Kokoro's Japanese pipeline with pyopenjtalk.

    Misaki defaults to its Cutlet backend, which needs a separately downloaded
    full UniDic dataset even after package installation.  pyopenjtalk ships its
    own compact dictionary and is already supported by Misaki's Japanese G2P,
    so select it while the cached pipeline is constructed.
    """
    if "j" in model._pipelines:
        return

    if importlib.util.find_spec("pyopenjtalk") is None:
        raise RuntimeError(
            "Japanese Kokoro support is not installed; run "
            "`uv sync --extra japanese` after installing working C++ build tools"
        )

    from misaki import ja

    original_jag2p = ja.JAG2P

    def pyopenjtalk_jag2p(*_args, **kwargs):
        kwargs["version"] = "pyopenjtalk"
        return original_jag2p(**kwargs)

    ja.JAG2P = pyopenjtalk_jag2p
    try:
        model._get_pipeline("j")
    finally:
        ja.JAG2P = original_jag2p


def _synthesize_wav(
    text: str,
    voice: str,
    speed: float,
    lang_code: str,
) -> bytes:
    """Generate one complete WAV response. Runs only in the MLX worker."""
    model = _ensure_model()

    if lang_code.lower() in {"j", "ja"}:
        _ensure_japanese_pipeline(model)

    chunks: list[np.ndarray] = []
    sample_rate: int | None = None

    for result in model.generate(
        text=text,
        voice=voice,
        speed=speed,
        lang_code=lang_code,
    ):
        audio = np.asarray(result.audio, dtype=np.float32).reshape(-1)
        if audio.size:
            chunks.append(audio)
        if sample_rate is None:
            sample_rate = int(result.sample_rate)

    if not chunks or sample_rate is None:
        raise RuntimeError("Kokoro generated no audio")

    combined = np.concatenate(chunks)
    wav = io.BytesIO()
    audio_write(wav, combined, sample_rate, format="wav")
    return wav.getvalue()


@asynccontextmanager
async def lifespan(_: FastAPI):
    """Fail during startup rather than on the first Emacs request."""
    loop = asyncio.get_running_loop()
    await loop.run_in_executor(_executor, _ensure_model)
    yield
    _executor.shutdown(wait=False, cancel_futures=True)


app = FastAPI(
    title="Local Kokoro TTS",
    version="1.0.0",
    lifespan=lifespan,
)


@app.get("/health")
async def health() -> dict[str, object]:
    return {
        "ok": _model is not None,
        "model": MODEL_ID,
        "voice": DEFAULT_VOICE,
        "lang_code": DEFAULT_LANG_CODE,
    }


@app.get("/v1/audio/voices")
async def voices() -> dict[str, object]:
    return {
        "model": MODEL_ID,
        "voices": {
            "british_female": ["bf_alice", "bf_emma"],
            "british_male": ["bm_daniel", "bm_george"],
            "american_female": ["af_heart", "af_bella", "af_nova", "af_sky"],
            "american_male": ["am_adam", "am_echo"],
            "japanese_female": ["jf_nezumi"],
            "japanese_male": ["jm_kumo"],
            "mandarin_female": ["zf_xiaoxiao"],
            "mandarin_male": ["zm_yunxi"],
            "spanish": ["ef_dora", "em_alex"],
            "french": ["ff_siwis"],
            "hindi": ["hf_alpha", "hm_omega"],
            "italian": ["if_sara", "im_nicola"],
            "portuguese": ["pf_dora", "pm_alex"],
        },
    }


@app.post("/v1/audio/speech")
async def speech(payload: SpeechRequest) -> Response:
    if payload.model != MODEL_ID:
        raise HTTPException(
            status_code=400,
            detail=f"This server has only {MODEL_ID!r} loaded",
        )

    if payload.stream:
        raise HTTPException(
            status_code=400,
            detail="This server returns complete WAV files; stream=false is required",
        )

    text = " ".join(payload.input.split())
    if not text:
        raise HTTPException(
            status_code=400,
            detail="input is empty after normalization",
        )

    loop = asyncio.get_running_loop()

    try:
        wav = await loop.run_in_executor(
            _executor,
            _synthesize_wav,
            text,
            payload.voice,
            payload.speed,
            payload.lang_code,
        )
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc

    return Response(
        content=wav,
        media_type="audio/wav",
        headers={
            "Content-Disposition": 'inline; filename="speech.wav"',
            "X-Kokoro-Model": MODEL_ID,
            "X-Kokoro-Voice": payload.voice,
        },
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run the local Kokoro TTS API"
    )
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default=8000, type=int)
    parser.add_argument("--log-level", default="info")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    uvicorn.run(
        app,
        host=args.host,
        port=args.port,
        log_level=args.log_level,
        access_log=True,
    )


if __name__ == "__main__":
    main()
