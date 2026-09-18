"""Build if necessary and open the native macOS application."""
from pathlib import Path
import subprocess
import sys


def main():
    root = Path(__file__).resolve().parent.parent
    app = root / "speech-http-app/build/Reader Speech Server.app"
    binary = app / "Contents/MacOS/ReaderSpeechServer"
    sources = [root / "speech-http-app/main.m", root / "speech-http-app/icon.png",
               root.parent / "scripts/build_speech_app.py"]
    if not binary.exists() or any(path.stat().st_mtime > binary.stat().st_mtime for path in sources):
        subprocess.run([sys.executable, str(root.parent / "scripts/build_speech_app.py")], check=True)
    subprocess.run(["/usr/bin/open", str(app)], check=True)


if __name__ == "__main__":
    main()
