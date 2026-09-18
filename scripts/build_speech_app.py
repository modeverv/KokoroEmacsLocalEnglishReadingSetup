"""Build the native AppKit controller with the installed Apple compiler."""
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent / "companion-implementations"
APP = ROOT / "speech-http-app/build/Reader Speech Server.app"


def build():
    contents = APP / "Contents"
    binary = contents / "MacOS/ReaderSpeechServer"
    binary.parent.mkdir(parents=True, exist_ok=True)
    resources = contents / "Resources"
    resources.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory() as directory:
        iconset = Path(directory) / "SpeechServer.iconset"
        iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                suffix = "@2x" if scale == 2 else ""
                subprocess.run(["/usr/bin/sips", "-z", str(size * scale), str(size * scale),
                                str(ROOT / "speech-http-app/icon.png"), "--out",
                                str(iconset / f"icon_{size}x{size}{suffix}.png")],
                               check=True, stdout=subprocess.DEVNULL)
        subprocess.run(["/usr/bin/iconutil", "-c", "icns", str(iconset), "-o",
                        str(resources / "SpeechServer.icns")], check=True)
    subprocess.run(["/usr/bin/clang", "-fobjc-arc", "-O2", "-Wall", "-Wextra",
                    "-Wno-unused-parameter", "-framework", "Cocoa",
                    str(ROOT / "speech-http-app/main.m"), "-o", str(binary)], check=True)
    with (contents / "Info.plist").open("wb") as stream:
        plistlib.dump({"CFBundleExecutable": "ReaderSpeechServer",
                      "CFBundleIdentifier": "local.reader.speech.gui",
                      "CFBundleName": "Reader Speech Server", "CFBundlePackageType": "APPL",
                      "CFBundleVersion": "2", "CFBundleIconFile": "SpeechServer.icns",
                      "NSHighResolutionCapable": True,
                      "ReaderSpeechRoot": str(ROOT)}, stream)
    print(APP)


if __name__ == "__main__":
    build()
