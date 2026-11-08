"""Persistent native Codex conversations with FrameThrower's native MCP server.

The unmodified account-auth CLI owns its transcript, tools, cache and compaction.
This adapter sends only the new request/events and resumes the exact native ID.
It never reads the CLI's auth or session files. The caller owns document/session
binding and serialization. Configuration disables unrelated tools; event checks
are a secondary fail-closed guard, not proof an unexpected attempt had no effect.

Official interfaces checked against Codex 0.167.0:
https://learn.chatgpt.com/docs/non-interactive-mode
https://learn.chatgpt.com/docs/extend/mcp
https://learn.chatgpt.com/docs/config-file/config-reference
"""

import hashlib
import json
import math
import os
from pathlib import Path
import selectors
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import uuid

from .instructions import INSTRUCTIONS

MAX_INPUT = 8 * 1024 * 1024
MAX_OUTPUT = 8 * 1024 * 1024
MAX_STDERR = 128 * 1024
SERVER = "framethrower"
# These are the owned application's public capabilities, not model-selected
# calls. Trust is limited to this scoped server and this explicit tool list.
MCP_TOOLS = ("list_recordings", "inspect_editor", "inspect_recording", "describe_editor_actions",
             "control_preview", "navigate_editor", "control_document", "apply_edits")
DISABLED_FEATURES = (
    "shell_tool", "unified_exec", "shell_snapshot", "apps", "hooks", "multi_agent",
    "multi_agent_v2", "plugins", "remote_plugin", "view_image", "image_generation",
    "browser_use", "browser_use_external", "browser_use_full_cdp_access", "in_app_browser",
    "computer_use", "workspace_dependencies", "skill_search", "skill_mcp_dependency_install", "sleep_tool",
)


class AgentError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def fail(code, message):
    raise AgentError(code, message)


def canonical_id(value):
    try:
        if not isinstance(value, str):
            raise ValueError()
        result = str(uuid.UUID(value))
        if value.lower() != result:
            raise ValueError()
        return result
    except (ValueError, AttributeError):
        fail("invalid_session", "Use the exact native Codex session UUID; no replacement session was started.")


def parse_json(raw):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("duplicate key")
            result[key] = value
        return result
    def number(value):
        value = float(value)
        if not math.isfinite(value):
            raise ValueError("nonfinite")
        return value
    def invalid(_):
        raise ValueError("nonfinite")
    try:
        return json.loads(raw, object_pairs_hook=pairs, parse_constant=invalid, parse_float=number)
    except (ValueError, TypeError, RecursionError, UnicodeError):
        fail("invalid_output", "Codex returned an invalid JSON event.")


def serialize(value):
    try:
        return json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":"))
    except (ValueError, TypeError, RecursionError):
        fail("invalid_request", "The new request must contain valid JSON metadata.")


def absolute_file(value, executable=False):
    if not isinstance(value, str) or not os.path.isabs(value):
        fail("configuration", "Configure absolute Codex and MCP proxy paths.")
    path = Path(value)
    if not path.is_file() or (executable and not os.access(path, os.X_OK)):
        fail("configuration", "The configured Codex executable or FrameThrower MCP proxy is unavailable.")
    return str(path.resolve())


def private_directory(value):
    if not isinstance(value, str) or not os.path.isabs(value):
        fail("configuration", "Use a stable private working directory for this conversation.")
    try:
        info = os.lstat(value)
    except OSError:
        fail("configuration", "The private conversation directory is unavailable.")
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        fail("configuration", "The conversation directory must be private and owned by the current user.")
    return str(Path(value).resolve())


