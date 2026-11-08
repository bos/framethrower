"""Pinned official Qwen Code native-session adapter (0.27.0).

Qwen owns transcript persistence, tool execution, cache reuse and compaction.
Only the new user turn and actual application events enter stdin. No app history
selection, synthetic tool loop or fallback conversation is implemented here.
"""
import json
import os
from pathlib import Path
import selectors
import stat
import subprocess
import sys
import threading
import time
from urllib.parse import urlsplit
import uuid

from .claude import DIRECTOR_INSTRUCTIONS

CLI_VERSION = "0.27.0"
CLI_COMMIT = "03b0c2435be1890a21b117860eaf389076787275"
TOOLS = ("list_recordings", "inspect_editor", "inspect_recording",
         "describe_editor_actions", "control_preview", "navigate_editor",
         "control_document", "apply_edits")
# Complete ToolNames registry from the pinned release, not an approval list.
# --allowed-tools alone does not remove Qwen's filesystem/shell/media tools.
EXCLUDED_TOOLS = (
    'exec',
    'edit',
    'write_file',
    'read_file',
    'zoom_image',
    'grep_search',
    'glob',
    'run_shell_command',
    'todo_write',
    'save_memory',
    'manage_memory',
    'search_memory',
    'agent',
    'skill',
    'exit_plan_mode',
    'enter_plan_mode',
    'web_fetch',
    'web_search',
    'image_gen',
    'list_directory',
    'lsp',
    'ask_user_question',
    'cron_create',
    'cron_list',
    'cron_delete',
    'autofix_pr',
    'loop_wakeup',
    'create_sub_session',
    'list_agents',
    'task_stop',
    'task_create',
    'task_update',
    'task_list',
    'team_create',
    'team_delete',
    'team_plan_approval',
    'request_shutdown',
    'send_message',
    'structured_output',
    'monitor',
    'notebook_edit',
    'tool_call',
    'tool_search',
    'read_mcp_resource',
    'advisor',
    'enter_worktree',
    'exit_worktree',
    'workflow',
    'artifact',
    'record_artifact',
    'record_source',
    'report_findings',
    'get_goal',
    'update_goal',
    'omni_downsample_image',
    'omni_downscale_video',
    'omni_downsample_audio',
    'omni_extract_keyframes',
    'omni_extract_audio',
    'omni_clip_video',
    'omni_convert_image',
    'omni_transcribe_audio',
    'omni_clip_image',
    'omni_clip_audio',
    'omni_caption_image',
    'omni_caption_audio',
    'omni_ocr_image',
    'omni_understand_video_segments',
    'omni_recall_media_memory',
    'propose_goal',
    'display_image',
)


class AdapterError(ValueError):
    pass


def _file(value, name, executable=False):
    if not isinstance(value, str) or not Path(value).is_absolute():
        raise AdapterError(f"{name} must be an absolute path.")
    if not Path(value).is_file() or (executable and not os.access(value, os.X_OK)):
        raise AdapterError(f"{name} is unavailable.")
    return value


