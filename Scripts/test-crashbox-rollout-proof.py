#!/usr/bin/env python3

import datetime as dt
import importlib.util
import json
import os
import tempfile
import unittest
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "Scripts/prove-crashbox-rollout.py"
SPEC = importlib.util.spec_from_file_location("rollout_proof", SCRIPT)
PROOF = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(PROOF)


class IdentityTests(unittest.TestCase):
    def info(self, **updates):
        value = {
            "CFBundleIdentifier": "com.tandemclip",
            "CFBundleExecutable": "tandemclip",
            "CFBundleShortVersionString": "0.25.1",
            "CFBundleVersion": "63",
            "TandemClipSourceCommit": "a" * 40,
            "CrashboxDSN": "https://public@example.test/project",
        }
        value.update(updates)
        return value

    def test_candidate_identity_is_derived_and_never_contains_the_dsn(self):
        identity = PROOF._identity_from_info(self.info(), reporting=True)
        self.assertEqual(
            identity["release"], "com.tandemclip:0.25.1:63:" + "a" * 40
        )
        self.assertRegex(identity["release"], PROOF.RECEIPT_TOKEN)
        self.assertNotIn("dsn", " ".join(identity).lower())
        self.assertNotIn("example.test", repr(identity))

    def test_candidate_requires_crashbox_and_rejects_hosted_sentry(self):
        with self.assertRaisesRegex(PROOF.Refused, "not_configured"):
            PROOF._identity_from_info(self.info(CrashboxDSN=""), reporting=True)
        with self.assertRaisesRegex(PROOF.Refused, "identity_invalid"):
            PROOF._identity_from_info(
                self.info(SentryDSN="https://hosted.invalid/1"), reporting=True
            )

    def test_rollback_must_be_reporting_disabled(self):
        with self.assertRaisesRegex(PROOF.Refused, "not_disabled"):
            PROOF._identity_from_info(self.info(), reporting=False)
        identity = PROOF._identity_from_info(
            self.info(CrashboxDSN=""), reporting=False
        )
        self.assertFalse(identity["reporting_configured"])


class ReceiptTests(unittest.TestCase):
    def setUp(self):
        self.proof = str(uuid.UUID("11111111-2222-4333-8444-555555555555"))
        self.candidate = {
            "release": "com.tandemclip:0.25.1:63:" + "a" * 40,
        }
        self.first = "2026-09-18T01:00:00Z"
        self.rollback = "2026-09-18T01:01:00Z"
        self.changed = "2026-09-18T01:02:00Z"

    def pair(self):
        return PROOF._receipt_pair(
            self.candidate,
            proof_id=self.proof,
            candidate_at=self.first,
            rollback_at=self.rollback,
            changed_at=self.changed,
        )

    def test_receipt_scope_is_fixed_and_reporting_disabled_is_the_rollback(self):
        value = self.pair()
        configuration = value["configuration"]
        rollback = value["rollback"]
        self.assertEqual(configuration["project"], "tandemclip-macos")
        self.assertEqual(
            configuration["protected_key_path"],
            "/protected/crashbox/project-keys/tandemclip-macos.key",
        )
        self.assertEqual(configuration["reporting_mode"], "enabled")
        self.assertIsNone(configuration["asset_origin"])
        self.assertEqual(rollback["target"], "reporting-disabled")
        self.assertEqual(rollback["result"], "reporting-disabled-verified")
        self.assertEqual(rollback["health"], "ready")

    def test_receipt_refuses_backdating_or_operator_chosen_identity(self):
        with self.assertRaisesRegex(PROOF.Refused, "chronology"):
            PROOF._receipt_pair(
                self.candidate,
                proof_id=self.proof,
                candidate_at=self.changed,
                rollback_at=self.rollback,
                changed_at=self.first,
            )
        with self.assertRaisesRegex(PROOF.Refused, "candidate_identity"):
            PROOF._receipt_pair(
                {"release": "invented"},
                proof_id=self.proof,
                candidate_at=self.first,
                rollback_at=self.rollback,
                changed_at=self.changed,
            )

    def test_remote_request_is_bounded_and_has_no_secret_input_surface(self):
        pair = self.pair()
        request = PROOF._canonical(
            {
                "schema_version": 1,
                "expected_previous_archive": "sha256:" + "b" * 64,
                **pair,
            }
        )
        self.assertLess(len(request), PROOF.MAX_REQUEST_BYTES)
        self.assertNotIn(b"dsn", request.lower())
        self.assertNotIn(b"private", request.lower())
        self.assertIn(b"tandemclip-macos", request)

    def test_timestamps_with_microseconds_remain_strict(self):
        base = dt.datetime(2026, 9, 18, 1, 0, tzinfo=dt.UTC)
        values = [
            PROOF._timestamp(base + dt.timedelta(microseconds=index))
            for index in range(3)
        ]
        pair = PROOF._receipt_pair(
            self.candidate,
            proof_id=self.proof,
            candidate_at=values[0],
            rollback_at=values[1],
            changed_at=values[2],
        )
        self.assertEqual(
            pair["configuration"]["configuration_changed_at"], values[2]
        )

    def test_candidate_activation_requires_one_unambiguous_process(self):
        original = PROOF._running_instances
        self.addCleanup(setattr, PROOF, "_running_instances", original)
        PROOF._running_instances = lambda: {}
        with self.assertRaisesRegex(PROOF.Refused, "process_ambiguous"):
            PROOF._candidate_started_at()
        started = dt.datetime(2026, 9, 18, 1, 0, tzinfo=dt.UTC)
        PROOF._running_instances = lambda: {42: started}
        self.assertEqual(PROOF._candidate_started_at(), started)


