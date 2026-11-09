#!/usr/bin/env python3
"""Exercise local credential loading and the app reader without network or media."""

import importlib.util
from pathlib import Path
import plistlib
import stat
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "oauth_config", ROOT / "Tools/embed-oauth-config.py"
)
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


class OAuthConfigurationChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.env = self.directory / ".env"
        self.output = self.directory / "resources/OAuthConfig.plist"

    def bundled(self, overrides=None):
        config.embed(self.env, self.output, overrides or {})
        return plistlib.loads(self.output.read_bytes())

    def test_literal_values_and_xml_escaping(self):
        self.env.write_text(
            '# local configuration\nexport GDRIVE_CLIENT_ID="example client"\n'
            "GDRIVE_CLIENT_SECRET='$(touch forbidden) & <literal>'\n"
            'SLACK_CLIENT_ID=example-slack # comment\n'
            'SLACK_CLIENT_SECRET="example \\\"quoted\\\" secret"\n'
        )
        self.assertEqual(self.bundled(), {
            "GDriveClientID": "example client",
            "GDriveClientSecret": "$(touch forbidden) & <literal>",
            "SlackClientID": "example-slack",
            "SlackClientSecret": 'example "quoted" secret',
        })
        self.assertFalse(self.output.stat().st_mode & (stat.S_IRWXG | stat.S_IRWXO))

    def test_environment_overrides_including_explicit_empty(self):
        self.env.write_text("SLACK_CLIENT_ID=local\nSLACK_CLIENT_SECRET=local-secret\n")
        result = self.bundled({"SLACK_CLIENT_ID": "ci-client", "SLACK_CLIENT_SECRET": ""})
        self.assertEqual(result["SlackClientID"], "ci-client")
        self.assertEqual(result["SlackClientSecret"], "")

    def test_removed_env_clears_stale_credentials(self):
        self.env.write_text("GDRIVE_CLIENT_ID=example-google\n")
        self.assertEqual(self.bundled()["GDriveClientID"], "example-google")
        self.env.unlink()
        self.assertTrue(all(value == "" for value in self.bundled().values()))

    def test_invalid_input_never_echoes_values(self):
        for contents in (
            'GDRIVE_CLIENT_SECRET="private-fixture\n',
            'GDRIVE_CLIENT_SECRET=private fixture\n',
            'GDRIVE_CLIENT_SECRET=first\nGDRIVE_CLIENT_SECRET=private-fixture\n',
        ):
            with self.subTest(contents=contents):
                self.env.write_text(contents)
                with self.assertRaises(ValueError) as caught:
                    self.bundled()
                self.assertNotIn("private", str(caught.exception))

    def test_app_reads_generated_resource_and_handles_missing_or_invalid_files(self):
        self.env.write_text(
            "GDRIVE_CLIENT_ID=example-google\nGDRIVE_CLIENT_SECRET=example-google-secret\n"
            "SLACK_CLIENT_ID=example-slack\nSLACK_CLIENT_SECRET=example-slack-secret\n"
        )
        self.bundled()
        malformed = self.directory / "malformed.plist"
        malformed.write_text("invalid plist")
        executable = self.directory / "checks"
        subprocess.run([
            "swiftc", "-swift-version", "6", "-warnings-as-errors",
            str(ROOT / "FrameThrower/Sources/FrameThrower/OAuthCredentials.swift"),
            str(ROOT / "Tests/OAuthCredentialsChecks.swift"), "-o", str(executable),
        ], check=True)
        subprocess.run([str(executable), str(self.output), str(malformed)], check=True)


if __name__ == "__main__":
    unittest.main()
