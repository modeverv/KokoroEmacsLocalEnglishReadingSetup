"""Build a relocatable Intel/Apple Silicon app targeting macOS Monterey (12)."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

from verify_playback_app import verify

ROOT = Path(__file__).resolve().parents[1] / "companion-implementations"
BUILD = ROOT / "playback-app/build"
APP = BUILD / "Reader Playback Server.app"
PYTHON_VERSION = "3.12.13"


def run(*args, **kwargs):
    subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def build():
    BUILD.mkdir(parents=True, exist_ok=True)
    cache = BUILD / "python-cache"
    targets = {"arm64": "aarch64", "x86_64": "x86_64"}
    run("uv", "python", "install", "--no-bin", "--install-dir", cache,
        *(f"cpython-{PYTHON_VERSION}-macos-{arch}-none" for arch in targets.values()))
    if APP.exists():
        shutil.rmtree(APP)
    contents = APP / "Contents"
    resources = contents / "Resources"
    binary = contents / "MacOS/ReaderPlaybackServer"
    binary.parent.mkdir(parents=True)
    resources.mkdir()
    env = dict(os.environ, MACOSX_DEPLOYMENT_TARGET="12.0")
    for name, arch in targets.items():
        runtime = resources / f"runtime-{name}"
        shutil.copytree(cache / f"cpython-{PYTHON_VERSION}-macos-{arch}-none", runtime, symlinks=True)
        site = runtime / "lib/python3.12/site-packages"
        run("uv", "pip", "install", "--python-version", "3.12", "--python-platform", f"{arch}-apple-darwin",
            "--target", site, "--only-binary", ":all:", "--link-mode", "copy",
            "--requirements", ROOT / "playback-app/requirements.txt", env=env)
    package = resources / "speech_http"
    package.mkdir()
    for name in ("__init__.py", "playback.py", "playback_queue.py"):
        shutil.copy2(ROOT / "speech_http" / name, package / name)
    shutil.copy2(ROOT / "playback-app/bootstrap.py", resources)
    shutil.copy2(ROOT / "playback-app/requirements.txt", resources / "DEPENDENCIES.txt")
    shutil.copy2(ROOT.parent / "LICENSE", resources / "LICENSE.txt")
    (resources / "THIRD_PARTY.txt").write_text(
        "Python runtimes: Astral python-build-standalone (CPython 3.12.13).\n"
        "Python and bundled library licenses are included in each runtime.\n"
        "Package licenses are under runtime-*/lib/python3.12/site-packages/*.dist-info/.\n"
        "PortAudio is bundled by sounddevice under the MIT license.\n", encoding="utf-8")
    with tempfile.TemporaryDirectory() as directory:
        iconset = Path(directory) / "Playback.iconset"
        iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                suffix = "@2x" if scale == 2 else ""
                run("/usr/bin/sips", "-z", size * scale, size * scale, ROOT / "speech-http-app/icon.png",
                    "--out", iconset / f"icon_{size}x{size}{suffix}.png", stdout=subprocess.DEVNULL)
        run("/usr/bin/iconutil", "-c", "icns", iconset, "-o", resources / "Playback.icns")
    run("/usr/bin/clang", "-arch", "arm64", "-arch", "x86_64", "-mmacosx-version-min=12.0",
        "-fobjc-arc", "-O2", "-Wall", "-Wextra", "-Wno-unused-parameter", "-framework", "Cocoa",
        ROOT / "playback-app/main.m", "-o", binary, env=env)
    with (contents / "Info.plist").open("wb") as stream:
        plistlib.dump({"CFBundleExecutable": "ReaderPlaybackServer", "CFBundleIdentifier": "local.reader.playback.gui",
                      "CFBundleName": "Reader Playback Server", "CFBundlePackageType": "APPL",
                      "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
                      "CFBundleIconFile": "Playback.icns", "LSMinimumSystemVersion": "12.0",
                      "NSHighResolutionCapable": True,
                      "NSLocalNetworkUsageDescription": "生成サーバーから音声を受信し、Emacsへ再生完了を通知します。"}, stream)
    report = verify(APP)
    for name in sorted({record["file"] for record in report}):
        run("/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", APP / name,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    run("/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", APP)
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", APP)
    (BUILD / "compatibility-report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    archive = BUILD / "ReaderPlaybackServer-macOS12-universal.zip"
    if archive.exists():
        archive.unlink()
    run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", APP, archive)
    print(f"App: {APP}\nZIP: {archive}\nVerified Mach-O slices: {len(report)}")


if __name__ == "__main__":
    build()