def _setup(configuration):
    cli = _file(configuration.get("cli"), "Qwen Code CLI", True)
    proxy = _file(configuration.get("mcp_proxy"), "FrameThrower MCP proxy")
    cwd = configuration.get("cwd")
    if not isinstance(cwd, str) or not Path(cwd).is_absolute() or not Path(cwd).is_dir():
        raise AdapterError("The stable private conversation directory is unavailable.")
    socket, document = configuration.get("mcp_socket"), configuration.get("document_id")
    if not isinstance(socket, str) or not Path(socket).is_absolute() or not isinstance(document, str) or not document:
        raise AdapterError("An absolute FrameThrower socket and document scope are required.")
    base = configuration.get("base_url")
    try:
        url = urlsplit(base)
        valid = (url.scheme == "http" and url.hostname == "127.0.0.1" and
                 url.port is not None and 0 < url.port < 65536 and url.path == "/v1" and
                 not url.username and not url.password and not url.query and not url.fragment)
    except (ValueError, TypeError):
        valid = False
    if not valid:
        raise AdapterError("Qwen requires the authenticated local model endpoint on this Mac.")
    token, model = configuration.get("local_token"), configuration.get("model")
    if not isinstance(token, str) or not token or any(c in token for c in "\r\n"):
        raise AdapterError("The local model endpoint token is unavailable.")
    if not isinstance(model, str) or not model or model.startswith("-"):
        raise AdapterError("The local model alias is unavailable.")
    context = configuration.get("context_window_size")
    if type(context) is not int or context < 32768:
        raise AdapterError("Qwen Code requires an actual local context of at least 32,768 tokens for its native estimator safety reserve.")
    if configuration.get("effort") not in (None, "none", "off"):
        raise AdapterError("The verified local model runs with reasoning disabled.")
    home = Path(cwd) / "qwen-home"
    home.mkdir(mode=0o700, exist_ok=True)
    attributes = home.lstat()
    if not stat.S_ISDIR(attributes.st_mode) or attributes.st_uid != os.getuid() or stat.S_IMODE(attributes.st_mode) != 0o700:
        raise AdapterError("The private Qwen configuration directory is unsafe.")
    settings = {
        "$version": 4,
        "general": {"enableAutoUpdate": False},
        "telemetry": {"enabled": False, "logPrompts": False},
        "security": {"auth": {"selectedType": "openai"}},
        "model": {"name": model, "baseUrl": base, "reasoningEffort": "none"},
        "modelProviders": {"openai": [{"id": model, "name": "FrameThrower local",
            "baseUrl": base, "envKey": "OPENAI_API_KEY",
            "capabilities": {"reasoning": {"profile": "qwen-chat-template"}},
            "generationConfig": {"contextWindowSize": context,
                "samplingParams": {"max_tokens": min(4096, context // 4)},
                "extra_body": {"chat_template_kwargs": {"enable_thinking": False}}}}]}}
    # This directory belongs to the broker's serialized conversation. Never
    # modify the user's Qwen configuration or authentication files.
    for name, value in (("settings.json", settings), ("system.json", {}), ("defaults.json", {})):
        target = home / name
        descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "w") as output:
            os.fchmod(output.fileno(), 0o600)
            json.dump(value, output)
    env = {key: value for key, value in os.environ.items() if not (
        key.startswith(("QWEN_", "OPENAI_", "ANTHROPIC_", "GEMINI_", "GOOGLE_", "DASHSCOPE_", "AWS_", "OTEL_"))
        or key.upper().endswith("_PROXY") or key in ("NODE_OPTIONS", "NODE_PATH"))}
    env.update(QWEN_HOME=str(home), QWEN_RUNTIME_DIR=str(home / "runtime"),
               QWEN_CODE_SYSTEM_SETTINGS_PATH=str(home / "system.json"),
               QWEN_CODE_SYSTEM_DEFAULTS_PATH=str(home / "defaults.json"),
               OPENAI_API_KEY=token, QWEN_CODE_DISABLE_PRECONNECT="1", DO_NOT_TRACK="1", NO_COLOR="1")
    mcp = {"mcpServers": {"framethrower": {"command": sys.executable,
        "args": [proxy, "--socket", socket, "--document-id", document],
        "includeTools": list(TOOLS), "trust": True}}}
    args = [cli, "--safe-mode", "--chat-recording=true", "--output-format", "stream-json",
            "--input-format", "text", "--auth-type", "openai", "--model", model,
            "--openai-base-url", base, "--system-prompt", DIRECTOR_INSTRUCTIONS,
            "--mcp-config", json.dumps(mcp), "--exclude-tools", *EXCLUDED_TOOLS,
            "--allowed-tools", *("mcp__framethrower__" + tool for tool in TOOLS)]
    return args, env, cwd


def _prompt(request, resumed):
    if not isinstance(request, dict) or set(request) - {"text", "editor_events", "bootstrap_context"}:
        raise AdapterError("Send only the new user message, actual editor events and optional bootstrap context.")
    text = request.get("text")
    if not isinstance(text, str) or not text.strip():
        raise AdapterError("A user message is required.")
    events = request.get("editor_events", [])
    bootstrap = request.get("bootstrap_context")
    if not isinstance(events, list) or any(not isinstance(event, dict) for event in events):
        raise AdapterError("Editor events must be actual JSON objects in chronological order.")
    if bootstrap is not None and not isinstance(bootstrap, dict):
        raise AdapterError("Bootstrap context must be an object.")
    data = {"editor_events": events} if events else {}
    if not resumed and bootstrap is not None:
        data["bootstrap_context"] = bootstrap
    if data:
        text += "\n\n<framethrower_application_data>\n" + json.dumps(data, ensure_ascii=False, allow_nan=False) + "\n</framethrower_application_data>"
    return text


def _run(args, env, cwd, prompt, timeout, consume):
    process = subprocess.Popen(args, cwd=cwd, env=env, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    writer_errors = []
    def write():
        try:
            process.stdin.write(prompt.encode("utf-8")); process.stdin.close()
        except (OSError, ValueError) as error:
            writer_errors.append(error)
    threading.Thread(target=write, daemon=True).start()
    deadline = time.monotonic() + timeout
    stderr, pending, total = bytearray(), bytearray(), 0
    selector = selectors.DefaultSelector()
    for stream in (process.stdout, process.stderr):
        os.set_blocking(stream.fileno(), False)
        selector.register(stream, selectors.EVENT_READ)
    try:
        while selector.get_map() or process.poll() is None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AdapterError("Qwen Code did not finish before the turn deadline.")
            for key, _ in selector.select(min(remaining, 0.1)):
                block = os.read(key.fileobj.fileno(), 65536)
                if not block:
                    selector.unregister(key.fileobj); continue
                total += len(block)
                if total > 32 * 1024 * 1024:
                    raise AdapterError("Qwen Code exceeded the turn output limit; the native conversation was retained.")
                if key.fileobj is process.stderr:
                    stderr.extend(block)
                else:
                    pending.extend(block)
                    while b"\n" in pending:
                        line, _, rest = pending.partition(b"\n"); pending = bytearray(rest)
                        if line.strip(): consume(json.loads(line))
        if pending.strip(): consume(json.loads(pending))
        if process.returncode:
            # Never echo potentially secret-bearing CLI stderr.
            raise AdapterError(f"Qwen Code exited unsuccessfully ({process.returncode}); its native conversation was retained.")
        if writer_errors: raise AdapterError("Qwen Code did not accept the complete new message.")
    finally:
        selector.close()
        if process.poll() is None:
            process.terminate()
            try: process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                process.kill()
                try: process.wait(timeout=1)
                except subprocess.TimeoutExpired: pass
        for stream in (process.stdin, process.stdout, process.stderr):
            try: stream.close()
            except OSError: pass


def run_turn(request: dict, configuration: dict) -> dict:
    native = configuration.get("native_session_id")
    result = {"native_session_id": native, "text": "", "usage": {}, "events": []}
    try:
        resumed = native is not None
        if resumed:
            if not isinstance(native, str) or str(uuid.UUID(native)) != native.lower():
                raise AdapterError("The native Qwen session identity is invalid.")
        args, env, cwd = _setup(configuration)
        prompt = _prompt(request, resumed)
        if not resumed:
            native = str(uuid.uuid4()); result["native_session_id"] = native
        callback = configuration.get("on_session_id")
        if callback is not None: callback(native)
        args.extend(["--resume" if resumed else "--session-id", native])
        final = None
        def consume(event):
            nonlocal final
            if not isinstance(event, dict): raise AdapterError("Qwen Code emitted a non-object event.")
            result["events"].append(event)
            if "session_id" in event and event["session_id"] != native:
                raise AdapterError("Qwen Code emitted a different native session identity.")
            if event.get("type") == "system" and event.get("subtype") == "init":
                allowed = {"mcp__framethrower__" + tool for tool in TOOLS}
                if event.get("qwen_code_version") != CLI_VERSION or set(event.get("tools", [])) != allowed:
                    raise AdapterError("The installed Qwen runtime or tool catalog differs from the verified release.")
            if event.get("type") == "assistant":
                for block in event.get("message", {}).get("content", []):
                    if block.get("type") == "tool_use" and block.get("name") not in {"mcp__framethrower__" + tool for tool in TOOLS}:
                        raise AdapterError("Qwen Code requested a tool outside the FrameThrower catalog.")
            if event.get("type") == "control_request":
                raise AdapterError("Qwen Code requested an unexpected permission decision.")
            if event.get("type") == "result":
                if final is not None: raise AdapterError("Qwen Code emitted multiple final results.")
                final = event
                result["usage"] = event.get("usage", {})
                if isinstance(event.get("result"), str): result["text"] = event["result"]
        timeout = configuration.get("timeout_seconds", configuration.get("timeout", 180))
        if type(timeout) not in (int, float) or not 0 < timeout <= 3600:
            raise AdapterError("Invalid Qwen turn deadline.")
        _run(args, env, cwd, prompt, timeout, consume)
        if final is None or final.get("is_error") is not False or final.get("subtype") != "success":
            raise AdapterError("Qwen Code did not complete the turn successfully; resume the retained native conversation.")
    except Exception as error:
        token = configuration.get("local_token")
        message = str(error)
        if isinstance(token, str) and token: message = message.replace(token, "[local token]")
        result["error"] = {"code": "qwen_native_turn_failed", "message": message}
    return result