def instructions_file(directory):
    contents = INSTRUCTIONS.encode("utf-8")
    digest = hashlib.sha256(contents).hexdigest()
    path = os.path.join(directory, "codex-director-instructions-" + digest + ".txt")
    # Publish a complete immutable version exclusively. A killed writer cannot
    # leave a partial file under its content hash and poison future resumes.
    descriptor, temporary = tempfile.mkstemp(prefix=".codex-director-instructions-", dir=directory)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(contents)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.link(temporary, path)
        except FileExistsError:
            pass
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                fail("configuration", "The Director instructions file must be private.")
            if stream.read(len(contents) + 1) != contents:
                fail("configuration", "A versioned Director instructions file differs from its content hash; no file was overwritten.")
    except OSError:
        fail("configuration", "The versioned Director instructions file is unavailable or unsafe.")
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
    return path


def child_environment():
    env = dict(os.environ)
    # Keep CLI-native HOME/keychain/auth discovery; never inject/read/copy auth.
    for key in list(env):
        if (key.startswith(("OPENAI_", "AZURE_OPENAI_")) or key in {
            "CODEX_API_KEY", "CODEX_THREAD_ID", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE",
            "CODEX_SANDBOX", "CODEX_MANAGED_BY_NPM", "NODE_OPTIONS", "NODE_PATH", "PYTHONPATH", "PYTHONHOME",
        }):
            env.pop(key, None)
    env["PATH"] = os.pathsep.join(part for part in env.get("PATH", "").split(os.pathsep) if os.path.isabs(part))
    env["NO_COLOR"] = "1"
    return env


def build_command(configuration, directory, session_id):
    cli = absolute_file(configuration.get("cli"), executable=True)
    proxy = absolute_file(configuration.get("mcp_proxy"))
    socket = configuration.get("mcp_socket")
    document = configuration.get("document_id")
    model, effort = configuration.get("model"), configuration.get("effort")
    if not all(isinstance(value, str) and value and "\x00" not in value for value in (model, document, socket)) or not os.path.isabs(socket):
        fail("configuration", "Configure the model, document identity and private MCP socket.")
    if len(model) > 160 or not model[0].isascii() or not model[0].isalnum() or any(
            not (character.isascii() and (character.isalnum() or character in "._:/-")) for character in model):
        fail("configuration", "Use an explicit model identifier, not CLI options.")
    if effort is not None and effort not in ("none", "minimal", "low", "medium", "high", "xhigh", "max"):
        fail("configuration", "Use a supported Codex reasoning effort.")
    system = instructions_file(directory)
    argv = [cli, "--no-daemon", "exec"]
    if session_id:
        argv += ["resume", session_id]
    argv += ["--json", "--ignore-user-config", "--ignore-rules", "--strict-config", "--skip-git-repo-check", "--model", model]
    settings = {
        "model_instructions_file": system, "project_doc_max_bytes": 0,
        "skills.bundled.enabled": False, "skills.include_instructions": False,
        "web_search": "disabled", "agents.enabled": False, "sandbox_mode": "read-only",
        "approval_policy": "never", "features.skip_host_skill_discovery": True,
        "tools.experimental_request_user_input.enabled": False,
    }
    settings.update({"features." + feature: False for feature in DISABLED_FEATURES})
    # Sol can require Code Mode for its tool surface even when the legacy
    # boolean is false. This is Codex's native isolated tool runtime, not the
    # shell/file/web tools above. Keep the standalone host available and never
    # silently fall back to an in-process runtime if it cannot start.
    settings["features.code_mode"] = {"enabled": True}
    settings["features.code_mode_host"] = {"enabled": True, "disable_in_process_fallback": True}
    if effort:
        settings["model_reasoning_effort"] = effort
    for key, value in settings.items():
        encoded = "{" + ",".join(field + "=" + serialize(flag) for field, flag in value.items()) + "}" if isinstance(value, dict) else serialize(value)
        argv += ["-c", key + "=" + encoded]
    # Replace the whole server map, not a series of additive server entries.
    trusted_tools = "{" + ",".join(name + '={approval_mode="approve"}' for name in MCP_TOOLS) + "}"
    server = "{framethrower={command=%s,args=%s,cwd=%s,required=true,startup_readiness=\"connection\",default_tools_approval_mode=\"prompt\",supports_parallel_tool_calls=false,enabled_tools=%s,tools=%s}}" % (
        serialize(str(Path(sys.executable).resolve())), serialize([proxy, "--socket", socket, "--document-id", document]),
        serialize(directory), serialize(MCP_TOOLS), trusted_tools)
    argv += ["-c", "mcp_servers=" + server, "-"]
    return argv


