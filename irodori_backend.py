"""Local Irodori MLX reference-voice synthesis, called on the shared MLX worker."""
from __future__ import annotations

import io
from pathlib import Path

import numpy as np
from mlx_audio.audio_io import write as audio_write
from mlx_audio.tts.utils import load_model

ROOT = Path(__file__).resolve().parent
MODEL_ID = "mlx-community/Irodori-TTS-500M-v3-8bit"
_model = None


def ensure_model():
    """Load once on the same worker as Kokoro to serialize Metal inference."""
    global _model
    if _model is None:
        print(f"[irodori-mlx] loading model: {MODEL_ID}", flush=True)
        _model = load_model(MODEL_ID)
    return _model


def synthesize(text: str, voice: str, speed: float) -> bytes:
    """Generate locally using asuka.wav; speed is inverse duration scale."""
    if voice != "asuka":
        raise ValueError("The reader Irodori profile currently supports voice 'asuka'")
    reference = ROOT / "assets/asuka.wav"
    if not reference.is_file():
        raise FileNotFoundError("Reference audio is missing: assets/asuka.wav")
    if not 0.5 <= speed <= 2.0:
        raise ValueError("Irodori speed must be between 0.5 and 2.0")
    model = ensure_model()
    chunks = []
    sample_rate = None
    for result in model.generate(
        text=text, ref_audio=str(reference), duration_scale=1.0 / speed,
        num_steps=24, t_schedule_mode="sway", sway_coeff=-1.0,
    ):
        audio = np.asarray(result.audio, dtype=np.float32).reshape(-1)
        if audio.size:
            chunks.append(audio)
        if sample_rate is not None and sample_rate != int(result.sample_rate):
            raise RuntimeError("Irodori changed sample rate within a response")
        sample_rate = int(result.sample_rate)
    if not chunks or not sample_rate:
        raise RuntimeError("Irodori generated no audio")
    wav = io.BytesIO()
    audio_write(wav, np.concatenate(chunks), sample_rate, format="wav")
    return wav.getvalue()
