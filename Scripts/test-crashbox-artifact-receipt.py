#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("verify-crashbox-artifact-receipt.py")
SPEC = importlib.util.spec_from_file_location("receipt_verifier", SCRIPT)
assert SPEC and SPEC.loader
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)

PROJECT = "6bb1b202-8b83-4ec4-9151-f4ef7548e544"
RELEASE = "com.tandemclip@0.25.1+63." + "a" * 40
ARTIFACT = "8f734b55-9af4-4c4c-9675-f6831bbf5510"


class ReceiptVerifierTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.archive = self.root / "TandemClip.dSYM.zip"
        self.archive.write_bytes(b"bounded fixture archive")
        self.receipt = self.root / "receipt.json"
        self.document = {
            "artifact_id": ARTIFACT,
            "project_id": PROJECT,
            "release": RELEASE,
            "sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest(),
            "state": "ready",
            "type": "apple_dsym",
        }

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write(self, document: dict[str, str] | None = None) -> None:
        self.receipt.write_text(json.dumps(document or self.document))

    def test_accepts_only_the_exact_ready_receipt(self) -> None:
        self.write()
        VERIFIER.verify(self.receipt, self.archive, RELEASE, PROJECT)

    def test_refuses_a_receipt_for_another_project_release_or_archive(self) -> None:
        for field, value in (
            ("project_id", "00000000-0000-4000-8000-000000000000"),
            ("release", "com.tandemclip@0.25.1+63." + "b" * 40),
            ("sha256", "0" * 64),
            ("state", "pending"),
            ("type", "javascript_source_map"),
        ):
            with self.subTest(field=field):
                changed = {**self.document, field: value}
                self.write(changed)
                with self.assertRaisesRegex(VERIFIER.Refused, "receipt_mismatch"):
                    VERIFIER.verify(self.receipt, self.archive, RELEASE, PROJECT)

    def test_refuses_duplicate_or_extra_fields(self) -> None:
        self.receipt.write_text('{"artifact_id":"one","artifact_id":"two"}')
        with self.assertRaisesRegex(VERIFIER.Refused, "receipt_invalid"):
            VERIFIER.verify(self.receipt, self.archive, RELEASE, PROJECT)
        self.write({**self.document, "token": "must-not-be-here"})
        with self.assertRaisesRegex(VERIFIER.Refused, "receipt_invalid"):
            VERIFIER.verify(self.receipt, self.archive, RELEASE, PROJECT)

    def test_refuses_symlinks_and_oversized_receipts(self) -> None:
        target = self.root / "target.json"
        target.write_text(json.dumps(self.document))
        self.receipt.symlink_to(target)
        with self.assertRaisesRegex(VERIFIER.Refused, "file_unavailable"):
            VERIFIER.verify(self.receipt, self.archive, RELEASE, PROJECT)
        self.receipt.unlink()
        self.receipt.write_bytes(b"x" * (VERIFIER.MAX_RECEIPT_BYTES + 1))
        with self.assertRaisesRegex(VERIFIER.Refused, "file_size_invalid"):
            VERIFIER.verify(self.receipt, self.archive, RELEASE, PROJECT)


if __name__ == "__main__":
    unittest.main()
