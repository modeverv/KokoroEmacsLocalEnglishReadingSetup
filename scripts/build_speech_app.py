"""Build the native AppKit controller with the installed Apple compiler."""
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "speech-http-app/build/Reader Speech Server.app"


def build():
    contents = APP / "Contents"
    binary = contents / "MacOS/ReaderSpeechServer"
    binary.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["/usr/bin/clang", "-fobjc-arc", "-O2", "-Wall", "-Wextra",
                    "-Wno-unused-parameter", "-framework", "Cocoa",
                    str(ROOT / "speech-http-app/main.m"), "-o", str(binary)], check=True)
    with (contents / "Info.plist").open("wb") as stream:
        plistlib.dump({"CFBundleExecutable": "ReaderSpeechServer",
                      "CFBundleIdentifier": "local.reader.speech.gui",
                      "CFBundleName": "Reader Speech Server", "CFBundlePackageType": "APPL",
                      "CFBundleVersion": "1", "NSHighResolutionCapable": True,
                      "ReaderSpeechRoot": str(ROOT)}, stream)
    print(APP)


if __name__ == "__main__":
    build()
