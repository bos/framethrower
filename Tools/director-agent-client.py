#!/usr/bin/env python3
"""Resume a provider-owned Director conversation, using native MCP tools.

Only the new user turn and actual editor events cross this boundary. Native
agents own history, tool loops, caching and compaction. Binding metadata stores
an opaque native session ID, never a reconstructed conversation.
"""
import fcntl
import importlib
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile

FAMILIES = {"claude", "codex", "qwen"}


def private_directory(path):
    directory = Path(path)
    if not directory.is_absolute():
        raise ValueError("The conversation directory must be absolute.")
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    attrs = directory.lstat()
    if not stat.S_ISDIR(attrs.st_mode) or attrs.st_uid != os.getuid() or stat.S_IMODE(attrs.st_mode) != 0o700:
        raise ValueError("The conversation directory must be owned, private and not a symlink.")
    return directory


def atomic_json(path, value):
    descriptor, temporary = tempfile.mkstemp(prefix=".binding-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as output:
            json.dump(value, output, separators=(",", ":")); output.flush(); os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)


def run(payload):
    request, configuration = dict(payload["request"]), dict(payload["configuration"])
    document = request.pop("document_id", None)
    if document is not None and document != configuration.get("document_id"):
        raise ValueError("The turn and native MCP document scopes differ.")
    recording = request.pop("recording_id", configuration.get("recording_id"))
    if not isinstance(recording, str) or not recording or recording != configuration.get("recording_id"):
        raise ValueError("The native conversation requires the recording's persistent identity.")
    family = configuration.pop("provider")
    if family not in FAMILIES: raise ValueError("Unknown native Director provider.")
    directory = private_directory(configuration["cwd"])
    lock_fd = os.open(directory / "session.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(lock_fd)
        return {"ok": False, "error": {"code": "busy", "message": "This native conversation is still finishing another turn."}}
    try:
        binding_path = directory / "binding.json"
        binding = {}
        if binding_path.exists():
            info = binding_path.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid(): raise ValueError("Unsafe conversation binding.")
            binding = json.loads(binding_path.read_text())
            if binding.get("provider") != family:
                raise ValueError("The native session binding belongs to a different provider.")
            if binding.get("recording_id") != recording:
                raise ValueError("The native session binding belongs to a different recording.")
        configuration["native_session_id"] = binding.get("native_session_id")
        if configuration["native_session_id"]:
            request.pop("bootstrap_context", None)
        def remember(identity):
            if not isinstance(identity, str) or not identity or len(identity) > 256 or any(ord(c) < 32 for c in identity):
                raise ValueError("The agent returned an invalid native session identity.")
            previous = binding.get("native_session_id")
            if previous is not None and previous != identity:
                raise ValueError("The agent changed its native session identity; no fresh-session fallback is allowed.")
            binding.update(provider=family, model=configuration["model"], native_session_id=identity, recording_id=recording)
            atomic_json(binding_path, binding)
        configuration["on_session_id"] = remember
        if not configuration.get("cli"):
            cli = shutil.which({"claude": "claude", "codex": "codex", "qwen": "qwen"}[family])
            if not cli: raise ValueError("Install the selected provider's native agent CLI before using it in Director.")
            configuration["cli"] = cli
        module = importlib.import_module("DirectorAgents." + family)
        result = module.run_turn(request, configuration)
        identity = result.get("native_session_id")
        if identity:
            try:
                remember(identity)
            except Exception as error:
                # The native turn may already have performed real edits. Keep
                # its identity, events and text even if binding storage fails.
                previous_error = result.get("error")
                result["error"] = {"code": "session_persistence", "message":
                    "Could not save the native conversation binding. Check the editor before retrying: " + str(error)}
                if previous_error: result["error"]["native_error"] = previous_error
        result["ok"] = not bool(result.get("error"))
        return result
    finally:
        os.close(lock_fd)


def main():
    # The provider and its MCP children share this owned process group, so
    # cancellation never signals the GUI or an unrelated native agent session.
    try: os.setsid()
    except PermissionError:
        if os.getpgrp() != os.getpid(): raise RuntimeError("Cannot isolate the native agent process group.")
    try:
        payload = json.load(sys.stdin)
        result = run(payload)
    except Exception as error:
        result = {"ok": False, "error": {"code": "native_agent_failed", "message": str(error)}}
    json.dump(result, sys.stdout, separators=(",", ":")); sys.stdout.write("\n"); sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
