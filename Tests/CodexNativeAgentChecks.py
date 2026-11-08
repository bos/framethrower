"""Offline native-session/MCP adapter checks; fake CLI, no inference or media."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "Tools/DirectorAgents/codex.py"
spec = importlib.util.spec_from_file_location("director_native_codex", MODULE)
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)
SESSION = "00000000-0000-4000-8000-000000000001"
OTHER = "00000000-0000-4000-8000-000000000002"
FAKE = r'''#!PYTHON
import json, os, pathlib, signal, subprocess, sys, time
cwd = pathlib.Path.cwd()
settings = json.loads((cwd/'fake.json').read_text())
prompt = sys.stdin.read()
with (cwd/'requests.jsonl').open('a') as f:
    f.write(json.dumps({'argv':sys.argv[1:],'prompt':prompt,'cwd':str(cwd),'pgid':os.getpgrp(),'env':{k:os.environ.get(k) for k in ['CODEX_HOME','CODEX_API_KEY','OPENAI_API_KEY']}})+'\n')
for event in settings.get('events', []):
    print(json.dumps(event), flush=True)
if settings.get('hang'):
    (cwd/'pid').write_text(str(os.getpid()))
    def terminated(*_):
        (cwd/'term-marker').write_text('graceful')
        sys.exit(0)
    signal.signal(signal.SIGTERM, terminated)
    child=subprocess.Popen([sys.executable,'-c','import sys; sys.stdin.buffer.read()'],stdin=subprocess.PIPE)
    (cwd/'child-pid').write_text(str(child.pid))
    (cwd/'ready').write_text('ready')
    while True: time.sleep(.02)
if settings.get('raw'): sys.stdout.write(settings['raw']); sys.stdout.flush()
if settings.get('stderr'): sys.stderr.write(settings['stderr'])
sys.exit(settings.get('exit',0))
'''.replace("PYTHON", sys.executable)


def native_events(text="Done.", session=SESSION):
    return [{"type": "thread.started", "thread_id": session}, {"type": "turn.started"},
        {"type": "item.completed", "item": {"id": "answer", "type": "agent_message", "text": text}},
        {"type": "turn.completed", "usage": {"input_tokens": 12, "cached_input_tokens": 8, "output_tokens": 3}}]


class NativeCodexChecks(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix="framethrower-native-codex-")
        self.cwd = Path(self.folder.name)
        self.cli = self.cwd / "fake-codex"
        self.cli.write_text(FAKE)
        self.cli.chmod(0o700)
        self.proxy = self.cwd / "proxy.py"
        self.proxy.write_text("# mock native MCP proxy\n")
        self.config = dict(cli=str(self.cli), model="gpt-6.1-sol", effort="medium", cwd=str(self.cwd),
            native_session_id=None, mcp_proxy=str(self.proxy), mcp_socket=str(self.cwd / "host.sock"), document_id="doc-original", timeout=3)
        self.configure(events=native_events())
    def tearDown(self):
        self.folder.cleanup()
    def configure(self, **value):
        (self.cwd / "fake.json").write_text(json.dumps(value))
    def run_turn(self, text="A new instruction", **request):
        return agent.run_turn(dict(text=text, editor_events=[], **request), self.config)
    def captured(self):
        return [json.loads(line) for line in (self.cwd / "requests.jsonl").read_text().splitlines()]
    def test_start_then_exact_resume_native_history_not_replayed(self):
        first = self.run_turn("Remember this rare phrase 17.", bootstrap_context={"document_id": "doc-original", "revision": "r1"})
        self.assertNotIn("error", first)
        self.assertEqual(first["native_session_id"], SESSION)
        self.config["native_session_id"] = first["native_session_id"]
        second = agent.run_turn({"text": "Use what I just told you.", "editor_events": [
            {"kind": "manual", "revision": "r2", "changes": ["Pointer size"]}, {"kind": "undo", "revision": "r3"}]}, self.config)
        self.assertNotIn("error", second)
        calls = self.captured()
        self.assertNotIn("resume", calls[0]["argv"])
        self.assertEqual(calls[1]["argv"][:4], ["--no-daemon", "exec", "resume", SESSION])
        self.assertNotIn("rare phrase", calls[1]["prompt"])
        self.assertNotIn('"revision":"r1"', calls[1]["prompt"])
        self.assertLess(calls[1]["prompt"].index('"revision":"r2"'), calls[1]["prompt"].index('"revision":"r3"'))
        self.assertTrue(calls[1]["prompt"].endswith("Use what I just told you."))
        for call in calls:
            self.assertFalse(set(call["argv"]) & {"--ephemeral", "--last", "--output-schema", "--json-schema"})
            self.assertIn("--ignore-user-config", call["argv"])
            self.assertIn("--ignore-rules", call["argv"])
            self.assertIn("--strict-config", call["argv"])
        self.assertEqual(second["usage"]["cached_input_tokens"], 8)
    def test_multiple_actual_mcp_calls_and_natural_prose_preserved(self):
        events = native_events("I aligned the camera and reduced its volume.")
        events[2:2] = [{"type": "item.completed", "item": {"type": "error", "message": "Code Mode disabled"}},
            {"type": "item.started", "item": {"id": "1", "type": "mcp_tool_call", "server": "framethrower", "tool": "inspect_editor", "arguments": {"document_id": "doc-original"}}},
            {"type": "item.completed", "item": {"id": "1", "type": "mcp_tool_call", "server": "framethrower", "tool": "inspect_editor", "result": {"revision": "r2"}}},
            {"type": "item.completed", "item": {"id": "2", "type": "mcp_tool_call", "server": "framethrower", "tool": "apply_edits", "result": {"applied": True}}}]
        self.configure(events=events)
        result = self.run_turn()
        self.assertNotIn("error", result)
        self.assertEqual(result["events"], events)
        self.assertEqual(result["text"], "I aligned the camera and reduced its volume.")
    def test_native_identity_callback_precedes_tools_and_keeps_internal_search_compaction(self):
        native = native_events()
        native[2:2] = [{"type": "item.completed", "item": {"type": "tool_search", "query": "camera"}},
            {"type": "item.completed", "item": {"type": "context_compaction"}},
            {"type": "thread.compacted"}]
        self.configure(events=native)
        identities = []
        self.config["on_session_id"] = identities.append
        result = self.run_turn()
        self.assertNotIn("error", result)
        self.assertEqual(identities, [SESSION])
        self.assertEqual(result["events"], native)
        self.config["native_session_id"] = SESSION
        result = self.run_turn()
        self.assertNotIn("error", result)
        self.assertEqual(identities, [SESSION, SESSION])
        def cannot_persist(_): raise OSError("private fixture")
        self.config["on_session_id"] = cannot_persist
        result = self.run_turn()
        self.assertEqual(result["error"]["code"], "session_persistence")
        self.assertEqual(result["native_session_id"], SESSION)
        self.assertEqual(result["events"], [native[0]], "callback failure prevents accepting subsequent native effects")

    def test_official_tool_isolation_config_native_mcp_only(self):
        with patch.dict(os.environ, {"OPENAI_API_KEY": "must-not-pass", "CODEX_API_KEY": "must-not-pass", "CODEX_HOME": "/native-cli-auth-location"}):
            result = self.run_turn()
        self.assertNotIn("error", result)
        call = self.captured()[0]
        overrides = [call["argv"][i + 1] for i, value in enumerate(call["argv"]) if value == "-c"]
        self.assertEqual(call["pgid"], os.getpgrp(), "CLI inherits broker process group")
        self.assertIn('sandbox_mode="read-only"', overrides)
        self.assertIn('approval_policy="never"', overrides)
        self.assertIn('web_search="disabled"', overrides)
        self.assertIn('agents.enabled=false', overrides)
        for feature in agent.DISABLED_FEATURES:
            self.assertIn("features." + feature + "=false", overrides)
        self.assertIn('features.code_mode={enabled=true}', overrides)
        self.assertIn('features.code_mode_host={enabled=true,disable_in_process_fallback=true}', overrides)
        self.assertNotIn('features.code_mode_host=false', overrides)
        self.assertNotIn('features.code_mode_only=false', overrides)
        mcp = next(value for value in overrides if value.startswith("mcp_servers="))
        self.assertIn("{framethrower={", mcp)
        self.assertIn("required=true", mcp)
        self.assertIn('"--socket"', mcp)
        self.assertIn('"--document-id","doc-original"', mcp)
        self.assertIn('default_tools_approval_mode="prompt"', mcp)
        self.assertIn('enabled_tools=' + agent.serialize(agent.MCP_TOOLS), mcp)
        self.assertEqual(len(agent.MCP_TOOLS), 8)
        for name in agent.MCP_TOOLS:
            self.assertIn(name + '={approval_mode="approve"}', mcp)
        self.assertEqual(call["env"]["CODEX_HOME"], "/native-cli-auth-location")
        self.assertIsNone(call["env"]["OPENAI_API_KEY"])
        self.assertIsNone(call["env"]["CODEX_API_KEY"])
        instructions = self.cwd / "codex-director-instructions.txt"
        self.assertEqual(instructions.stat().st_mode & 0o777, 0o600)
        self.assertIn("Use native MCP tools directly", instructions.read_text())
    def test_captured_fail_closed_native_runtime_is_not_successful_prose(self):
        events = native_events("I could not access the editor controls, so no changes were made.")
        events.insert(1, {"type": "item.completed", "item": {"id": "runtime-warning", "type": "error", "message":
            "Code Mode is unavailable because code-mode host is disabled. Code mode will fail closed; enable `features.code_mode_host` and install `codex-code-mode-host`."}})
        self.configure(events=events)
        result = self.run_turn()
        self.assertEqual(result["error"]["code"], "tool_runtime_unavailable")
        self.assertEqual(result["native_session_id"], SESSION)
        self.assertEqual(result["events"], events[:2])
        self.assertFalse(result["text"], "startup failure is detected before accepting ordinary final prose")

    def test_captured_cli_approval_gate_is_infrastructure_failure(self):
        events = native_events("I could not apply the edit because the editor blocked it.")
        failed = {"type": "item.completed", "item": {"type": "mcp_tool_call", "server": "framethrower", "tool": "apply_edits",
            "arguments": {"document_id": "doc-original", "commands": [{"action": "mutate", "mutation": {
                "operation": "cameraOverlay", "patch": {"fullscreen": 1}, "timing": {"start": 9, "end": 11, "transition": "smooth"}}}]},
            "result": None, "error": {"message": "MCP tool call requires approval, but approval policy is never"}, "status": "failed"}}
        events.insert(2, failed)
        self.configure(events=events)
        result = self.run_turn()
        self.assertEqual(result["error"]["code"], "mcp_approval_unavailable")
        self.assertEqual(result["native_session_id"], SESSION)
        self.assertIn(failed, result["events"])
        self.assertFalse(result["text"], "do not accept final editing prose after native approval failure")

    def test_domain_conflict_stays_an_actual_tool_result(self):
        events = native_events("Choose Existing or Proposed in the timeline.")
        domain = {"type": "item.completed", "item": {"type": "mcp_tool_call", "server": "framethrower", "tool": "apply_edits",
            "result": {"structured_content": {"ok": False, "error": {"code": "framing_conflict"}, "proposal": {"id": "frozen"}}, "isError": True},
            "error": None, "status": "completed"}}
        events.insert(2, domain)
        self.configure(events=events)
        result = self.run_turn()
        self.assertNotIn("error", result)
        self.assertEqual(result["events"], events)
        self.assertEqual(result["text"], "Choose Existing or Proposed in the timeline.")

    def test_unexpected_tools_fail_preserving_native_events(self):
        for item in [{"type": "command_execution", "command": "touch bad"}, {"type": "file_change"},
                {"type": "web_search"}, {"type": "mcp_tool_call", "server": "another-service", "tool": "send"},
                {"type": "mcp_tool_call", "server": "framethrower", "tool": "untrusted_future_tool"}]:
            with self.subTest(item=item):
                events = native_events()
                events.insert(2, {"type": "item.started", "item": item})
                self.configure(events=events)
                result = self.run_turn()
                self.assertEqual(result["error"]["code"], "isolation")
                self.assertEqual(result["native_session_id"], SESSION)
                self.assertIn(events[2], result["events"])
    def test_native_failure_retains_partial_applied_call_and_id(self):
        events = native_events()[:2] + [{"type": "item.completed", "item": {
            "type": "mcp_tool_call", "server": "framethrower", "tool": "apply_edits", "result": {"applied": True}}},
            {"type": "turn.failed", "error": {"message": "usage limit reached"}}]
        self.configure(events=events, exit=1)
        result = self.run_turn()
        self.assertEqual(result["error"]["code"], "rate_limited")
        self.assertEqual(result["native_session_id"], SESSION)
        self.assertEqual(result["events"], events)
        self.assertEqual(len(self.captured()), 1, "never auto-retry an actual mutation")
    def test_truncated_or_mismatched_native_sessions_rejected(self):
        self.configure(events=native_events()[:-1])
        self.assertEqual(self.run_turn()["error"]["code"], "incomplete_turn")
        self.config["native_session_id"] = SESSION
        self.configure(events=native_events(session=OTHER))
        result = self.run_turn()
        self.assertEqual(result["error"]["code"], "session_mismatch")
        self.assertEqual(result["native_session_id"], SESSION)
    def test_model_cannot_inject_cli_options(self):
        self.config["model"] = "--dangerously-bypass-approvals-and-sandbox"
        self.assertEqual(self.run_turn()["error"]["code"], "configuration")
        self.assertFalse((self.cwd / "requests.jsonl").exists())

    def test_scope_bootstrap_and_private_paths_rejected_before_spawn(self):
        self.config["native_session_id"] = "--last"
        self.assertEqual(self.run_turn()["error"]["code"], "invalid_session")
        self.config["native_session_id"] = SESSION
        self.assertEqual(self.run_turn(bootstrap_context={"state": "not re-injected"})["error"]["code"], "invalid_request")
        self.config["native_session_id"] = None
        self.config["cli"] = "codex"
        self.assertEqual(self.run_turn()["error"]["code"], "configuration")
        self.assertFalse((self.cwd / "requests.jsonl").exists())
    def test_input_is_not_silently_trimmed_and_instructions_not_overwritten(self):
        with patch.object(agent, "MAX_INPUT", 12):
            self.assertEqual(self.run_turn("a" * 13)["error"]["code"], "input_limit")
        path = self.cwd / "codex-director-instructions.txt"
        path.write_text("different instructions")
        path.chmod(0o600)
        self.assertEqual(self.run_turn()["error"]["code"], "configuration")
        self.assertEqual(path.read_text(), "different instructions")
        self.assertFalse((self.cwd / "requests.jsonl").exists())
    def test_timeout_graceful_term_and_descendant_cleanup(self):
        self.configure(events=native_events()[:2], hang=True)
        self.config["timeout"] = 2
        result = self.run_turn()
        self.assertEqual(result["error"]["code"], "timeout")
        self.assertEqual(result["native_session_id"], SESSION)
        self.assertEqual((self.cwd / "term-marker").read_text(), "graceful")
        self.assert_dead(int((self.cwd / "pid").read_text()))
        self.assert_dead(int((self.cwd / "child-pid").read_text()))
    def assert_dead(self, pid):
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline:
            try: os.kill(pid, 0)
            except ProcessLookupError: return
            time.sleep(.01)
        self.fail("owned fake CLI process still alive: %d" % pid)
    def test_sigterm_parent_cleans_own_cli_and_preserves_partial_id(self):
        self.configure(events=native_events()[:2], hang=True)
        driver = "import importlib.util,json,sys;s=importlib.util.spec_from_file_location('native',sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);print(json.dumps(m.run_turn({'text':'test','editor_events':[]},json.loads(sys.argv[2]))),flush=True)"
        process = subprocess.Popen([sys.executable, "-c", driver, str(MODULE), json.dumps(self.config)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 3
            while not (self.cwd / "ready").exists() and time.monotonic() < deadline:
                time.sleep(.01)
            self.assertTrue((self.cwd / "ready").exists(), "fake CLI must reach readiness before parent cancellation")
            process.send_signal(signal.SIGTERM)
            output, error = process.communicate(timeout=3)
            self.assertEqual(process.returncode, 0, error)
            result = json.loads(output)
            self.assertEqual(result["error"]["code"], "cancelled")
            self.assertEqual(result["native_session_id"], SESSION)
            self.assertEqual((self.cwd / "term-marker").read_text(), "graceful")
            self.assert_dead(int((self.cwd / "pid").read_text()))
            self.assert_dead(int((self.cwd / "child-pid").read_text()))
        finally:
            if process.poll() is None: process.kill()
            process.communicate(timeout=2)
    def test_invalid_stream_and_finite_limits(self):
        self.configure(raw='{"type":"turn.completed","type":"error"}\n')
        self.assertEqual(self.run_turn()["error"]["code"], "invalid_output")
        self.configure(events=native_events())
        self.config["timeout"] = float("nan")
        self.assertEqual(self.run_turn()["error"]["code"], "configuration")
        result = agent.run_turn({}, None)
        self.assertEqual(result["error"]["code"], "configuration")


if __name__ == "__main__":
    unittest.main()