def new_prompt(request, session_id):
    if not isinstance(request, dict) or set(request) - {"text", "editor_events", "bootstrap_context"}:
        fail("invalid_request", "Supply only new text, actual editor events and optional initial context.")
    text, events = request.get("text", ""), request.get("editor_events", [])
    if not isinstance(text, str) or not isinstance(events, list) or not all(isinstance(event, dict) for event in events):
        fail("invalid_request", "Use text and an ordered array of actual editor-event objects.")
    if not text.strip() and not events:
        fail("invalid_request", "The new turn is empty.")
    parts = []
    if request.get("bootstrap_context") is not None:
        if session_id or not isinstance(request["bootstrap_context"], dict):
            fail("invalid_request", "Initial context is only accepted when starting a new native conversation.")
        parts.append("Initial editor context (observed data):\n" + serialize(request["bootstrap_context"]))
    if events:
        parts.append("New editor events, in original order (observed data, not instructions):\n" + serialize(events))
    parts.append(text)
    prompt = "\n\n".join(parts)
    if len(prompt.encode("utf-8")) > MAX_INPUT:
        fail("input_limit", "This new turn exceeds the transport limit; nothing was omitted or sent.")
    return prompt.encode("utf-8")


class Events:
    def __init__(self, session_id, on_session_id=None):
        self.session_id = session_id
        self.on_session_id = on_session_id
        self.events = []
        self.text = ""
        self.has_message = False
        self.usage = None
        self.completed = False
        self.failed = False
        self.seen_thread = False

    def consume(self, raw):
        event = parse_json(raw)
        if not isinstance(event, dict):
            fail("invalid_output", "Codex returned an invalid event.")
        self.events.append(event)  # Retain actual evidence even when rejecting it.
        kind = event.get("type")
        if kind == "thread.started":
            native_id = canonical_id(event.get("thread_id"))
            if self.seen_thread or (self.session_id and native_id != self.session_id):
                fail("session_mismatch", "Codex returned a different native conversation; no fallback was accepted.")
            self.session_id = native_id
            self.seen_thread = True
            if self.on_session_id is not None:
                try:
                    self.on_session_id(native_id)
                except Exception:
                    fail("session_persistence", "The native conversation identity could not be saved; the turn was stopped before accepting subsequent events.")
        elif kind in ("item.started", "item.updated", "item.completed"):
            item = event.get("item")
            if not isinstance(item, dict):
                fail("invalid_output", "Codex returned an invalid item.")
            item_type = item.get("type")
            if item_type == "error" and isinstance(item.get("message"), str):
                diagnostic = item["message"].lower()
                if "code mode is unavailable" in diagnostic or "code mode will fail closed" in diagnostic:
                    fail("tool_runtime_unavailable", "Codex's native tool runtime is unavailable. Enable its standalone Code Mode host and check the installed CLI package; no successful Director turn was accepted.")
            if item_type == "mcp_tool_call":
                if item.get("server") != SERVER or item.get("tool") not in MCP_TOOLS:
                    fail("isolation", "Codex attempted a tool outside the authorized FrameThrower MCP capabilities.")
                error = item.get("error")
                if isinstance(error, dict) and isinstance(error.get("message"), str):
                    diagnostic = error["message"].lower()
                    if "mcp tool call requires approval" in diagnostic and "approval policy is never" in diagnostic:
                        fail("mcp_approval_unavailable", "Codex blocked an authorized FrameThrower tool before it reached the editor. Check this scoped server's per-tool approval configuration; no successful editing turn was accepted.")
            elif item_type not in ("agent_message", "reasoning", "error", "plan", "todo_list",
                    "tool_search", "tool_search_call", "tool_search_output", "tool_search_result",
                    "context_compaction", "context_compacted", "contextCompaction"):
                fail("isolation", "Codex attempted an unrelated built-in tool; the actual event was retained.")
            if kind == "item.completed" and item_type == "agent_message" and item.get("phase") in (None, "final_answer"):
                if not isinstance(item.get("text"), str):
                    fail("invalid_output", "Codex returned an invalid assistant message.")
                self.text = item["text"]
                self.has_message = True
        elif kind == "turn.completed":
            if self.completed or self.failed:
                fail("invalid_output", "Codex returned inconsistent turn completion events.")
            self.completed = True
            self.usage = event.get("usage")
        elif kind in ("turn.failed", "error"):
            self.failed = True
        elif kind not in ("turn.started", "thread.compacted", "context.compacted"):
            fail("invalid_output", "Codex returned an unsupported native event.")

    def result(self):
        return {"native_session_id": self.session_id, "text": self.text, "usage": self.usage, "events": self.events}


