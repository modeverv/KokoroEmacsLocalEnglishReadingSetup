"""Check the repository boundary and executable paths after relocation."""
from pathlib import Path
import unittest
from unittest.mock import patch

import build_playback_app
import build_speech_app
from speech_http import gui, service

ROOT = Path(__file__).resolve().parents[1]
COMPANION = ROOT / "companion-implementations"


class CompanionLayoutTests(unittest.TestCase):
    def test_root_contains_only_public_project_entries(self):
        expected = {"docs", "companion-implementations", "my-read", "my-read.el",
                    "README.md", "LICENSE", "Makefile", ".gitignore", "mise.toml",
                    "uv.lock", "test", "scripts"}
        actual = {p.name for p in ROOT.iterdir() if p.name not in {".git", ".DS_Store"}}
        self.assertEqual(actual, expected)

    def test_uv_uses_one_root_lockfile(self):
        self.assertTrue((COMPANION / "uv.lock").is_symlink())
        self.assertEqual((COMPANION / "uv.lock").resolve(), ROOT / "uv.lock")
        self.assertTrue((COMPANION / "pyproject.toml").is_file())

    def test_app_builders_and_service_use_companion_root(self):
        self.assertEqual(build_playback_app.ROOT, COMPANION)
        self.assertEqual(build_speech_app.ROOT, COMPANION)
        self.assertEqual(service.ROOT, COMPANION)
        self.assertTrue((build_playback_app.ROOT.parent / "LICENSE").is_file())
        for relative in ("playback-app/main.m", "playback-app/bootstrap.py",
                         "playback-app/requirements.txt", "speech-http-app/main.m",
                         "speech-http-app/icon.png", "speech_http/playback.py",
                         "macos-speech-bridge/main.m", "my-read-k2/bridge/Package.swift"):
            self.assertTrue((COMPANION / relative).is_file(), relative)

    def test_gui_rebuild_uses_repository_script_and_companion_app(self):
        with patch.object(Path, "exists", return_value=False), patch.object(gui.subprocess, "run") as run:
            gui.main()
        build, launch = run.call_args_list
        self.assertEqual(Path(build.args[0][1]), ROOT / "scripts/build_speech_app.py")
        self.assertEqual(Path(launch.args[0][1]), build_speech_app.APP)
        self.assertTrue(build.kwargs["check"])
        self.assertTrue(launch.kwargs["check"])


if __name__ == "__main__":
    unittest.main()