class RecoveryTests(unittest.TestCase):
    def test_resume_selects_only_the_exact_failed_post_reactivation_journal(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        state = Path(temporary.name)
        proof_id = "11111111-2222-4333-8444-555555555555"
        candidate = {
            "version": "0.25.1",
            "build": "63",
            "source_commit": "a" * 40,
            "release": "com.tandemclip:0.25.1:63:" + "a" * 40,
        }
        rollback = {"source_commit": "b" * 40}
        pair = PROOF._receipt_pair(
            candidate,
            proof_id=proof_id,
            candidate_at="2026-09-18T01:00:00Z",
            rollback_at="2026-09-18T01:01:00Z",
            changed_at="2026-09-18T01:02:00Z",
        )
        legacy = json.loads(json.dumps(pair))
        legacy_identity = "com.tandemclip@0.25.1+63." + "a" * 40
        legacy["configuration"]["candidate_identity"] = legacy_identity
        legacy["rollback"]["candidate_identity"] = legacy_identity
        value = {
            "phase": "failed",
            "proof_id": proof_id,
            "project": "tandemclip-macos",
            "candidate_identity": legacy_identity,
            "candidate_source": "a" * 40,
            "rollback_source": "b" * 40,
            "previous_receipts_archive": "sha256:" + "c" * 64,
            "candidate_first_activated_at": "2026-09-18T01:00:00Z",
            "rollback_completed_at": "2026-09-18T01:01:00Z",
            "configuration_changed_at": "2026-09-18T01:02:00Z",
            "receipts": legacy,
        }
        journal = state / f"proof-{proof_id}.json"
        journal.write_text(json.dumps(value), encoding="ascii")
        os.chmod(journal, 0o600)

        observed_path, observed_value, corrected = PROOF._resume_journal(
            state,
            candidate=candidate,
            rollback=rollback,
            previous="sha256:" + "c" * 64,
        )
        self.assertEqual(observed_path, journal)
        self.assertEqual(observed_value, value)
        self.assertEqual(corrected, pair)

    def test_reporting_disabled_bundle_is_replaced_by_saved_candidate(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        installed = root / "TandemClip.app"
        candidate_slot = root / "candidate.app"
        rollback_slot = root / "rollback.app"
        installed.mkdir()
        candidate_slot.mkdir()
        (installed / "kind").write_text("rollback")
        (candidate_slot / "kind").write_text("candidate")

        original = {
            "INSTALLED_APP": PROOF.INSTALLED_APP,
            "_verify_app": PROOF._verify_app,
            "_running_pids": PROOF._running_pids,
            "_quit": PROOF._quit,
            "_launch": PROOF._launch,
        }
        for name, value in original.items():
            self.addCleanup(setattr, PROOF, name, value)
        PROOF.INSTALLED_APP = installed

        def verify(path, *, reporting):
            kind = (path / "kind").read_text()
            if reporting and kind != "candidate":
                raise PROOF.Refused("candidate_reporting_not_configured")
            return {"tree_sha256": "candidate-tree" if kind == "candidate" else "rollback-tree"}

        PROOF._verify_app = verify
        PROOF._running_pids = lambda: {42}
        PROOF._quit = lambda: None
        PROOF._launch = lambda previous: None
        PROOF._restore_candidate(
            candidate_slot, rollback_slot, {"tree_sha256": "candidate-tree"}
        )
        self.assertEqual((installed / "kind").read_text(), "candidate")
        self.assertEqual((rollback_slot / "kind").read_text(), "rollback")


if __name__ == "__main__":
    unittest.main()
