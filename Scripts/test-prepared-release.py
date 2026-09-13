#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("prepared-release.py")
SPEC = importlib.util.spec_from_file_location("prepared_release", SCRIPT)
assert SPEC and SPEC.loader
PREPARED = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREPARED)

RECEIPT_SCRIPT = Path(__file__).with_name("verify-crashbox-artifact-receipt.py")
RECEIPT_SPEC = importlib.util.spec_from_file_location("receipt_verifier", RECEIPT_SCRIPT)
assert RECEIPT_SPEC and RECEIPT_SPEC.loader
RECEIPT = importlib.util.module_from_spec(RECEIPT_SPEC)
RECEIPT_SPEC.loader.exec_module(RECEIPT)

PROJECT = "6bb1b202-8b83-4ec4-9151-f4ef7548e544"
ARTIFACT = "8f734b55-9af4-4c4c-9675-f6831bbf5510"


class PreparedReleaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        subprocess.run(["git", "init", "-q", self.root], check=True)
        subprocess.run(["git", "-C", self.root, "config", "user.name", "Test"], check=True)
        subprocess.run(
            ["git", "-C", self.root, "config", "user.email", "test@example.invalid"],
            check=True,
        )
        self.app = self.root / "build" / "TandemClip.app"
        executable = self.app / "Contents" / "MacOS" / "tandemclip"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"signed app bytes")
        executable.chmod(0o755)
        resources = self.app / "Contents" / "Resources"
        resources.mkdir()
        (resources / "current").symlink_to("asset.txt")
        (resources / "asset.txt").write_bytes(b"resource")
        self.dsym = self.root / "dist" / "TandemClip.dSYM.zip"
        self.dsym.parent.mkdir()
        self.dsym.write_bytes(b"dSYM archive")
        self.dmg = self.root / "dist" / "TandemClip.dmg"
        self.dmg.write_bytes(b"notarized DMG")
        self.appcast = self.root / "dist" / "appcast.xml"
        self.appcast.write_text("<rss/>")
        self.cask = self.root / "Casks" / "tandemclip.rb"
        self.cask.parent.mkdir()
        self.cask.write_text('version "0.25.1,63"\n')
        self.site = self.root / "site" / "index.html"
        self.site.parent.mkdir()
        self.site.write_text("0.25.1")
        self.supporters = self.root / "site" / "supporters.json"
        self.supporters.write_text("[]")
        tracked = self.root / "Sources" / "main.swift"
        tracked.parent.mkdir()
        tracked.write_text("print(1)\n")
        subprocess.run(["git", "-C", self.root, "add", "."], check=True)
        subprocess.run(["git", "-C", self.root, "commit", "-qm", "fixture"], check=True)
        self.source = subprocess.run(
            ["git", "-C", self.root, "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        self.manifest = self.root / "prepared.json"
        self.receipt = self.root / "receipt.json"
        self.args = argparse.Namespace(
            repository=self.root,
            app=self.app,
            dsym_archive=self.dsym,
            dmg=self.dmg,
            appcast=self.appcast,
            cask=self.cask,
            site=self.site,
            supporters=self.supporters,
            source_commit=self.source,
            version="0.25.1",
            build="63",
            release=f"com.tandemclip@0.25.1+63.{self.source}",
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def prepare(self) -> None:
        PREPARED.write_manifest(self.manifest, PREPARED.snapshot(self.args))

    def verify(self) -> None:
        PREPARED.verify_manifest(self.manifest, PREPARED.snapshot(self.args))

    def write_receipt(self) -> None:
        self.receipt.write_text(
            json.dumps(
                {
                    "artifact_id": ARTIFACT,
                    "project_id": PROJECT,
                    "release": self.args.release,
                    "sha256": hashlib.sha256(self.dsym.read_bytes()).hexdigest(),
                    "state": "ready",
                    "type": "apple_dsym",
                }
            )
        )

    def test_prepare_receipt_then_resume_reuses_the_exact_release(self) -> None:
        self.prepare()
        self.write_receipt()
        self.verify()
        RECEIPT.verify(self.receipt, self.dsym, self.args.release, PROJECT)
        self.assertEqual(self.manifest.stat().st_mode & 0o777, 0o600)

    def test_resume_branch_accepts_the_existing_dmg_as_input(self) -> None:
        release = Path(__file__).with_name("release.sh").read_text()
        resume = release.index('if [[ -n "$RESUME_MANIFEST" ]]; then')
        normal_build = release.index("\nelse\n", resume)
        existing_dmg_guard = release.index('if [[ -f "$DMG"', normal_build)
        self.assertLess(normal_build, existing_dmg_guard)
        self.assertIn("FORCE_REBUILD cannot resume", release[resume:normal_build])
        self.assertIn("prepared_release verify", release)

    def test_resume_refuses_every_changed_release_surface(self) -> None:
        self.prepare()
        self.write_receipt()
        changes = (
            (self.app / "Contents" / "MacOS" / "tandemclip", b"changed app"),
            (self.dsym, b"changed dSYM"),
            (self.dmg, b"changed DMG"),
            (self.appcast, b"changed appcast"),
            (self.cask, b"changed cask"),
            (self.site, b"changed site"),
            (self.supporters, b"changed supporters"),
            (self.root / "Sources" / "main.swift", b"changed source tree"),
        )
        for path, replacement in changes:
            with self.subTest(path=path.relative_to(self.root)):
                original = path.read_bytes()
                path.write_bytes(replacement)
                with self.assertRaises(PREPARED.Refused):
                    self.verify()
                if path == self.dsym:
                    with self.assertRaises(RECEIPT.Refused):
                        RECEIPT.verify(self.receipt, self.dsym, self.args.release, PROJECT)
                path.write_bytes(original)
                if path.name == "tandemclip":
                    path.chmod(0o755)
                self.verify()

    def test_resume_refuses_changed_identity_or_manifest_shape(self) -> None:
        self.prepare()
        original = self.args.source_commit
        self.args.source_commit = "0" * 40
        with self.assertRaisesRegex(PREPARED.Refused, "prepared_identity_invalid"):
            self.verify()
        self.args.source_commit = original

        document = json.loads(self.manifest.read_text())
        document["credential"] = "must not be accepted"
        self.manifest.write_text(json.dumps(document))
        with self.assertRaisesRegex(PREPARED.Refused, "prepared_manifest_invalid"):
            PREPARED._read_manifest(self.manifest)

    def test_manifest_is_bounded_not_followed_and_not_overwritten(self) -> None:
        self.prepare()
        with self.assertRaisesRegex(PREPARED.Refused, "prepared_manifest_unavailable"):
            PREPARED.write_manifest(self.manifest, PREPARED.snapshot(self.args))

        self.manifest.unlink()
        target = self.root / "target.json"
        target.write_text("{}")
        self.manifest.symlink_to(target)
        with self.assertRaisesRegex(PREPARED.Refused, "prepared_file_unavailable"):
            PREPARED._read_manifest(self.manifest)
        self.manifest.unlink()
        self.manifest.write_bytes(b"x" * (PREPARED.MAX_MANIFEST_BYTES + 1))
        with self.assertRaisesRegex(PREPARED.Refused, "prepared_file_size_invalid"):
            PREPARED._read_manifest(self.manifest)

    def test_optional_supporters_refuses_a_broken_symlink(self) -> None:
        self.supporters.unlink()
        self.supporters.symlink_to("missing.json")
        with self.assertRaisesRegex(PREPARED.Refused, "prepared_file_unavailable"):
            PREPARED.snapshot(self.args)


if __name__ == "__main__":
    unittest.main()
