#!/usr/bin/env python3

import importlib.util
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "Scripts/verify-reporting-disabled-metadata.py"
SPEC = importlib.util.spec_from_file_location("rollback_metadata", SCRIPT)
ROLLBACK = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(ROLLBACK)


class RollbackMetadataTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        subprocess.run(["git", "init", "-q"], cwd=self.repo, check=True)
        subprocess.run(["git", "config", "user.email", "test@example.test"], cwd=self.repo, check=True)
        subprocess.run(["git", "config", "user.name", "Test"], cwd=self.repo, check=True)
        packaging = self.repo / "Packaging"
        packaging.mkdir()
        self.info = {
            "CFBundleIdentifier": "com.tandemclip",
            "CFBundleExecutable": "tandemclip",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "42",
            "CrashboxDSN": "",
            "TandemClipSourceCommit": "",
        }
        with (packaging / "Info.plist").open("wb") as handle:
            plistlib.dump(self.info, handle)
        subprocess.run(["git", "add", "."], cwd=self.repo, check=True)
        subprocess.run(["git", "commit", "-qm", "fixture"], cwd=self.repo, check=True)
        self.commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=self.repo, text=True).strip()
        self.app = self.root / "TandemClip.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/MacOS/tandemclip").write_bytes(b"binary")
        self.write_plist(TandemClipSourceCommit=self.commit)

    def write_plist(self, **updates):
        info = {**self.info, **updates}
        with (self.app / "Contents/Info.plist").open("wb") as handle:
            plistlib.dump(info, handle)

    def test_exact_disabled_metadata_passes(self):
        self.assertEqual(
            self.app / "Contents/MacOS/tandemclip",
            ROLLBACK.verify(self.repo, self.app, self.commit),
        )

    def test_any_reporting_configuration_is_refused(self):
        for key in ("CrashboxDSN", "SentryDSN"):
            with self.subTest(key=key):
                self.write_plist(TandemClipSourceCommit=self.commit, **{key: "https://public@example.test/1"})
                with self.assertRaisesRegex(ROLLBACK.Refused, "reporting configuration"):
                    ROLLBACK.verify(self.repo, self.app, self.commit)

    def test_source_and_version_must_match_the_exact_commit(self):
        self.write_plist(TandemClipSourceCommit="a" * 40)
        with self.assertRaisesRegex(ROLLBACK.Refused, "source identity"):
            ROLLBACK.verify(self.repo, self.app, self.commit)
        self.write_plist(TandemClipSourceCommit=self.commit, CFBundleVersion="99")
        with self.assertRaisesRegex(ROLLBACK.Refused, "version"):
            ROLLBACK.verify(self.repo, self.app, self.commit)
        with self.assertRaisesRegex(ROLLBACK.Refused, "unavailable"):
            ROLLBACK.verify(self.repo, self.app, "a" * 40)

    def test_executable_and_bundle_components_must_be_real_and_contained(self):
        executable = self.app / "Contents/MacOS/tandemclip"
        executable.unlink()
        executable.symlink_to("/tmp/outside")
        with self.assertRaises(ROLLBACK.Refused):
            ROLLBACK.verify(self.repo, self.app, self.commit)
        executable.unlink()
        executable.write_bytes(b"binary")
        contents = self.app / "Contents"
        moved = self.root / "actual-contents"
        contents.rename(moved)
        contents.symlink_to(moved, target_is_directory=True)
        with self.assertRaises(ROLLBACK.Refused):
            ROLLBACK.verify(self.repo, self.app, self.commit)


class RollbackBuildGateTests(unittest.TestCase):
    def test_signed_disabled_build_is_explicit_and_cannot_override_release_gate(self):
        source = (ROOT / "Scripts/make-app.sh").read_text()
        self.assertIn('TANDEMCLIP_REPORTING_DISABLED_ROLLBACK', source)
        self.assertIn('a reporting-disabled rollback must not carry a Crashbox DSN', source)
        self.assertIn('a Crashbox-required release cannot use the rollback-only build mode', source)
        builder = (ROOT / "Scripts/build-reporting-disabled-rollback.sh").read_text()
        self.assertIn('TANDEMCLIP_CRASHBOX_CONFIG_FILE=/dev/null', builder)
        self.assertIn('verify-reporting-disabled-rollback.sh', builder)
        self.assertIn('notarytool submit', builder)


if __name__ == "__main__":
    unittest.main()