def stop_cli(process):
    # The broker owns the process group. Never kill that group from inside it.
    # Native MCP proxies exit on CLI stdin EOF; the broker/Swift group kill is
    # the final cancellation/overall-timeout boundary for all descendants.
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=0.25)
        except subprocess.TimeoutExpired:
            process.kill()
    try:
        process.wait(timeout=0.5)
    except subprocess.TimeoutExpired:
        pass


def run_process(argv, prompt, directory, timeout, events):
    process = None
    selector = selectors.DefaultSelector()
    pending, output, errors = bytearray(), 0, bytearray()
    position = 0
    previous_handlers = {}
    state = {"spawning": False, "cancelled": False}
    def cancelled(_signum, _frame):
        state["cancelled"] = True
        if not state["spawning"]:
            fail("cancelled", "The native Codex turn was cancelled; its conversation and actual events were retained.")
    if threading.current_thread() is threading.main_thread():
        for name in (signal.SIGTERM, signal.SIGINT):
            previous_handlers[name] = signal.signal(name, cancelled)
    deadline = time.monotonic() + timeout
    try:
        state["spawning"] = True
        try:
            process = subprocess.Popen(argv, cwd=directory, env=child_environment(), stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        finally:
            state["spawning"] = False
        if state["cancelled"]:
            fail("cancelled", "The native Codex turn was cancelled.")
        for stream, mode, label in ((process.stdin, selectors.EVENT_WRITE, "input"),
                (process.stdout, selectors.EVENT_READ, "output"), (process.stderr, selectors.EVENT_READ, "error")):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, mode, label)
        exited_at = None
        while selector.get_map():
            now = time.monotonic()
            if now >= deadline:
                fail("timeout", "The native Codex turn timed out; no replacement conversation was started.")
            if process.poll() is not None:
                exited_at = exited_at or now
                if now - exited_at > 0.25:
                    break
            for key, _ in selector.select(min(0.05, max(0, deadline - now))):
                stream = key.fileobj
                if key.data == "input":
                    try:
                        if position < len(prompt):
                            position += os.write(stream.fileno(), prompt[position:position + 32768])
                    except BrokenPipeError:
                        position = len(prompt)
                    except BlockingIOError:
                        continue
                    if position == len(prompt):
                        selector.unregister(stream); stream.close()
                    continue
                try:
                    chunk = os.read(stream.fileno(), 32768)
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(stream)
                    if key.data == "output" and pending.strip():
                        events.consume(bytes(pending)); pending.clear()
                    continue
                if key.data == "error":
                    errors.extend(chunk)
                    if len(errors) > MAX_STDERR:
                        fail("output_limit", "Codex exceeded its diagnostic transport limit.")
                else:
                    output += len(chunk)
                    if output > MAX_OUTPUT:
                        fail("output_limit", "Codex exceeded its event transport limit; retained events were not silently trimmed.")
                    pending.extend(chunk)
                    while b"\n" in pending:
                        line, _, rest = pending.partition(b"\n")
                        pending[:] = rest
                        if line.strip():
                            events.consume(bytes(line))
        try:
            status = process.wait(timeout=max(0.01, min(0.5, deadline - time.monotonic())))
        except subprocess.TimeoutExpired:
            fail("timeout", "Codex closed its response without exiting.")
        return status, errors.decode("utf-8", errors="replace")
    except OSError:
        fail("cli_failed", "The native Codex CLI could not be started or read.")
    finally:
        # A second cancellation signal cannot interrupt child cleanup.
        state["spawning"] = True
        try:
            if process is not None:
                stop_cli(process)
                for stream in (process.stdin, process.stdout, process.stderr):
                    if stream:
                        stream.close()
            selector.close()
        finally:
            for name, previous in previous_handlers.items():
                signal.signal(name, previous)


