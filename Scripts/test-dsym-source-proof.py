#!/usr/bin/env python3
"""Regression tests for the native crash-probe dSYM source proof."""

from __future__ import annotations

import os
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
VERIFIER = ROOT / "Scripts" / "verify-dsym-source-proof.py"


class DsymSourceProofTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.dsym = self.root / "tandemclip.dSYM"
        dwarf = self.dsym / "Contents" / "Resources" / "DWARF"
        dwarf.mkdir(parents=True)
        (dwarf / "tandemclip").write_bytes(b"dwarf")
        self.source = self.root / "CrashReporting.swift"
        self.source.write_text("let address = pointer\naddress.pointee = 0\n", encoding="utf-8")
        self.dwarfdump = self.root / "dwarfdump"

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _tool(self, path: Path, output: str, status: int = 0) -> None:
        path.write_text(
            "#!/bin/sh\n"
            + "printf '%s\\n' "
            + shlex.quote(output)
            + f"\nexit {status}\n",
            encoding="utf-8",
        )
        path.chmod(0o755)

    def run_verifier(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                os.fspath(VERIFIER),
                os.fspath(self.dsym),
                "--source",
                os.fspath(self.source),
                "--dwarfdump",
                os.fspath(self.dwarfdump),
            ],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_one_stable_symbol_with_a_real_source_line_passes(self) -> None:
        self._tool(
            self.dwarfdump,
            """0x0010: DW_TAG_subprogram
              DW_AT_low_pc (0x00000001000479a0)
              DW_AT_high_pc (0x00000001000479a8)
              DW_AT_linkage_name ("$s10tandemclip0A17CrashboxTestCrashyyF")
              DW_AT_name ("tandemclipCrashboxTestCrash")
              DW_AT_decl_file ("/src/CrashReporting.swift")
              DW_AT_decl_line (1)
0x0020: DW_TAG_subprogram
              DW_AT_linkage_name\t("tandemclipCrashboxTestCrash")
              DW_AT_name ("tandemclipCrashboxTestCrash")
Line info: file '/src/CrashReporting.swift', line 2, column 0""",
        )
        result = self.run_verifier()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("CrashReporting.swift:2", result.stdout)

    def test_missing_or_ambiguous_probe_linkage_is_refused(self) -> None:
        for output in (
            "DW_AT_linkage_name\t(\"somethingElse\")",
            "\n".join(["DW_AT_linkage_name\t(\"tandemclipCrashboxTestCrash\")"] * 2),
        ):
            with self.subTest(output=output):
                self._tool(self.dwarfdump, output)
                result = self.run_verifier()
                self.assertNotEqual(0, result.returncode)
                self.assertIn("exactly one stable", result.stderr)

    def test_missing_or_ambiguous_source_backed_function_is_refused(self) -> None:
        stable = 'DW_AT_linkage_name\t("tandemclipCrashboxTestCrash")'
        good = """0x0010: DW_TAG_subprogram
              DW_AT_low_pc (0x00000001000479a0)
              DW_AT_high_pc (0x00000001000479a8)
              DW_AT_name ("tandemclipCrashboxTestCrash")
              DW_AT_decl_file ("/src/CrashReporting.swift")
              DW_AT_decl_line (1)"""
        for output in (stable, stable + "\n" + good + "\n" + good):
            with self.subTest(output=output):
                self._tool(self.dwarfdump, output)
                result = self.run_verifier()
                self.assertNotEqual(0, result.returncode)
                self.assertIn("exactly one source-backed", result.stderr)

    def test_compiler_generated_missing_and_wrong_source_lines_are_refused(self) -> None:
        prefix = """0x0010: DW_TAG_subprogram
              DW_AT_low_pc (0x00000001000479a0)
              DW_AT_high_pc (0x00000001000479a8)
              DW_AT_name ("tandemclipCrashboxTestCrash")
              DW_AT_decl_file ("/src/CrashReporting.swift")
              DW_AT_decl_line (1)
0x0020: DW_TAG_subprogram
              DW_AT_linkage_name\t("tandemclipCrashboxTestCrash")
"""
        for output in (
            "Line info: file '/<compiler-generated>', line 0, column 0",
            "Line info: file '/src/CrashReporting.swift', line 0, column 0",
            "Line info: file '/src/Other.swift', line 2, column 0",
            "no line information",
        ):
            with self.subTest(output=output):
                self._tool(self.dwarfdump, prefix + output)
                result = self.run_verifier()
                self.assertNotEqual(0, result.returncode)
                self.assertIn(
                    "faulting write has no real CrashReporting.swift dSYM source line",
                    result.stderr,
                )

    def test_symlinked_dwarf_member_is_refused(self) -> None:
        dwarf = self.dsym / "Contents" / "Resources" / "DWARF" / "tandemclip"
        dwarf.unlink()
        target = self.root / "outside"
        target.write_bytes(b"dwarf")
        dwarf.symlink_to(target)
        self._tool(self.dwarfdump, "unused")
        result = self.run_verifier()
        self.assertNotEqual(0, result.returncode)
        self.assertIn("exactly one regular DWARF binary", result.stderr)

    def test_release_invokes_the_source_proof_before_packaging(self) -> None:
        release = (ROOT / "Scripts" / "release.sh").read_text(encoding="utf-8")
        proof = release.index('Scripts/verify-dsym-source-proof.py "$RELEASE_DSYM"')
        package = release.index('Scripts/package-dsym.sh "$RELEASE_DSYM" "$DEBUG_ARCHIVE"')
        self.assertLess(proof, package)

    def test_native_probe_uses_a_source_anchored_fault_not_fatal_error(self) -> None:
        source = (ROOT / "Sources" / "tandemclip" / "CrashReporting.swift").read_text(
            encoding="utf-8"
        )
        body = source[source.index('@_cdecl("tandemclipCrashboxTestCrash")') :]
        self.assertIn("@inline(never)", body)
        self.assertIn("address.pointee = 0", body)
        self.assertIn("abort()", body)
        self.assertNotIn("fatalError", body)


if __name__ == "__main__":
    unittest.main()
