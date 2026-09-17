#!/usr/bin/env python3
"""Install the locked MLX runtime and cache Irodori model/codec weights."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
subprocess.run(["uv", "sync", "--locked", "--inexact"], cwd=root, check=True)
subprocess.run([str(root / ".venv/bin/python"), "-c",
                "from irodori_backend import ensure_model; ensure_model()"], cwd=root, check=True)
print("Irodori MLX is ready. Reference audio: assets/asuka.wav")
