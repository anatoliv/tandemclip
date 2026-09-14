#!/usr/bin/env python3

from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "Scripts/package-dsym.sh"


class PackageDsymTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.dsym = self.root / "tandemclip.dSYM"
        self.dwarf = self.dsym / "Contents/Resources/DWARF"
        self.dwarf.mkdir(parents=True)
        self.binary = self.dwarf / "tandemclip"
        self.binary.write_bytes(b"mach-o fixture")
        # The old --sequesterRsrc path turned this metadata into a second
        # __MACOSX/.../._tandemclip pseudo-DWARF member.
        subprocess.run(
            ["xattr", "-w", "com.tandemclip.test", "resource metadata", str(self.binary)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        self.archive = self.root / "symbols.zip"

    def package(self):
        return subprocess.run(
            [str(SCRIPT), str(self.dsym), str(self.archive)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_emits_one_real_dwarf_and_no_appledouble_members(self):
        result = self.package()
        self.assertEqual(result.returncode, 0, result.stderr)
        with zipfile.ZipFile(self.archive) as bundle:
            names = bundle.namelist()
        self.assertFalse(any("__MACOSX" in name for name in names))
        self.assertEqual(
            ["tandemclip.dSYM/Contents/Resources/DWARF/tandemclip"],
            [name for name in names if "/Contents/Resources/DWARF/" in name and not name.endswith("/")],
        )

    def test_refuses_ambiguous_dwarf_payload(self):
        (self.dwarf / "second").write_bytes(b"another fixture")
        result = self.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exactly one DWARF", result.stderr)


if __name__ == "__main__":
    unittest.main()
