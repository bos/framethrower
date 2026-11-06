#!/usr/bin/env python3
"""Temporary fixtures only; no real process tools, signatures, or user apps."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("debug_installer", Path(__file__).parents[1] / "Tools/install-debug.py")
installer = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = installer
spec.loader.exec_module(installer)


class DebugInstallerChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "build/FrameThrower.app"
        self.target = self.root / "Applications/FrameThrower.app"
        self.make_app(self.source, "new")
        self.make_app(self.target, "old")
        self.mutations = []
        self.processes = [""]
        self.verify_failure = lambda app: False
        self.copy_failure = False
        self.copy_hook = None
        self.rename_failure = lambda source, target, exchange: False
        self.system = installer.Installer(run=self.run_command, rename=self.rename)

    def make_app(self, path, version, team="TEAM"):
        (path / "Contents/MacOS").mkdir(parents=True)
        (path / "Contents/Resources").mkdir()
        with (path / "Contents/Info.plist").open("wb") as output:
            plistlib.dump({"CFBundleIdentifier": installer.BUNDLE_ID, "CFBundleExecutable": "FrameThrower", "CFBundlePackageType": "APPL"}, output)
        executable = path / "Contents/MacOS/FrameThrower"
        executable.write_text("fixture executable")
        executable.chmod(0o755)
        (path / "Contents/Resources/signature.json").write_text(json.dumps({"version": version, "team": team}))

    def signature(self, path):
        return json.loads((path / "Contents/Resources/signature.json").read_text())

    def run_command(self, arguments):
        output, code = "", 0
        if arguments[0] == "/bin/ps":
            output = self.processes[0]
            if len(self.processes) > 1:
                self.processes.pop(0)
        elif arguments[0] == "/usr/bin/ditto":
            self.mutations.append("copy")
            shutil.copytree(arguments[1], arguments[2])
            if self.copy_hook:
                self.copy_hook(Path(arguments[2]))
            code = int(self.copy_failure)
        elif arguments[0] == "/usr/bin/codesign":
            path = Path(arguments[-1])
            if "--verify" in arguments:
                code = int(self.verify_failure(path))
            else:
                signature = self.signature(path)
                digest = hashlib.sha256(signature["version"].encode()).hexdigest()
                output = f"Identifier={installer.BUNDLE_ID}\nTeamIdentifier={signature['team']}\nCDHash={digest}\n"
        else:
            raise AssertionError(f"Unexpected subprocess: {arguments}")
        return subprocess.CompletedProcess(arguments, code, stdout=output, stderr="fixture failure" if code else "")

    def rename(self, source, target, exchange=False):
        source, target = Path(source), Path(target)
        self.mutations.append("exchange" if exchange else "rename")
        if self.rename_failure(source, target, exchange):
            raise OSError("injected rename failure")
        if exchange:
            temporary = self.root / "exchange-fixture"
            os.rename(source, temporary)
            os.rename(target, source)
            os.rename(temporary, target)
        else:
            if os.path.lexists(target):
                raise FileExistsError(target)
            os.rename(source, target)

    def install(self):
        return self.system.install(self.source, self.target)

    def fails(self, code):
        with self.assertRaises(installer.InstallError) as caught:
            self.install()
        self.assertEqual(caught.exception.code, code)
        return caught.exception

    def no_staging(self):
        self.assertFalse(list(self.target.parent.glob(".FrameThrower.install-*")))

    def test_running_refuses_before_mutation(self):
        self.processes = [f"731 {self.target}/Contents/MacOS/FrameThrower\n"]
        self.fails("app_running")
        self.assertEqual(self.mutations, [])
        self.no_staging()
        self.assertEqual(self.signature(self.target)["version"], "old")

    def test_target_symlink_refuses_before_mutation(self):
        old = self.target.with_name("Original.app")
        os.rename(self.target, old)
        self.target.symlink_to(old, target_is_directory=True)
        self.fails("unsafe_target")
        self.assertEqual(self.mutations, [])
        self.assertEqual(self.signature(old)["version"], "old")

    def test_wrong_bundle_refuses_before_mutation(self):
        info = self.target / "Contents/Info.plist"
        with info.open("wb") as output:
            plistlib.dump({"CFBundleIdentifier": "other.app"}, output)
        self.fails("wrong_bundle")
        self.assertEqual(self.mutations, [])

    def test_signing_team_mismatch_refuses_before_mutation(self):
        (self.target / "Contents/Resources/signature.json").write_text(json.dumps({"version": "old", "team": "OTHER"}))
        self.fails("signing_team_mismatch")
        self.assertEqual(self.mutations, [])

    def test_invalid_source_signature_refuses_before_mutation(self):
        self.verify_failure = lambda app: app == self.source
        self.fails("invalid_signature")
        self.assertEqual(self.mutations, [])

    def test_copy_failure_preserves_previous_app(self):
        self.copy_failure = True
        self.fails("copy_failed")
        self.assertEqual(self.signature(self.target)["version"], "old")
        self.assertEqual(self.mutations, ["copy"])
        self.no_staging()

    def test_staged_verification_failure_preserves_previous_app(self):
        self.verify_failure = lambda app: app.parent.name.startswith(".FrameThrower.install-")
        self.fails("invalid_signature")
        self.assertEqual(self.signature(self.target)["version"], "old")
        self.assertEqual(self.mutations, ["copy"])
        self.no_staging()

    def test_process_starts_before_swap(self):
        self.processes = ["", f"732 {self.target}/Contents/MacOS/FrameThrower\n"]
        self.fails("app_running")
        self.assertEqual(self.mutations, ["copy"])
        self.assertEqual(self.signature(self.target)["version"], "old")
        self.no_staging()

    def test_safe_success_keeps_recoverable_backup(self):
        result = self.install()
        self.assertTrue(result["ok"])
        self.assertEqual(self.signature(self.target)["version"], "new")
        self.assertEqual(self.signature(Path(result["backup"]))["version"], "old")
        self.assertEqual(self.signature(self.source)["version"], "new")
        self.assertEqual(self.mutations, ["copy", "exchange", "rename"])
        self.no_staging()

    def test_post_swap_verification_failure_rolls_back(self):
        self.verify_failure = lambda app: app == self.target and self.signature(app)["version"] == "new"
        error = self.fails("invalid_signature")
        self.assertTrue(error.details["rolled_back"])
        self.assertEqual(self.signature(self.target)["version"], "old")
        self.assertEqual(self.mutations, ["copy", "exchange", "exchange"])
        self.no_staging()

    def test_backup_rename_failure_rolls_back(self):
        self.rename_failure = lambda source, target, exchange: target.name.startswith(".FrameThrower.previous-")
        error = self.fails("replacement_failed")
        self.assertTrue(error.details["rolled_back"])
        self.assertEqual(self.signature(self.target)["version"], "old")
        self.no_staging()

    def test_failed_rollback_retains_prior_app_for_recovery(self):
        self.verify_failure = lambda app: app == self.target and self.signature(app)["version"] == "new"
        self.rename_failure = lambda source, target, exchange: exchange and self.mutations.count("exchange") == 2
        error = self.fails("rollback_failed")
        self.assertEqual(self.signature(Path(error.details["previous"]))["version"], "old")
        self.assertEqual(self.signature(self.target)["version"], "new")
        self.assertTrue(Path(error.details["staging"]).exists())

    def test_process_starts_before_rollback_preserves_both_builds(self):
        self.verify_failure = lambda app: app == self.target and self.signature(app)["version"] == "new"
        self.processes = ["", "", f"733 {self.target}/Contents/MacOS/FrameThrower\n"]
        error = self.fails("rollback_failed")
        self.assertEqual(self.signature(Path(error.details["previous"]))["version"], "old")
        self.assertEqual(self.signature(self.target)["version"], "new")
        self.assertEqual(self.mutations, ["copy", "exchange"])

    def test_target_changed_during_copy_is_not_overwritten(self):
        def change_target(staged):
            (self.target / "Contents/Resources/signature.json").write_text(json.dumps({"version": "changed", "team": "TEAM"}))
        self.copy_hook = change_target
        self.fails("target_changed")
        self.assertEqual(self.signature(self.target)["version"], "changed")
        self.assertEqual(self.mutations, ["copy"])
        self.no_staging()

    def test_different_signed_staged_build_is_refused(self):
        def change_stage(staged):
            (staged / "Contents/Resources/signature.json").write_text(json.dumps({"version": "different", "team": "TEAM"}))
        self.copy_hook = change_stage
        self.fails("staged_build_mismatch")
        self.assertEqual(self.signature(self.target)["version"], "old")
        self.assertEqual(self.mutations, ["copy"])
        self.no_staging()

    def test_atomic_swap_failure_leaves_installed_app_intact(self):
        self.rename_failure = lambda source, target, exchange: exchange
        self.fails("replacement_failed")
        self.assertEqual(self.signature(self.target)["version"], "old")
        self.no_staging()

    def test_interruption_immediately_after_swap_rolls_back(self):
        interrupted = False
        def interrupt_after_exchange(source, target, exchange=False):
            nonlocal interrupted
            self.rename(source, target, exchange)
            if exchange and not interrupted:
                interrupted = True
                raise KeyboardInterrupt()
        self.system.rename = interrupt_after_exchange
        error = self.fails("interrupted")
        self.assertTrue(error.details["rolled_back"])
        self.assertEqual(self.signature(self.target)["version"], "old")
        self.no_staging()

    def test_interruption_after_backup_publish_restores_prior_build(self):
        interrupted = False
        def interrupt_after_backup(source, target, exchange=False):
            nonlocal interrupted
            self.rename(source, target, exchange)
            if not exchange and target.name.startswith(".FrameThrower.previous-") and not interrupted:
                interrupted = True
                raise KeyboardInterrupt()
        self.system.rename = interrupt_after_backup
        error = self.fails("interrupted")
        self.assertTrue(error.details["rolled_back"])
        self.assertEqual(self.signature(self.target)["version"], "old")
        self.assertEqual(self.signature(Path(error.details["rejected_build"]))["version"], "new")
        self.no_staging()

    @unittest.skipUnless(sys.platform == "darwin", "Darwin renamex_np API")
    def test_real_darwin_exchange_and_exclusive_collision(self):
        # These are disposable directories, not app bundles or user paths.
        first, second = self.root / "first", self.root / "second"
        first.mkdir(); second.mkdir()
        (first / "marker").write_text("one")
        (second / "marker").write_text("two")
        installer.atomic_rename(first, second, exchange=True)
        self.assertEqual((first / "marker").read_text(), "two")
        self.assertEqual((second / "marker").read_text(), "one")
        with self.assertRaises(FileExistsError):
            installer.atomic_rename(first, second)
        self.assertEqual((first / "marker").read_text(), "two")
        self.assertEqual((second / "marker").read_text(), "one")
        published = self.root / "published"
        installer.atomic_rename(first, published)
        self.assertFalse(first.exists())
        self.assertEqual((published / "marker").read_text(), "two")

    def test_first_install_uses_exclusive_publication(self):
        shutil.rmtree(self.target)
        result = self.install()
        self.assertIsNone(result["backup"])
        self.assertEqual(self.signature(self.target)["version"], "new")
        self.assertEqual(self.mutations, ["copy", "rename"])
        self.no_staging()


if __name__ == "__main__":
    unittest.main(verbosity=2)
