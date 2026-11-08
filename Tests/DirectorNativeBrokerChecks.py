#!/usr/bin/env python3
"""Native conversation ownership checks; no model, media or desktop access."""
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("broker", ROOT / "Tools/director-agent-client.py")
broker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(broker)


class NativeBrokerChecks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name) / "conversation"
        self.payload = {"request": {"text": "Full screen over two seconds.", "document_id": "doc-a",
            "bootstrap_context": {"duration": 14}, "editor_events": []},
            "configuration": {"provider": "claude", "model": "sonnet", "cli": "/fake/cli",
                "cwd": str(self.directory), "document_id": "doc-a", "recording_id": "persistent-recording-a"}}

    def call(self, callback):
        with patch.object(broker.importlib, "import_module", return_value=types.SimpleNamespace(run_turn=callback)):
            return broker.run(self.payload)

    def test_binding_precedes_actions_and_resume_does_not_replay_bootstrap(self):
        seen = []
        def native(request, configuration):
            seen.append((dict(request), configuration["native_session_id"]))
            self.assertNotIn("document_id", request)
            configuration["on_session_id"]("actual-native-id")
            self.assertEqual(json.loads((self.directory / "binding.json").read_text())["native_session_id"], "actual-native-id")
            return {"native_session_id": "actual-native-id", "text": "Applied.", "events": []}
        self.assertTrue(self.call(native)["ok"])
        self.payload["configuration"]["model"] = "haiku"
        self.payload["request"]["text"] = "Yes, picture in picture."
        self.assertTrue(self.call(native)["ok"])
        self.assertIsNone(seen[0][1])
        self.assertEqual(seen[1][1], "actual-native-id")
        self.assertIn("bootstrap_context", seen[0][0])
        self.assertNotIn("bootstrap_context", seen[1][0])
        self.assertEqual(seen[1][0]["text"], "Yes, picture in picture.")
        self.assertEqual((self.directory / "binding.json").stat().st_mode & 0o777, 0o600)

    def test_partial_failure_keeps_identity_and_actual_results(self):
        def partial(request, config):
            config["on_session_id"]("same-native-id")
            return {"native_session_id": "same-native-id", "events": [{"actual_change": "camera"}],
                "error": {"code": "interrupted", "message": "Stopped after one action."}}
        result = self.call(partial)
        self.assertFalse(result["ok"])
        self.assertEqual(result["events"], [{"actual_change": "camera"}])
        def changed(request, config):
            config["on_session_id"]("different-id")
        with self.assertRaisesRegex(ValueError, "fresh-session fallback"):
            self.call(changed)
        self.assertEqual(json.loads((self.directory / "binding.json").read_text())["native_session_id"], "same-native-id")

    def test_document_scope_mismatch_rejected_before_launch(self):
        self.payload["request"]["document_id"] = "other-doc"
        with self.assertRaisesRegex(ValueError, "scopes differ"):
            self.call(lambda *_: self.fail("must not launch"))

    def test_replaced_recording_at_same_path_cannot_inherit_conversation(self):
        def native(request, config):
            config["on_session_id"]("old-recording-session")
            return {"native_session_id": "old-recording-session"}
        self.call(native)
        self.payload["configuration"]["recording_id"] = "persistent-recording-b"
        with self.assertRaisesRegex(ValueError, "different recording"):
            self.call(lambda *_: self.fail("must not resume the previous recording"))

    def test_busy_native_session_is_not_forked(self):
        self.directory.mkdir(mode=0o700)
        with (self.directory / "session.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.call(lambda *_: self.fail("busy session must not launch"))
        self.assertEqual(result["error"]["code"], "busy")

    def test_failed_binding_save_preserves_native_evidence(self):
        def native(request, config):
            try:
                config["on_session_id"]("known-native-id")
            except OSError:
                return {"native_session_id": "known-native-id", "text": "Native status.",
                    "events": [{"actual_state": "preserve this evidence"}],
                    "error": {"code": "session_binding", "message": "Storage failed."}}
            self.fail("binding failure not injected")
        with patch.object(broker, "atomic_json", side_effect=OSError("Synthetic full disk")):
            result = self.call(native)
        self.assertFalse(result["ok"])
        self.assertEqual(result["native_session_id"], "known-native-id")
        self.assertEqual(result["text"], "Native status.")
        self.assertEqual(result["events"], [{"actual_state": "preserve this evidence"}])
        self.assertEqual(result["error"]["native_error"]["code"], "session_binding")

    def test_unsafe_session_directory_rejected(self):
        self.directory.mkdir(mode=0o755)
        with self.assertRaisesRegex(ValueError, "private"):
            self.call(lambda *_: self.fail("unsafe session must not launch"))


if __name__ == "__main__":
    unittest.main()
