"""Native Claude Code conversation adapter.

The official CLI owns authentication, transcripts, cache reuse, compaction and
its MCP tool loop. A turn launches/resumes that conversation; no app-selected
history, command schema, structured-output shim, or model context limit is sent.
Managed Claude policy still applies, including policy this adapter cannot relax.
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import uuid


from .instructions import INSTRUCTIONS as DIRECTOR_INSTRUCTIONS


class ConfigurationError(ValueError):
    pass


def _absolute_file(value, label, executable=False):
    if not isinstance(value, str) or not Path(value).is_absolute():
        raise ConfigurationError(f"{label} must be an absolute path.")
    path = Path(value)
    if not path.is_file() or (executable and not os.access(path, os.X_OK)):
        raise ConfigurationError(f"{label} is unavailable.")
    return str(path)


def _configuration(configuration):
    cli = _absolute_file(configuration.get("cli"), "Claude CLI", executable=True)
    proxy = _absolute_file(configuration.get("mcp_proxy"), "FrameThrower MCP proxy")
    cwd = configuration.get("cwd")
    if not isinstance(cwd, str) or not Path(cwd).is_absolute() or not Path(cwd).is_dir():
        raise ConfigurationError("The stable private conversation directory is unavailable.")
    socket = configuration.get("mcp_socket")
    document = configuration.get("document_id")
    if not isinstance(socket, str) or "\0" in socket or not Path(socket).is_absolute():
        raise ConfigurationError("The FrameThrower socket must be an absolute path.")
    if not isinstance(document, str) or not document or "\0" in document:
        raise ConfigurationError("A document scope is required.")
    model = configuration.get("model")
    if not isinstance(model, str) or not model or model.startswith("-") or "\0" in model:
        raise ConfigurationError("A Claude model is required.")
    effort = configuration.get("effort")
    if effort not in (None, "low", "medium", "high", "xhigh", "max"):
        raise ConfigurationError("Unsupported Claude effort level.")
    callback = configuration.get("on_session_id")
    if callback is not None and not callable(callback):
        raise ConfigurationError("The native session callback must be callable.")
    return cli, proxy, cwd, socket, document, model, effort


def _prompt(request, resumed):
    if not isinstance(request, dict) or set(request) - {"text", "editor_events", "bootstrap_context"}:
        raise ConfigurationError("A native turn accepts only text, editor_events and bootstrap_context.")
    text = request.get("text")
    if not isinstance(text, str) or not text.strip():
        raise ConfigurationError("A user message is required.")
    events = request.get("editor_events", [])
    if not isinstance(events, list) or any(not isinstance(event, dict) for event in events):
        raise ConfigurationError("Editor events must be actual JSON objects in chronological order.")
    bootstrap = request.get("bootstrap_context")
    if bootstrap is not None and not isinstance(bootstrap, dict):
        raise ConfigurationError("Bootstrap context must be a JSON object.")
    # Only newly observed data accompanies this user turn. In particular, never
    # serialize the application's conversation archive back into Claude.
    data = {}
    if events:
        data["editor_events"] = events
    if not resumed and bootstrap is not None:
        data["bootstrap_context"] = bootstrap
    if not data:
        return text
    return text + "\n\n<framethrower_application_data>\n" + json.dumps(
        data, ensure_ascii=False, allow_nan=False, separators=(",", ":")
    ) + "\n</framethrower_application_data>"


def _error(result, code, message):
    result["error"] = {"code": code, "message": message}
    return result


def _stream(process, prompt):
    """Yield native events immediately; avoid pipe deadlocks on either stream."""
    stderr = bytearray()
    writer_errors = []

    def write():
        try:
            process.stdin.write(prompt.encode("utf-8"))
            process.stdin.close()
        except (BrokenPipeError, OSError) as error:
            writer_errors.append(error)

    def drain():
        while True:
            data = process.stderr.read(65536)
            if not data:
                return
            stderr.extend(data)

    writer = threading.Thread(target=write, daemon=True)
    reader = threading.Thread(target=drain, daemon=True)
    writer.start(); reader.start()
    try:
        for line in process.stdout:
            yield line
    finally:
        process.wait()
        writer.join(); reader.join()
        process.stdout.close(); process.stderr.close()
        if not process.stdin.closed:
            process.stdin.close()
        process.director_stderr = bytes(stderr)
        process.director_writer_errors = writer_errors


def run_turn(request: dict, configuration: dict) -> dict:
    """Run one native turn, retaining its identity and actual events on failure.

    The broker owns stable directories, session bindings, exclusive per-session
    locking and cancellation. The child deliberately inherits its process group
    so cancelling the broker can also terminate this CLI and its MCP proxy.
    """
    native_id = configuration.get("native_session_id")
    result = {"native_session_id": native_id, "text": "", "usage": {}, "events": []}
    try:
        resumed = native_id is not None
        if resumed:
            try:
                valid_session = isinstance(native_id, str) and str(uuid.UUID(native_id)) == native_id.lower()
            except ValueError:
                valid_session = False
            if not valid_session:
                raise ConfigurationError("The native Claude session ID is invalid.")
        cli, proxy, cwd, socket, document, model, effort = _configuration(configuration)
        prompt = _prompt(request, resumed)
        prompt.encode("utf-8")
        if not resumed:
            # Invalid input/configuration must not reserve a nonexistent
            # conversation. Publish only after complete prelaunch validation.
            native_id = str(uuid.uuid4())
            result["native_session_id"] = native_id
        mcp = {"mcpServers": {"framethrower": {
            "type": "stdio", "command": sys.executable,
            "args": [proxy, "--socket", socket, "--document-id", document]
        }}}
        settings = {"disableAllHooks": True, "disableClaudeAiConnectors": True,
                    "claudeMdExcludes": ["/**"], "disableSkillShellExecution": True}
        args = [cli, "-p", "--output-format", "stream-json", "--verbose",
                "--restricted", "--setting-sources", "", "--settings", json.dumps(settings),
                "--tools", "", "--no-chrome", "--strict-mcp-config", "--mcp-config", json.dumps(mcp),
                "--permission-mode", "dontAsk", "--permission-prompts", "none",
                "--allowedTools", "mcp__framethrower", "--model", model,
                "--append-system-prompt", DIRECTOR_INSTRUCTIONS,
                "--resume" if resumed else "--session-id", native_id]
        if effort is not None:
            args.extend(["--effort", effort])
        environment = os.environ.copy()
        # Account login stays inside the official CLI. Do not accidentally use
        # an inherited API key/provider override instead, and never read tokens.
        for key in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
                    "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
                    "CLAUDE_CODE_SIMPLE", "CLAUDE_CODE_SAFE_MODE"):
            environment.pop(key, None)
        callback = configuration.get("on_session_id")
        if callback is not None:
            # The CLI accepts our UUID as its native identity. Publish it
            # durably before the child can run any MCP action, even if startup
            # is later cancelled before its transcript exists.
            try:
                callback(native_id)
            except Exception as error:
                return _error(result, "session_binding", str(error))
        process = subprocess.Popen(args, cwd=cwd, env=environment, stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        completed = None
        init_seen = False
        protocol_error = None
        for line in _stream(process, prompt):
            if not line.strip():
                continue
            try:
                event = json.loads(line)
                if not isinstance(event, dict):
                    raise ValueError("Expected a native event object.")
            except (ValueError, UnicodeDecodeError):
                protocol_error = "Claude emitted invalid stream JSON. Its native transcript has not been reset."
                continue
            result["events"].append(event)
            event_id = event.get("session_id")
            if event_id is not None and (not isinstance(event_id, str) or event_id.lower() != native_id.lower()):
                protocol_error = "Claude reported a different native conversation. No new conversation was substituted."
            if event.get("type") == "system" and event.get("subtype") == "init":
                init_seen = True
                if event_id is None:
                    protocol_error = "Claude did not confirm the reserved native conversation ID."
                servers = event.get("mcp_servers", [])
                if (not isinstance(servers, list) or any(not isinstance(server, dict) for server in servers) or
                    event.get("mcp_server_errors") or
                    not any(server.get("name") == "framethrower" and server.get("status") == "connected" for server in servers) or
                    any(server.get("name") != "framethrower" for server in servers)):
                    protocol_error = "Claude could not connect exclusively to the FrameThrower MCP server."
            if event.get("type") == "assistant":
                message = event.get("message", {})
                content = message.get("content", []) if isinstance(message, dict) else None
                if not isinstance(content, list) or any(not isinstance(block, dict) for block in content):
                    protocol_error = "Claude emitted an invalid native assistant message. Its session is retained."
                    continue
                for block in content:
                    name = block.get("name")
                    if block.get("type") == "tool_use" and (not isinstance(name, str) or (
                            name != "ToolSearch" and not name.startswith("mcp__framethrower__"))):
                        protocol_error = "Claude attempted a tool outside the configured FrameThrower server."
            if event.get("type") == "result":
                completed = event
                if isinstance(event.get("result"), str):
                    result["text"] = event["result"]
                result["usage"] = {key: event[key] for key in (
                    "usage", "modelUsage", "total_cost_usd", "duration_ms", "duration_api_ms", "num_turns"
                ) if key in event}
        if protocol_error:
            return _error(result, "native_protocol", protocol_error)
        if process.returncode != 0 or (completed is not None and (
                completed.get("is_error") or completed.get("subtype") != "success")):
            errors = completed.get("errors") if completed is not None else None
            message = "\n".join(str(item) for item in errors) if isinstance(errors, list) else result["text"]
            return _error(result, "native_turn_failed", message or process.director_stderr.decode("utf-8", errors="replace").strip() or "Claude could not complete this turn.")
        if not init_seen or completed is None:
            return _error(result, "incomplete_turn", "Claude ended before reporting a complete native turn. The existing session is retained.")
        if process.director_writer_errors:
            return _error(result, "native_transport", "Claude stopped reading the user message before it was delivered completely. Its actual native events and session are retained.")
        return result
    except (ConfigurationError, OSError, ValueError, TypeError) as error:
        return _error(result, "configuration" if isinstance(error, ConfigurationError) else "native_transport", str(error))
