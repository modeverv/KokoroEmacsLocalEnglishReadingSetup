"""On-demand macOS playback service shared by the CLI and GUI.

Registered with the current login session; not a login item. Closing a control
application does not stop playback. Stop explicitly or log out to end it.
"""
import argparse
import json
import math
import os
from pathlib import Path
import plistlib
import socket
import sys
import time
import urllib.request

from .service import control_lock, launchctl

ROOT = Path(__file__).resolve().parent.parent


def paths(port):
    directory = Path.home() / "Library/Caches/ReaderPlaybackServer" / str(port)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    label = f"local.reader.playback.{port}"
    return directory, label, f"gui/{os.getuid()}/{label}"


def health(port):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=.5) as response:
            data = json.load(response)
        return data if data.get("ok") and data.get("service") == "reader-playback" else None
    except (OSError, ValueError):
        return None


def status(port=8768):
    directory, _, target = paths(port)
    registered = launchctl("print", target, check=False).returncode == 0
    result = dict(health(port) or {"ok": False}, managed=registered,
                  port=port, log=str(directory / "server.log"))
    if registered:
        try:
            with (directory / "server.plist").open("rb") as stream:
                config = plistlib.load(stream)
            args = config["ProgramArguments"]
            for option in ("host", "device", "prebuffer"):
                if "--" + option in args:
                    result[option] = args[args.index("--" + option) + 1]
        except (OSError, ValueError, KeyError):
            pass
    return result


def command(host, port, device, prebuffer):
    # Bundled Python needs the isolated bootstrap to locate bundled modules.
    bootstrap = ROOT / "bootstrap.py"
    prefix = ([sys.executable, "-I", "-B", str(bootstrap)] if bootstrap.is_file()
              else [sys.executable, "-m", "speech_http.playback"])
    return prefix + ["--host", host, "--port", str(port), "--prebuffer", str(prebuffer)] + (
        ["--device", device] if device else [])


def start(port=8768, host="127.0.0.1", device=None, prebuffer=1.0, timeout=15):
    if not 1 <= port <= 65535 or not math.isfinite(prebuffer) or not 0 <= prebuffer <= 30:
        raise ValueError("Port must be 1..65535; prebuffer must be 0..30 seconds")
    if host not in ("127.0.0.1", "0.0.0.0"):
        raise ValueError("Choose 127.0.0.1 or 0.0.0.0")
    directory, label, target = paths(port)
    with control_lock(directory):
        state = status(port)
        if state["ok"]:
            return state
        launchctl("bootout", target, check=False)
        # Do not create a second listener beside a foreground or unrelated app.
        try:
            connection = socket.create_connection(("127.0.0.1", port), timeout=.5)
        except OSError:
            pass
        else:
            connection.close()
            raise RuntimeError(f"Port {port} is already occupied; stop its owner first")
        config = {"Label": label, "ProgramArguments": command(host, port, device, prebuffer),
                  "WorkingDirectory": str(ROOT), "RunAtLoad": True, "KeepAlive": False,
                  "EnvironmentVariables": {"READER_PLAYBACK_TOKEN": os.getenv("READER_PLAYBACK_TOKEN", "")},
                  "StandardOutPath": str(directory / "server.log"),
                  "StandardErrorPath": str(directory / "server.log")}
        plist = directory / "server.plist"
        fd = os.open(plist, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as stream:
            os.fchmod(stream.fileno(), 0o600)
            plistlib.dump(config, stream)
        try:
            launchctl("bootstrap", f"gui/{os.getuid()}", str(plist))
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if health(port):
                    return status(port)
                time.sleep(.1)
            raise RuntimeError(f"Playback service did not start; inspect {directory / 'server.log'}")
        except Exception:
            launchctl("bootout", target, check=False)
            plist.unlink(missing_ok=True)
            raise


def stop(port=8768):
    directory, _, target = paths(port)
    with control_lock(directory):
        state = status(port)
        if not state["managed"]:
            if state["ok"]:
                raise RuntimeError("This server runs separately; stop it in its own terminal or old GUI")
        else:
            launchctl("bootout", target)
        (directory / "server.plist").unlink(missing_ok=True)
        # bootout can return before launchd has removed the job. Hold the lock
        # until removal so an immediate start cannot race the old listener.
        deadline = time.monotonic() + 5
        while True:
            result = status(port)
            if not result.get("managed"):
                return result
            if time.monotonic() >= deadline:
                raise RuntimeError("Playback service is still stopping; check status before restarting")
            time.sleep(.1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("start", "stop", "status"))
    parser.add_argument("--port", type=int, default=8768)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--device")
    parser.add_argument("--prebuffer", type=float, default=1.0)
    args = parser.parse_args()
    try:
        if not 1 <= args.port <= 65535:
            raise ValueError("Port must be 1..65535")
        result = (start(args.port, args.host, args.device, args.prebuffer) if args.action == "start"
                  else stop(args.port) if args.action == "stop" else status(args.port))
        print(json.dumps(result))
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
