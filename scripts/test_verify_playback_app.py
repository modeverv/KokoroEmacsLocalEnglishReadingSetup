"""Regression checks for the standalone app compatibility gate."""
import struct
import tempfile
import unittest
from pathlib import Path
from verify_playback_app import slices, verify


def thin(cpu, minimum=0xC0000, library=None):
    commands = struct.pack("<IIIIII", 0x32, 24, 1, minimum, minimum, 0)
    if library:
        name = library.encode() + b"\0"
        commands += struct.pack("<IIIIII", 0xC, 24 + len(name), 24, 0, 0, 0) + name
    return struct.pack("<IIIIIIII", 0xFEEDFACF, cpu, 0, 2, 2 if library else 1, len(commands), 0, 0) + commands


class CompatibilityTests(unittest.TestCase):
    def test_universal_slices(self):
        arm, intel = thin(0x100000C), thin(0x1000007)
        data = struct.pack(">II", 0xCAFEBABE, 2)
        data += struct.pack(">IIIII", 0x100000C, 0, 48, len(arm), 0)
        data += struct.pack(">IIIII", 0x1000007, 0, 48 + len(arm), len(intel), 0)
        self.assertEqual({r["arch"] for r in slices(data + arm + intel)}, {"arm64", "x86_64"})

    def test_rejects_new_os_external_library_and_wrong_cpu(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Contents/Resources/runtime-x86_64/bin/python"
            path.parent.mkdir(parents=True)
            for data, message in [(thin(0x1000007, 0xD0000), "newer than 12"),
                                  (thin(0x1000007, library="/opt/homebrew/lib/test.dylib"), "external dependency"),
                                  (thin(0x100000C), "missing architecture")]:
                with self.subTest(message=message):
                    path.write_bytes(data)
                    with self.assertRaisesRegex(ValueError, message):
                        verify(directory)
            path.write_bytes(thin(0x1000007, library="/usr/lib/libSystem.B.dylib"))
            self.assertEqual(len(verify(directory)), 1)

    def test_rejects_escaping_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "external").symlink_to("/usr/lib")
            with self.assertRaisesRegex(ValueError, "non-portable symlink"):
                verify(directory)


if __name__ == "__main__":
    unittest.main()
