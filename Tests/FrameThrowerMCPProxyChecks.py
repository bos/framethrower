#!/usr/bin/env python3
"""No GUI: synthetic local Unix peers, subprocess pipes, temporary paths only."""
import importlib.util
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import sys
import tempfile
import threading
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "Tools/framethrower-mcp.py"
spec = importlib.util.spec_from_file_location("proxy", SCRIPT)
proxy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proxy)


class ProxyChecks(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="ft-mcp-", dir="/tmp")
        self.path = str(Path(self.directory.name) / "control.sock")

    def tearDown(self):
        self.directory.cleanup()

    def listener(self):
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(self.path)
        os.chmod(self.path, 0o600)
        listener.listen(2)
        listener.settimeout(3)
        self.addCleanup(listener.close)
        return listener

    def test_unavailable_actionable_no_stdout(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "--socket", self.path], capture_output=True, timeout=3)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, b"")
        self.assertIn("Open FrameThrower normally", json.loads(result.stderr)["error"]["message"])

    def test_symlinks_and_modes_refused(self):
        target = Path(self.directory.name) / "sentinel"
        target.write_text("keep")
        os.symlink(target, self.path)
        with self.assertRaises(proxy.ProxyError):
            proxy.connect(self.path)
        self.assertEqual(target.read_text(), "keep")
        os.unlink(self.path)
        self.listener()
        os.chmod(self.path, 0o666)
        with self.assertRaises(proxy.ProxyError):
            proxy.connect(self.path)
        os.chmod(self.path, 0o600)
        os.chmod(self.directory.name, 0o755)
        with self.assertRaises(proxy.ProxyError):
            proxy.connect(self.path)
        os.chmod(self.directory.name, 0o700)

    def test_bidirectional_preserves_messages_eof_only_closes_client(self):
        listener = self.listener()
        seen, closed = [], threading.Event()
        def serve():
            connection, _ = listener.accept()
            with connection:
                stream = connection.makefile("rb")
                try:
                    for line in stream:
                        seen.append(line)
                        message = json.loads(line)
                        if "id" in message:
                            connection.sendall(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": {"value": "vector only"}}).encode() + b"\n")
                finally:
                    stream.close()
            closed.set()
        thread = threading.Thread(target=serve, daemon=True); thread.start()
        process = subprocess.Popen([sys.executable, str(SCRIPT), "--socket", self.path], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(lambda: process.kill() if process.poll() is None else None)
        request = b'{"jsonrpc":"2.0","id":"a","method":"ping"}\n'
        process.stdin.write(request[:8]); process.stdin.flush()
        process.stdin.write(request[8:]); process.stdin.flush()
        self.assertTrue(select.select([process.stdout], [], [], 2)[0])
        self.assertEqual(json.loads(process.stdout.readline())["id"], "a")
        notification = b'{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"a"}}\n'
        process.stdin.write(notification); process.stdin.flush()
        # Send another request as a barrier, so EOF cannot discard unsent input.
        process.stdin.write(b'{"jsonrpc":"2.0","id":2,"method":"ping"}\n'); process.stdin.flush()
        self.assertTrue(select.select([process.stdout], [], [], 2)[0])
        self.assertEqual(json.loads(process.stdout.readline())["id"], 2)
        process.stdin.close(); process.wait(timeout=2)
        self.assertEqual(process.returncode, 0)
        self.assertTrue(closed.wait(1))
        self.assertEqual(seen[:2], [request, notification])
        self.assertTrue(Path(self.path).exists())  # proxy never removes app socket
        self.assertEqual(process.stderr.read(), b"")
        process.stdout.close(); process.stderr.close()

    def test_line_and_partial_bounds(self):
        lines = proxy.Lines()
        with self.assertRaises(proxy.ProxyError):
            lines.feed(b"x" * (proxy.MAX_LINE + 1))
        lines = proxy.Lines(); self.assertEqual(lines.feed(b'{"x":'), b"")
        with self.assertRaises(proxy.ProxyError):
            lines.check(lines.since + proxy.IO_TIMEOUT + 1)
        lines = proxy.Lines(); lines.feed(b"old")
        lines.since -= proxy.IO_TIMEOUT - 0.01
        self.assertEqual(lines.feed(b"\nnew"), b"old\n")
        lines.check(lines.since + 0.01)  # new partial has its own deadline


if __name__ == "__main__":
    unittest.main()
