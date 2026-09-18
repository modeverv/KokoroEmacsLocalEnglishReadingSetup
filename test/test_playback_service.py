"""Service ownership, independent launch arguments, and failure cleanup."""
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch, Mock

from speech_http import playback_service as service


class PlaybackServiceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)
        self.patcher = patch.object(service, "paths", return_value=(self.directory, "test.playback", "gui/1/test.playback"))
        self.patcher.start()
        self.addCleanup(self.patcher.stop)

    def test_existing_service_is_reused_without_bootstrap(self):
        with patch.object(service, "status", return_value={"ok": True, "pid": 42}), patch.object(service, "launchctl") as launch:
            self.assertEqual(service.start()["pid"], 42)
            launch.assert_not_called()

    def test_start_uses_independent_job_and_private_token_config(self):
        state = {"ok": True, "managed": True, "pid": 42}
        with patch.object(service, "status", side_effect=[{"ok": False}, state]), patch.object(service, "health", return_value=state), patch.object(service, "launchctl") as launch, patch.object(service.socket, "create_connection", side_effect=ConnectionRefusedError), patch.dict(os.environ, READER_PLAYBACK_TOKEN="test-secret"):
            self.assertEqual(service.start(host="0.0.0.0"), state)
        config_path = self.directory / "server.plist"
        config = plistlib.loads(config_path.read_bytes())
        self.assertTrue(config["RunAtLoad"])
        self.assertFalse(config["KeepAlive"])
        self.assertEqual(config["EnvironmentVariables"]["READER_PLAYBACK_TOKEN"], "test-secret")
        self.assertEqual(config_path.stat().st_mode & 0o777, 0o600)
        self.assertIn("speech_http.playback", config["ProgramArguments"])
        self.assertEqual(launch.call_args_list[-1].args[0], "bootstrap")

    def test_bundled_job_uses_relocatable_isolated_bootstrap(self):
        (self.directory / "bootstrap.py").write_text("")
        with patch.object(service, "ROOT", self.directory):
            command = service.command("127.0.0.1", 8768, "headphones", 2)
        self.assertEqual(command[1:4], ["-I", "-B", str(self.directory / "bootstrap.py")])
        self.assertNotIn("service", command)
        self.assertEqual(command[-2:], ["--device", "headphones"])

    def test_unmanaged_server_cannot_be_stopped(self):
        with patch.object(service, "status", return_value={"ok": True, "managed": False}), patch.object(service, "launchctl") as launch:
            with self.assertRaisesRegex(RuntimeError, "separately"):
                service.stop()
            launch.assert_not_called()

    def test_stop_removes_registration_and_secret_file(self):
        (self.directory / "server.plist").write_text("secret")
        with patch.object(service, "status", side_effect=[{"ok": True, "managed": True}, {"ok": False}]), patch.object(service, "launchctl") as launch:
            self.assertFalse(service.stop()["ok"])
            launch.assert_called_once_with("bootout", "gui/1/test.playback")
        self.assertFalse((self.directory / "server.plist").exists())

    def test_stop_waits_for_launchd_removal(self):
        with patch.object(service, "status", side_effect=[{"ok": True, "managed": True},
                          {"ok": False, "managed": True}, {"ok": False, "managed": False}]), patch.object(service, "launchctl"), patch.object(service.time, "sleep") as sleep:
            self.assertFalse(service.stop()["managed"])
            sleep.assert_called_once_with(.1)

    def test_failed_start_unregisters_and_removes_secret(self):
        with patch.object(service, "status", return_value={"ok": False}), patch.object(service, "launchctl") as launch, patch.object(service.socket, "create_connection", side_effect=ConnectionRefusedError):
            with self.assertRaisesRegex(RuntimeError, "did not start"):
                service.start(timeout=0)
            self.assertEqual(launch.call_args_list[-1].args[0], "bootout")
        self.assertFalse((self.directory / "server.plist").exists())

    def test_occupied_port_does_not_bootstrap(self):
        with patch.object(service, "status", return_value={"ok": False}), patch.object(service, "launchctl") as launch, patch.object(service.socket, "create_connection", return_value=Mock()):
            with self.assertRaisesRegex(RuntimeError, "occupied"):
                service.start()
            self.assertFalse(any(call.args[0] == "bootstrap" for call in launch.call_args_list))

    def test_status_never_exposes_token(self):
        config = {"ProgramArguments": ["python", "--host", "0.0.0.0", "--prebuffer", "2"],
                  "EnvironmentVariables": {"READER_PLAYBACK_TOKEN": "secret"}}
        (self.directory / "server.plist").write_bytes(plistlib.dumps(config))
        with patch.object(service, "health", return_value={"ok": True, "pid": 42}), patch.object(service, "launchctl", return_value=Mock(returncode=0)):
            state = service.status()
        self.assertEqual(state["host"], "0.0.0.0")
        self.assertNotIn("secret", repr(state))

    def test_invalid_settings_do_not_control_jobs(self):
        with patch.object(service, "launchctl") as launch:
            for args in ({"port": 0}, {"prebuffer": float("nan")}, {"host": "remote"}):
                with self.assertRaises(ValueError):
                    service.start(**args)
            launch.assert_not_called()
