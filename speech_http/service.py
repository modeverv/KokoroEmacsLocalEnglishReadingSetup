"""Shared on-demand macOS service lifecycle for Emacs and the native app.

The launchd job is registered in the current login session, not installed as
a login item. launchd owns the server even after the GUI or Emacs exits.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time
import urllib.request
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent


def health(endpoint, timeout=.5):
    try:
        with urllib.request.urlopen(endpoint.rstrip("/") + "/health", timeout=timeout) as response:
            result = json.load(response)
        return result if result.get("ok") and result.get("service") == "reader-speech" else None
    except (OSError, ValueError):
        return None


def local_port(endpoint):
    parsed = urlsplit(endpoint)
    if parsed.scheme != "http" or parsed.hostname not in ("127.0.0.1", "localhost"):
        raise RuntimeError("Remote server is unavailable; automatic startup is local-only")
    if parsed.path not in ("", "/") or parsed.query or parsed.username:
        raise ValueError("Local endpoint must contain only a host and port")
    return parsed.port or 80


def service_paths(port):
    directory = Path.home() / "Library" / "Caches" / "ReaderSpeechServer" / str(port)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    label = f"local.reader.speech.{port}"
    return directory, label, f"gui/{os.getuid()}/{label}"


def launchctl(*arguments, check=True):
    result = subprocess.run(["/bin/launchctl", *arguments], capture_output=True, text=True, timeout=15)
    if check and result.returncode:
        raise RuntimeError(result.stderr.strip() or "launchctl failed")
    return result


def ensure(endpoint="http://127.0.0.1:8765", host="0.0.0.0", timeout=20):
    if result := health(endpoint):
        return result
    port = local_port(endpoint)
    directory, label, target = service_paths(port)
    with (directory / "control.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if result := health(endpoint):
            return result
        # A stale registered job is replaced only while the speech service is down.
        launchctl("bootout", target, check=False)
        env = {name: value for name, value in os.environ.items()
               if name.startswith(("KOKORO_", "IRODORI_", "HF_", "READER_SPEECH_"))}
        env["PATH"] = str(ROOT / ".venv/bin") + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        config = {"Label": label, "ProgramArguments": [sys.executable, "-m", "speech_http.server",
                  "--host", host, "--port", str(port)], "WorkingDirectory": str(ROOT),
                  "EnvironmentVariables": env, "RunAtLoad": True, "KeepAlive": False,
                  "StandardOutPath": str(directory / "server.log"),
                  "StandardErrorPath": str(directory / "server.log")}
        plist = directory / "server.plist"
        fd = os.open(plist, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as stream:
            plistlib.dump(config, stream)
        launchctl("bootstrap", f"gui/{os.getuid()}", str(plist))
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if result := health(endpoint):
                return result
            time.sleep(.1)
        raise RuntimeError(f"Speech server did not start; inspect {directory / 'server.log'}")


def stop(endpoint="http://127.0.0.1:8765"):
    port = local_port(endpoint)
    directory, _label, target = service_paths(port)
    with (directory / "control.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        registered = launchctl("print", target, check=False).returncode == 0
        if not registered:
            if health(endpoint):
                raise RuntimeError("This server was started separately; stop it in its own terminal")
            return
        launchctl("bootout", target)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("start", "stop", "status"))
    parser.add_argument("--endpoint", default="http://127.0.0.1:8765")
    parser.add_argument("--host", default="0.0.0.0")
    args = parser.parse_args()
    try:
        if args.action == "start":
            result = ensure(args.endpoint, args.host)
        elif args.action == "stop":
            stop(args.endpoint)
            result = {"ok": False}
        else:
            result = health(args.endpoint) or {"ok": False}
        print(json.dumps(result))
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