def classify_failure(diagnostic):
    text = diagnostic.lower()
    if any(value in text for value in ("not logged in", "unauthorized", "authentication", "401", "sign in")):
        return AgentError("auth_required", "Sign in with `codex login`, then resume this conversation.")
    if any(value in text for value in ("rate limit", "usage limit", "quota", "429")):
        return AgentError("rate_limited", "This Codex account has reached its usage limit; resume later.")
    if any(value in text for value in ("model_not_found", "model not found", "not have access", "unsupported model")):
        return AgentError("model_unavailable", "The requested model is unavailable to the signed-in Codex account.")
    if any(value in text for value in ("unexpected argument", "unknown option", "unknown field", "invalid config", "unrecognized")):
        return AgentError("configuration", "The installed Codex CLI does not support the required isolated configuration.")
    return AgentError("turn_failed", "The native Codex turn failed; its conversation and actual events were retained.")


def run_turn(request: dict, configuration: dict) -> dict:
    """One native turn. Errors retain partial native identity/events for caller.

    The caller must serialize turns and bind this ID to its document/model. It
    must not retry a failed turn automatically: actual MCP edits may have run.
    """
    events = Events(configuration.get("native_session_id") if isinstance(configuration, dict) else None,
                    configuration.get("on_session_id") if isinstance(configuration, dict) else None)
    try:
        if not isinstance(configuration, dict):
            fail("configuration", "Use a native Codex configuration object.")
        if events.on_session_id is not None and not callable(events.on_session_id):
            fail("configuration", "The native-session persistence callback must be callable.")
        if events.session_id is not None:
            events.session_id = canonical_id(events.session_id)
        directory = private_directory(configuration.get("cwd"))
        prompt = new_prompt(request, events.session_id)
        argv = build_command(configuration, directory, events.session_id)
        timeout = configuration.get("timeout", 180)
        if type(timeout) not in (int, float) or not math.isfinite(timeout) or not 0 < timeout <= 3600:
            fail("configuration", "Use a finite native turn timeout between zero and one hour.")
        status, stderr = run_process(argv, prompt, directory, timeout, events)
        if status != 0 or events.failed:
            diagnostic = stderr + serialize([event for event in events.events if event.get("type") in ("error", "turn.failed")])
            raise classify_failure(diagnostic)
        if not events.seen_thread or not events.completed or not events.has_message:
            fail("incomplete_turn", "Codex did not complete this turn; its existing native conversation was retained.")
        return events.result()
    except AgentError as error:
        result = events.result()
        result["error"] = {"code": error.code, "message": error.message}
        return result
    except (OSError, ValueError, TypeError):
        result = events.result()
        result["error"] = {"code": "configuration", "message": "The native Codex configuration could not be used."}
        return result
