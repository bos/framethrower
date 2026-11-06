#!/usr/bin/env python3
"""Install an already-built signed app. Never quits, kills, or launches an app."""
import argparse
import ctypes
from dataclasses import dataclass
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import uuid

BUNDLE_ID = "com.example.screencast"
EXECUTABLE = "FrameThrower"


class InstallError(Exception):
    def __init__(self, code, message, **details):
        super().__init__(message)
        self.code, self.details = code, details

    def result(self):
        return {"ok": False, "error": {"code": self.code, "message": str(self), **self.details}}


def execute(arguments):
    return subprocess.run(arguments, capture_output=True, text=True, timeout=120)


def atomic_rename(source, destination, exchange=False):
    """Darwin atomic exchange or exclusive publication; never overwrites by accident."""
    function = ctypes.CDLL(None, use_errno=True).renamex_np
    function.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    # Values from the macOS SDK's sys/stdio.h.
    if function(os.fsencode(source), os.fsencode(destination), 2 if exchange else 4) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


@dataclass(frozen=True)
class Signature:
    team: str
    code_hash: str


class Installer:
    def __init__(self, run=execute, rename=atomic_rename):
        self.run, self.rename = run, rename

    def command(self, arguments, code):
        try:
            result = self.run([str(value) for value in arguments])
        except (OSError, subprocess.SubprocessError) as error:
            raise InstallError(code, f"{Path(arguments[0]).name} could not complete.", reason=str(error)) from error
        if result.returncode:
            raise InstallError(code, f"{Path(arguments[0]).name} failed.", reason=(result.stderr or result.stdout).strip()[-3000:])
        return result.stdout + result.stderr

    def verify(self, app):
        if app.is_symlink() or not app.is_dir():
            raise InstallError("invalid_bundle", "The app must be a regular bundle directory.", path=str(app))
        try:
            with (app / "Contents/Info.plist").open("rb") as source:
                info = plistlib.load(source)
        except (OSError, ValueError, plistlib.InvalidFileException) as error:
            raise InstallError("invalid_bundle", "The app has no readable bundle metadata.", path=str(app)) from error
        if not isinstance(info, dict):
            raise InstallError("invalid_bundle", "The app bundle metadata must be a dictionary.", path=str(app))
        if (info.get("CFBundleIdentifier") != BUNDLE_ID or info.get("CFBundleExecutable") != EXECUTABLE or info.get("CFBundlePackageType") != "APPL"):
            raise InstallError("wrong_bundle", "The app is not the expected FrameThrower bundle.", path=str(app))
        executable = app / "Contents/MacOS" / EXECUTABLE
        if executable.is_symlink() or not executable.is_file() or not os.access(executable, os.X_OK):
            raise InstallError("invalid_bundle", "The app has no regular executable.", path=str(app))
        self.command(["/usr/bin/codesign", "--verify", "--deep", "--strict", app], "invalid_signature")
        details = self.command(["/usr/bin/codesign", "--display", "--verbose=4", app], "invalid_signature")
        fields = dict(re.findall(r"^(Identifier|TeamIdentifier|CDHash)=(.+)$", details, re.M))
        if fields.get("Identifier") != BUNDLE_ID or not fields.get("TeamIdentifier") or fields["TeamIdentifier"] == "not set" or not re.fullmatch(r"[0-9a-fA-F]+", fields.get("CDHash", "")):
            raise InstallError("invalid_signature", "Use a developer-signed FrameThrower build with its bundle identifier.", path=str(app))
        return Signature(fields["TeamIdentifier"], fields["CDHash"])

    def require_stopped(self, target):
        listing = self.command(["/bin/ps", "-ww", "-axo", "pid=,comm="], "process_check_failed")
        running = []
        for line in listing.splitlines():
            fields = line.strip().split(None, 1)
            if len(fields) != 2 or not fields[0].isdigit():
                if line.strip():
                    raise InstallError("process_check_failed", "The process list could not be interpreted.")
                continue
            command = fields[1]
            if Path(command).name == EXECUTABLE or command.startswith(str(target) + "/"):
                running.append(int(fields[0]))
        if running:
            raise InstallError("app_running", "Quit FrameThrower before installing. The installer never quits or launches it.", pids=running)

    @staticmethod
    def identity(path):
        if not os.path.lexists(path):
            return None
        value = path.lstat()
        if not stat.S_ISDIR(value.st_mode):
            raise InstallError("unsafe_target", "The installed app cannot be a symlink or another file type.", path=str(path))
        return value.st_dev, value.st_ino

    def install(self, source, target):
        source, target = Path(source).absolute(), Path(target).absolute()
        if target.name != "FrameThrower.app" or target.parent.is_symlink():
            raise InstallError("unsafe_target", "Use a regular Applications directory and FrameThrower.app destination.", path=str(target))
        if source.resolve() == target.resolve() or source.resolve() in target.resolve().parents or target.resolve() in source.resolve().parents:
            raise InstallError("unsafe_source", "The build and installed app must be separate bundles.")
        old_identity = self.identity(target)
        source_signature = self.verify(source)
        old_signature = self.verify(target) if old_identity else None
        if old_signature and old_signature.team != source_signature.team:
            raise InstallError("signing_team_mismatch", "The build and installed app use different signing teams.")
        self.require_stopped(target)  # All refusal checks above precede any writes.
        target.parent.mkdir(parents=True, exist_ok=True)
        staging = Path(tempfile.mkdtemp(prefix=".FrameThrower.install-", dir=target.parent))
        staged_app = staging / "FrameThrower.app"
        backup = target.parent / (".FrameThrower.previous-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8] + ".app")
        published = False
        preserve_staging = False
        staged_identity = None

        def same_identity(path, expected):
            try:
                return expected is not None and self.identity(path) == expected
            except (InstallError, OSError):
                return False
        try:
            self.command(["/usr/bin/ditto", source, staged_app], "copy_failed")
            if self.verify(staged_app) != source_signature:
                raise InstallError("staged_build_mismatch", "The staged app differs from the verified build.")
            staged_identity = self.identity(staged_app)
            if self.identity(target) != old_identity or (old_signature and self.verify(target) != old_signature):
                raise InstallError("target_changed", "The installed app changed during preparation.")
            self.require_stopped(target)  # Last operation before the atomic rename.
            # Until the syscall's outcome is known, retain any directory that
            # could contain the prior build, including on interruption.
            preserve_staging = old_identity is not None
            self.rename(staged_app, target, exchange=old_identity is not None)
            published = True
            if self.verify(target) != source_signature:
                raise InstallError("installed_build_mismatch", "The replacement differs from the verified staged build.")
            if old_identity:
                self.rename(staged_app, backup)
            preserve_staging = False
            return {"ok": True, "installed": str(target), "backup": str(backup) if old_identity else None}
        except (Exception, KeyboardInterrupt) as error:
            original = error if isinstance(error, InstallError) else InstallError("interrupted" if isinstance(error, KeyboardInterrupt) else "replacement_failed", "The app replacement did not complete.", reason=str(error))
            prior = next((path for path in (staged_app, backup) if same_identity(path, old_identity)), None)
            # Also recover if a callback/syscall completed just before an
            # interruption prevented the Python success flag from being set.
            published = published or same_identity(target, staged_identity) or prior is not None
            if published:
                preserve_staging = True
                try:
                    if not same_identity(target, staged_identity):
                        raise InstallError("target_changed", "The replacement app changed before rollback.")
                    self.require_stopped(target)
                    if old_identity:
                        if prior is None:
                            raise InstallError("missing_prior_build", "The prior build could not be located for rollback.")
                        self.rename(prior, target, exchange=True)
                        if prior == backup:
                            original.details["rejected_build"] = str(backup)
                    else:
                        self.rename(target, staged_app)
                except (Exception, KeyboardInterrupt) as rollback_error:
                    raise InstallError("rollback_failed", "Replacement failed and automatic rollback could not complete; retained bundles for recovery.", previous=str(prior) if prior else None, installed=str(target), staging=str(staging), reason=str(rollback_error), original_error=original.code) from rollback_error
                preserve_staging = False
                original.details["rolled_back"] = True
            elif same_identity(target, old_identity) and same_identity(staged_app, staged_identity):
                preserve_staging = False
            raise original
        finally:
            if not preserve_staging:
                shutil.rmtree(staging, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", nargs="?", type=Path, default=Path(__file__).resolve().parents[1] / "build/Build/Products/Debug/FrameThrower.app")
    args = parser.parse_args()
    try:
        result = Installer().install(args.source, Path.home() / "Applications/FrameThrower.app")
    except InstallError as error:
        print(json.dumps(error.result(), sort_keys=True), file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print(json.dumps(InstallError("interrupted", "The installation was interrupted.").result()), file=sys.stderr)
        return 1
    except OSError as error:
        print(json.dumps(InstallError("filesystem_error", "The installation could not complete.", reason=str(error)).result(), sort_keys=True), file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
