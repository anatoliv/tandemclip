#!/usr/bin/env python3

from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "Scripts/package-dsym.sh"
SELECTOR = ROOT / "Scripts/dsym-member.py"


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
        selected = subprocess.run(
            ["python3", str(SELECTOR), str(self.archive)],
            text=True, capture_output=True, check=False,
        )
        self.assertEqual(selected.returncode, 0, selected.stderr)
        self.assertEqual(selected.stdout.strip(), "tandemclip.dSYM/Contents/Resources/DWARF/tandemclip")

    def test_refuses_ambiguous_dwarf_payload(self):
        (self.dwarf / "second").write_bytes(b"another fixture")
        result = self.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exactly one DWARF", result.stderr)

    def test_resume_uses_the_same_portable_member_selector(self):
        release = (ROOT / "Scripts/release.sh").read_text()
        self.assertIn('python3 Scripts/dsym-member.py "$DEBUG_ARCHIVE"', release)
        self.assertNotIn("unzip -Z1", release)


if __name__ == "__main__":
    unittest.main()
